# Time Series Benchmark Suite (TSBS)
This repo contains code for benchmarking several time series databases,
including TimescaleDB, MongoDB, InfluxDB, CrateDB and Cassandra.
This code is based on a fork of work initially made public by InfluxDB
at https://github.com/influxdata/influxdb-comparisons.

Current databases supported:

+ Akumuli [(supplemental docs)](docs/akumuli.md)
+ Cassandra [(supplemental docs)](docs/cassandra.md)
+ ClickHouse [(supplemental docs)](docs/clickhouse.md)
+ CrateDB [(supplemental docs)](docs/cratedb.md)
+ InfluxDB [(supplemental docs)](docs/influx.md)
+ MongoDB [(supplemental docs)](docs/mongo.md)
+ QuestDB [(supplemental docs)](docs/questdb.md)
+ SiriDB [(supplemental docs)](docs/siridb.md)
+ TimescaleDB [(supplemental docs)](docs/timescaledb.md)
+ Timestream [(supplemental docs)](docs/timestream.md)
+ VictoriaMetrics [(supplemental docs)](docs/victoriametrics.md)

For a local MatrixOne-versus-ClickHouse run using the deterministic TSBS
`cpu-only` workload, see [`matrixone/README.md`](matrixone/README.md).  The
adapter uses the TSBS generator and portable prepared CSV while keeping the
database-specific load and query paths separate.

## External benchmark artifacts

Benchmark data and generated query archives do not need to live in the source
tree. The scripts accept these environment variables (the old
`BULK_DATA_DIR`/`DATA_ROOT` names remain compatible):

```bash
export TSBS_ROOT=/mnt/fastdata/tsbs
export TSBS_DATA_ROOT=/data/tsbs-data/scale4000_3d_10s_seed123
export TSBS_QUERY_ROOT=/data/tsbs-queries/scale4000_3d_10s_seed123
export TSBS_RESULT_ROOT=/data/tsbs-results/scale4000_3d_10s_seed123
export TSBS_LOG_ROOT=/data/tsbs-logs/scale4000_3d_10s_seed123
```

`TSBS_DATA_ROOT` is used by data generation, generic loaders, and the local
MatrixOne/ClickHouse adapter. `TSBS_QUERY_ROOT` is used by query generation and
the ClickHouse/InfluxDB query wrappers. `TSBS_RESULT_ROOT` controls query
outputs, while the local adapter uses `TSBS_LOG_ROOT` for stderr and load logs.
The defaults preserve the historical `/tmp/bulk_data`, `/tmp/bulk_queries`, and
repository-local result locations.

## MatrixOne, ClickHouse, and InfluxDB: separate test procedures

The three databases use different input formats. Do not feed a ClickHouse
archive to the InfluxDB loader, or an InfluxDB line-protocol archive to the
MatrixOne adapter:

| Database | Test entry point | Input artifact |
|---|---|---|
| MatrixOne | `matrixone/run_benchmark.sh matrixone` | ClickHouse-format TSBS archive, converted to prepared CSV |
| ClickHouse | `matrixone/run_benchmark.sh clickhouse` | The same prepared CSV as MatrixOne |
| InfluxDB | `scripts/load/load_influx.sh` and `scripts/run_queries/run_queries_influx.sh` | Native InfluxDB TSBS archive |

The custom MatrixOne/ClickHouse adapter is intended for a reproducible
cross-engine comparison. The upstream InfluxDB scripts are kept separate
because InfluxDB has a different line-protocol format.

### 1. Common environment

Run this once in the shell that will execute the benchmark. The data, query,
result, and log roots are examples and can be changed independently. The
`TSBS_DATA_ROOT` value below is the exact dataset directory, not the source
checkout:

```bash
set -euo pipefail

export TSBS_ROOT=/mnt/fastdata/tsbs
export DATASET_ID=scale4000_3d_10s_seed123
export TSBS_DATASET_ID="$DATASET_ID"

# Artifacts outside the source tree.
export TSBS_DATA_ROOT=/data1/pengzhen/tsbs_data/${DATASET_ID}
export TSBS_QUERY_ROOT=/data1/pengzhen/tsbs_queries/${DATASET_ID}
export TSBS_RESULT_ROOT=/data1/pengzhen/tsbs_results/${DATASET_ID}
export TSBS_LOG_ROOT=/data1/pengzhen/tsbs_logs/${DATASET_ID}
export DB_NAME_SUFFIX="_${DATASET_ID}"

# Deterministic TSBS generation parameters.
export SCALE=4000
export SEED=123
export TS_START=2026-01-01T00:00:00Z
export TS_END=2026-01-04T00:00:00Z
export QUERY_TS_END=2026-01-04T00:00:01Z
export LOG_INTERVAL=10s
export QUERY_REPEATS=3

mkdir -p "$TSBS_DATA_ROOT" "$TSBS_QUERY_ROOT" \
  "$TSBS_RESULT_ROOT" "$TSBS_LOG_ROOT"
```

The equivalent formal profile can be sourced before overriding the four path
variables:

```bash
set -euo pipefail
source "$TSBS_ROOT/matrixone/benchmark_profiles/tsbs_reference_scale4000_3d_10s.env"
export TSBS_DATA_ROOT=/data1/pengzhen/tsbs_data/tsbs-reference-scale4000-3d-10s-seed123
export TSBS_QUERY_ROOT=/data1/pengzhen/tsbs_queries/tsbs-reference-scale4000-3d-10s-seed123
export TSBS_RESULT_ROOT=/data1/pengzhen/tsbs_results/tsbs-reference-scale4000-3d-10s-seed123
export TSBS_LOG_ROOT=/data1/pengzhen/tsbs_logs/tsbs-reference-scale4000-3d-10s-seed123

# Aliases consumed by the standalone commands below.
export DATASET_ID="$TSBS_DATASET_ID"
export SCALE="$TSBS_SCALE"
export SEED="$TSBS_SEED"
export TS_START="$TSBS_TIMESTAMP_START"
export TS_END="$TSBS_TIMESTAMP_END"
export QUERY_TS_END="$TSBS_QUERY_TIMESTAMP_END"
export LOG_INTERVAL="$TSBS_LOG_INTERVAL"
export DB_NAME_SUFFIX="$TSBS_DB_NAME_SUFFIX"
export QUERY_REPEATS="${QUERY_REPEATS:-3}"
mkdir -p "$TSBS_DATA_ROOT" "$TSBS_QUERY_ROOT" \
  "$TSBS_RESULT_ROOT" "$TSBS_LOG_ROOT"
```

