#!/usr/bin/env python3
"""Compare two TPC-H benchmark result files.

Each input file is a JSON document in the ClickBench-style format:

    {
        "comment": "...",
        "result": [
            [t1, t2, t3],   # query 1: one timing per run (null = failed run)
            ...
        ]
    }

For every query the "best time" is the minimum of its non-null run timings.
A query counts as failed only if all of its runs are null.

The script prints:
  1. A summary table (per file): completed queries, per-query wins,
     total best time and geometric mean of best times.
  2. A per-query breakdown table comparing the best time of each query.

Two best times are treated as a tie when they differ by less than a
relative tolerance (default 1%): i.e. when (max - min) / min < tolerance.

Usage:
    python3 compare_runs.py FILE_A FILE_B [--tolerance 0.01] [--markdown]
"""

import argparse
import json
import math
import os
import sys

RED = "\033[31m"
GREEN = "\033[32m"
RESET = "\033[0m"

# Toggled off when output is not a TTY or --no-color is passed.
USE_COLOR = True


def colorize_winner(text, winner):
    """Wrap text in red for an A win, green for a B win; else leave plain."""
    if not USE_COLOR:
        return text
    if winner == "A":
        return f"{RED}{text}{RESET}"
    if winner == "B":
        return f"{GREEN}{text}{RESET}"
    return text


def colorize_line(text, winner):
    """Colour a whole row: red for an A win, green for a B win."""
    return colorize_winner(text, winner)


def load_best_times(path):
    """Return (metadata, best_times) for a result file.

    best_times is a list with one entry per query: the minimum non-null
    run timing, or None if every run for that query failed.
    """
    with open(path) as f:
        doc = json.load(f)

    best_times = []
    for row in doc.get("result", []):
        if isinstance(row, (int, float)):
            vals = [row]
        else:
            vals = [v for v in row if v is not None]
        best_times.append(min(vals) if vals else None)

    return doc, best_times


def geomean(values):
    """Geometric mean of a list of positive numbers (None if empty)."""
    if not values:
        return None
    return math.exp(sum(math.log(v) for v in values) / len(values))


def short_label(path, doc):
    """A compact label for a file: comment if present, else basename."""
    comment = doc.get("comment")
    base = os.path.basename(path)
    if comment:
        return f"{base}  ({comment})"
    return base


def within_tolerance(va, vb, tol):
    """True if va and vb differ by less than the relative tolerance."""
    if va is None or vb is None:
        return False
    lo = min(va, vb)
    if lo <= 0:
        return va == vb
    return (max(va, vb) - lo) / lo < tol


def compare(path_a, path_b, tol=0.02):
    doc_a, best_a = load_best_times(path_a)
    doc_b, best_b = load_best_times(path_b)

    n = max(len(best_a), len(best_b))
    # Pad the shorter list with None so indices line up.
    best_a += [None] * (n - len(best_a))
    best_b += [None] * (n - len(best_b))

    wins_a = wins_b = ties = 0
    rows = []
    for i in range(n):
        va, vb = best_a[i], best_b[i]

        if va is None and vb is None:
            winner = "both fail"
        elif va is None:
            winner = "B"
            wins_b += 1
        elif vb is None:
            winner = "A"
            wins_a += 1
        elif within_tolerance(va, vb, tol):
            winner = "tie"
            ties += 1
        elif va < vb:
            winner = "A"
            wins_a += 1
        else:
            winner = "B"
            wins_b += 1

        delta = (vb - va) if (va is not None and vb is not None) else None
        ratio = (vb / va) if (va is not None and vb is not None and va > 0) else None
        rows.append((i + 1, va, vb, winner, delta, ratio))

    completed_a = [v for v in best_a if v is not None]
    completed_b = [v for v in best_b if v is not None]

    summary = {
        "completed": (len(completed_a), len(completed_b)),
        "wins": (wins_a, wins_b),
        "ties": ties,
        "total": (sum(completed_a), sum(completed_b)),
        "geomean": (geomean(completed_a), geomean(completed_b)),
    }
    labels = (short_label(path_a, doc_a), short_label(path_b, doc_b))
    summary["tolerance"] = tol
    return labels, summary, rows


def fmt(value, spec="{:.3f}"):
    return spec.format(value) if value is not None else "null"


def winner_of(va, vb, lower_is_better=True, tol=0.0):
    """Return 'A', 'B' or 'tie' comparing two scalar metrics.

    Values within the relative tolerance of each other are a tie.
    """
    if va is None and vb is None:
        return "-"
    if va is None:
        return "B"
    if vb is None:
        return "A"
    if va == vb or within_tolerance(va, vb, tol):
        return "tie"
    if lower_is_better:
        return "A" if va < vb else "B"
    return "A" if va > vb else "B"


