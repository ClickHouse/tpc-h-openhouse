#!/usr/bin/env bash
# Import all TPC-H tables for one DB in parallel.
# Usage: import_db.sh <db>
set -uo pipefail

DB="${1:?db required (sf10|sf100|sf1000)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOG_DIR}/${DB}"
MASTER="${LOG_DIR}/master.log"

ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

TABLES=(nation region part supplier partsupp customer orders lineitem)

echo "[$(ts)] BEGIN db=${DB} tables=${TABLES[*]}" | tee -a "${MASTER}"

declare -A PIDS=()
for t in "${TABLES[@]}"; do
  bash "${SCRIPT_DIR}/import_table.sh" "${DB}" "${t}" &
  PIDS[$t]=$!
  echo "[$(ts)]   spawned ${DB}.${t} pid=${PIDS[$t]}" | tee -a "${MASTER}"
done

overall_rc=0
for t in "${TABLES[@]}"; do
  pid="${PIDS[$t]}"
  if wait "${pid}"; then
    echo "[$(ts)]   OK   ${DB}.${t} (pid ${pid})" | tee -a "${MASTER}"
  else
    rc=$?
    overall_rc=1
    echo "[$(ts)]   FAIL ${DB}.${t} (pid ${pid}, rc=${rc})" | tee -a "${MASTER}"
  fi
done

echo "[$(ts)] END   db=${DB} overall_rc=${overall_rc}" | tee -a "${MASTER}"
exit "${overall_rc}"