The five cross-engine comparison queries are the checked-in SQL TSV files in
`matrixone/` (one file per database and use case).  The generic TSBS query
archives generated later in this section are a separate, 1,000-query-per-shape
workload for the upstream database runners; they are not silently substituted
for the five-query MatrixOne/ClickHouse comparison set.  The adapter reads each
TSV from top to bottom: Q1 through Q5 are executed sequentially, and each query
is repeated `QUERY_REPEATS` times with no concurrent query workers.

Build the binaries used by the upstream ClickHouse/InfluxDB scripts if they
are not already present:

```bash
cd "$TSBS_ROOT"
docker run --rm \
  -v "$TSBS_ROOT:/src" \
  -v /home/pengzhen/go/pkg/mod:/go/pkg/mod \
  -w /src matrixorigin/golang:1.26.4-ubuntu22.04 bash -lc '
    export GOMODCACHE=/go/pkg/mod
    export GOPROXY=file:///go/pkg/mod/cache/download GOSUMDB=off
    go build -buildvcs=false -o bin/tsbs_generate_data ./cmd/tsbs_generate_data
    go build -buildvcs=false -o bin/tsbs_generate_queries ./cmd/tsbs_generate_queries
    go build -buildvcs=false -o bin/tsbs_load_clickhouse ./cmd/tsbs_load_clickhouse
    go build -buildvcs=false -o bin/tsbs_load_influx ./cmd/tsbs_load_influx
    go build -buildvcs=false -o bin/tsbs_run_queries_clickhouse ./cmd/tsbs_run_queries_clickhouse
    go build -buildvcs=false -o bin/tsbs_run_queries_influx ./cmd/tsbs_run_queries_influx
  '
```

### 2. Generate or verify external data

The MatrixOne/ClickHouse adapter requires one ClickHouse-format archive per use
case. Generate only the archive that is missing; existing archives are not
overwritten by this command unless the output path is explicitly reused:

```bash
cd "$TSBS_ROOT"
for use_case in cpu-only devops iot; do
  output="$TSBS_DATA_ROOT/clickhouse_${use_case}_${DATASET_ID}.dat.gz"
  if [[ ! -f "$output" ]]; then
    partial="${output}.partial.$$"
    if ! bin/tsbs_generate_data \
        --format clickhouse --use-case "$use_case" --scale "$SCALE" \
        --timestamp-start "$TS_START" --timestamp-end "$TS_END" \
        --log-interval "$LOG_INTERVAL" --seed "$SEED" --max-data-points 0 \
        | gzip -c > "$partial"; then
      rm -f "$partial"
      exit 1
    fi
    mv "$partial" "$output"
  fi
done
```

InfluxDB needs a separate native archive. Keep it in the same external data
directory or in a separate directory and pass the exact file with `DATA_FILE`:

```bash
for use_case in cpu-only devops iot; do
  output="$TSBS_DATA_ROOT/influx_${use_case}_${DATASET_ID}.dat.gz"
  if [[ ! -f "$output" ]]; then
    partial="${output}.partial.$$"
    if ! bin/tsbs_generate_data \
        --format influx --use-case "$use_case" --scale "$SCALE" \
        --timestamp-start "$TS_START" --timestamp-end "$TS_END" \
        --log-interval "$LOG_INTERVAL" --seed "$SEED" --max-data-points 0 \
        | gzip -c > "$partial"; then
      rm -f "$partial"
      exit 1
    fi
    mv "$partial" "$output"
  fi
done
```

Check the external files before loading:

```bash
find "$TSBS_DATA_ROOT" -maxdepth 1 -type f -name '*.dat.gz' -printf '%f %s bytes\n' | sort
```

To reuse an archive generated on another host, copy it into the external data
root; do not copy it into the source checkout and do not delete the source
archive after the copy:

```bash
rsync -aH --partial --info=progress2 \
  /source/tsbs-data/scale4000_3d_10s_seed123/ \
  "$TSBS_DATA_ROOT/"
```

After a partial transfer, remove only the explicitly named `*.partial` files
before retrying.  The benchmark scripts never remove the source archives.

The loaders do not modify these archives. MatrixOne preparation writes only
to `prepared-<use-case>` below `TSBS_DATA_ROOT`:

```bash
cd "$TSBS_ROOT"
for use_case in cpu-only devops iot; do
  source_file="$TSBS_DATA_ROOT/clickhouse_${use_case}_${DATASET_ID}.dat.gz"
  prepared_dir="$TSBS_DATA_ROOT/prepared-${use_case}"
  if [[ ! -f "$prepared_dir/metadata.json" ]]; then
    python3 matrixone/prepare_data.py \
      --source "$source_file" --output "$prepared_dir"
  fi
done
```

### 3. Test MatrixOne only

MatrixOne must be running and reachable through its MySQL protocol.  If it is
already managed by a service or a test harness, skip the start block.  For a
local binary, the following is a complete example; adjust `MO_ROOT` and the
launch file for the installation being tested:

