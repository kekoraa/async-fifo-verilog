# Asynchronous (Dual-Clock) FIFO with Gray-Code CDC

A parameterized asynchronous FIFO written in Verilog, verified with a
self-checking testbench (scoreboard + functional-coverage-style reporting),
built to demonstrate front-end RTL design and verification practice for
ASIC/digital-design work: clock-domain crossing (CDC), Gray-code pointer
synchronization, and a verification methodology beyond "it compiled."

No FPGA board required — everything here runs in simulation with the
open-source Icarus Verilog toolchain.

## Why this project

Clock-domain crossing is one of the first things a chip design/verification
interview will probe, because it's where subtle, hard-to-catch bugs live in
real silicon. An asynchronous FIFO is the standard vehicle for demonstrating
it: it forces you to reason about metastability, pointer synchronization, and
what "safe to compare across domains" actually means, rather than just
writing a counter and a mux.

## Architecture

```
        write domain (wr_clk)                    read domain (rd_clk)
   ┌───────────────────────────┐            ┌───────────────────────────┐
   │  wr_bin, wr_gray counters │            │  rd_bin, rd_gray counters │
   │           │               │            │           │               │
   │           ▼               │            │           ▼               │
   │   dual-port memory  ──────┼── mem[] ───┼──►  read data out         │
   │           │               │            │           │               │
   │   wr_gray ├──────────────►│  2-flop    │◄──────────┤ rd_gray       │
   │           │   synchronizer│  sync      │ synchronizer│              │
   │           ▼               │            │           ▼               │
   │   compare vs rd_gray_sync │            │  compare vs wr_gray_sync  │
   │        -> full (reg)      │            │        -> empty (reg)     │
   └───────────────────────────┘            └───────────────────────────┘
```

- **Storage**: a simple inferred dual-port RAM, written on `wr_clk`, read on
  `rd_clk`.
- **Pointers**: both sides keep a binary counter (for addressing memory) and
  its Gray-coded form (for crossing domains). Gray code guarantees only one
  bit changes per increment, so a synchronizer that samples mid-transition
  can only ever be off by one count — never a garbage value.
- **Synchronizers**: each domain's Gray pointer is passed through a 2-flop
  synchronizer (`rtl/gray_sync.v`) into the *other* domain. Two flops is the
  standard choice — it reduces the probability of a metastable value
  propagating downstream to a level that's negligible in practice (MTBF
  grows exponentially with each added stage).
