#!/usr/bin/env bash
set -euo pipefail

# Run the same prepared TSBS data against MatrixOne or ClickHouse.  This is a
# local correctness/performance harness. Data, results, and logs can be kept
# outside the source tree with TSBS_DATA_ROOT, TSBS_RESULT_ROOT, and
# TSBS_LOG_ROOT.

TSBS_ROOT=${TSBS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
USE_CASE=${USE_CASE:-cpu-only}
TSBS_DATA_ROOT=${TSBS_DATA_ROOT:-${DATA_ROOT:-"${TSBS_ROOT}/data/baseline-scale100-1d"}}
RESULT_BASE=${TSBS_RESULT_ROOT:-"${TSBS_ROOT}/results"}
LOG_BASE=${TSBS_LOG_ROOT:-"${TSBS_ROOT}/logs"}
PREPARED_DIR=${PREPARED_DIR:-"${TSBS_DATA_ROOT}/prepared-${USE_CASE}"}
RESULT_ROOT=${RESULT_ROOT:-"${RESULT_BASE}/tsbs_local/${USE_CASE}"}
LOG_ROOT=${LOG_ROOT:-"${LOG_BASE}/tsbs_local/${USE_CASE}"}
QUERY_REPEATS=${QUERY_REPEATS:-3}
QUERY_FILE=${QUERY_FILE:-}
DB_NAME_SUFFIX=${DB_NAME_SUFFIX:-}

MO_HOST=${MO_HOST:-127.0.0.1}
MO_PORT=${MO_PORT:-6001}
MO_USER=${MO_USER:-root}
MO_PASSWORD=${MO_PASSWORD:-111}
MYSQL_BIN=${MYSQL_BIN:-mysql}

CH_HOST=${CH_HOST:-127.0.0.1}
CH_PORT=${CH_PORT:-9000}
CH_USER=${CH_USER:-tsbs}
CH_PASSWORD=${CH_PASSWORD:-tsbs}
CLICKHOUSE_BIN=${CLICKHOUSE_BIN:-/mnt/fastdata/clickhouse}

usage() {
    echo "usage: $0 matrixone|clickhouse [--skip-load] [--query-repeats N]"
    echo "env: USE_CASE=cpu-only|devops|iot, TSBS_DATA_ROOT, PREPARED_DIR"
    echo "     TSBS_RESULT_ROOT, TSBS_LOG_ROOT, RESULT_ROOT, LOG_ROOT"
    echo "     MO_HOST/MO_PORT/MO_USER/MO_PASSWORD"
    echo "     CH_HOST/CH_PORT/CH_USER/CH_PASSWORD, MYSQL_BIN, CLICKHOUSE_BIN"
}

if [[ $# -lt 1 ]]; then
    usage >&2
    exit 2
fi
DB_KIND=$1
shift
case "$USE_CASE" in
    cpu-only|devops|iot) ;;
    *) echo "unsupported use case: $USE_CASE" >&2; usage >&2; exit 2 ;;
esac
SKIP_LOAD=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-load) SKIP_LOAD=true ;;
        --query-repeats)
            [[ $# -ge 2 ]] || { echo "--query-repeats needs a value" >&2; exit 2; }
            QUERY_REPEATS=$2
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

mkdir -p "$RESULT_ROOT" "$LOG_ROOT"
[[ -f "$PREPARED_DIR/metadata.json" ]] || { echo "missing prepared data: $PREPARED_DIR" >&2; exit 1; }

mapfile -t METRIC_TABLES < <(python3 - "$PREPARED_DIR/metadata.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    metadata = json.load(stream)
for table in metadata.get("metric_tables", {}):
    print(table)
PY
)
[[ ${#METRIC_TABLES[@]} -gt 0 ]] || { echo "metadata has no metric tables: $PREPARED_DIR/metadata.json" >&2; exit 1; }

use_case_db=${USE_CASE//-/_}

ns_now() { date +%s%N; }
elapsed_ms() { awk -v start="$1" -v end="$2" 'BEGIN {printf "%.3f", (end-start)/1000000}'; }

if [[ "$DB_KIND" == "matrixone" ]]; then
    DB_NAME="tsbs_matrixone_${use_case_db}${DB_NAME_SUFFIX}"
    if [[ -z "$QUERY_FILE" ]]; then
        if [[ "$USE_CASE" == "cpu-only" ]]; then
            QUERY_FILE="$TSBS_ROOT/matrixone/queries_matrixone.tsv"
        else
            QUERY_FILE="$TSBS_ROOT/matrixone/queries_${USE_CASE}_matrixone.tsv"
        fi
    fi
    DB_LOG="$LOG_ROOT/matrixone.log"
    SUMMARY="$RESULT_ROOT/matrixone_summary.tsv"
    export MYSQL_PWD="$MO_PASSWORD"
    mysql_args=(--protocol=tcp --connect-timeout=10 --local-infile=1 -h"$MO_HOST" -P"$MO_PORT" -u"$MO_USER")
    run_sql() { "$MYSQL_BIN" "${mysql_args[@]}" --batch --raw --skip-column-names "$@"; }
    if [[ "$SKIP_LOAD" != true ]]; then
        : >"$DB_LOG"
        load_start=$(ns_now)
        schema_sql=$(sed "s/tsbs_matrixone/${DB_NAME}/g" "$PREPARED_DIR/schema_matrixone.sql")
        run_sql <<<"$schema_sql" >>"$DB_LOG" 2>&1
        schema_end=$(ns_now)
        run_sql -D "$DB_NAME" -e "LOAD DATA LOCAL INFILE '$PREPARED_DIR/tags.csv' INTO TABLE tags FIELDS TERMINATED BY ',' LINES TERMINATED BY '\\n';" >>"$DB_LOG" 2>&1
        tags_end=$(ns_now)
        for csv_file in "$PREPARED_DIR"/*.csv; do
            table=$(basename "$csv_file" .csv)
            [[ "$table" == tags ]] && continue
            run_sql -D "$DB_NAME" -e "LOAD DATA LOCAL INFILE '$csv_file' INTO TABLE \`$table\` FIELDS TERMINATED BY ',' LINES TERMINATED BY '\\n';" >>"$DB_LOG" 2>&1
        done
        load_end=$(ns_now)
        {
            echo -e "phase\tmilliseconds"
            printf 'schema\t%s\n' "$(elapsed_ms "$load_start" "$schema_end")"
            printf 'tags\t%s\n' "$(elapsed_ms "$schema_end" "$tags_end")"
            printf 'metrics\t%s\n' "$(elapsed_ms "$tags_end" "$load_end")"
            printf 'total\t%s\n' "$(elapsed_ms "$load_start" "$load_end")"
        } >"$RESULT_ROOT/matrixone_load.tsv"
    fi
    {
        echo -e "table_name\trow_count"
        run_sql -e "SELECT 'tags', COUNT(*) FROM ${DB_NAME}.tags;"
        for table in "${METRIC_TABLES[@]}"; do
            run_sql -e "SELECT '$table', COUNT(*) FROM ${DB_NAME}.\`$table\`;"
        done
    } >"$RESULT_ROOT/matrixone_row_counts.tsv"
    query_prefix=("$MYSQL_BIN" "${mysql_args[@]}" -D "$DB_NAME" --batch --raw --skip-column-names)
elif [[ "$DB_KIND" == "clickhouse" ]]; then
    DB_NAME="tsbs_clickhouse_${use_case_db}${DB_NAME_SUFFIX}"
    if [[ -z "$QUERY_FILE" ]]; then
        if [[ "$USE_CASE" == "cpu-only" ]]; then
            QUERY_FILE="$TSBS_ROOT/matrixone/queries_clickhouse.tsv"
        else
            QUERY_FILE="$TSBS_ROOT/matrixone/queries_${USE_CASE}_clickhouse.tsv"
        fi
    fi
    DB_LOG="$LOG_ROOT/clickhouse.log"
    SUMMARY="$RESULT_ROOT/clickhouse_summary.tsv"
    ch_args=(--host "$CH_HOST" --port "$CH_PORT" --user "$CH_USER" --password "$CH_PASSWORD")
    run_ch() { "$CLICKHOUSE_BIN" client "${ch_args[@]}" "$@"; }
    if [[ "$SKIP_LOAD" != true ]]; then
        : >"$DB_LOG"
        load_start=$(ns_now)
        schema_sql=$(sed "s/tsbs_clickhouse/${DB_NAME}/g" "$PREPARED_DIR/schema_clickhouse.sql")
        run_ch --multiquery --query "$schema_sql" >>"$DB_LOG" 2>&1
        schema_end=$(ns_now)
        run_ch --query "INSERT INTO ${DB_NAME}.tags FORMAT CSV" <"$PREPARED_DIR/tags.csv" >>"$DB_LOG" 2>&1
        tags_end=$(ns_now)
        for csv_file in "$PREPARED_DIR"/*.csv; do
            table=$(basename "$csv_file" .csv)
            [[ "$table" == tags ]] && continue
            run_ch --query "INSERT INTO ${DB_NAME}.\`$table\` FORMAT CSV" <"$csv_file" >>"$DB_LOG" 2>&1
        done
        load_end=$(ns_now)
        {
            echo -e "phase\tmilliseconds"
            printf 'schema\t%s\n' "$(elapsed_ms "$load_start" "$schema_end")"
            printf 'tags\t%s\n' "$(elapsed_ms "$schema_end" "$tags_end")"
            printf 'metrics\t%s\n' "$(elapsed_ms "$tags_end" "$load_end")"
            printf 'total\t%s\n' "$(elapsed_ms "$load_start" "$load_end")"
        } >"$RESULT_ROOT/clickhouse_load.tsv"
    fi
    {
        echo -e "table_name\trow_count"
        run_ch --query "SELECT 'tags', count() FROM ${DB_NAME}.tags FORMAT TabSeparated"
        for table in "${METRIC_TABLES[@]}"; do
            run_ch --query "SELECT '$table', count() FROM ${DB_NAME}.\`$table\` FORMAT TabSeparated"
        done
    } >"$RESULT_ROOT/clickhouse_row_counts.tsv"
    query_prefix=("$CLICKHOUSE_BIN" client "${ch_args[@]}" --database "$DB_NAME" --format TSV)
else
    echo "unsupported database: $DB_KIND" >&2
    usage >&2
    exit 2
fi

[[ -f "$QUERY_FILE" ]] || { echo "missing query file: $QUERY_FILE" >&2; exit 1; }
printf 'query\trepeat\tlatency_ms\trows\tresult_file\n' >"$SUMMARY"
while IFS=$'\t' read -r label sql; do
    [[ -z "$label" ]] && continue
    for repeat in $(seq 1 "$QUERY_REPEATS"); do
        result_file="$RESULT_ROOT/${DB_KIND}_${label}_r${repeat}.tsv"
        error_file="$LOG_ROOT/${DB_KIND}_${label}_r${repeat}.err"
        start=$(ns_now)
        if [[ "$DB_KIND" == "matrixone" ]]; then
            "${query_prefix[@]}" -e "$sql" >"$result_file" 2>"$error_file"
        else
            "${query_prefix[@]}" --query "$sql" >"$result_file" 2>"$error_file"
        fi
        end=$(ns_now)
        rows=$(wc -l <"$result_file")
        printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$repeat" "$(elapsed_ms "$start" "$end")" "$rows" "$result_file" >>"$SUMMARY"
    done
done <"$QUERY_FILE"

echo "Completed $DB_KIND benchmark"
echo "Load summary: ${RESULT_ROOT}/${DB_KIND}_load.tsv"
echo "Query summary: $SUMMARY"
echo "Row counts: ${RESULT_ROOT}/${DB_KIND}_row_counts.tsv"
