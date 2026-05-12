#!/usr/bin/env bash
# Top-level orchestrator: run sf10 -> sf100 -> sf1000 sequentially in tmux.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION="${TPCH_SESSION:-tpch_import}"

mkdir -p "${SCRIPT_DIR}/logs"

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux not found" >&2
  exit 1
fi

tmux kill-session -t "${SESSION}" 2>/dev/null || true

CMD="cd '${SCRIPT_DIR}' && \
  echo '[start] '\$(date -u +%FT%TZ) | tee -a logs/master.log && \
  ./import_db.sh sf10   | tee -a logs/master.log; \
  ./import_db.sh sf100  | tee -a logs/master.log; \
  ./import_db.sh sf1000 | tee -a logs/master.log; \
  ./verify.sh           | tee logs/verify.log; \
  echo '[done] '\$(date -u +%FT%TZ) | tee -a logs/master.log; \
  echo 'IMPORT_FINISHED'; \
  sleep infinity"

tmux new-session -d -s "${SESSION}" -c "${SCRIPT_DIR}" "bash -lc \"${CMD}\""

cat <<EOF
tmux session '${SESSION}' started.

Attach:        tmux attach -t ${SESSION}
Master log:    tail -f ${SCRIPT_DIR}/logs/master.log
Per-table log: tail -f ${SCRIPT_DIR}/logs/<db>/<table>.log
Progress TSV:  cat ${SCRIPT_DIR}/logs/progress.tsv
EOF
