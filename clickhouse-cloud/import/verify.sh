#!/usr/bin/env bash
# Print row counts and on-disk sizes for sf10/sf100/sf1000, plus
# expected vs actual TPC-H cardinalities so short loads jump out.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/clickhouse-client.xml"

ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

echo "==== $(ts) verify: system.tables ===="
clickhouse-client --config-file="${CONFIG}" --query "
SELECT
  database,
  name AS table,
  total_rows,
  formatReadableSize(total_bytes) AS size,
  total_bytes AS bytes
FROM system.tables
WHERE database IN ('sf10','sf100','sf1000')
ORDER BY database, name
FORMAT PrettyCompactMonoBlock
"

echo
echo "==== $(ts) verify: live count(*) per table ===="
for db in sf10 sf100 sf1000; do
  for t in nation region supplier customer part partsupp orders lineitem; do
    cnt=$(clickhouse-client --config-file="${CONFIG}" \
            --max_execution_time 0 \
            --query "SELECT count() FROM ${db}.${t}" 2>/dev/null || echo "ERR")
    printf '%-7s %-9s %s\n' "${db}" "${t}" "${cnt}"
  done
done

echo
echo "==== $(ts) verify: expected vs actual ===="
# TPC-H base cardinalities at SF=1
declare -A BASE=(
  [region]=5
  [nation]=25
  [supplier]=10000
  [customer]=150000
  [part]=200000
  [partsupp]=800000
  [orders]=1500000
  [lineitem]=6001215
)

printf '%-7s %-9s %15s %15s %8s\n' "db" "table" "expected" "actual" "delta_%"
for db in sf10 sf100 sf1000; do
  case "${db}" in
    sf10)   sf=10 ;;
    sf100)  sf=100 ;;
    sf1000) sf=1000 ;;
  esac
  for t in region nation supplier customer part partsupp orders lineitem; do
    base="${BASE[$t]}"
    if [[ "${t}" == "nation" || "${t}" == "region" ]]; then
      expected="${base}"
    else
      expected=$((base * sf))
    fi
    actual=$(clickhouse-client --config-file="${CONFIG}" \
              --max_execution_time 0 \
              --query "SELECT count() FROM ${db}.${t}" 2>/dev/null || echo 0)
    if [[ "${expected}" -gt 0 ]]; then
      delta=$(awk -v a="${actual}" -v e="${expected}" 'BEGIN{ if(e==0){print "NA"} else {printf "%+.3f", (a-e)*100.0/e } }')
    else
      delta="NA"
    fi
    printf '%-7s %-9s %15s %15s %8s\n' "${db}" "${t}" "${expected}" "${actual}" "${delta}"
  done
done

echo
echo "==== $(ts) verify: progress.tsv ===="
if [[ -f "${SCRIPT_DIR}/logs/progress.tsv" ]]; then
  printf 'finished_at\tdb\ttable\tstatus\trows\tbytes\tduration_s\n'
  cat "${SCRIPT_DIR}/logs/progress.tsv"
fi
