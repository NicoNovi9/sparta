"""Figure: benefit of balancing the grid by particles instead of cells (CPU).

Reads nicola/results/scaling/cpu_n<N>[_balpart]_<job>/summary.txt (1000-step
runs only) and writes report/figures/balance_cpu.pdf and .png.

    python nicola/report/scripts/plot_balance.py
"""
import glob, os, re
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "..", "..", "results", "scaling")
OUT = os.path.join(HERE, "..", "figures", "balance_cpu")

# reference palette, light mode (validated: CVD dE 24.7, normal dE 33.6)
SURFACE, TEXT, TEXT2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"
C_CELL, C_PART, C_IDEAL = "#2a78d6", "#eb6834", "#8a8983"

def read(d):
    s = open(os.path.join(d, "summary.txt")).read()
    loop = float(re.search(r"Loop time of ([\d.]+)", s).group(1))
    sync = float(re.search(r"MPI Sync\|.*\|\s*([\d.]+)\s*$", s, re.M).group(1))
    nodes = int(re.search(r"^nodes\s+(\d+)", s, re.M).group(1))
    return nodes, loop, sync

runs = {"cell": {}, "part": {}}
for d in glob.glob(os.path.join(RESULTS, "cpu_n*")):
    if re.search(r"_s\d+_", os.path.basename(d)):   # longer runs, e.g. _s10000_
        continue
    kind = "part" if "_balpart_" in d else "cell"
    n, loop, sync = read(d)
    runs[kind][n] = (loop, sync)

nodes = sorted(set(runs["cell"]) & set(runs["part"]))
cell_t = [runs["cell"][n][0] for n in nodes]
part_t = [runs["part"][n][0] for n in nodes]
cell_s = [runs["cell"][n][1] for n in nodes]
part_s = [runs["part"][n][1] for n in nodes]
base = runs["cell"][1][0]

plt.rcParams.update({
    "font.family": "DejaVu Sans", "font.size": 10,
    "axes.edgecolor": GRID, "axes.labelcolor": TEXT2, "axes.titlecolor": TEXT,
    "xtick.color": TEXT2, "ytick.color": TEXT2,
    "axes.spines.top": False, "axes.spines.right": False,
})
fig, axes = plt.subplots(1, 3, figsize=(14, 4.4), facecolor=SURFACE)
for ax in axes:
    ax.set_facecolor(SURFACE)
    ax.grid(axis="y", color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)

x = range(len(nodes))
w = 0.38
gap = 0.02   # surface gap between the two bars of a pair

# 1 - loop time, with the gain per node count
ax = axes[0]
ax.bar([i - w/2 - gap/2 for i in x], cell_t, w, color=C_CELL, label="rcb cell (current deck)")
ax.bar([i + w/2 + gap/2 for i in x], part_t, w, color=C_PART, label="rcb part (after create_particles)")
for i, (a, b) in enumerate(zip(cell_t, part_t)):
    ax.text(i, max(a, b) * 1.03, f"{a/b:.2f}\u00d7 faster", ha="center", va="bottom",
            color=TEXT, fontsize=9.5, fontweight="bold")
ax.set_xticks(list(x), [str(n) for n in nodes])
ax.set_xlabel("nodes (192 MPI ranks each)")
ax.set_ylabel("loop time, 1000 steps [s]")
ax.set_ylim(0, max(cell_t) * 1.15)
ax.set_title("Time to run 1000 steps", loc="left", fontsize=11, fontweight="bold")

# 2 - speedup, both normalised to the current setup on 1 node
ax = axes[1]
ax.plot(nodes, nodes, "--", color=C_IDEAL, linewidth=1.5, label="ideal (current, 1 node = 1)")
ax.plot(nodes, [base/t for t in cell_t], "-o", color=C_CELL, linewidth=2, markersize=8)
ax.plot(nodes, [base/t for t in part_t], "-o", color=C_PART, linewidth=2, markersize=8)
for n, t in zip(nodes, part_t):
    ax.annotate(f"{base/t:.1f}", (n, base/t), textcoords="offset points", xytext=(-9 if n == nodes[-1] else 0, 9),
                ha="center", color=TEXT, fontsize=9)
ax.set_xscale("log", base=2)
ax.set_yscale("log", base=2)
ax.set_xticks(nodes, [str(n) for n in nodes])
ax.minorticks_off()
ax.set_xlabel("nodes")
ax.set_ylabel("speedup vs current setup on 1 node")
ax.set_ylim(0.8, max(nodes) * 1.4)
ax.set_yticks([1, 2, 4, 8], ["1", "2", "4", "8"])
ax.yaxis.set_minor_locator(plt.NullLocator())
ax.set_title("Strong scaling (log-log)", loc="left", fontsize=11, fontweight="bold")

# 3 - why: share of the loop spent waiting for the slowest rank
ax = axes[2]
ax.bar([i - w/2 - gap/2 for i in x], cell_s, w, color=C_CELL)
ax.bar([i + w/2 + gap/2 for i in x], part_s, w, color=C_PART)
ax.set_xticks(list(x), [str(n) for n in nodes])
ax.set_xlabel("nodes")
ax.set_ylabel("MPI Sync, % of loop time")
ax.set_ylim(0, 100)
ax.set_title("Time spent waiting for other ranks", loc="left", fontsize=11, fontweight="bold")

handles, labels = axes[0].get_legend_handles_labels()
h2, l2 = axes[1].get_legend_handles_labels()
fig.legend(handles + h2, labels + l2, loc="upper center", ncol=3, frameon=False,
           bbox_to_anchor=(0.5, 1.0), labelcolor=TEXT)
# no title: in the report the caption carries it
fig.tight_layout(rect=(0, 0, 1, 0.92))
for ext in ("pdf", "png"):
    fig.savefig(f"{OUT}.{ext}", dpi=200, facecolor=SURFACE)
print("written", OUT + ".pdf/.png")
for n, a, b, sa, sb in zip(nodes, cell_t, part_t, cell_s, part_s):
    print(f"{n} nodes: {a:6.2f} -> {b:6.2f} s  ({a/b:.2f}x)   sync {sa:4.1f}% -> {sb:4.1f}%")