```bash
export MO_ROOT=/mnt/fastdata/matrixone
export MO_SERVICE="$MO_ROOT/mo-service"
export MO_LAUNCH="$MO_ROOT/etc/launch/launch.toml"
export MO_SERVICE_LOG="$TSBS_LOG_ROOT/matrixone/service.log"
mkdir -p "$(dirname "$MO_SERVICE_LOG")"

cd "$MO_ROOT"
nohup env LD_LIBRARY_PATH="$MO_ROOT/cgo:$MO_ROOT/thirdparties/install/lib:${LD_LIBRARY_PATH:-}" \
  "$MO_SERVICE" -launch "$MO_LAUNCH" >"$MO_SERVICE_LOG" 2>&1 &
```

Configure the endpoint and the MySQL client explicitly, then wait for the
same endpoint that the benchmark will use:

```bash
export MO_HOST=127.0.0.1
export MO_PORT=6001
export MO_USER=root
export MO_PASSWORD=111
export MYSQL_BIN=mysql

until "$MYSQL_BIN" --protocol=tcp -h"$MO_HOST" -P"$MO_PORT" -u"$MO_USER" \
  --connect-timeout=3 -p"$MO_PASSWORD" -e 'SELECT 1' >/dev/null 2>&1; do
  sleep 1
done
"$MYSQL_BIN" --protocol=tcp -h"$MO_HOST" -P"$MO_PORT" -u"$MO_USER" \
  --connect-timeout=10 -p"$MO_PASSWORD" -e 'SELECT VERSION()'
```

Do not put a password in a committed profile.  `MO_PASSWORD` may instead be
provided through a protected shell environment or `MYSQL_PWD`.

Run one use case at a time. This command creates/recreates the dedicated
benchmark database `tsbs_matrixone_<use-case>_scale4000_3d_10s_seed123`, loads
the prepared CSV, checks row counts, and executes the five adapter queries for
each requested repetition:

```bash
export USE_CASE=cpu-only
export PREPARED_DIR="$TSBS_DATA_ROOT/prepared-${USE_CASE}"
export QUERY_FILE="$TSBS_ROOT/matrixone/queries_${USE_CASE}_matrixone_${DATASET_ID}.tsv"
export RESULT_ROOT="$TSBS_RESULT_ROOT/matrixone/${USE_CASE}"
export LOG_ROOT="$TSBS_LOG_ROOT/matrixone/${USE_CASE}"

cd "$TSBS_ROOT"
TSBS_ROOT="$TSBS_ROOT" \
TSBS_DATA_ROOT="$TSBS_DATA_ROOT" \
USE_CASE="$USE_CASE" PREPARED_DIR="$PREPARED_DIR" \
QUERY_FILE="$QUERY_FILE" RESULT_ROOT="$RESULT_ROOT" LOG_ROOT="$LOG_ROOT" \
DB_NAME_SUFFIX="$DB_NAME_SUFFIX" \
MO_HOST="$MO_HOST" MO_PORT="$MO_PORT" MO_USER="$MO_USER" \
MO_PASSWORD="$MO_PASSWORD" MYSQL_BIN="$MYSQL_BIN" \
  bash matrixone/run_benchmark.sh matrixone --query-repeats "$QUERY_REPEATS"
```

Run `USE_CASE=devops` or `USE_CASE=iot` in separate invocations. To rerun
queries without reloading data, add `--skip-load` while retaining the same
`PREPARED_DIR`, `RESULT_ROOT`, `LOG_ROOT`, and `QUERY_FILE` values:

```bash
USE_CASE=cpu-only PREPARED_DIR="$TSBS_DATA_ROOT/prepared-cpu-only" \
QUERY_FILE="$TSBS_ROOT/matrixone/queries_cpu-only_matrixone_${DATASET_ID}.tsv" \
RESULT_ROOT="$TSBS_RESULT_ROOT/matrixone/cpu-only-rerun" \
LOG_ROOT="$TSBS_LOG_ROOT/matrixone/cpu-only-rerun" \
  bash "$TSBS_ROOT/matrixone/run_benchmark.sh" matrixone \
    --skip-load --query-repeats 3
```

Outputs are written to `RESULT_ROOT`:

- `matrixone_load.tsv`: schema, tags, metric, and total load time;
- `matrixone_row_counts.tsv`: row counts for tags and metric tables;
- `matrixone_summary.tsv`: per-query latency and row count;
- `matrixone_<query>_r<n>.tsv`: query result sets.

Errors and client stderr are written below `LOG_ROOT`.

### 4. Test ClickHouse only

The custom ClickHouse test uses the same prepared CSV as the MatrixOne test,
so no second data conversion is needed. Configure the native ClickHouse
endpoint and client.  If ClickHouse is not already managed by systemd, this is
the reproducible container setup used by the local harness (the image must be
the pinned image approved for the comparison; record its server version below):

```bash
export CH_CONTAINER=tsbs-clickhouse
export CH_IMAGE=63a3278e83e1
export CH_DATA_DIR=/data1/pengzhen/clickhouse-data
export CH_LOG_DIR=/data1/pengzhen/clickhouse-logs
mkdir -p "$CH_DATA_DIR" "$CH_LOG_DIR"

if ! docker inspect "$CH_CONTAINER" >/dev/null 2>&1; then
  docker run -d --name "$CH_CONTAINER" \
    --ulimit nofile=262144:262144 \
    -e CLICKHOUSE_USER=tsbs -e CLICKHOUSE_PASSWORD=tsbs \
    -e CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 \
    -p 9000:9000 -p 8123:8123 \
    -v "$CH_DATA_DIR:/var/lib/clickhouse" \
    -v "$CH_LOG_DIR:/var/log/clickhouse-server" \
    "$CH_IMAGE"
else
  docker start "$CH_CONTAINER" >/dev/null || true
fi
```

Configure the endpoint and client, and record the actual version before
comparing results:

