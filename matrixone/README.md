# Local TSBS MatrixOne / ClickHouse test

This directory contains a local adapter for the TSBS `cpu-only`, `devops`, and
`iot` use cases.  It keeps TSBS as the deterministic data generator, and loads
the same prepared rows into MatrixOne through its MySQL protocol and into a
current ClickHouse server through the native client.  The repository's historical
`tsbs_load_clickhouse` DDL uses deprecated MergeTree syntax, so the adapter
generates modern DDL instead of modifying the upstream benchmark semantics.

## Layout

- `prepare_data.py` converts a TSBS pseudo-CSV (`.dat` or `.dat.gz`) to
  `tags.csv`, one CSV per metric table, `metadata.json`, and modern DDL for both
  databases.
- `queries_matrixone.tsv` and `queries_clickhouse.tsv` contain the five
  `cpu-only` queries.  `queries_{devops,iot}_{matrixone,clickhouse}.tsv`
  contain equivalent query shapes for the other two use cases.
- `run_benchmark.sh` recreates the dedicated test database, bulk loads the
  prepared CSV files, records load/query timings, and writes row counts/results.
  The `USE_CASE` variable selects the query set and isolates the database name.
- `validate_results.py` normalizes timestamp fractions and numeric formatting,
  then compares the ordered result sets from both engines.  It allows small
  floating-point aggregate differences and checks repeated results when more
  than one repetition is requested.
- `run_local.sh` runs preparation (if needed), all selected database tests, and
  result validation sequentially.

The source tree and benchmark artifacts are separate. By default the scripts
retain their historical locations below `TSBS_ROOT`, but every path can be
overridden through environment variables:

| Variable | Meaning | Default |
|---|---|---|
| `TSBS_ROOT` | TSBS source tree and scripts | repository root |
| `TSBS_DATA_ROOT` | One dataset directory containing source archives and `prepared-*` | `TSBS_ROOT/data/baseline-scale100-1d` |
| `TSBS_QUERY_ROOT` | Generic TSBS query archive directory | `/tmp/bulk_queries` |
| `TSBS_RESULT_ROOT` | Result base directory | `TSBS_ROOT/results` |
| `TSBS_LOG_ROOT` | Log base directory | `TSBS_ROOT/logs` |

`DATA_ROOT`, `BULK_DATA_DIR`, `RESULT_ROOT`, and `LOG_ROOT` remain supported as
backwards-compatible per-script overrides. The source archive is never
modified by preparation.

`benchmark_profiles/tsbs_external_paths.env.example` is a ready-to-copy
template for these variables and the three database endpoints. Keep credentials
in the shell environment or a machine-local file, not in a committed profile.

## Build TSBS tools

The host Go installation used on the test machine has conflicting standard
library files.  Build the required TSBS binaries in the preinstalled Go
container, using the host module cache:

```bash
cd /mnt/fastdata/tsbs
mkdir -p bin
docker run --rm \
  -v /mnt/fastdata/tsbs:/src \
  -v /home/pengzhen/go/pkg/mod:/go/pkg/mod \
  -w /src matrixorigin/golang:1.26.4-ubuntu22.04 bash -lc '
    export GOMODCACHE=/go/pkg/mod GOPROXY=file:///go/pkg/mod/cache/download GOSUMDB=off
    go build -buildvcs=false -o bin/tsbs_generate_data ./cmd/tsbs_generate_data
    go build -buildvcs=false -o bin/tsbs_generate_queries ./cmd/tsbs_generate_queries
    go build -buildvcs=false -o bin/tsbs_load_clickhouse ./cmd/tsbs_load_clickhouse
    go build -buildvcs=false -o bin/tsbs_load_influx ./cmd/tsbs_load_influx
    go build -buildvcs=false -o bin/tsbs_run_queries_clickhouse ./cmd/tsbs_run_queries_clickhouse
    go build -buildvcs=false -o bin/tsbs_run_queries_influx ./cmd/tsbs_run_queries_influx
  '
```

## Generate deterministic data

The checked baseline uses 100 hosts/trucks for one day at a 10-second interval.
Set `TSBS_DATA_ROOT` to the directory where the generated sources should live;
it may be outside this repository. Each source has a corresponding `prepared-*`
directory. For example, generate the `cpu-only` source with:

