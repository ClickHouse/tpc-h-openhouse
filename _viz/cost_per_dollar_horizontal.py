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
FORMULA_COLOR = "#777777"
FORMULA_ON_BAR_COLOR = "#2B2B2B"

# ---------- Helpers ----------
def load_records_from_stdin():
    records = []
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        records.append(json.loads(line))
    return records


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


def ordinal(n: int) -> str:
    if 10 <= n % 100 <= 20:
        suffix = "th"
    else:
        suffix = {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
    return f"{n}{suffix}"


def factor_label(factor: float) -> str:
    if math.isclose(factor, 1.0, rel_tol=1e-9):
        return "best"
    return f"{int(round(factor))}× worse"


def formula_for_row(row):
    rt = row["rt"]
    query_cost = row["query_cost"]
    clustering_cost = row["clustering_cost"]
    total_cost = row["total_cost"]
    idx = row["index_raw"]

    if clustering_cost > 0:
        return (
            f"{fmt_money(total_cost)} (= {fmt_money(query_cost)} query + "
            f"{fmt_money(clustering_cost)} clustering) × {rt:.3f}s = {idx:.5f}"
        )
    return f"{fmt_money(total_cost)} × {rt:.3f}s = {idx:.5f}"


# ---------- Main ----------
def main():
    parser = argparse.ArgumentParser(
        description="Render a compact, horizontal cost-performance index bar chart from NDJSON input."
    )
    parser.add_argument("-o", "--out", help="Output PNG filename.")
    parser.add_argument("--dpi", type=int, default=300)
    parser.add_argument("--no-title", action="store_true")
    parser.add_argument("--no-labels", action="store_true")
    parser.add_argument("--bar-height", type=float, default=0.52)
    parser.add_argument("--bar-distance", type=float, default=0.74)
    parser.add_argument("--fig-width", type=float, default=14.0)
    parser.add_argument("--label-font-size", type=float, default=13.5)
    parser.add_argument("--summary-font-size", type=float, default=16.0)
    parser.add_argument("--formula-font-size", type=float, default=9.5)
    parser.add_argument(
        "--inline-formulas-until-rank",
        type=int,
        default=8,
        help="Put formulas after the best/N-times-worse label until this rank; later ranks get the formula inside the bar.",
    )
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
    labels = [f"{ordinal(rank)} • {base_label}" for rank, base_label in enumerate(base_labels, start=1)]

    systems = [row["record"]["system"] for row in rows]
    x_vals = [row["index_factor"] for row in rows]

    fig_h = max(3.0, len(rows) * 0.48)
    fig, ax = plt.subplots(figsize=(args.fig_width, fig_h))

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
        ax.set_yticklabels(labels, color=TEXT_COLOR, fontsize=args.label_font_size)

    max_x = max(x_vals)
    ax.set_xlim(0, max_x * 1.12)
    ax.set_xlabel(
        "Cost-Performance Score (cost × runtime, smaller is better)",
        color=TEXT_COLOR,
        labelpad=16,
        fontsize=12.5,
    )
    ax.set_xticks([])
    ax.tick_params(axis="x", bottom=False, labelbottom=False)
    ax.spines["bottom"].set_visible(False)

    # Title
    if not args.no_title:
        ax.set_title("Cost-performance ranking", color=TEXT_COLOR, pad=16, fontsize=20)

    # Style spines
    ax.spines["left"].set_visible(True)
    ax.spines["left"].set_color(TEXT_COLOR)
    ax.spines["left"].set_linewidth(1.2)
    for side in ["right", "top"]:
        ax.spines[side].set_visible(False)

    ax.tick_params(axis="y", colors=TEXT_COLOR, pad=12)

    # Summary + formula on one line. The first rows get the formula after the
    # summary label; the last / longest rows get the formula inside the bar.
    for rank, (y, row) in enumerate(zip(y_positions, rows), start=1):
        factor = row["index_factor"]
        summary = factor_label(factor)
        formula = formula_for_row(row)

        summary_x = factor + (max_x * 0.012)
        ax.text(
            summary_x,
            y,
            summary,
            va="center",
            ha="left",
            color=TEXT_COLOR,
            fontsize=args.summary_font_size,
        )

        if rank <= args.inline_formulas_until_rank:
            # Put the small calculation behind the main summary label on the same row.
            formula_x = summary_x + (max_x * 0.13)
            ax.text(
                formula_x,
                y,
                formula,
                va="center",
                ha="left",
                color=FORMULA_COLOR,
                fontsize=args.formula_font_size,
            )
        else:
            # For very long bars, keep the calculation inside the bar to avoid
            # wasting horizontal space and to keep the slide compact.
            formula_x = max_x * 0.012
            ax.text(
                formula_x,
                y,
                formula,
                va="center",
                ha="left",
                color=FORMULA_ON_BAR_COLOR,
                fontsize=args.formula_font_size,
            )

    # Slightly reduce vertical whitespace around the bars.
    pad = bar_distance * 0.45
    ax.set_ylim(y_positions[-1] + pad, -pad)

    plt.tight_layout(pad=0.5)

    if args.out:
        plt.savefig(args.out, dpi=args.dpi, facecolor=fig.get_facecolor())
    else:
        plt.show()


if __name__ == "__main__":
    main()
