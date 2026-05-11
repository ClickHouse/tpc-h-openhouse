#!/usr/bin/env bash
set -euo pipefail

CLOUD="aws"
REGION="us-east-1"
PLAN="premium"

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 <benchmark_json> <pricing_json> <output_json> [--cloud <val>] [--region <val>] [--plan <val>]" >&2
  exit 1
fi

BENCH_FILE="$1"
PRICING_FILE="$2"
OUT_FILE="$3"
shift 3

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cloud) CLOUD="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --plan) PLAN="$2"; shift 2 ;;
    *)
      echo "❌ Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "❌ jq is required but not installed." >&2
  exit 1
fi

if [ ! -f "$BENCH_FILE" ]; then
  echo "❌ Benchmark file not found: $BENCH_FILE" >&2
  exit 1
fi

if [ ! -f "$PRICING_FILE" ]; then
  echo "❌ Pricing file not found: $PRICING_FILE" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT_FILE")"

# Current input convention:
#   .machine      = Databricks warehouse size, e.g. "4X-Large"
#   .cluster_size = DBUs/hour, e.g. 528.0
#
# Desired output convention:
#   .machine      = "serverless"
#   .cluster_size = original warehouse size, e.g. "4X-Large"
WAREHOUSE_SIZE=$(jq -r '.machine // empty' "$BENCH_FILE")

if [ -z "$WAREHOUSE_SIZE" ]; then
  echo "❌ Could not read .machine from $BENCH_FILE" >&2
  exit 1
fi

echo "→ Enriching ClickBench results for ${WAREHOUSE_SIZE}"
echo "  Cloud         : ${CLOUD}"
echo "  Region        : ${REGION}"
echo "  Plan          : ${PLAN}"
echo "  Warehouse size: ${WAREHOUSE_SIZE}"
echo "  Input         : ${BENCH_FILE}"
echo "  Pricing       : ${PRICING_FILE}"
echo "  Output        : ${OUT_FILE}"
echo

TMP_OUT="${OUT_FILE}.tmp"

jq -s \
  --arg cloud "$CLOUD" \
  --arg region "$REGION" \
  --arg plan "$PLAN" \
  --arg warehouse_size "$WAREHOUSE_SIZE" '
  .[0] as $bench |
  .[1] as $pricing |

  (
    $pricing.pricing[]
    | select(.cloud == $cloud and .region == $region and .plan == $plan)
  ) as $pricing_block |

  (
    $pricing_block.instances[]
    | select(.name == $warehouse_size)
  ) as $instance |

  ($pricing_block.dbu_price_per_hour) as $dbu_price_per_hour |
  ($instance.dbu_per_hour) as $dbu_per_hour |

  (
    $bench.result
    | map(
        map(
          if . == null then
            null
          else
            . / 3600.0 * $dbu_per_hour * $dbu_price_per_hour
          end
        )
      )
  ) as $compute_costs |

  (
    [$compute_costs[][] | select(. != null)] | add // 0
  ) as $compute_cost |

  (
    if ($pricing_block.storage? != null and $bench.data_size != null) then
      ($pricing_block.storage.storage // 0) as $storage_price |
      ($pricing_block.storage.storage_price_unit // 1) as $storage_price_unit |
      ($bench.data_size * $storage_price / $storage_price_unit)
    else
      0
    end
  ) as $storage_cost |

  $bench
  + {
      machine: "serverless",
      cluster_size: $warehouse_size
    }
  + {
      costs: [
        {
          tier: $plan,
          provider: $cloud,
          service: $pricing.service,
          cloud: $cloud,
          region: $region,
          data_size: $bench.data_size,
          storage_cost: $storage_cost,
          storage_costs: [
            {
              type: "data",
              bytes: $bench.data_size,
              price_per_unit: ($pricing_block.storage.storage // 0),
              unit_bytes: ($pricing_block.storage.storage_price_unit // 1),
              estimated_cost: $storage_cost
            }
          ],
          compute_costs: $compute_costs,
          pricing_base: {
            dbu_per_hour: $dbu_per_hour,
            dbu_price_per_hour: $dbu_price_per_hour
          }
        }
      ]
    }
' "$BENCH_FILE" "$PRICING_FILE" > "$TMP_OUT"

if [ ! -s "$TMP_OUT" ]; then
  rm -f "$TMP_OUT"
  echo "❌ No matching pricing entry found." >&2
  echo "   cloud=${CLOUD}" >&2
  echo "   region=${REGION}" >&2
  echo "   plan=${PLAN}" >&2
  echo "   warehouse_size=${WAREHOUSE_SIZE}" >&2
  exit 1
fi

mv "$TMP_OUT" "$OUT_FILE"

TOTAL_COST=$(jq -r '[.costs[0].compute_costs[][] | select(. != null)] | add // 0' "$OUT_FILE")

printf "\n✅ Done! Wrote enriched result to: %s\n" "$OUT_FILE"
printf "💰 Total estimated compute cost (all runs): \$%.4f\n" "$TOTAL_COST"