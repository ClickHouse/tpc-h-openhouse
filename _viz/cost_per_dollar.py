#!/usr/bin/env python3
import sys
import json
import argparse
import math
import matplotlib
import matplotlib.pyplot as plt

# Font config
matplotlib.rcParams['font.family'] = 'Inter'
matplotlib.rcParams['font.sans-serif'] = ['Inter']
matplotlib.rcParams['font.weight'] = 'normal'
matplotlib.rcParams['axes.titleweight'] = 'bold'

# ---------- Colors ----------
VENDOR_COLOR = {
    "ClickHouse": "#FDFF88",
    "Redshift":   "#FFB30A",
    "Databricks": "#FF4B3A",
    "Snowflake":  "#29B5E8",
    "BigQuery":   "#4285F4",
    "Alibaba":    "#FF6A00",
}

BACKGROUND_COLOR = "#2B2B2B"
TEXT_COLOR = "white"
FORMULA_COLOR = "#6C6C6C"

# ---------- Helpers ----------
def load_records_from_stdin():
    records = []
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        records.append(json.loads(line))
    return records


def vendor_from_system(system: str) -> str:
    return system


def parse_clustering_costs(values):
    """
    Parse repeated args of the form:
      --clustering-cost 20=12.5
      --clustering-cost 19=3.2
    into:
      {"20": 12.5, "19": 3.2}
    """
    result = {}
    for v in values or []:
        if "=" not in v:
            raise ValueError(
                f"Invalid --clustering-cost value '{v}'. Expected format ID=AMOUNT, e.g. 20=12.5"
            )
        rec_id, amount = v.split("=", 1)
        rec_id = rec_id.strip()
        if not rec_id:
            raise ValueError(f"Invalid --clustering-cost value '{v}': empty ID")
        try:
            result[rec_id] = float(amount)
        except ValueError:
            raise ValueError(
                f"Invalid --clustering-cost amount in '{v}'. Amount must be numeric."
            )
    return result

def fmt_money(x):
    s = f"{x:,.5f}".rstrip("0").rstrip(".")
    return f"${s}"


