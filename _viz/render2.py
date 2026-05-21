#!/usr/bin/env python3
import sys
import json
import argparse
import matplotlib
import matplotlib.pyplot as plt
from matplotlib.ticker import ScalarFormatter
from matplotlib.ticker import FuncFormatter, NullFormatter
from matplotlib.transforms import offset_copy

matplotlib.rcParams['font.family'] = 'Inter'
matplotlib.rcParams['font.sans-serif'] = ['Inter']
matplotlib.rcParams['font.weight'] = 'normal'
matplotlib.rcParams['axes.titleweight'] = 'bold'

VENDOR_COLOR = {
    "ClickHouse": "#FDFF88",
    "Redshift":   "#FFB30A",
    "Databricks": "#FF4B3A",
    "Snowflake":  "#29B5E8",
    "BigQuery":   "#4285F4",
    "Alibaba":    "#FF6A00",
}

XTICKS = [100, 200, 300, 500, 1000]
YTICKS = [10, 20, 30, 50, 70, 100, 200, 500, 1000, 2000, 3000]

BACKGROUND_COLOR = "#2B2B2B"


def load_records_from_stdin():
    return [json.loads(line.strip()) for line in sys.stdin if line.strip()]


def vendor_from_system(system: str) -> str:
    return system


def auto_label(rec: dict) -> str:
    system = rec.get("system", "")
    cluster = str(rec.get("cluster", "")).lower()

    if system in ("Databricks", "Snowflake"):
        if "4x" in cluster:
            size = "4XL"
        elif "large" in cluster or cluster in ("8",):
            size = "L"
        else:
            size = cluster or "?"
        return f"{system} Ent ({size})"
    return system or "unknown"


def parse_tick_list(value):
    if not value:
        return None
    return [float(v.strip()) for v in value.split(",") if v.strip()]


def parse_range(s):
    if not s:
        return None
    lo, hi = [p.strip() for p in s.split(",")]
    return float(lo), float(hi)


