#!/usr/bin/env python3
"""Convert a TSBS pseudo-CSV stream into database-loadable CSV files.

TSBS emits one tag row followed by one measurement row for every point.  The
native ClickHouse loader in this checkout targets an old MergeTree syntax, so
the local harness keeps the TSBS generator as the source of truth and emits
portable CSV files which can be loaded by both MatrixOne and current
ClickHouse versions.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import functools
import gzip
import hashlib
import json
import pathlib
import re
import sys
from typing import Dict, Iterable, List, TextIO, Tuple


IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
TYPE_MAP = {
    "string": ("VARCHAR(255)", "String"),
    "float32": ("FLOAT", "Nullable(Float32)"),
    "float64": ("DOUBLE", "Nullable(Float64)"),
    "int32": ("INT", "Nullable(Int32)"),
    "int64": ("BIGINT", "Nullable(Int64)"),
}


def quote_identifier(name: str) -> str:
    if not IDENTIFIER.match(name):
        raise ValueError(f"unsafe identifier in TSBS header: {name!r}")
    return f"`{name}`"


def parse_typed_name(token: str) -> Tuple[str, str]:
    try:
        name, typ = token.rsplit(" ", 1)
    except ValueError as exc:
        raise ValueError(f"invalid typed tag header {token!r}") from exc
    if typ not in TYPE_MAP:
        raise ValueError(f"unsupported TSBS tag type {typ!r}")
    if not IDENTIFIER.match(name):
        raise ValueError(f"unsafe tag identifier {name!r}")
    return name, typ


def read_header(reader: Iterable[List[str]]) -> Tuple[List[str], List[str], Dict[str, List[str]]]:
    iterator = iter(reader)
    try:
        first = next(iterator)
    except StopIteration as exc:
        raise ValueError("TSBS input is empty") from exc
    if not first or first[0] != "tags":
        raise ValueError("TSBS input must start with a tags header")
    tag_defs = [parse_typed_name(item) for item in first[1:]]
    if not tag_defs:
        raise ValueError("TSBS input has no tag columns")

    metric_defs: Dict[str, List[str]] = {}
    for row in iterator:
        if not row:
            break
        if len(row) < 2:
            raise ValueError(f"invalid metric header: {row!r}")
        table = row[0]
        if not IDENTIFIER.match(table):
            raise ValueError(f"unsafe metric table identifier {table!r}")
        fields = row[1:]
        if not fields or any(not IDENTIFIER.match(field) for field in fields):
            raise ValueError(f"invalid metric fields for {table!r}")
        metric_defs[table] = fields
    if not metric_defs:
        raise ValueError("TSBS input has no metric tables")
    return [name for name, _ in tag_defs], [typ for _, typ in tag_defs], metric_defs


@functools.lru_cache(maxsize=131072)
def timestamp_text(raw: str) -> Tuple[str, str, str]:
    """Return date, DATETIME(6), and ClickHouse DateTime64(6) text."""
    nanos = int(raw)
    seconds, remainder = divmod(nanos, 1_000_000_000)
    timestamp = dt.datetime.fromtimestamp(seconds, tz=dt.timezone.utc).replace(
        microsecond=remainder // 1_000
    )
    text = timestamp.strftime("%Y-%m-%d %H:%M:%S.%f")
    return timestamp.date().isoformat(), text, text


def null_or_value(raw: str) -> str:
    # LOAD DATA and ClickHouse CSV both use \\N as the NULL marker.  Empty
    # metric values are how TSBS represents a missing metric.
    return r"\N" if raw == "" else raw


def write_matrixone_schema(
    path: pathlib.Path,
    db_name: str,
    tag_names: List[str],
    tag_types: List[str],
    metric_defs: Dict[str, List[str]],
) -> None:
    db = quote_identifier(db_name)
    lines = [f"DROP DATABASE IF EXISTS {db};", f"CREATE DATABASE {db};", f"USE {db};", ""]
    # IoT intentionally emits missing tag values.  Keep the tag columns
    # nullable so those rows can be loaded instead of being rejected by the
    # target database.
    tag_columns = [f"{quote_identifier(name)} {TYPE_MAP[typ][0]} NULL" for name, typ in zip(tag_names, tag_types)]
    lines.append(
        "CREATE TABLE `tags` (\n"
        "  `id` BIGINT NOT NULL,\n"
        + ",\n".join(f"  {column}" for column in tag_columns)
        + ",\n  PRIMARY KEY (`id`)\n);"
    )
    for table, fields in metric_defs.items():
        field_columns = [f"  {quote_identifier(field)} DOUBLE" for field in fields]
        lines.append(
            f"CREATE TABLE {quote_identifier(table)} (\n"
            "  `created_date` DATE NOT NULL,\n"
            "  `created_at` DATETIME(6) NOT NULL,\n"
            "  `event_time` DATETIME(6) NOT NULL,\n"
            "  `tags_id` BIGINT NOT NULL,\n"
            "  `additional_tags` VARCHAR(4096),\n"
            + ",\n".join(field_columns)
            + ",\n  PRIMARY KEY (`tags_id`, `created_at`)\n);"
        )
    path.write_text("\n\n".join(lines) + "\n", encoding="utf-8")


def write_clickhouse_schema(
    path: pathlib.Path,
    db_name: str,
    tag_names: List[str],
    tag_types: List[str],
    metric_defs: Dict[str, List[str]],
) -> None:
    db = quote_identifier(db_name)
    lines = [f"DROP DATABASE IF EXISTS {db};", f"CREATE DATABASE {db};", f"USE {db};", ""]
    tag_columns = []
    for name, typ in zip(tag_names, tag_types):
        clickhouse_type = TYPE_MAP[typ][1]
        if not clickhouse_type.startswith("Nullable("):
            clickhouse_type = f"Nullable({clickhouse_type})"
        tag_columns.append(f"{quote_identifier(name)} {clickhouse_type}")
    lines.append(
        "CREATE TABLE `tags` (\n"
        "  `id` UInt64,\n"
        + ",\n".join(f"  {column}" for column in tag_columns)
        + "\n) ENGINE = MergeTree ORDER BY (`id`);"
    )
    for table, fields in metric_defs.items():
        field_columns = [f"  {quote_identifier(field)} Nullable(Float64)" for field in fields]
        lines.append(
            f"CREATE TABLE {quote_identifier(table)} (\n"
            "  `created_date` Date,\n"
            "  `created_at` DateTime64(6),\n"
            "  `event_time` DateTime64(6),\n"
            "  `tags_id` UInt64,\n"
            "  `additional_tags` String,\n"
            + ",\n".join(field_columns)
            + "\n) ENGINE = MergeTree ORDER BY (`tags_id`, `created_at`);"
        )
    path.write_text("\n\n".join(lines) + "\n", encoding="utf-8")


def convert(source: pathlib.Path, output: pathlib.Path, force: bool) -> None:
    if output.exists() and any(output.iterdir()) and not force:
        raise SystemExit(f"output directory is not empty: {output}; use --force to rebuild")
    output.mkdir(parents=True, exist_ok=True)
    for child in output.iterdir():
        if child.is_file():
            child.unlink()
        elif child.is_dir():
            raise SystemExit(f"refusing to remove existing directory {child}; choose a new output path")

    source_hash = hashlib.sha256()
    metric_rows: Dict[str, int] = {}
    metric_values: Dict[str, int] = {}
    tagset_to_id: Dict[Tuple[str, ...], int] = {}
    tag_names: List[str]
    tag_types: List[str]
    metric_defs: Dict[str, List[str]]
    metric_files: Dict[str, TextIO] = {}
    metric_writers: Dict[str, csv.writer] = {}
    tags_path = output / "tags.csv"

    def open_source() -> TextIO:
        if source.name.endswith(".gz"):
            return gzip.open(source, "rt", encoding="utf-8", newline="")
        return source.open("r", encoding="utf-8", newline="")

    with open_source() as raw:
        # Hash the compressed source separately from parsing so metadata can
        # prove which deterministic input produced the prepared files.
        with source.open("rb") as binary:
            for chunk in iter(lambda: binary.read(1024 * 1024), b""):
                source_hash.update(chunk)
        reader = csv.reader(raw)
        tag_names, tag_types, metric_defs = read_header(reader)
        tags_file = tags_path.open("w", encoding="utf-8", newline="")
        tags_writer = csv.writer(tags_file, lineterminator="\n")
        for record in reader:
            if not record:
                continue
            if record[0] != "tags":
                raise ValueError(f"expected a tags row, got {record[0]!r}")
            if len(record) < len(tag_names) + 1:
                raise ValueError("tags row has fewer values than the header")
            values: List[str] = []
            for item in record[1:]:
                if "=" not in item:
                    raise ValueError(f"invalid tag assignment {item!r}")
                values.append(item.split("=", 1)[1])
            common_values = values[: len(tag_names)]
            tagset = tuple(common_values)
            if tagset not in tagset_to_id:
                tagset_to_id[tagset] = len(tagset_to_id) + 1
                tags_writer.writerow(
                    [tagset_to_id[tagset], *(r"\N" if value == "" else value for value in common_values)]
                )

            try:
                measurement = next(reader)
            except StopIteration as exc:
                raise ValueError("tags row is missing its measurement row") from exc
            if len(measurement) < 2:
                raise ValueError(f"invalid measurement row: {measurement!r}")
            table = measurement[0]
            if table not in metric_defs:
                raise ValueError(f"measurement {table!r} is absent from the header")
            timestamp = measurement[1]
            date_text, datetime_text, event_text = timestamp_text(timestamp)
            fields = measurement[2:]
            expected_fields = len(metric_defs[table])
            if len(fields) != expected_fields:
                raise ValueError(
                    f"measurement {table!r} has {len(fields)} fields, expected {expected_fields}"
                )
            if table not in metric_writers:
                metric_files[table] = (output / f"{table}.csv").open("w", encoding="utf-8", newline="")
                metric_writers[table] = csv.writer(metric_files[table], lineterminator="\n")
            extras = values[len(tag_names) :]
            extra_text = ";".join(extras) if extras else ""
            row = [date_text, datetime_text, event_text, tagset_to_id[tagset], extra_text]
            row.extend(null_or_value(value) for value in fields)
            metric_writers[table].writerow(row)
            metric_rows[table] = metric_rows.get(table, 0) + 1
            metric_values[table] = metric_values.get(table, 0) + sum(value != "" for value in fields)

    tags_file.close()
    for file in metric_files.values():
        file.close()
    write_matrixone_schema(output / "schema_matrixone.sql", "tsbs_matrixone", tag_names, tag_types, metric_defs)
    write_clickhouse_schema(output / "schema_clickhouse.sql", "tsbs_clickhouse", tag_names, tag_types, metric_defs)
    metadata = {
        "source": str(source.resolve()),
        "source_sha256": source_hash.hexdigest(),
        "tag_columns": [{"name": name, "type": typ} for name, typ in zip(tag_names, tag_types)],
        "metric_tables": {
            table: {"fields": fields, "rows": metric_rows.get(table, 0), "values": metric_values.get(table, 0)}
            for table, fields in metric_defs.items()
        },
        "hosts": len(tagset_to_id),
    }
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(metadata, indent=2))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=pathlib.Path, required=True, help="TSBS pseudo-CSV or .gz source")
    parser.add_argument("--output", type=pathlib.Path, required=True, help="prepared output directory")
    parser.add_argument("--force", action="store_true", help="rebuild files in an existing output directory")
    args = parser.parse_args()
    try:
        convert(args.source, args.output, args.force)
    except (OSError, ValueError) as exc:
        print(f"prepare_data: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
