#!/usr/bin/env bash
# Concatenate redshift/queries/*.sql into a flat redshift/queries.sql,
# one query per line, which is the format run.sh reads.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT="${ROOT_DIR}/queries.sql"

shopt -s nullglob
FILES=("${ROOT_DIR}/queries/"query_*.sql)
shopt -u nullglob
[ "${#FILES[@]}" -gt 0 ] || { echo "ERROR: no query files in queries/" >&2; exit 1; }

: > "$OUT"
for f in "${FILES[@]}"; do
  # Collapse newlines + multiple spaces -> single line.
  tr '\n' ' ' < "$f" \
    | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' \
    >> "$OUT"
  echo >> "$OUT"
done
echo "Wrote $(wc -l < "$OUT") queries to $OUT"
