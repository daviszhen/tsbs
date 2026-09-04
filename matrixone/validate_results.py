#!/usr/bin/env python3
"""Validate the local MatrixOne and ClickHouse TSBS query results.

The query files use equivalent SQL rather than byte-for-byte identical SQL
(date truncation has different function names).  This validator normalizes
numeric text and zero-valued timestamp fractions, then compares each ordered
result set and checks the expected cardinality of the deterministic queries.
"""

from __future__ import annotations

import argparse
import decimal
import math
import pathlib
import re
import sys
from typing import Iterable, List, Sequence


TIMESTAMP_ZERO_FRACTION = re.compile(r"^(.*)\.0+$")
CPU_EXPECTED_ROWS = {
    "q1_hourly_max": 24,
    "q2_host_hourly_avg": 2400,
    "q4_last_point_per_host": 100,
    "q5_recent_minute_max": 5,
}


def normalize_cell(value: str) -> str:
    value = value.strip()
    if value == r"\N":
        return "NULL"
    match = TIMESTAMP_ZERO_FRACTION.match(value)
    if match and "-" in value and ":" in value:
        value = match.group(1)
    try:
        number = decimal.Decimal(value)
    except decimal.InvalidOperation:
        return value
    if number.is_finite():
        return format(number.normalize(), "f")
    return value


def cells_equal(left: str, right: str) -> bool:
    """Compare text exactly, allowing normal floating-point aggregate noise."""
    if left == right:
        return True
    try:
        left_number = float(left)
        right_number = float(right)
    except ValueError:
        return False
    if not (math.isfinite(left_number) and math.isfinite(right_number)):
        return False
    return math.isclose(left_number, right_number, rel_tol=1e-9, abs_tol=1e-9)


def rows_equal(left_rows: Sequence[Sequence[str]], right_rows: Sequence[Sequence[str]]) -> bool:
    if len(left_rows) != len(right_rows):
        return False
    return all(
        len(left_row) == len(right_row)
        and all(cells_equal(left_cell, right_cell) for left_cell, right_cell in zip(left_row, right_row))
        for left_row, right_row in zip(left_rows, right_rows)
    )


def read_rows(path: pathlib.Path) -> List[List[str]]:
    rows: List[List[str]] = []
    with path.open(encoding="utf-8") as stream:
        for line in stream:
            line = line.rstrip("\n\r")
            if line:
                rows.append([normalize_cell(cell) for cell in line.split("\t")])
    return rows


def compare(label: str, left: pathlib.Path, right: pathlib.Path, expected_rows: dict[str, int]) -> bool:
    left_rows = read_rows(left)
    right_rows = read_rows(right)
    expected = expected_rows.get(label)
    if expected is not None and len(left_rows) != expected:
        print(f"{label}: MatrixOne returned {len(left_rows)} rows, expected {expected}")
        return False
    if label == "q3_high_cpu" and not left_rows:
        print("q3_high_cpu: expected at least one high-CPU row")
        return False
    if len(left_rows) != len(right_rows):
        print(f"{label}: row count differs ({len(left_rows)} vs {len(right_rows)})")
        return False
    for index, (left_row, right_row) in enumerate(zip(left_rows, right_rows), 1):
        if len(left_row) != len(right_row) or any(
            not cells_equal(left_cell, right_cell)
            for left_cell, right_cell in zip(left_row, right_row)
        ):
            print(f"{label}: row {index} differs")
            print(f"  MatrixOne: {left_row}")
            print(f"  ClickHouse: {right_row}")
            return False
    print(f"{label}: {len(left_rows)} rows match")
    return True


def labels_from_directory(matrixone_dir: pathlib.Path) -> Iterable[str]:
    marker = "matrixone_"
    suffix = "_r1.tsv"
    for path in sorted(matrixone_dir.glob(f"{marker}*{suffix}")):
        name = path.name[len(marker) : -len(suffix)]
        if name:
            yield name


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--results", type=pathlib.Path, required=True)
    parser.add_argument("--use-case", choices=("cpu-only", "devops", "iot"), default="cpu-only")
    parser.add_argument("--expected-hours", type=int, default=24)
    args = parser.parse_args()
    all_ok = True
    labels = list(labels_from_directory(args.results))
    if not labels:
        print(f"no MatrixOne result files found in {args.results}", file=sys.stderr)
        return 1
    expected_rows = {}
    if args.use_case == "cpu-only":
        tag_count = None
        row_count_file = args.results / "matrixone_row_counts.tsv"
        if row_count_file.exists():
            for line in row_count_file.read_text(encoding="utf-8").splitlines()[1:]:
                fields = line.split("\t")
                if len(fields) == 2 and fields[0] == "tags":
                    tag_count = int(fields[1])
                    break
        if tag_count is None:
            tag_count = 100
        expected_rows = {
            "q1_hourly_max": args.expected_hours,
            "q2_host_hourly_avg": tag_count * args.expected_hours,
            "q4_last_point_per_host": tag_count,
            "q5_recent_minute_max": 5,
        }
    for label in labels:
        left = args.results / f"matrixone_{label}_r1.tsv"
        right = args.results / f"clickhouse_{label}_r1.tsv"
        if not right.exists():
            print(f"{label}: missing ClickHouse result {right}")
            all_ok = False
            continue
        all_ok = compare(label, left, right, expected_rows) and all_ok

        # A repeated query must return the same ordered rows.  This catches
        # accidental dependence on engine state in addition to the cross-engine
        # comparison above.
        first_rows = read_rows(left)
        for repeat in sorted(args.results.glob(f"matrixone_{label}_r*.tsv")):
            if repeat.name == left.name:
                continue
            if not rows_equal(read_rows(repeat), first_rows):
                print(f"{label}: MatrixOne repeat differs in {repeat.name}")
                all_ok = False
        first_rows = read_rows(right)
        for repeat in sorted(args.results.glob(f"clickhouse_{label}_r*.tsv")):
            if repeat.name == right.name:
                continue
            if not rows_equal(read_rows(repeat), first_rows):
                print(f"{label}: ClickHouse repeat differs in {repeat.name}")
                all_ok = False
    return 0 if all_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
