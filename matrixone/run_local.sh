#!/usr/bin/env bash
set -euo pipefail

TSBS_ROOT=${TSBS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# TSBS_DATA_ROOT is the dataset directory (source archives and prepared-*).
# DATA_ROOT remains as a backwards-compatible alias for existing invocations.
TSBS_DATA_ROOT=${TSBS_DATA_ROOT:-${DATA_ROOT:-"${TSBS_ROOT}/data/baseline-scale100-1d"}}
USE_CASES=${USE_CASES:-"cpu-only devops iot"}
QUERY_REPEATS=${QUERY_REPEATS:-3}
DATASET_ID=${TSBS_DATASET_ID:-scale100_1d_10s_seed123}
QUERY_ROOT=${QUERY_ROOT:-"${TSBS_ROOT}/matrixone"}
EXPECTED_HOURS=${TSBS_EXPECTED_HOURS:-24}
RESULT_SET=${TSBS_RESULT_SET:-tsbs_local}
LOG_SET=${TSBS_LOG_SET:-"$RESULT_SET"}
DB_NAME_SUFFIX=${TSBS_DB_NAME_SUFFIX:-}
RESULT_BASE=${TSBS_RESULT_ROOT:-"${TSBS_ROOT}/results"}
LOG_BASE=${TSBS_LOG_ROOT:-"${TSBS_ROOT}/logs"}

mkdir -p "${RESULT_BASE}/${RESULT_SET}" "${LOG_BASE}/${LOG_SET}"

for use_case in $USE_CASES; do
    source_data="${TSBS_DATA_ROOT}/clickhouse_${use_case}_${DATASET_ID}.dat.gz"
    prepared_dir="${TSBS_DATA_ROOT}/prepared-${use_case}"
    if [[ ! -f "$prepared_dir/metadata.json" ]]; then
        [[ -f "$source_data" ]] || {
            echo "missing source data for $use_case: $source_data" >&2
            exit 1
        }
        python3 "$TSBS_ROOT/matrixone/prepare_data.py" \
            --source "$source_data" --output "$prepared_dir"
    fi

    result_root="${RESULT_BASE}/${RESULT_SET}/${use_case}"
    log_root="${LOG_BASE}/${LOG_SET}/${use_case}"
    query_file="${QUERY_ROOT}/queries_${use_case}_matrixone_${DATASET_ID}.tsv"
    clickhouse_query_file="${QUERY_ROOT}/queries_${use_case}_clickhouse_${DATASET_ID}.tsv"
    if [[ ! -f "$query_file" ]]; then
        if [[ "$use_case" == "cpu-only" ]]; then
            query_file="${QUERY_ROOT}/queries_matrixone.tsv"
            clickhouse_query_file="${QUERY_ROOT}/queries_clickhouse.tsv"
        else
            query_file="${QUERY_ROOT}/queries_${use_case}_matrixone.tsv"
            clickhouse_query_file="${QUERY_ROOT}/queries_${use_case}_clickhouse.tsv"
        fi
    fi
    USE_CASE="$use_case" \
    PREPARED_DIR="$prepared_dir" \
    RESULT_ROOT="$result_root" \
    LOG_ROOT="$log_root" \
    QUERY_FILE="$query_file" \
    DB_NAME_SUFFIX="$DB_NAME_SUFFIX" \
        bash "$TSBS_ROOT/matrixone/run_benchmark.sh" matrixone --query-repeats "$QUERY_REPEATS"
    USE_CASE="$use_case" \
    PREPARED_DIR="$prepared_dir" \
    RESULT_ROOT="$result_root" \
    LOG_ROOT="$log_root" \
    QUERY_FILE="$clickhouse_query_file" \
    DB_NAME_SUFFIX="$DB_NAME_SUFFIX" \
        bash "$TSBS_ROOT/matrixone/run_benchmark.sh" clickhouse --query-repeats "$QUERY_REPEATS"
    python3 "$TSBS_ROOT/matrixone/validate_results.py" \
        --results "$result_root" --use-case "$use_case" --expected-hours "$EXPECTED_HOURS"
done