def parse_clustering_costs(values):
    result = {}
    for v in values or []:
        if "=" not in v:
            raise ValueError(
                f"Invalid --clustering-cost value '{v}'. Expected format ID=AMOUNT, e.g. 20=2550"
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


def main():
    parser = argparse.ArgumentParser(
        description="Render runtime vs cost scatter plot from NDJSON input."
    )
    parser.add_argument("-o", "--out", help="Output PNG filename.")
    parser.add_argument("--dpi", type=int, default=300)

    parser.add_argument("--no-title", action="store_true")
    parser.add_argument("--no-labels", action="store_true")
    parser.add_argument(
        "--with-axes",
        action="store_true",
        help="Enable axes, ticks, and spines (disabled by default)."
    )

    parser.add_argument("--marker-size", type=float, default=70)

    parser.add_argument("--xticks", type=str)
    parser.add_argument("--yticks", type=str)
    parser.add_argument("--xlim", type=str)
    parser.add_argument(
        "--clustering-cost",
        action="append",
        default=[],
        metavar="ID=AMOUNT",
        help="Extra clustering cost to add to cost_hot for a specific record id, e.g. --clustering-cost 20=2550",
    )

    args = parser.parse_args()

    try:
        clustering_costs = parse_clustering_costs(args.clustering_cost)
    except ValueError as e:
        print(str(e), file=sys.stderr)
        sys.exit(2)

    records = load_records_from_stdin()
    if not records:
        print("No input records from stdin.", file=sys.stderr)
        sys.exit(1)

    runtimes = [float(r["rt_hot"]) for r in records]
    costs = [
        float(r["cost_hot"]) + clustering_costs.get(str(r.get("id", "")), 0.0)
        for r in records
    ]
    labels = [r.get("bar_label") or auto_label(r) for r in records]
    vendors = [vendor_from_system(r["system"]) for r in records]

    fig, ax = plt.subplots(figsize=(8, 6))
    fig.patch.set_facecolor(BACKGROUND_COLOR)
    ax.set_facecolor(BACKGROUND_COLOR)

    # ----------------------- PLOT BUBBLES & LABELS -----------------------
    texts = []
    for x, y, label, vendor in zip(runtimes, costs, labels, vendors):
        color = VENDOR_COLOR.get(vendor, "white")
        size = args.marker_size * (1.3 if "4X" in label or "4XL" in label else 1.0)

        ax.scatter(
            x, y,
            s=size,
            color=color,
            edgecolors="black",
            linewidths=0.8,
            zorder=3,
        )

        if not args.no_labels:
            x_off, y_off, ha = -8, 0, "right"

            if "Snowflake (unclustered," in label:
                x_off = 180
                y_off = 0
                ha = "right"
            elif "Snowflake (Gen2" in label:
                x_off = 138
                y_off = 0
                ha = "right"

            text_transform = offset_copy(
                ax.transData, fig=fig, x=x_off, y=y_off, units="points"
            )
            texts.append(
                ax.text(
                    x,
                    y,
                    label,
                    transform=text_transform,
                    fontsize=10,
                    color="white",
                    ha=ha,
                    va="center",
                )
            )

    # ----------------------- LOG + INVERSION -----------------------
    ax.set_xscale("log")
    ax.set_yscale("log")

    if args.xlim:
        xmin, xmax = parse_range(args.xlim)
        ax.set_xlim(xmin, xmax)

    # Gartner orientation: low runtime + low cost = TOP RIGHT
    ax.invert_xaxis()
    ax.invert_yaxis()

    xticks = parse_tick_list(args.xticks) or XTICKS
    yticks = parse_tick_list(args.yticks) or YTICKS
    ax.set_xticks(xticks)
    ax.set_yticks(yticks)

    ax.xaxis.set_major_formatter(ScalarFormatter())
    ax.xaxis.get_major_formatter().set_scientific(False)
    ax.yaxis.set_major_formatter(FuncFormatter(lambda y, pos: f"{y:g}"))
    ax.yaxis.set_minor_formatter(NullFormatter())

    # ----------------------- AXES ON / OFF -----------------------
    if not args.with_axes:
        ax.minorticks_off()
        ax.tick_params(
            which="both",
            bottom=False,
            top=False,
            left=False,
            right=False,
            labelbottom=False,
            labeltop=False,
            labelleft=False,
            labelright=False,
        )
        for spine in ax.spines.values():
            spine.set_visible(False)
        ax.grid(False)
        ax.set_xlabel("")
        ax.set_ylabel("")
    else:
        ax.minorticks_on()

        for side in ("left", "bottom"):
            ax.spines[side].set_visible(False)
        for side in ("top", "right"):
            ax.spines[side].set_visible(True)
            ax.spines[side].set_color("white")

        ax.xaxis.tick_top()
        ax.yaxis.tick_right()
        ax.xaxis.set_label_position("top")
        ax.yaxis.set_label_position("right")

        ax.tick_params(
            which="both",
            bottom=False,
            top=True,
            left=False,
            right=True,
            labelbottom=False,
            labeltop=True,
            labelleft=False,
            labelright=True,
            colors="white",
        )

        ax.grid(False)

        ax.set_xlabel(
            "Total runtime (s; log scale)\n↓ lower is better",
            color="white",
            labelpad=8,
        )
        ax.set_ylabel(
            "Total cost (USD; log scale)\n↓ lower is better",
            color="white",
            labelpad=12,
        )

    # ----------------------- TITLE -----------------------
    if not args.no_title:
        ax.set_title("Runtime vs Cost", color="white", pad=15)

    plt.tight_layout()

    if args.out:
        plt.savefig(args.out, dpi=args.dpi, facecolor=fig.get_facecolor())
    else:
        plt.show()


if __name__ == "__main__":
    main()