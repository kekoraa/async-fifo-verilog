#!/usr/bin/env python3
"""
plot_waveform.py
Renders a static waveform figure from sim/async_fifo.vcd covering the
directed fill-to-full / drain-to-empty test, so the README can show actual
simulation results rather than just an RTL description.
"""
import vcdvcd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD_PATH = "sim/async_fifo.vcd"
OUT_PATH = "docs/waveform.png"

v = vcdvcd.VCDVCD(VCD_PATH)

def get_series(name):
    sig = v[name]
    tv = sig.tv  # list of (time, value_str)
    return tv

def sample_at(tv, times):
    """Step-hold sample of a (time, value) series at the given time points."""
    out = []
    idx = 0
    cur = tv[0][1] if tv else "x"
    for t in times:
        while idx + 1 < len(tv) and tv[idx + 1][0] <= t:
            idx += 1
            cur = tv[idx][1]
        out.append(cur)
    return out

def to_int(vals):
    o = []
    for x in vals:
        try:
            o.append(int(x, 2))
        except ValueError:
            o.append(0)
    return o

sig_names = {
    "wr_clk": "tb_async_fifo.wr_clk",
    "wr_en": "tb_async_fifo.wr_en",
    "wr_data": "tb_async_fifo.wr_data[7:0]",
    "full": "tb_async_fifo.dut.full",
    "almost_full": "tb_async_fifo.dut.almost_full",
    "rd_clk": "tb_async_fifo.rd_clk",
    "rd_en": "tb_async_fifo.rd_en",
    "rd_data": "tb_async_fifo.rd_data[7:0]",
    "empty": "tb_async_fifo.dut.empty",
    "almost_empty": "tb_async_fifo.dut.almost_empty",
}

series = {k: get_series(n) for k, n in sig_names.items()}

# Window: covers reset release through the end of the fill-to-full /
# drain-to-empty directed tests (test 1 + test 2). VCD timestamps are in ps
# (timescale 1ns/1ps), so a 0-900ns window is 0-900000 in raw VCD units.
T0_ns, T1_ns = 0, 900
T0, T1 = T0_ns * 1000, T1_ns * 1000
STEP = 250  # ps -> 0.25ns resolution
times = [T0 + i * STEP for i in range(int((T1 - T0) / STEP))]

samp = {k: sample_at(v_, times) for k, v_ in series.items()}
times_ns = [t / 1000.0 for t in times]

digital_signals = ["wr_clk", "wr_en", "full", "almost_full",
                    "rd_clk", "rd_en", "empty", "almost_empty"]
bus_signals = [("wr_data", samp["wr_data"]), ("rd_data", samp["rd_data"])]

n_rows = len(digital_signals) + len(bus_signals)
fig, axes = plt.subplots(n_rows, 1, figsize=(13, 1.05 * n_rows), sharex=True)

def digital_to_int(vals):
    return [1 if x == "1" else 0 for x in vals]

row = 0
for name in digital_signals:
    ax = axes[row]
    y = digital_to_int(samp[name])
    ax.step(times_ns, y, where="post", linewidth=1.4, color="#2563eb")
    ax.set_ylim(-0.3, 1.3)
    ax.set_yticks([0, 1])
    ax.set_ylabel(name, rotation=0, ha="right", va="center", fontsize=10)
    ax.grid(True, axis="x", linewidth=0.3, alpha=0.5)
    row += 1

for name, vals in bus_signals:
    ax = axes[row]
    ints = to_int(vals)
    ax.step(times_ns, ints, where="post", linewidth=1.2, color="#059669")
    ax.set_ylabel(name, rotation=0, ha="right", va="center", fontsize=10)
    ax.grid(True, axis="x", linewidth=0.3, alpha=0.5)
    row += 1

axes[-1].set_xlabel("time (ns)")
fig.suptitle("async_fifo -- directed test: fill to full, then drain to empty\n"
             "(wr_clk period 7ns, rd_clk period 11ns -- independent, unrelated clocks)",
             fontsize=11)
fig.tight_layout(rect=[0, 0, 1, 0.95])
fig.savefig(OUT_PATH, dpi=150)
print(f"Wrote {OUT_PATH}")
