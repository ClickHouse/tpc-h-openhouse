#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------
# Enrich Snowflake ClickBench results with cost info
# using a pricing JSON.
#
# Usage:
#   ./enrich.sh <clickbench_json> <pricing_json> <output_json> \
#       [--cloud <val>] [--region <val>]
#
# Example:
#   ./enrich.sh clickbench/results/4xl.json \
#               pricings/gen2_warehouse.json \
#               results/4xl_enriched.json \
#               --cloud aws --region us-east-1
#
# This computes costs for all matching pricing plans
# (standard, enterprise, business_critical, …) and writes
# them into the .costs[] array, one entry per plan.
#
# If the input bench JSON contains clustering_credits_used,
# the script also computes:
#   clustering_cost = clustering_credits_used * credit_price_per_hour
# and stores it per pricing tier.
# ---------------------------------------------

CLOUD="aws"
REGION="us-east-1"

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 <clickbench_json> <pricing_json> <output_json> [--cloud <val>] [--region <val>]" >&2
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
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "❌ jq is required." >&2
  exit 1
fi

OUT_DIR=$(dirname "$OUT_FILE")
mkdir -p "$OUT_DIR"

echo "→ Enriching Snowflake ClickBench results"
echo "  Cloud : ${CLOUD}"
echo "  Region: ${REGION}"
echo

jq -s \
  --arg cloud "$CLOUD" \
  --arg region "$REGION" '
  .[0] as $bench |
  .[1] as $pricing |

  # Use cluster_size as the credits-per-hour lookup key.
  ($bench.cluster_size) as $cluster_credits |

  [
    $pricing.pricing[]
    | select(.cloud == $cloud and .region == $region)
    | . as $block

    # Find matching warehouse size by credits/hour.
    | ($block.warehouses[]
       | select(.credits_per_hour == $cluster_credits)) as $wh

    # Base prices.
    | ($block.credit_price_per_hour) as $credit_price
    | ($wh.credits_per_hour)         as $credits_per_hour

    # Optional clustering credits from input bench file.
    | ($bench.clustering_credits_used? // null) as $clustering_credits_used

    # Storage pricing.
    | ($block.storage.storage)            as $storage_price
    | ($block.storage.storage_price_unit) as $storage_unit

    # Compute costs: seconds * (credits_per_hour * credit_price / 3600)
    | ($bench.result
       | map(
           map(
             if . == null then null
             else (. * ($credits_per_hour * $credit_price / 3600.0))
             end
           )
         )
      ) as $compute_costs

    # Storage cost: bytes / unit * price
    | ($bench.data_size / $storage_unit * $storage_price) as $storage_cost

    # Optional clustering cost: clustering credits * credit price
    | (if $clustering_credits_used != null
       then ($clustering_credits_used * $credit_price)
       else null
       end) as $clustering_cost

    # Build one cost object per pricing plan.
    | ({
        tier: .plan,
        provider: $cloud,
        service:  $pricing.service,
        cloud:    $cloud,
        region:   $region,

        warehouse_size: $wh.name,
        data_size:      $bench.data_size,

        storage_cost: $storage_cost,
        storage_costs: [
          {
            model: "object",
            term: "active",
            period: "monthly",
            price_per_byte: ($storage_price / $storage_unit),
            bytes: $bench.data_size,
            estimated_cost: $storage_cost,
            pricing_base: {
              price_usd:        $storage_price,
              price_unit:       "byte_month",
              price_unit_bytes: $storage_unit,
              notes: "Snowflake storage (list price)."
            }
          }
        ],

        compute_costs: $compute_costs,

        pricing_base: {
          credits_per_hour:      $credits_per_hour,
          credit_price_per_hour: $credit_price,
          storage:               $storage_price,
          storage_price_unit:    $storage_unit
        }
      }
      + if $clustering_cost != null
        then { clustering_cost: $clustering_cost }
        else {}
        end)
  ] as $all_costs

  | $bench + { costs: $all_costs }
' "$BENCH_FILE" "$PRICING_FILE" > "$OUT_FILE"

echo "✅ Written to $OUT_FILE"
echo "💰 Total compute cost per tier:"
jq -r '
  .costs[]
  | "\(.tier): \([.compute_costs[][]] | add)"
' "$OUT_FILE"

if jq -e '.costs[0].clustering_cost? != null' "$OUT_FILE" >/dev/null 2>&1; then
  echo "🧩 Clustering cost per tier:"
  jq -r '
    .costs[]
    | "\(.tier): \(.clustering_cost)"
  ' "$OUT_FILE"
fi

echo "💾 Storage cost (same per tier):"
jq -r '.costs[0].storage_cost' "$OUT_FILE"