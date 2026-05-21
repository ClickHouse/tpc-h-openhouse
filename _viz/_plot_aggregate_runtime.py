#!/usr/bin/env python3
import argparse

import pandas as pd
import matplotlib.pyplot as plt
from matplotlib.patches import Patch


VENDOR_COLOR = {
    "ClickHouse": "#FDFF88",
    "Redshift": "#FFB30A",
    "Databricks": "#FF4B3A",
    "Snowflake": "#29B5E8",
    "BigQuery": "#4285F4",
}

BACKGROUND_COLOR = "#2B2B2B"


def wrap_label(label: str) -> str:
    keep_together = {
        "1 x 59 Cores": "1\u00A0x\u00A059\u00A0Cores",
        "1x59Cores": "1\u00A0x\u00A059\u00A0Cores",
        "2000 slots": "2000\u00A0slots",
        "128 RPU": "128\u00A0RPU",
        "59 Cores": "59\u00A0Cores",
        "59Cores": "59\u00A0Cores",
    }

    for old, new in keep_together.items():
        label = label.replace(old, new)

    return label.replace(" ", "\n")


def main():
    parser = argparse.ArgumentParser(
        description="Render aggregate TPC-H hot runtime bar chart from NDJSON."
    )
    parser.add_argument("--out", required=True, help="Output PNG path")
    parser.add_argument("--title", default="TPC-H SF100 aggregate hot runtime")
    parser.add_argument("--no-title", action="store_true")
    parser.add_argument("--no-legend", action="store_true")
    parser.add_argument(
        "--sort",
        action="store_true",
        help="Sort bars by runtime ascending.",
    )
    parser.add_argument(
        "--show-values",
        action="store_true",
        help="Show runtime labels above bars.",
    )
    args = parser.parse_args()

    df = pd.read_json("/dev/stdin", lines=True)

    required = {"system", "bar_label", "rt_hot"}
    missing = required - set(df.columns)
    if missing:
        raise SystemExit(f"Missing required fields: {sorted(missing)}")

    df["rt_hot"] = df["rt_hot"].astype(float)

    if args.sort:
        df = df.sort_values("rt_hot", ascending=True)

    bg = BACKGROUND_COLOR
    grid = "#3A3A3A"
    text = "#F2F2F2"
    muted = "#B8B8B8"

    fig, ax = plt.subplots(figsize=(13.5, 7.2))
    fig.patch.set_facecolor(bg)
    ax.set_facecolor(bg)

    colors = [VENDOR_COLOR.get(system, "#CCCCCC") for system in df["system"]]

    bars = ax.bar(
        df["bar_label"],
        df["rt_hot"],
        color=colors,
        width=0.68,
    )

    if not args.no_title:
        ax.set_title(
            args.title,
            color=text,
            fontsize=26,
            fontweight="bold",
            pad=24,
        )

    ax.set_ylabel(
        "Runtime, seconds — sum of fastest per-query runs",
        color=muted,
        fontsize=13,
    )

    xlabels = [wrap_label(label) for label in df["bar_label"]]
    ax.set_xticklabels(
        xlabels,
        color=text,
        fontsize=12,
        rotation=0,
        ha="center",
        multialignment="center",
    )

    ax.tick_params(axis="y", colors=muted, labelsize=11)

    ax.grid(axis="y", color=grid, linewidth=0.8, alpha=0.9)
    ax.set_axisbelow(True)

    for spine in ax.spines.values():
        spine.set_color(grid)

    if args.show_values:
        ymax = df["rt_hot"].max()
        for bar, value in zip(bars, df["rt_hot"]):
            ax.text(
                bar.get_x() + bar.get_width() / 2,
                value + ymax * 0.025,
                f"{value:.1f}s",
                ha="center",
                va="bottom",
                color=text,
                fontsize=13,
                fontweight="bold",
            )

    if not args.no_legend:
        legend_handles = [
            Patch(
                facecolor=VENDOR_COLOR.get(system, "#CCCCCC"),
                edgecolor="none",
                label=system,
            )
            for system in df["system"]
        ]

        ax.legend(
            handles=legend_handles,
            loc="upper center",
            bbox_to_anchor=(0.5, 1.03 if args.no_title else 1.00),
            ncol=len(legend_handles),
            frameon=False,
            fontsize=11,
            labelcolor=text,
        )

    ax.text(
        0.5,
        -0.18,
        "Lower is better. Runtime is the sum of the fastest run for each of the 22 TPC-H queries.",
        transform=ax.transAxes,
        ha="center",
        va="top",
        color=muted,
        fontsize=12,
    )

    plt.tight_layout(rect=[0.02, 0.13, 0.98, 0.94])
    fig.savefig(
        args.out,
        dpi=180,
        facecolor=fig.get_facecolor(),
        bbox_inches="tight",
    )
    print(f"Wrote {args.out}")


if __name__ == "__main__":
    main()