# ---------- Main ----------
def main():
    parser = argparse.ArgumentParser(
        description="Render cost-performance index bar chart from NDJSON input."
    )
    parser.add_argument("-o", "--out", help="Output PNG filename.")
    parser.add_argument("--dpi", type=int, default=300)
    parser.add_argument("--no-title", action="store_true")
    parser.add_argument("--no-labels", action="store_true")
    parser.add_argument("--bar-height", type=float, default=0.55)
    parser.add_argument("--bar-distance", type=float, default=1.0)
    parser.add_argument(
        "--clustering-cost",
        action="append",
        default=[],
        metavar="ID=AMOUNT",
        help="Extra clustering cost to add for a specific record id, e.g. --clustering-cost 20=4.3",
    )
    args = parser.parse_args()

    try:
        clustering_costs = parse_clustering_costs(args.clustering_cost)
    except ValueError as e:
        print(str(e), file=sys.stderr)
        sys.exit(2)

    records = load_records_from_stdin()
    if not records:
        print("No input records!", file=sys.stderr)
        sys.exit(1)

    # ---- Metric: index = runtime * (query_cost + clustering_cost) ----
    enriched = []
    for r in records:
        rec_id = str(r.get("id", ""))
        rt = float(r["rt_hot"])
        query_cost = float(r["cost_hot"])
        clustering_cost = clustering_costs.get(rec_id, 0.0)
        total_cost = query_cost + clustering_cost
        index = rt * total_cost

        enriched.append((r, {
            "rt": rt,
            "query_cost": query_cost,
            "clustering_cost": clustering_cost,
            "total_cost": total_cost,
            "index": index,
        }))

    best_index = min(item["index"] for _, item in enriched)

    rows = []
    for r, item in enriched:
        factor = item["index"] / best_index
        rows.append({
            "record": r,
            "rt": item["rt"],
            "query_cost": item["query_cost"],
            "clustering_cost": item["clustering_cost"],
            "total_cost": item["total_cost"],
            "index_raw": item["index"],
            "index_factor": factor,
        })

    # Sort ascending: best first
    rows.sort(key=lambda x: x["index_factor"])

    # Build ranking labels
    base_labels = [
        row["record"].get("bar_label") or row["record"]["system"]
        for row in rows
    ]
    labels = []
    for rank, base_label in enumerate(base_labels, start=1):
        suffix = "th"
        if rank == 1:
            suffix = "st"
        elif rank == 2:
            suffix = "nd"
        elif rank == 3:
            suffix = "rd"
        labels.append(f"{rank}{suffix} • {base_label}")

    systems = [row["record"]["system"] for row in rows]
    factors = [row["index_factor"] for row in rows]
    x_vals = factors

    fig_h = max(3.2, len(rows) * 0.75)
    fig, ax = plt.subplots(figsize=(8, fig_h))

    fig.patch.set_facecolor(BACKGROUND_COLOR)
    ax.set_facecolor(BACKGROUND_COLOR)

    bar_height = args.bar_height
    bar_distance = args.bar_distance
    y_positions = [i * bar_distance for i in range(len(rows))]

    # Draw bars
    for y, x, system in zip(y_positions, x_vals, systems):
        color = VENDOR_COLOR.get(system, "#FFFFFF")
        ax.barh(y, x, color=color, height=bar_height, edgecolor="none")

    ax.invert_yaxis()

    # Y labels
    ax.set_yticks(y_positions)
    if args.no_labels:
        ax.set_yticklabels([])
    else:
        ax.set_yticklabels(labels, color=TEXT_COLOR)

    # X axis — no ticks or values
    ax.set_xlim(0, max(x_vals) * 1.05)
    ax.set_xlabel("Cost-Performance Score (cost × runtime, smaller is better)", color=TEXT_COLOR, labelpad=15)
    ax.set_xticks([])
    ax.tick_params(axis="x", bottom=False, labelbottom=False)
    ax.spines["bottom"].set_visible(False)

    # Title
    if not args.no_title:
        ax.set_title("Cost-performance ranking", color=TEXT_COLOR, pad=20, fontsize=18)

    # Style spines
    ax.spines["left"].set_visible(True)
    ax.spines["left"].set_color(TEXT_COLOR)
    for side in ["right", "top"]:
        ax.spines[side].set_visible(False)

    ax.tick_params(axis="y", colors=TEXT_COLOR)
    ax.tick_params(axis="y", pad=10)

    # Right-hand "baseline / Nx worse"
    for y, factor in zip(y_positions, x_vals):
        if math.isclose(factor, 1.0, rel_tol=1e-9):
            txt = "best"
        else:
            txt = f"{int(round(factor))}× worse"
        ax.text(factor * 1.01, y, txt, va="center", ha="left", color=TEXT_COLOR, fontsize=12)

    # ---- Formula annotation BELOW each bar ----
    for y, row in zip(y_positions, rows):
        rt = row["rt"]
        query_cost = row["query_cost"]
        clustering_cost = row["clustering_cost"]
        total_cost = row["total_cost"]
        idx = row["index_raw"]

        if clustering_cost > 0:
            formula = (
                f"{fmt_money(total_cost)} (= {fmt_money(query_cost)} query + "
                f"{fmt_money(clustering_cost)} clustering) × {rt:.3f}s = {idx:.5f}"
            )
        else:
            formula = f"{fmt_money(total_cost)} × {rt:.3f}s = {idx:.5f}"

        y_formula = y + (bar_height * 0.80)
        x_formula = max(x_vals) * 0.01

        ax.text(
            x_formula,
            y_formula,
            formula,
            va="center",
            ha="left",
            color=FORMULA_COLOR,
            fontsize=10,
        )

    plt.tight_layout()

    if args.out:
        plt.savefig(args.out, dpi=args.dpi, facecolor=fig.get_facecolor())
    else:
        plt.show()


if __name__ == "__main__":
    main()