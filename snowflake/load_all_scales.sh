#!/usr/bin/env bash
set -euo pipefail

SCALES=(sf10 sf100 sf1000)

for scale in "${SCALES[@]}"; do
  echo "============================================================"
  echo "Loading ${scale}"
  echo "============================================================"
  ./load_scale.sh "$scale"
done