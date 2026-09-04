#!/bin/bash

# Ensure runner is available
EXE_FILE_NAME=${EXE_FILE_NAME:-$(which tsbs_run_queries_clickhouse)}
if [[ -z "$EXE_FILE_NAME" ]]; then
    echo "tsbs_run_queries_clickhouse not available. It is not specified explicitly and not found in \$PATH"
    exit 1
fi

# Default queries folder
BULK_DATA_DIR=${BULK_DATA_DIR:-${TSBS_QUERY_ROOT:-"/tmp/bulk_queries"}}
RESULT_ROOT=${RESULT_ROOT:-${TSBS_RESULT_ROOT:-}}
DATABASE_HOST=${DATABASE_HOST:-localhost}
DATABASE_PORT=${DATABASE_PORT:-9000}
DATABASE_NAME=${DATABASE_NAME:-benchmark}
DATABASE_USER=${DATABASE_USER:-default}
DATABASE_PASSWORD=${DATABASE_PASSWORD:-}
MAX_QUERIES=${MAX_QUERIES:-"0"}
NUM_WORKERS=${NUM_WORKERS:-$(grep -c ^processor /proc/cpuinfo)}  # match # of cores - worker per core

#
# Run test for one file
#
function run_file()
{
    # $FULL_DATA_FILE_NAME:  /full/path/to/file_with.ext
    # $DATA_FILE_NAME:       file_with.ext
    # $DIR:                  /full/path/to
    # $EXTENSION:            ext
    # NO_EXT_DATA_FILE_NAME: file_with
    FULL_DATA_FILE_NAME=$1
    DATA_FILE_NAME=$(basename -- "${FULL_DATA_FILE_NAME}")
    DIR=$(dirname "${FULL_DATA_FILE_NAME}")
    EXTENSION="${DATA_FILE_NAME##*.}"
    NO_EXT_DATA_FILE_NAME="${DATA_FILE_NAME%.*}"

    # Several options on how to name results file
    #OUT_FULL_FILE_NAME="${DIR}/result_${DATA_FILE_NAME}"
    if [[ -n "${RESULT_ROOT}" ]]; then
        mkdir -p "${RESULT_ROOT}"
        OUT_FULL_FILE_NAME="${RESULT_ROOT}/result_${NO_EXT_DATA_FILE_NAME}.out"
    else
        OUT_FULL_FILE_NAME="${DIR}/result_${NO_EXT_DATA_FILE_NAME}.out"
    fi
    #OUT_FULL_FILE_NAME="${DIR}/${NO_EXT_DATA_FILE_NAME}.out"

    if [ "${EXTENSION}" == "gz" ]; then
        GUNZIP="gunzip"
    else
        GUNZIP="cat"
    fi

    echo "Running ${DATA_FILE_NAME}"
    cat $FULL_DATA_FILE_NAME \
        | $GUNZIP \
        | $EXE_FILE_NAME \
            --max-queries $MAX_QUERIES \
            --workers $NUM_WORKERS \
            --db-name "${DATABASE_NAME}" \
            --hosts "${DATABASE_HOST}" \
            --port "${DATABASE_PORT}" \
            --user "${DATABASE_USER}" \
            --password "${DATABASE_PASSWORD}" \
        | tee $OUT_FULL_FILE_NAME
}

if [ "$#" -gt 0 ]; then
    echo "Have $# files specified as params"
    for FULL_DATA_FILE_NAME in "$@"; do
        run_file $FULL_DATA_FILE_NAME
    done
else
    echo "Do not have any files specified - run from query folder as ${BULK_DATA_DIR}/queries_clickhouse*"
    for FULL_DATA_FILE_NAME in "${BULK_DATA_DIR}/queries_clickhouse"*; do
        run_file $FULL_DATA_FILE_NAME
    done
fi