def print_summary(labels, summary):
    la, lb = labels
    tol = summary.get("tolerance", 0.0)
    print("=" * 78)
    print("SUMMARY")
    print("=" * 78)
    print(f"A: {la}")
    print(f"B: {lb}")
    print(f"(tie tolerance: {tol * 100:.3g}%)")
    print()

    header = f"{'Metric':<26}{'A':>14}{'B':>14}{'Winner':>10}"
    print(header)
    print("-" * len(header))

    ca, cb = summary["completed"]
    print(f"{'Completed queries (n)':<26}{ca:>14d}{cb:>14d}"
          f"{winner_of(ca, cb, lower_is_better=False):>10}")

    wa, wb = summary["wins"]
    print(f"{'Best queries (n)':<26}{wa:>14d}{wb:>14d}"
          f"{winner_of(wa, wb, lower_is_better=False):>10}")

    ta, tb = summary["total"]
    print(f"{'Total best time (s)':<26}{fmt(ta):>14}{fmt(tb):>14}"
          f"{winner_of(ta, tb, tol=tol):>10}")

    ga, gb = summary["geomean"]
    print(f"{'Geometric mean (s)':<26}{fmt(ga, '{:.4f}'):>14}{fmt(gb, '{:.4f}'):>14}"
          f"{winner_of(ga, gb, tol=tol):>10}")

    if summary["ties"]:
        print(f"\n(ties on per-query best time: {summary['ties']})")


def print_breakdown(rows):
    print()
    print("=" * 78)
    print("PER-QUERY BREAKDOWN (best time per query)")
    print("=" * 78)
    header = (f"{'Q#':>3}  {'A (best)':>10}  {'B (best)':>10}  "
              f"{'Winner':>9}  {'Δ (B-A)':>10}  {'(B-A)/A %':>10}")
    print(header)
    print("-" * len(header))
    for q, va, vb, winner, delta, ratio in rows:
        pct = ((ratio - 1) * 100) if ratio is not None else None
        line = (f"{q:>3}  {fmt(va):>10}  {fmt(vb):>10}  {winner:>9}  "
                f"{fmt(delta, '{:+.3f}'):>10}  {fmt(pct, '{:+.1f}%'):>10}")
        print(colorize_line(line, winner))


def winner_md(winner):
    """Decorate a winner label with a colour-square indicator for Markdown."""
    if winner == "A":
        return "🟥 A"
    if winner == "B":
        return "🟩 B"
    return winner


def print_summary_md(labels, summary):
    la, lb = labels
    tol = summary.get("tolerance", 0.0)
    print("## Summary")
    print()
    print(f"- **A:** {la}")
    print(f"- **B:** {lb}")
    print(f"- Tie tolerance: {tol * 100:.3g}%")
    print()
    print("| Metric | A | B | Winner |")
    print("|---|---:|---:|:---:|")

    ca, cb = summary["completed"]
    print(f"| Completed queries (n) | {ca} | {cb} | "
          f"{winner_md(winner_of(ca, cb, lower_is_better=False))} |")

    wa, wb = summary["wins"]
    print(f"| Best queries (n) | {wa} | {wb} | "
          f"{winner_md(winner_of(wa, wb, lower_is_better=False))} |")

    ta, tb = summary["total"]
    print(f"| Total best time (s) | {fmt(ta)} | {fmt(tb)} | "
          f"{winner_md(winner_of(ta, tb, tol=tol))} |")

    ga, gb = summary["geomean"]
    print(f"| Geometric mean (s) | {fmt(ga, '{:.4f}')} | {fmt(gb, '{:.4f}')} | "
          f"{winner_md(winner_of(ga, gb, tol=tol))} |")

    if summary["ties"]:
        print()
        print(f"_Ties on per-query best time: {summary['ties']}_")


def print_breakdown_md(rows):
    print()
    print("## Per-query breakdown (best time per query)")
    print()
    print("| Q# | A (best) | B (best) | Winner | Δ (B-A) | (B-A)/A % |")
    print("|---:|---:|---:|:---:|---:|---:|")
    for q, va, vb, winner, delta, ratio in rows:
        pct = ((ratio - 1) * 100) if ratio is not None else None
        print(f"| {q} | {fmt(va)} | {fmt(vb)} | {winner_md(winner)} | "
              f"{fmt(delta, '{:+.3f}')} | {fmt(pct, '{:+.1f}%')} |")


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Compare two TPC-H benchmark result JSON files.")
    parser.add_argument("file_a", help="First result file (labelled A)")
    parser.add_argument("file_b", help="Second result file (labelled B)")
    parser.add_argument(
        "-t", "--tolerance", type=float, default=0.01,
        help="Relative tolerance for calling a tie (default: 0.01 = 1%%). "
             "Accepts a fraction, e.g. 0.05 for 5%%.")
    parser.add_argument(
        "--no-color", action="store_true",
        help="Disable ANSI colour in the per-query breakdown.")
    parser.add_argument(
        "-m", "--markdown", action="store_true",
        help="Emit GitHub-flavoured Markdown tables instead of plain text.")
    args = parser.parse_args(argv)

    if args.tolerance < 0:
        parser.error("tolerance must be >= 0")

    global USE_COLOR
    USE_COLOR = (
        not args.no_color
        and not args.markdown
        and os.environ.get("NO_COLOR") is None
        and sys.stdout.isatty()
    )

    for p in (args.file_a, args.file_b):
        if not os.path.isfile(p):
            parser.error(f"file not found: {p}")

    labels, summary, rows = compare(args.file_a, args.file_b, tol=args.tolerance)
    if args.markdown:
        print_summary_md(labels, summary)
        print_breakdown_md(rows)
    else:
        print_summary(labels, summary)
        print_breakdown(rows)
    return 0


if __name__ == "__main__":
    sys.exit(main())