```bash
export CH_HOST=127.0.0.1
export CH_PORT=9000
export CH_USER=tsbs
export CH_PASSWORD=tsbs
export CLICKHOUSE_BIN=/mnt/fastdata/clickhouse

until "$CLICKHOUSE_BIN" client --host "$CH_HOST" --port "$CH_PORT" \
  --user "$CH_USER" --password "$CH_PASSWORD" --query 'SELECT 1' >/dev/null 2>&1; do
  sleep 1
done
"$CLICKHOUSE_BIN" client --host "$CH_HOST" --port "$CH_PORT" \
  --user "$CH_USER" --password "$CH_PASSWORD" --query 'SELECT version()'
```

Run the ClickHouse adapter independently for one use case:

```bash
export USE_CASE=cpu-only
export PREPARED_DIR="$TSBS_DATA_ROOT/prepared-${USE_CASE}"
export QUERY_FILE="$TSBS_ROOT/matrixone/queries_${USE_CASE}_clickhouse_${DATASET_ID}.tsv"
export RESULT_ROOT="$TSBS_RESULT_ROOT/clickhouse/${USE_CASE}"
export LOG_ROOT="$TSBS_LOG_ROOT/clickhouse/${USE_CASE}"

cd "$TSBS_ROOT"
TSBS_ROOT="$TSBS_ROOT" \
TSBS_DATA_ROOT="$TSBS_DATA_ROOT" \
USE_CASE="$USE_CASE" PREPARED_DIR="$PREPARED_DIR" \
QUERY_FILE="$QUERY_FILE" RESULT_ROOT="$RESULT_ROOT" LOG_ROOT="$LOG_ROOT" \
DB_NAME_SUFFIX="$DB_NAME_SUFFIX" \
CH_HOST="$CH_HOST" CH_PORT="$CH_PORT" CH_USER="$CH_USER" \
CH_PASSWORD="$CH_PASSWORD" CLICKHOUSE_BIN="$CLICKHOUSE_BIN" \
  bash matrixone/run_benchmark.sh clickhouse --query-repeats "$QUERY_REPEATS"
```

For the upstream ClickHouse format instead of the custom adapter, use the
generic scripts and pass the exact archive and database name.  Generate the
native ClickHouse query archives first (this does not modify the data archive):

```bash
cd "$TSBS_ROOT"
TSBS_QUERY_ROOT="$TSBS_QUERY_ROOT" \
BULK_DATA_DIR="$TSBS_QUERY_ROOT" FORMATS=clickhouse USE_CASE="$USE_CASE" \
SCALE="$SCALE" SEED="$SEED" TS_START="$TS_START" \
TS_END="$QUERY_TS_END" QUERIES=1000 \
  scripts/generate_queries.sh
```

Then load and run the generated files:

```bash
export DATA_FILE="$TSBS_DATA_ROOT/clickhouse_${USE_CASE}_${DATASET_ID}.dat.gz"
export DATABASE_NAME="tsbs_clickhouse_${USE_CASE//-/_}_${DATASET_ID}"
export DATABASE_HOST="$CH_HOST"
export DATABASE_PORT="$CH_PORT"
export DATABASE_USER="$CH_USER"
export DATABASE_PASSWORD="$CH_PASSWORD"
export EXE_FILE_NAME="$TSBS_ROOT/bin/tsbs_load_clickhouse"
export NUM_WORKERS=16
export BATCH_SIZE=10000

cd "$TSBS_ROOT"
EXE_FILE_NAME="$EXE_FILE_NAME" DATA_FILE="$DATA_FILE" \
DATABASE_NAME="$DATABASE_NAME" DATABASE_HOST="$DATABASE_HOST" \
DATABASE_PORT="$DATABASE_PORT" DATABASE_USER="$DATABASE_USER" \
DATABASE_PASSWORD="$DATABASE_PASSWORD" NUM_WORKERS="$NUM_WORKERS" \
BATCH_SIZE="$BATCH_SIZE" scripts/load/load_clickhouse.sh

mapfile -t CH_QUERY_FILES < <(
  find "$TSBS_QUERY_ROOT" -maxdepth 1 -type f \
    -name "queries_clickhouse_*_${USE_CASE}.dat.gz" -print | sort
)
[[ ${#CH_QUERY_FILES[@]} -gt 0 ]] || {
  echo "no ClickHouse query archives found for ${USE_CASE}" >&2
  exit 1
}
EXE_FILE_NAME="$TSBS_ROOT/bin/tsbs_run_queries_clickhouse" \
TSBS_QUERY_ROOT="$TSBS_QUERY_ROOT" \
TSBS_RESULT_ROOT="$TSBS_RESULT_ROOT/clickhouse-upstream/${USE_CASE}" \
DATABASE_NAME="$DATABASE_NAME" DATABASE_HOST="$DATABASE_HOST" \
DATABASE_PORT="$DATABASE_PORT" DATABASE_USER="$DATABASE_USER" \
DATABASE_PASSWORD="$DATABASE_PASSWORD" MAX_QUERIES=1000 NUM_WORKERS=1 \
  scripts/run_queries/run_queries_clickhouse.sh "${CH_QUERY_FILES[@]}"
```

The custom adapter is preferred for MatrixOne-versus-ClickHouse result
comparison. The upstream loader/query runner is useful when comparing TSBS's
native ClickHouse path with other TSBS database targets.

### 5. Test InfluxDB only

Start or verify InfluxDB 1.x at the configured HTTP endpoint. The following
example keeps the InfluxDB storage outside the TSBS checkout.  If a container
with this name already exists, start it instead of creating a second one:

```bash
export INFLUX_URL=http://127.0.0.1:8086
export INFLUX_DATA_DIR=/data1/pengzhen/influxdb-data
mkdir -p "$INFLUX_DATA_DIR"

if ! docker inspect tsbs-influxdb-1.8 >/dev/null 2>&1; then
  docker run -d --name tsbs-influxdb-1.8 \
    -p 8086:8086 \
    -v "$INFLUX_DATA_DIR:/var/lib/influxdb" \
    influxdb:1.8.10
else
  docker start tsbs-influxdb-1.8 >/dev/null || true
fi

until curl -fsS "$INFLUX_URL/ping" >/dev/null; do
  sleep 1
done
curl -fsSI "$INFLUX_URL/ping"
```

Load one native InfluxDB archive. `DATA_FILE` takes precedence over
`TSBS_DATA_ROOT`, which avoids relying on the short `influx-data.gz` symlink:

```bash
export USE_CASE=cpu-only
export DATABASE_NAME="tsbs_influx_${USE_CASE//-/_}_${DATASET_ID}"
export DATA_FILE="$TSBS_DATA_ROOT/influx_${USE_CASE}_${DATASET_ID}.dat.gz"
export EXE_FILE_NAME="$TSBS_ROOT/bin/tsbs_load_influx"
export DATABASE_HOST=127.0.0.1
export DATABASE_PORT=8086
export NUM_WORKERS=16
export BATCH_SIZE=10000
export BACKOFF_SECS=1s
export REPORTING_PERIOD=10s

cd "$TSBS_ROOT"
EXE_FILE_NAME="$EXE_FILE_NAME" DATA_FILE="$DATA_FILE" \
DATABASE_NAME="$DATABASE_NAME" DATABASE_HOST="$DATABASE_HOST" \
DATABASE_PORT="$DATABASE_PORT" INFLUX_URL="$INFLUX_URL" \
NUM_WORKERS="$NUM_WORKERS" BATCH_SIZE="$BATCH_SIZE" \
BACKOFF_SECS="$BACKOFF_SECS" REPORTING_PERIOD="$REPORTING_PERIOD" \
  scripts/load/load_influx.sh \
  2>&1 | tee "$TSBS_LOG_ROOT/influx-${USE_CASE}-load.log"
```

Generate native InfluxDB query archives if they are not already available:

```bash
cd "$TSBS_ROOT"
TSBS_QUERY_ROOT="$TSBS_QUERY_ROOT" \
BULK_DATA_DIR="$TSBS_QUERY_ROOT" FORMATS=influx USE_CASE="$USE_CASE" \
SCALE="$SCALE" SEED="$SEED" TS_START="$TS_START" \
TS_END="$QUERY_TS_END" QUERIES=1000 \
  scripts/generate_queries.sh
```

Run the query archive against the same database and write results outside the
query directory:

```bash
mapfile -t INFLUX_QUERY_FILES < <(
  find "$TSBS_QUERY_ROOT" -maxdepth 1 -type f \
    -name "queries_influx_*_${USE_CASE}.dat.gz" -print | sort
)
[[ ${#INFLUX_QUERY_FILES[@]} -gt 0 ]] || {
  echo "no InfluxDB query archives found for ${USE_CASE}" >&2
  exit 1
}
EXE_FILE_NAME="$TSBS_ROOT/bin/tsbs_run_queries_influx" \
TSBS_QUERY_ROOT="$TSBS_QUERY_ROOT" \
TSBS_RESULT_ROOT="$TSBS_RESULT_ROOT/influx/${USE_CASE}" \
DATABASE_NAME="$DATABASE_NAME" INFLUX_URL="$INFLUX_URL" \
MAX_QUERIES=1000 NUM_WORKERS=1 \
  scripts/run_queries/run_queries_influx.sh \
  "${INFLUX_QUERY_FILES[@]}" 2>&1 \
  | tee "$TSBS_LOG_ROOT/influx-${USE_CASE}-queries.log"
```

The query archive names contain the query shape, generator version, count,
scale, seed, time range, and use case.  The `find` patterns therefore select
all generated shapes for the selected use case without depending on a short
symlink.  The wrapper passes `--db-name` and `--urls` to
`tsbs_run_queries_influx`, so the query database and endpoint match the load
command.

InfluxDB loading drops the configured benchmark database before loading. Use a
dedicated `DATABASE_NAME`; the external archive and query files themselves are
not deleted or modified.

### 6. Results and cleanup

For separate runs, keep the following layout:

```text
/mnt/fastdata/tsbs/                         # source checkout and scripts
/data1/pengzhen/tsbs_data/<dataset>/         # archives and prepared CSV
/data1/pengzhen/tsbs_queries/<dataset>/      # generated query archives
/data1/pengzhen/tsbs_results/<dataset>/      # result TSV/summary files
/data1/pengzhen/tsbs_logs/<dataset>/         # load/query logs
```

Do not remove the external data root after a test if the dataset will be
reused. The custom MatrixOne/ClickHouse runner only recreates its benchmark
database; the InfluxDB loader only drops its configured benchmark database.
Use `--skip-load` for query-only reruns when the database is still available.

## Overview

The **Time Series Benchmark Suite (TSBS)** is a collection of Go
programs that are used to generate datasets and then benchmark read
and write performance of various databases. The intent is to make the
TSBS extensible so that a variety of use cases (e.g., devops, IoT,
finance, etc.), query types, and databases can be included and benchmarked.
To this end we hope to help prospective database administrators find the
best database for their needs and their workloads. Further, if you
are the developer of a time series database and want to include your
database in the TSBS, feel free to open a pull request to add it!

## Current use cases

Currently, TSBS supports two use cases.

### Dev ops
A 'dev ops' use case, which comes in two forms. The full form is used to
generate, insert, and measure data from 9 'systems' that could be monitored
in a real world dev ops scenario (e.g., CPU, memory, disk, etc).
Together, these 9 systems generate 100 metrics per reading interval.
The alternate form focuses solely on CPU metrics for a simpler, more
streamlined use case. This use case generates 10 CPU metrics per reading.