```bash
export TSBS_DATA_ROOT=/data/tsbs-data/baseline-scale100-1d
mkdir -p "$TSBS_DATA_ROOT"
bin/tsbs_generate_data \
  --format clickhouse --use-case cpu-only --scale 100 \
  --timestamp-start 2026-01-01T00:00:00Z \
  --timestamp-end 2026-01-02T00:00:00Z \
  --log-interval 10s --seed 123 --max-data-points 0 \
  | gzip -c > "$TSBS_DATA_ROOT/clickhouse_cpu-only_scale100_1d_10s_seed123.dat.gz"

python3 matrixone/prepare_data.py \
  --source "$TSBS_DATA_ROOT/clickhouse_cpu-only_scale100_1d_10s_seed123.dat.gz" \
  --output "$TSBS_DATA_ROOT/prepared-cpu-only"
```

Use `--use-case devops` or `--use-case iot` to generate the other sources.
IoT intentionally contains missing and out-of-order entries; the converter
keeps missing tag values as NULL and maps each distinct tag set to an ID so
metric primary keys remain unique.

## Start the local ClickHouse server

The tested machine already has a ClickHouse image and binary.  The dedicated
container below uses only the TSBS runtime directories and ports 9000/8123:

```bash
mkdir -p runtime/clickhouse-main/data runtime/clickhouse-main/logs
docker run -d --name tsbs-clickhouse-main \
  --ulimit nofile=262144:262144 \
  -e CLICKHOUSE_USER=tsbs -e CLICKHOUSE_PASSWORD=tsbs \
  -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 \
  -p 9000:9000 -p 8123:8123 \
  -v /mnt/fastdata/tsbs/runtime/clickhouse-main/data:/var/lib/clickhouse \
  -v /mnt/fastdata/tsbs/runtime/clickhouse-main/logs:/var/log/clickhouse-server \
  63a3278e83e1
```

Wait until this succeeds:

```bash
/mnt/fastdata/clickhouse client --host 127.0.0.1 --port 9000 \
  --user tsbs --password tsbs --query 'SELECT version()'
```

MatrixOne is expected at `127.0.0.1:6001` with `root/111`; override
`MO_HOST`, `MO_PORT`, `MO_USER`, and `MO_PASSWORD` if needed.  Override
ClickHouse connection variables with `CH_HOST`, `CH_PORT`, `CH_USER`, and
`CH_PASSWORD`.

## Run both engines

```bash
cd /mnt/fastdata/tsbs
TSBS_DATA_ROOT=/data/tsbs-data/baseline-scale100-1d \
TSBS_RESULT_ROOT=/data/tsbs-results \
TSBS_LOG_ROOT=/data/tsbs-logs \
QUERY_REPEATS=1 USE_CASES='cpu-only devops iot' \
  matrixone/run_local.sh
```

The run is sequential for each use case: MatrixOne is loaded and queried, then
ClickHouse is loaded and queried.  `${TSBS_RESULT_ROOT}/tsbs_local/<use-case>/`
contains load timing tables, per-query timing summaries, row counts, and TSV
result sets. `${TSBS_LOG_ROOT}/tsbs_local/<use-case>/` contains database load
logs and per-query stderr. With the defaults these resolve to
`TSBS_ROOT/results` and `TSBS_ROOT/logs`.
Validation fails if a query errors, a deterministic row count is wrong, or the
normalized MatrixOne and ClickHouse result sets differ.  To run one use case,
set `USE_CASES='iot'`.

## Observed local run

Environment: MatrixOne `8.0.30-MatrixOne-v1.3.0` on `127.0.0.1:6001`,
ClickHouse `25.12.3.21` in the dedicated container.  The one-repetition
baseline completed successfully for all 15 queries:

| Use case | MatrixOne rows | ClickHouse rows | MatrixOne load | ClickHouse load |
|---|---:|---:|---:|---:|
| cpu-only | 864,000 | 864,000 | 2.87 s | 0.91 s |
| devops (9 tables) | 7,776,000 | 7,776,000 | 28.02 s | 7.78 s |
| iot (2 tables) | 1,554,681 | 1,554,681 | 3.93 s | 1.51 s |

All result row counts and ordered result sets matched after timestamp, NULL, and
floating-point normalization.  The IoT dataset has 883 distinct observed tag
sets because the workload intentionally clears tags on some entries; this is
recorded in its `metadata.json`.

These are local smoke/compatibility measurements, not a published throughput
benchmark: each query is launched through a command-line client, and this
single-node setup is not tuned for either engine.

## TSBS reference-scale comparison

The formal comparison profile is kept separate from the smoke baseline. Keep
its source and prepared data outside the repository by setting
`TSBS_DATA_ROOT`:

```text
scale=4000
timestamp-start=2026-01-01T00:00:00Z
timestamp-end=2026-01-04T00:00:00Z
log-interval=10s
seed=123
query timestamp end=2026-01-04T00:00:01Z
query count=1000 (TSBS reference; the adapter's cross-engine smoke set has 5 query shapes)
query repeats=3
```

The reproducible environment values are in
`benchmark_profiles/tsbs_reference_scale4000_3d_10s.env`. The generated
source and prepared data use the directory named by `TSBS_DATA_ROOT`, and the six query files with
the matching three-day window are named
`queries_<use-case>_<database>_scale4000_3d_10s_seed123.tsv`.

To regenerate the three source archives with exactly these parameters:

```bash
cd /mnt/fastdata/tsbs
source matrixone/benchmark_profiles/tsbs_reference_scale4000_3d_10s.env
export TSBS_DATA_ROOT=/data/tsbs-data/tsbs-reference-scale4000-3d-10s-seed123
mkdir -p "$TSBS_DATA_ROOT"
for use_case in cpu-only devops iot; do
  bin/tsbs_generate_data --format clickhouse --use-case "$use_case" \
    --scale "$TSBS_SCALE" --timestamp-start "$TSBS_TIMESTAMP_START" \
    --timestamp-end "$TSBS_TIMESTAMP_END" --log-interval "$TSBS_LOG_INTERVAL" \
    --seed "$TSBS_SEED" --max-data-points 0 \
    | gzip -c > "$TSBS_DATA_ROOT/clickhouse_${use_case}_${TSBS_DATASET_ID}.dat.gz"
done
```

Prepare each archive before running the comparison:

```bash
for use_case in cpu-only devops iot; do
  python3 matrixone/prepare_data.py \
    --source "$TSBS_DATA_ROOT/clickhouse_${use_case}_${TSBS_DATASET_ID}.dat.gz" \
    --output "$TSBS_DATA_ROOT/prepared-${use_case}"
done
```

After the data has been generated and prepared, run the three use cases in
sequence with:

```bash
cd /mnt/fastdata/tsbs
source matrixone/benchmark_profiles/tsbs_reference_scale4000_3d_10s.env
TSBS_DATA_ROOT=/data/tsbs-data/tsbs-reference-scale4000-3d-10s-seed123 \
TSBS_RESULT_ROOT=/data/tsbs-results \
TSBS_LOG_ROOT=/data/tsbs-logs \
  matrixone/run_local.sh
```

The run keeps the scale=100 results and databases separate by using a profile
specific result directory and database suffix. The query
validator derives the expected CPU hourly cardinalities from the profile's
72-hour window. This remains a single-node comparison; collect resource
usage and physical database sizes separately before treating it as a full
throughput benchmark.

## Run the upstream ClickHouse and InfluxDB scripts with external artifacts

The generic TSBS scripts use the same artifact contract. Set
`TSBS_DATA_ROOT` for generated/load archives and `TSBS_QUERY_ROOT` for query
archives; `BULK_DATA_DIR` and explicit `DATA_FILE` still take precedence when
an existing command requires them. Results from the ClickHouse and InfluxDB
query wrappers can be placed in `TSBS_RESULT_ROOT` instead of beside the input
query files.

```bash
export TSBS_DATA_ROOT=/data/tsbs-data/scale4000_3d_10s_seed123
export TSBS_QUERY_ROOT=/data/tsbs-queries/scale4000_3d_10s_seed123
export TSBS_RESULT_ROOT=/data/tsbs-results/scale4000_3d_10s_seed123

# Load an InfluxDB archive.
TSBS_DATA_ROOT="$TSBS_DATA_ROOT" \
  scripts/load/load_influx.sh

# Run generated InfluxDB queries against a selected endpoint.
INFLUX_URL=http://127.0.0.1:8086 \
TSBS_QUERY_ROOT="$TSBS_QUERY_ROOT" \
TSBS_RESULT_ROOT="$TSBS_RESULT_ROOT/influx" \
  scripts/run_queries/run_queries_influx.sh

# Run generated ClickHouse queries against a selected endpoint.
DATABASE_HOST=127.0.0.1 DATABASE_PORT=9000 \
TSBS_QUERY_ROOT="$TSBS_QUERY_ROOT" \
TSBS_RESULT_ROOT="$TSBS_RESULT_ROOT/clickhouse" \
  scripts/run_queries/run_queries_clickhouse.sh
```

The custom MatrixOne/ClickHouse adapter uses prepared CSV under
`TSBS_DATA_ROOT`; the upstream InfluxDB loader consumes its native Influx
archive from the same root. These formats are intentionally not converted
implicitly, so generate or transfer the format required by each loader.