- **Full / empty**: computed by comparing the local pointer against the
  synchronized remote pointer, per Clifford Cummings' well-known
  ["Simulation and Synthesis Techniques for Asynchronous FIFO Design"](https://www.google.com/search?q=cummings+asynchronous+fifo+design+snug+2002)
  (SNUG 2002) full-detection scheme (top two bits inverted + compare).
- **`full` and `empty` are registered outputs**, not combinational — see
  "Bugs found during bring-up" below for why that matters.
- **`almost_full` / `almost_empty`**: derived from the local binary pointer
  and the *recovered binary* form of the synchronized remote Gray pointer —
  never from the remote domain's raw binary counter, which would silently
  reintroduce an unsafe CDC path.

## Repo layout

```
async_fifo/
├── rtl/
│   ├── async_fifo.v      -- the FIFO itself
│   └── gray_sync.v        -- 2-flop Gray-code synchronizer
├── tb/
│   └── tb_async_fifo.v    -- self-checking testbench
├── docs/
│   ├── plot_waveform.py   -- renders waveform.png from the VCD dump
│   └── waveform.png       -- rendered simulation waveform
├── sim/                    -- simulation outputs (gitignored in practice)
└── Makefile
```

## Verification plan

The testbench (`tb/tb_async_fifo.v`) is self-checking: every read is checked
against a behavioral reference queue, not just eyeballed in a waveform
viewer. It runs:

1. **Directed: fill to full.** Write past capacity without reading; confirm
   `full` asserts at exactly the right point and excess writes are silently
   (and correctly) rejected.
2. **Directed: drain to empty.** Read everything back and check FIFO
   ordering (first word in is first word out) against the reference model.
3. **Directed: simultaneous write/read pressure** near the empty boundary,
   using `fork`/`join` on two independently clocked processes.
4. **Randomized stress test.** 2,000 write attempts and 2,000 read attempts,
   each with independently randomized inter-arrival gaps (`$urandom_range`),
   run on two clocks with unrelated periods (7 ns / 11 ns, deliberately not
   a small integer ratio) so the CDC logic is exercised at every possible
   relative phase rather than getting lucky with aligned edges.
5. A continuous safety monitor asserting `full` and `empty` are never both
   true.
6. A functional-coverage-style summary at the end (bins for `full`,
   `empty`, `almost_full`, `almost_empty`, write-while-full,
   read-while-empty, and concurrent write/read activity), so the report
   reads like a verification sign-off rather than a pass/fail stub.

Both write and read tasks *always* drive their enable and let the DUT decide
whether to honor it — the point is to prove the FIFO itself rejects invalid
operations, not to avoid triggering them from the testbench.

### Latest run

```
=====================================================
 RESULTS
=====================================================
 Total writes accepted : 1315
 Total reads checked   : 1315
 Errors                : 0
-----------------------------------------------------
 Coverage summary:
   full asserted (cycles)         : 3771  [HIT]
   empty asserted (cycles)        : 2571  [HIT]
   almost_full asserted (cycles)  : 2894  [HIT]
   almost_empty asserted (cycles) : 7     [HIT]
   write attempted while full     : 722   [HIT]
   read attempted while empty     : 745   [HIT]
   concurrent wr/rd sequences run : 1     [HIT]
=====================================================
 RESULT: ALL CHECKS PASSED
=====================================================
```

![Waveform of the directed fill-to-full / drain-to-empty test](waveform.png)

## Bugs found during bring-up (and why they're worth mentioning)

Both of these were caught by actually simulating and reading the failure,
not by inspection — which is the point of writing a testbench in the first
place. Leaving them documented here because "I hit this and fixed it" is a
more credible signal than a project that happened to work on the first try.

1. **Combinational loop through `full`.** The first version computed `full`
   with a continuous `assign` from `wr_gray_next`, while the pointer
   increment (`wr_bin_next`) was itself gated by `~full`. That's a direct
   cycle: `full → wr_bin_next → wr_gray_next → full`. Icarus Verilog doesn't
   flag this — it just spins through zero-delay evaluation forever, so the
   first simulation run hung indefinitely with no output and no error. The
   fix (and the textbook-correct approach, per Cummings) is to make `full`
   and `empty` **registered** outputs: the pointer increment is gated by the
   *previous* cycle's registered flag, and the *new* flag value is computed
   and registered for next cycle. That turns the cycle into a normal
   sequential dependency.
2. **Reference-model array too small.** The testbench's behavioral scoreboard
   stored expected data in a fixed-size array sized for ~1,000 entries; the
   randomized stress test issues up to ~2,000+ writes. The array silently
   wrapped, and reads past real data compared against uninitialized (`X`)
   memory, producing a wall of spurious mismatches that had nothing to do
   with the DUT. Fixed by sizing the reference array with headroom above the
   test's real operation count — a reminder to size your *testbench*
   scoreboard as carefully as the RTL it's checking.

## Running it

Requires [Icarus Verilog](http://iverilog.icarus.com/) (`iverilog`/`vvp`) and,
optionally, Python 3 with `vcdvcd` + `matplotlib` to regenerate the waveform
PNG.

```bash
# compile + simulate
make sim

# regenerate docs/waveform.png from the VCD dump
make wave

# view the waveform interactively instead (GTKWave)
make gtkwave
```

## What I'd add next

- Convert the immediate-assertion style checks into proper SystemVerilog
  concurrent assertions (SVA) bound to the RTL for tool-driven formal/lint
  checking, rather than testbench-only checks.
- A UVM-style layered testbench (driver/monitor/scoreboard/agent) as the
  natural next step up from this directed-plus-random approach.
- Synthesize through an open-source flow (Yosys) to sanity-check that the
  RTL is synthesizable as written, not just simulatable.