In addition to metric readings, 'tags' (including the location
of the host, its operating system, etc) are generated for each host
with readings in the dataset. Each unique set of tags identifies
one host in the dataset and the number of different hosts generated is
defined by the `scale` flag (see below).

### Internet of Things (IoT)
The second use case is meant to simulate the data load in an IoT
environment. This use case simulates data streaming from a set of trucks
belonging to a fictional trucking company. This use case simulates
diagnostic data and metrics from each truck, and introduces environmental
factors such as out-of-order data and batch ingestion (for trucks
that are offline for a period of time). It also tracks truck metadata
and uses this to tie metrics and diagnostics together as part of the query
set.  

The queries that are generated as part of this use case will cover both real
time truck status and analytics that will look at the time series data in
an effort to be more predictive about truck behavior.  The scale factor with
this use case will be based on the number of trucks tracked.  

---

Not all databases implement all use cases. This table below shows which use
cases are implemented for each database:

|Database|Dev ops|IoT|
|:---|:---:|:---:|
|Akumuli|X¹||
|Cassandra|X||
|ClickHouse|X||
|CrateDB|X||
|InfluxDB|X|X|
|MongoDB|X|
|QuestDB|X|X
|SiriDB|X|
|TimescaleDB|X|X|
|Timestream|X||
|VictoriaMetrics|X²||

¹ Does not support the `groupby-orderby-limit` query
² Does not support the `groupby-orderby-limit`, `lastpoint`, `high-cpu-1`, `high-cpu-all` queries

## What the TSBS tests

TSBS is used to benchmark bulk load performance and
query execution performance. (It currently does not measure
concurrent insert and query performance, which is a future priority.)
To accomplish this in a fair way, the data to be inserted and the
queries to run are pre-generated and native Go clients are used
wherever possible to connect to each database (e.g., `mgo` for MongoDB, 
`aws sdk` for Timestream).

Although the data is randomly generated, TSBS data and queries are
entirely deterministic. By supplying the same PRNG (pseudo-random number
generator) seed to the generation programs, each database is loaded
with identical data and queried using identical queries.

## Installation

TSBS is a collection of Go programs (with some auxiliary bash and Python
scripts). The easiest way to get and install the Go programs is to use
`go get` and then `make all` to install all binaries:
```bash
# Fetch TSBS and its dependencies
$ go get github.com/timescale/tsbs
$ cd $GOPATH/src/github.com/timescale/tsbs
$ make
```

## How to use TSBS

Using TSBS for benchmarking involves 3 phases: data and query
generation, data loading/insertion, and query execution.

### Data and query generation

So that benchmarking results are not affected by generating data or
queries on-the-fly, with TSBS you generate the data and queries you want
to benchmark first, and then you can (re-)use it as input to the
benchmarking phases.

#### Data generation

Variables needed:
1. a use case. E.g., `iot` (choose from `cpu-only`, `devops`, or `iot`)
1. a PRNG seed for deterministic generation. E.g., `123`
1. the number of devices / trucks to generate for. E.g., `4000`
1. a start time for the data's timestamps. E.g., `2016-01-01T00:00:00Z`
1. an end time. E.g., `2016-01-04T00:00:00Z`
1. how much time should be between each reading per device, in seconds. E.g., `10s`
1. and which database(s) you want to generate for. E.g., `timescaledb`
 (choose from `cassandra`, `clickhouse`, `cratedb`, `influx`, `mongo`, `questdb`, `siridb`,
  `timescaledb` or `victoriametrics`)

Given the above steps you can now generate a dataset (or multiple
datasets, if you chose to generate for multiple databases) that can
be used to benchmark data loading of the database(s) chosen using
the `tsbs_generate_data` tool:
```bash
$ tsbs_generate_data --use-case="iot" --seed=123 --scale=4000 \
    --timestamp-start="2016-01-01T00:00:00Z" \
    --timestamp-end="2016-01-04T00:00:00Z" \
    --log-interval="10s" --format="timescaledb" \
    | gzip > /tmp/timescaledb-data.gz

# Each additional database would be a separate call.
```
_Note: We pipe the output to gzip to reduce on-disk space. This also requires
you to pipe through gunzip when you run your tests._

The example above will generate a pseudo-CSV file that can be used to
bulk load data into TimescaleDB. Each database has it's own format of how
it stores the data to make it easiest for its corresponding loader to
write data. The above configuration will generate just over 100M rows
(1B metrics), which is usually a good starting point.
Increasing the time period by a day will add an additional ~33M rows
so that, e.g., 30 days would yield a billion rows (10B metrics)

##### IoT use case

The main difference between the `iot` use case and other use cases is that
it generates data which can contain out-of-order, missing, or empty
entries to better represent real-life scenarios associated to the use case.
Using a specified seed means that we can do this in a deterministic and
reproducible way for multiple runs of data generation.

#### Query generation

Variables needed:
1. the same use case, seed, # of devices, and start time as used in data generation
1. an end time that is one second after the end time from data generation. E.g., for `2016-01-04T00:00:00Z` use `2016-01-04T00:00:01Z`
1. the number of queries to generate. E.g., `1000`
1. and the type of query you'd like to generate. E.g., `single-groupby-1-1-1` or `last-loc`

