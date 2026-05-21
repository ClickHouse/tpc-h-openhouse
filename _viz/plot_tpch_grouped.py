#!/usr/bin/env python3
import argparse
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

SYSTEM_ORDER = [
    "ClickHouse",
    "BigQuery",
    "Redshift",
    "Snowflake",
    "Databricks",
]

DISPLAY_LABEL = {
    "ClickHouse": "ClickHouse",
    "BigQuery": "BigQuery",
    "Redshift": "Redshift",
    "Snowflake": "Snowflake",
    "Databricks": "Databricks",
}


def main():
    parser = argparse.ArgumentParser(
        description="Render one grouped TPC-H runtime chart from NDJSON."
    )
    parser.add_argument("--input", required=True, help="Input NDJSON file")
    parser.add_argument("--output", required=True, help="Output PNG file")
    parser.add_argument("--title", default="TPC-H hot query runtimes")
    parser.add_argument("--log-scale", action="store_true", help="Use log scale for y-axis.")
    parser.add_argument(
        "--sort-within-query",
        action="store_true",
        help="Sort bars within each query group by runtime ascending.",
    )
    args = parser.parse_args()

    df = pd.read_json(args.input, lines=True)

    required = {"system", "query_id", "query_label", "rt_hot"}
    missing = required - set(df.columns)
    if missing:
        raise SystemExit(f"Missing required columns: {sorted(missing)}")

    df["query_id"] = df["query_id"].astype(int)
    df["rt_hot"] = df["rt_hot"].astype(float)

    bg = "#2B2B2B"
    grid = "#303030"
    text = "#F2F2F2"
    muted = "#B8B8B8"

    queries = (
        df[["query_id", "query_label"]]
        .drop_duplicates()
        .sort_values("query_id")
        .to_dict("records")
    )

    systems = [s for s in SYSTEM_ORDER if s in set(df["system"])]

    n_queries = len(queries)
    x = list(range(n_queries))
    group_width = 0.82
    bar_width = group_width / len(systems)

    fig, ax = plt.subplots(figsize=(24, 9))
    fig.patch.set_facecolor(bg)
    ax.set_facecolor(bg)

    system_rank = {system: i for i, system in enumerate(SYSTEM_ORDER)}

    for q_pos, q in enumerate(queries):
        qdf = df[df["query_id"] == q["query_id"]].copy()

        if args.sort_within_query:
            qdf = qdf.sort_values(["rt_hot", "system"])
        else:
            qdf["system_rank"] = qdf["system"].map(system_rank).fillna(999)
            qdf = qdf.sort_values(["system_rank", "system"])

        q_systems = qdf["system"].tolist()
        q_values = qdf["rt_hot"].tolist()

        for i, (system, value) in enumerate(zip(q_systems, q_values)):
            xpos = q_pos - group_width / 2 + bar_width / 2 + i * bar_width
            ax.bar(
                xpos,
                value,
                width=bar_width * 0.94,
                color=VENDOR_COLOR.get(system, "#CCCCCC"),
            )

    ax.set_title(args.title, color=text, fontsize=26, fontweight="bold", pad=24)

    ax.set_xticks(x)
    ax.set_xticklabels([q["query_label"] for q in queries], color=text, fontsize=12)
    ax.tick_params(axis="y", colors=muted, labelsize=11)

    if args.log_scale:
        ax.set_yscale("log")
        ax.set_ylabel(
            "Runtime, seconds — fastest of 3 runs, log scale",
            color=muted,
            fontsize=13,
        )
    else:
        ax.set_ylabel(
            "Runtime, seconds — fastest of 3 runs",
            color=muted,
            fontsize=13,
        )

    ax.grid(axis="y", color=grid, linewidth=0.8, alpha=0.9)
    ax.set_axisbelow(True)

    for spine in ax.spines.values():
        spine.set_color(grid)

    legend_handles = [
        Patch(
            facecolor=VENDOR_COLOR.get(system, "#CCCCCC"),
            edgecolor="none",
            label=DISPLAY_LABEL.get(system, system),
        )
        for system in systems
    ]

    ax.legend(
        handles=legend_handles,
        loc="upper center",
        bbox_to_anchor=(0.5, 1.08),
        ncol=len(systems),
        frameon=False,
        fontsize=13,
        labelcolor=text,
    )

    note = "Lower is better. Each bar shows the fastest runtime across three benchmark runs."
    if args.sort_within_query:
        note += " Bars are sorted fastest-to-slowest within each query."

    ax.text(
        0.5,
        -0.12,
        note,
        transform=ax.transAxes,
        ha="center",
        va="top",
        color=muted,
        fontsize=12,
    )

    plt.tight_layout(rect=[0.01, 0.06, 0.99, 0.93])
    fig.savefig(args.output, dpi=180, facecolor=fig.get_facecolor(), bbox_inches="tight")
    print(f"Wrote {args.output}")


if __name__ == "__main__":
    main()