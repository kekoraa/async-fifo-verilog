// -----------------------------------------------------------------------------
// tb_async_fifo.v
// Self-checking testbench for async_fifo.
//
// Verification strategy:
//   1. Independent, unrelated write/read clocks (different periods, no
//      common multiple within the sim window) to genuinely stress the CDC
//      logic rather than get lucky with aligned edges.
//   2. A behavioral reference model (a plain SystemVerilog-style queue) that
//      mirrors expected FIFO contents. Every read is checked against it --
//      this is a scoreboard, not just a "did it not crash" test.
//   3. Directed corner-case tests: fill to full, drain to empty, simultaneous
//      write+read at boundaries, back-to-back writes while nominally full,
//      back-to-back reads while nominally empty (both must be gracefully
//      ignored, per the RTL's full/empty gating).
//   4. A randomized stress test with randomized inter-arrival gaps on both
//      sides, run for many thousand cycles, checking data integrity, FIFO
//      ordering, and flag correctness (full/empty never both true, no
//      overflow/underflow) every cycle.
//   5. A simple functional-coverage-style tally (bins hit) printed at the end
//      so results read like a real verification report, not just a log.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_async_fifo;

    localparam DATA_WIDTH = 8;
    localparam ADDR_WIDTH = 4;
    localparam DEPTH      = 1 << ADDR_WIDTH;

    reg                    wr_clk = 0;
    reg                    rd_clk = 0;
    reg                    wr_rst_n = 0;
    reg                    rd_rst_n = 0;
    reg                    wr_en = 0;
    reg  [DATA_WIDTH-1:0]  wr_data = 0;
    wire                   full, almost_full;
    reg                    rd_en = 0;
    wire [DATA_WIDTH-1:0]  rd_data;
    wire                   empty, almost_empty;

    integer errors   = 0;
    integer checks   = 0;
    integer wr_count = 0;
    integer rd_count = 0;

    // Reference model: simple behavioral FIFO queue mirroring expected data.
    // Sized generously above the total number of writes issued across the
    // whole test (directed tests + 2000-iteration randomized stress test):
    // undersizing this array was an actual bug hit during bring-up -- it
    // silently wrapped/corrupted ref_tail and produced spurious "expected=x"
    // mismatches around read #1025 that had nothing to do with the DUT.
    reg [DATA_WIDTH-1:0] ref_queue [0:16383];
    integer ref_head = 0;
    integer ref_tail = 0;

    task ref_push(input [DATA_WIDTH-1:0] d);
        begin
            ref_queue[ref_tail] = d;
            ref_tail = ref_tail + 1;
        end
    endtask

    // Coverage-style bins
    integer cov_full_hit        = 0;
    integer cov_empty_hit       = 0;
    integer cov_almost_full_hit = 0;
    integer cov_almost_empty_hit= 0;
    integer cov_simul_wr_rd     = 0;
    integer cov_write_to_full   = 0;
    integer cov_read_from_empty = 0;

    async_fifo #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) dut (
        .wr_clk       (wr_clk),
        .wr_rst_n     (wr_rst_n),
        .wr_en        (wr_en),
        .wr_data      (wr_data),
        .full         (full),
        .almost_full  (almost_full),
        .rd_clk       (rd_clk),
        .rd_rst_n     (rd_rst_n),
        .rd_en        (rd_en),
        .rd_data      (rd_data),
        .empty        (empty),
        .almost_empty (almost_empty)
    );

    // Clocks: 7ns and 11ns periods (coprime-ish, so relative phase drifts --
    // guarantees we exercise every edge relationship over time)
    always #3.5 wr_clk = ~wr_clk;
    always #5.5 rd_clk = ~rd_clk;

    initial begin
        $dumpfile("sim/async_fifo.vcd");
        $dumpvars(0, tb_async_fifo);
    end

    // ---------------- Coverage / safety monitor (every wr_clk & rd_clk edge) ----------------
    always @(posedge wr_clk) begin
        if (full)                       cov_full_hit = cov_full_hit + 1;
        if (almost_full)                cov_almost_full_hit = cov_almost_full_hit + 1;
        if (wr_en && full) begin
            cov_write_to_full = cov_write_to_full + 1;
        end
    end

    always @(posedge rd_clk) begin
        if (empty)                      cov_empty_hit = cov_empty_hit + 1;
        if (almost_empty)               cov_almost_empty_hit = cov_almost_empty_hit + 1;
        if (rd_en && empty) begin
            cov_read_from_empty = cov_read_from_empty + 1;
        end
    end

    // Safety invariant: full and empty must never both be asserted for a
    // non-trivial (depth > 1) FIFO. Checked continuously.
    always @(*) begin
        if (full && empty) begin
            errors = errors + 1;
            $display("[%0t] ERROR: full and empty asserted simultaneously!", $time);
        end
    end

    // ---------------- Write driver ----------------
    task automatic do_write(input [DATA_WIDTH-1:0] d);
        reg was_full;
        begin
            @(posedge wr_clk);
            #0.1;
            was_full = full;
            wr_en    = 1;          // always attempt -- RTL must reject if full
            wr_data  = d;
            @(posedge wr_clk);
            #0.1;
            wr_en = 0;
            if (!was_full) begin
                ref_push(d);
                wr_count = wr_count + 1;
            end
        end
    endtask

    // ---------------- Read + check ----------------
    task automatic do_read_and_check;
        reg [DATA_WIDTH-1:0] expected;
        reg was_empty;
        begin
            @(posedge rd_clk);
            #0.1;
            was_empty = empty;
            rd_en     = 1;          // always attempt -- RTL must reject if empty
            @(posedge rd_clk);
            #0.1;
            rd_en = 0;
            if (!was_empty) begin
                expected = ref_queue[ref_head];
                ref_head = ref_head + 1;
                rd_count = rd_count + 1;
                checks   = checks + 1;
                if (rd_data !== expected) begin
                    errors = errors + 1;
                    $display("[%0t] ERROR: rd_data=%0h expected=%0h (read #%0d)",
                              $time, rd_data, expected, rd_count);
                end
            end
        end
    endtask

    integer i;
    reg [DATA_WIDTH-1:0] rand_byte;

    initial begin
        // ---------------- Reset ----------------
        wr_rst_n = 0; rd_rst_n = 0;
        wr_en = 0; rd_en = 0;
        repeat (5) @(posedge wr_clk);
        wr_rst_n = 1;
        repeat (5) @(posedge rd_clk);
        rd_rst_n = 1;
        repeat (3) @(posedge wr_clk);

        $display("=====================================================");
        $display(" ASYNC FIFO VERIFICATION  (DATA_WIDTH=%0d, DEPTH=%0d)", DATA_WIDTH, DEPTH);
        $display("=====================================================");

        // ---------------- Directed test 1: fill to full ----------------
        $display("[TEST 1] Fill FIFO to full without reading...");
        for (i = 0; i < DEPTH + 4; i = i + 1) begin
            do_write(i[DATA_WIDTH-1:0]);
        end
        if (!full) begin
            errors = errors + 1;
            $display("ERROR: expected FIFO full after %0d writes, full=%b", DEPTH, full);
        end else begin
            $display("  -> full asserted correctly after %0d accepted writes (attempted %0d)",
                       wr_count, DEPTH + 4);
        end

        // ---------------- Directed test 2: drain to empty, check order ----------------
        $display("[TEST 2] Drain FIFO to empty, verifying FIFO ordering...");
        for (i = 0; i < DEPTH + 4; i = i + 1) begin
            do_read_and_check;
        end
        if (!empty) begin
            errors = errors + 1;
            $display("ERROR: expected FIFO empty after full drain, empty=%b", empty);
        end else begin
            $display("  -> empty asserted correctly, %0d values verified against reference model",
                       checks);
        end

        // ---------------- Directed test 3: simultaneous write+read at boundary ----------------
        $display("[TEST 3] Simultaneous write and read pressure near empty...");
        fork
            begin
                for (i = 0; i < 20; i = i + 1) do_write($random);
            end
            begin
                repeat (5) @(posedge rd_clk); // let some data accumulate first
                for (i = 0; i < 20; i = i + 1) do_read_and_check;
                cov_simul_wr_rd = cov_simul_wr_rd + 1;
            end
        join

        // ---------------- Randomized stress test ----------------
        $display("[TEST 4] Randomized stress test (2000 write attempts, 2000 read attempts, independent random gaps)...");
        fork
            begin : rand_writer
                integer n;
                for (n = 0; n < 2000; n = n + 1) begin
                    repeat ($urandom_range(0,3)) @(posedge wr_clk); // random gap
                    rand_byte = $urandom_range(0,255);
                    do_write(rand_byte);
                end
            end
            begin : rand_reader
                integer n;
                for (n = 0; n < 2000; n = n + 1) begin
                    repeat ($urandom_range(0,3)) @(posedge rd_clk); // random gap
                    do_read_and_check;
                end
            end
        join

        // Drain anything left so the reference model empties out cleanly
        repeat (DEPTH*2) do_read_and_check;

        // ---------------- Report ----------------
        $display("=====================================================");
        $display(" RESULTS");
        $display("=====================================================");
        $display(" Total writes accepted : %0d", wr_count);
        $display(" Total reads checked   : %0d", checks);
        $display(" Errors                : %0d", errors);
        $display("-----------------------------------------------------");
        $display(" Coverage summary:");
        $display("   full asserted (cycles)         : %0d %s", cov_full_hit,        cov_full_hit>0        ? "[HIT]" : "[MISS]");
        $display("   empty asserted (cycles)        : %0d %s", cov_empty_hit,       cov_empty_hit>0       ? "[HIT]" : "[MISS]");
        $display("   almost_full asserted (cycles)  : %0d %s", cov_almost_full_hit, cov_almost_full_hit>0 ? "[HIT]" : "[MISS]");
        $display("   almost_empty asserted (cycles) : %0d %s", cov_almost_empty_hit,cov_almost_empty_hit>0? "[HIT]" : "[MISS]");
        $display("   write attempted while full     : %0d %s", cov_write_to_full,   cov_write_to_full>0   ? "[HIT]" : "[MISS]");
        $display("   read attempted while empty     : %0d %s", cov_read_from_empty, cov_read_from_empty>0 ? "[HIT]" : "[MISS]");
        $display("   concurrent wr/rd sequences run  : %0d %s", cov_simul_wr_rd,     cov_simul_wr_rd>0     ? "[HIT]" : "[MISS]");
        $display("=====================================================");
        if (errors == 0)
            $display(" RESULT: ALL CHECKS PASSED");
        else
            $display(" RESULT: %0d CHECK(S) FAILED", errors);
        $display("=====================================================");

        $finish;
    end

    // Safety timeout
    initial begin
        #200000;
        $display("ERROR: TIMEOUT -- simulation did not finish in time");
        $finish;
    end

endmodule