For the last step there are numerous queries to choose from, which are
listed in [Appendix I](#appendix-i-query-types). Additionally, the file
`scripts/generate_queries.sh` contains a list of all of them as the
default value for the environmental variable `QUERY_TYPES`. If you are
generating more than one type of query, we recommend you use the
helper script.

For generating just one set of queries for a given type:
```bash
$ tsbs_generate_queries --use-case="iot" --seed=123 --scale=4000 \
    --timestamp-start="2016-01-01T00:00:00Z" \
    --timestamp-end="2016-01-04T00:00:01Z" \
    --queries=1000 --query-type="breakdown-frequency" --format="timescaledb" \
    | gzip > /tmp/timescaledb-queries-breakdown-frequency.gz
```
_Note: We pipe the output to gzip to reduce on-disk space. This also requires
you to pipe through gunzip when you run your tests._

For generating sets of queries for multiple types:
```bash
$ FORMATS="timescaledb" SCALE=4000 SEED=123 \
    TS_START="2016-01-01T00:00:00Z" \
    TS_END="2016-01-04T00:00:01Z" \
    QUERIES=1000 QUERY_TYPES="last-loc low-fuel avg-load" \
    BULK_DATA_DIR="/tmp/bulk_queries" scripts/generate_queries.sh
```

A full list of query types can be found in
[Appendix I](#appendix-i-query-types) at the end of this README.

### Benchmarking insert/write performance

TSBS has two ways to benchmark insert/write performance:
* On the fly simulation and load with `tsbs_load`
* Pre-generate data to a file and load it either with `tsbs_load` or the
db specific executables `tsbs_load_*`

#### Using the unified `tsbs_load` executable

The `tsbs_load` executable can load data in any of the supported databases.
It can use a pregenerated data file as input, or simulate the data on the 
fly. 

You first start by generating a config yaml file populated with the default
values for each property with:
```shell script
$ tsbs_load config --target=<db-name> --data-source=[FILE|SIMULATOR]
```
for example, to generate an example for TimescaleDB, loading the data from file
```shell script
$ tsbs_load config --target=timescaledb --data-source=FILE
Wrote example config to: ./config.yaml
```

You can then run tsbs_load with the generated config file with:
```shell script
$ tsbs_load load timescaledb --config=./config.yaml
```

For more details on how to use tsbs_load check out the [supplemental docs](docs/tsbs_load.md)

#### Using the database specific `tsbs_load_*` executables

TSBS measures insert/write performance by taking the data generated in
the previous step and using it as input to a database-specific command
line program. To the extent that insert programs can be shared, we have
made an effort to do that (e.g., the TimescaleDB loader can
be used with a regular PostgreSQL database if desired). Each loader does
share some common flags -- e.g., batch size (number of readings inserted
together), workers (number of concurrently inserting clients), connection
details (host & ports), etc -- but they also have database-specific tuning
flags. To find the flags for a particular database, use the `-help` flag
(e.g., `tsbs_load_timescaledb -help`).

Here's an example of loading data to a remote timescaledb instance with SSL
required, with a gzipped data set as created in the instructions above:

```bash
cat /tmp/timescaledb-data.gz | gunzip | tsbs_load_timescaledb \
--postgres="sslmode=require" --host="my.tsdb.host" --port=5432 --pass="password" \
--user="benchmarkuser" --admin-db-name=defaultdb --workers=8  \
--in-table-partition-tag=true --chunk-time=8h --write-profile= \
--field-index-count=1 --do-create-db=true --force-text-format=false \
--do-abort-on-exist=false
```

For simpler testing, especially locally, we also supply
`scripts/load/load_<database>.sh` for convenience with many of the flags set
to a reasonable default for some of the databases.
So for loading into TimescaleDB, ensure that TimescaleDB is running and
then use:
```bash
# Will insert using 2 clients, batch sizes of 10k, from a file
# named `timescaledb-data.gz` in directory `/tmp`
$ NUM_WORKERS=2 BATCH_SIZE=10000 BULK_DATA_DIR=/tmp \
    scripts/load/load_timescaledb.sh
```

This will create a new database called `benchmark` where the data is
stored. It **will overwrite** the database if it exists; if you don't
want that to happen, supply a different `DATABASE_NAME` to the above
command.

Example for writing to remote host using `load_timescaledb.sh`:
```bash
# Will insert using 2 clients, batch sizes of 10k, from a file
# named `timescaledb-data.gz` in directory `/tmp`
$ NUM_WORKERS=2 BATCH_SIZE=10000 BULK_DATA_DIR=/tmp DATABASE_HOST=remotehostname
DATABASE_USER=user DATABASE \
    scripts/load/load_timescaledb.sh
```

---

By default, statistics about the load performance are printed every 10s,
and when the full dataset is loaded the looks like this:
```text
time,per. metric/s,metric total,overall metric/s,per. row/s,row total,overall row/s
# ...
1518741528,914996.143291,9.652000E+08,1096817.886674,91499.614329,9.652000E+07,109681.788667
1518741548,1345006.018902,9.921000E+08,1102333.152918,134500.601890,9.921000E+07,110233.315292
1518741568,1149999.844750,1.015100E+09,1103369.385320,114999.984475,1.015100E+08,110336.938532

Summary:
loaded 1036800000 metrics in 936.525765sec with 8 workers (mean rate 1107070.449780/sec)
loaded 103680000 rows in 936.525765sec with 8 workers (mean rate 110707.044978/sec)
```

All but the last two lines contain the data in CSV format, with column names in the header. Those column names correspond to:
* timestamp,
* metrics per second in the period,
* total metrics inserted,
* overall metrics per second,
* rows per second in the period,
* total number of rows,
* overall rows per second.

For databases, like Cassandra, that do not use rows when inserting,
the last three values are always empty (indicated with a `-`).

The last two lines are a summary of how many metrics (and rows where
applicable) were inserted, the wall time it took, and the average rate
of insertion.

### Benchmarking query execution performance

To measure query execution performance in TSBS, you first need to load
the data using the previous section and generate the queries as
described earlier. Once the data is loaded and the queries are generated,
just use the corresponding `tsbs_run_queries_` binary for the database
being tested:
```bash
$ cat /tmp/queries/timescaledb-cpu-max-all-eight-hosts-queries.gz | \
    gunzip | tsbs_run_queries_timescaledb --workers=8 \
        --postgres="host=localhost user=postgres sslmode=disable"
```

You can change the value of the `--workers` flag to
control the level of parallel queries run at the same time. The
resulting output will look similar to this:
```text
run complete after 1000 queries with 8 workers:
TimescaleDB max cpu all fields, rand    8 hosts, rand 12hr by 1h:
min:    51.97ms, med:   757.55, mean:  2527.98ms, max: 28188.20ms, stddev:  2843.35ms, sum: 5056.0sec, count: 2000
all queries                                                     :
min:    51.97ms, med:   757.55, mean:  2527.98ms, max: 28188.20ms, stddev:  2843.35ms, sum: 5056.0sec, count: 2000
wall clock time: 633.936415sec
```

The output gives you the description of the query and multiple groupings
of measurements (which may vary depending on the database).

---

For easier testing of multiple queries, we provide
`scripts/generate_run_script.py` which creates a bash script with commands
to run multiple query types in a row. The queries it generates should be
put in a file with one query per line and the path given to the script.
For example, if you had a file named `queries.txt` that looked like this:
```text
last-loc
avg-load
high-load
long-driving-session
```

You could generate a run script named `query_test.sh`:
```bash
# Generate run script for TimescaleDB, using queries in `queries.txt`
# with the generated query files in /tmp/queries for 8 workers
$ python generate_run_script.py -d timescaledb -o /tmp/queries \
    -w 8 -f queries.txt > query_test.sh
```

And the resulting script file would look like:
```bash
#!/bin/bash
# Queries
cat /tmp/queries/timescaledb-last-loc-queries.gz | gunzip | query_benchmarker_timescaledb --workers=8 --limit=1000 --hosts="localhost" --postgres="user=postgres sslmode=disable"  | tee query_timescaledb_timescaledb-last-loc-queries.out

cat /tmp/queries/timescaledb-avg-load-queries.gz | gunzip | query_benchmarker_timescaledb --workers=8 --limit=1000 --hosts="localhost" --postgres="user=postgres sslmode=disable"  | tee query_timescaledb_timescaledb-avg-load-queries.out

cat /tmp/queries/timescaledb-high-load-queries.gz | gunzip | query_benchmarker_timescaledb --workers=8 --limit=1000 --hosts="localhost" --postgres="user=postgres sslmode=disable"  | tee query_timescaledb_timescaledb-high-load-queries.out

cat /tmp/queries/timescaledb-long-driving-session-queries.gz | gunzip | query_benchmarker_timescaledb --workers=8 --limit=1000 --hosts="localhost" --postgres="user=postgres sslmode=disable"  | tee query_timescaledb_timescaledb-long-driving-session-queries.out
```

### Query validation (optional)

Additionally each `tsbs_run_queries_` binary allows you print the
actual query results so that you can compare across databases that the
results are the same. Using the flag `-print-responses` will return
the results.

## Appendix I: Query types <a name="appendix-i-query-types"></a>

### Devops / cpu-only
|Query type|Description|
|:---|:---|
|single-groupby-1-1-1| Simple aggregrate (MAX) on one metric for 1 host, every 5 mins for 1 hour
|single-groupby-1-1-12| Simple aggregrate (MAX) on one metric for 1 host, every 5 mins for 12 hours
|single-groupby-1-8-1| Simple aggregrate (MAX) on one metric for 8 hosts, every 5 mins for 1 hour
|single-groupby-5-1-1| Simple aggregrate (MAX) on 5 metrics for 1 host, every 5 mins for 1 hour
|single-groupby-5-1-12| Simple aggregrate (MAX) on 5 metrics for 1 host, every 5 mins for 12 hours
|single-groupby-5-8-1| Simple aggregrate (MAX) on 5 metrics for 8 hosts, every 5 mins for 1 hour
|cpu-max-all-1| Aggregate across all CPU metrics per hour over 1 hour for a single host
|cpu-max-all-8| Aggregate across all CPU metrics per hour over 1 hour for eight hosts
|double-groupby-1| Aggregate on across both time and host, giving the average of 1 CPU metric per host per hour for 24 hours
|double-groupby-5| Aggregate on across both time and host, giving the average of 5 CPU metrics per host per hour for 24 hours
|double-groupby-all| Aggregate on across both time and host, giving the average of all (10) CPU metrics per host per hour for 24 hours
|high-cpu-all| All the readings where one metric is above a threshold across all hosts
|high-cpu-1| All the readings where one metric is above a threshold for a particular host
|lastpoint| The last reading for each host
|groupby-orderby-limit| The last 5 aggregate readings (across time) before a randomly chosen endpoint

### IoT
|Query type|Description|
|:---|:---|
|last-loc|Fetch real-time (i.e. last) location of each truck
|low-fuel|Fetch all trucks with low fuel (less than 10%)
|high-load|Fetch trucks with high current load (over 90% load capacity)
|stationary-trucks|Fetch all trucks that are stationary (low avg velocity in last 10 mins)
|long-driving-sessions|Get trucks which haven't rested for at least 20 mins in the last 4 hours
|long-daily-sessions|Get trucks which drove more than 10 hours in the last 24 hours
|avg-vs-projected-fuel-consumption|Calculate average vs. projected fuel consumption per fleet
|avg-daily-driving-duration|Calculate average daily driving duration per driver
|avg-daily-driving-session|Calculate average daily driving session per driver
|avg-load|Calculate average load per truck model per fleet
|daily-activity|Get the number of hours truck has been active (vs. out-of-commission) per day per fleet
|breakdown-frequency|Calculate breakdown frequency by truck model

## Contributing

We welcome contributions from the community to make TSBS better!

You can help either by opening an
[issue](https://github.com/timescale/tsbs/issues) with
any suggestions or bug reports, or by forking this repository,
making your own contribution, and submitting a pull request.

Before we accept any contributions, Timescale contributors need to
sign the [Contributor License Agreement](https://cla-assistant.io/timescale/tsbs) (CLA).
By signing a CLA, we can ensure that the community is free and confident in its
ability to use your contributions.
