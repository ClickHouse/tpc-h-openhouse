#!/usr/bin/env python3
import argparse
import math
import textwrap

import pandas as pd
import matplotlib.pyplot as plt
from matplotlib.patches import Patch


VENDOR_COLOR = {
    "ClickHouse": "#FDFF88",
    "Redshift":   "#FFB30A",
    "Databricks": "#FF4B3A",
    "Snowflake":  "#29B5E8",
    "BigQuery":   "#4285F4",
}

# This controls bar order within each query panel.
BAR_ORDER = [
    "ClickHouse 1 x 59 Cores",
    "Snowflake Medium",
    "Snowflake Large",
    "Snowflake 4X-L",
    "Databricks Medium",
    "Databricks Large",
    "Databricks 4X-Large",
    "BigQuery 2000 slots",
    "Redshift Serverless 128 RPU",
]

SHORT_LABEL = {
    "ClickHouse 1 x 59 Cores": "CH\n1x59C",
    "BigQuery 2000 slots": "BQ",
    "Redshift Serverless 128 RPU": "RS",
    "Snowflake Medium": "SF\nM",
    "Snowflake Large": "SF\nL",
    "Snowflake 4X-L": "SF\n4XL",
    "Databricks Medium": "DB\nM",
    "Databricks Large": "DB\nL",
    "Databricks 4X-Large": "DB\n4XL",
}


def label_for_bar(label: str) -> str:
    if label in SHORT_LABEL:
        return SHORT_LABEL[label]
    return "\n".join(textwrap.wrap(label, 10))


def main():
    parser = argparse.ArgumentParser(
        description="Render TPC-H per-query hot runtime bars from NDJSON."
    )
    parser.add_argument("--input", required=True, help="Input NDJSON file")
    parser.add_argument("--output", required=True, help="Output PNG file")
    parser.add_argument("--title", default="TPC-H hot query runtimes")
    parser.add_argument(
        "--log-scale",
        action="store_true",
        help="Use log scale for y-axis. Useful when outliers dominate.",
    )
    parser.add_argument(
    "--cols",
    type=int,
    default=6,
    help="Maximum number of sub-charts per row. Default: 6.",
    )
    args = parser.parse_args()

    df = pd.read_json(args.input, lines=True)

    required = {"system", "bar_label", "query_id", "query_label", "rt_hot"}
    missing = required - set(df.columns)
    if missing:
        raise SystemExit(f"Missing required columns: {sorted(missing)}")

    df["query_id"] = df["query_id"].astype(int)
    df["rt_hot"] = df["rt_hot"].astype(float)

    order_map = {label: i for i, label in enumerate(BAR_ORDER)}
    df["bar_order"] = df["bar_label"].map(order_map).fillna(999).astype(int)

    queries = sorted(df["query_id"].unique())

    ncols = args.cols
    nrows = math.ceil(len(queries) / ncols)

    fig_w = 24
    fig_h = 3.25 * nrows

    fig, axes = plt.subplots(nrows=nrows, ncols=ncols, figsize=(fig_w, fig_h))
    axes = axes.flatten()

    bg = "#2B2B2B"
    grid = "#333333"
    text = "#F5F5F5"
    muted = "#B8B8B8"

    fig.patch.set_facecolor(bg)

    for ax in axes:
        ax.set_facecolor(bg)

    for ax, query_id in zip(axes, queries):
        qdf = df[df["query_id"] == query_id].sort_values(["bar_order", "bar_label"])

        labels = [label_for_bar(x) for x in qdf["bar_label"]]
        values = qdf["rt_hot"].tolist()
        colors = [VENDOR_COLOR.get(x, "#CCCCCC") for x in qdf["system"]]

        x = list(range(len(values)))
        ax.bar(x, values, color=colors, width=0.76)

        ax.set_title(f"Q{query_id:02d}", color=text, fontsize=15, fontweight="bold", pad=8)
        ax.set_xticks(x)
        ax.set_xticklabels(labels, color=text, fontsize=8)
        ax.tick_params(axis="y", colors=muted, labelsize=8)

        ax.grid(axis="y", color=grid, linewidth=0.6, alpha=0.85)
        ax.set_axisbelow(True)

        for spine in ax.spines.values():
            spine.set_color(grid)

        if args.log_scale:
            ax.set_yscale("log")
            ax.set_ylabel("sec, log", color=muted, fontsize=8)
        else:
            ax.set_ylabel("sec", color=muted, fontsize=8)

        ymax = max(values) if values else 0
        for i, v in enumerate(values):
            if args.log_scale:
                y = v * 1.08
            else:
                y = v + ymax * 0.035

            ax.text(
                i,
                y,
                f"{v:.2f}",
                ha="center",
                va="bottom",
                color="#EDEDED",
                fontsize=7,
                rotation=90,
            )

    for ax in axes[len(queries):]:
        ax.axis("off")

    legend_handles = [
        Patch(facecolor=color, edgecolor="none", label=vendor)
        for vendor, color in VENDOR_COLOR.items()
    ]

    fig.legend(
        handles=legend_handles,
        loc="upper center",
        ncol=len(legend_handles),
        frameon=False,
        fontsize=13,
        labelcolor=text,
        bbox_to_anchor=(0.5, 0.985),
    )

    fig.suptitle(
        args.title,
        color=text,
        fontsize=26,
        fontweight="bold",
        y=1.035,
    )

    fig.text(
        0.5,
        0.012,
        "Each bar shows the fastest of three runs. Lower is better.",
        ha="center",
        color=muted,
        fontsize=12,
    )

    plt.tight_layout(rect=[0.01, 0.04, 0.99, 0.94])
    fig.savefig(args.output, dpi=180, facecolor=fig.get_facecolor(), bbox_inches="tight")
    print(f"Wrote {args.output}")


if __name__ == "__main__":
    main()