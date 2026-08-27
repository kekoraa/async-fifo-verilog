// -----------------------------------------------------------------------------
// async_fifo.v
// Parameterized asynchronous (dual-clock) FIFO with Gray-code pointer CDC.
//
// Architecture (Cummings, "Simulation and Synthesis Techniques for
// Asynchronous FIFO Design", SNUG 2002 -- the canonical reference for this
// structure):
//   - Dual-port memory, written by wr_clk, read by rd_clk.
//   - Read/write addresses kept as binary counters AND their Gray-coded
//     equivalents. Gray code is used for CDC because only one bit changes
//     per increment, so a synchronizer sampling mid-transition can only ever
//     be off by one count -- never garbage.
//   - Each domain synchronizes the *other* domain's Gray pointer into its own
//     clock via a 2-flop synchronizer (gray_sync.v), then compares pointers
//     to generate full/empty.
//   - full  = write pointer (in gray) would equal read pointer with the top
//             two bits inverted (the standard "wrapped around and caught up"
//             check).
//   - empty = read pointer (gray) equals the synchronized write pointer.
// -----------------------------------------------------------------------------
module async_fifo #(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 4                 // FIFO depth = 2**ADDR_WIDTH
) (
    // Write domain
    input  wire                    wr_clk,
    input  wire                    wr_rst_n,
    input  wire                    wr_en,
    input  wire [DATA_WIDTH-1:0]   wr_data,
    output reg                     full,
    output wire                    almost_full,

    // Read domain
    input  wire                    rd_clk,
    input  wire                    rd_rst_n,
    input  wire                    rd_en,
    output reg  [DATA_WIDTH-1:0]   rd_data,
    output reg                     empty,
    output wire                    almost_empty
);

    localparam DEPTH = 1 << ADDR_WIDTH;

    // Memory (inferred dual-port RAM)
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // Binary + Gray pointers, one extra MSB used as a wrap bit for full detect
    reg  [ADDR_WIDTH:0] wr_bin, wr_gray;
    reg  [ADDR_WIDTH:0] rd_bin, rd_gray;

    wire [ADDR_WIDTH:0] wr_gray_sync;   // write pointer synced into rd_clk
    wire [ADDR_WIDTH:0] rd_gray_sync;   // read pointer synced into wr_clk

    wire [ADDR_WIDTH:0] wr_bin_next  = wr_bin + (wr_en & ~full);
    wire [ADDR_WIDTH:0] wr_gray_next = (wr_bin_next >> 1) ^ wr_bin_next;

    wire [ADDR_WIDTH:0] rd_bin_next  = rd_bin + (rd_en & ~empty);
    wire [ADDR_WIDTH:0] rd_gray_next = (rd_bin_next >> 1) ^ rd_bin_next;

    // ---------------------------------------------------------------
    // Write domain
    // ---------------------------------------------------------------
    // NOTE ON A BUG WE HIT DURING BRING-UP: `full` must be a REGISTERED
    // signal, not a continuous `assign` computed from wr_gray_next. wr_bin_next
    // is gated by `~full`, and if `full` were itself combinationally derived
    // from wr_gray_next (which depends on wr_bin_next), you get a zero-delay
    // combinational loop: full -> wr_bin_next -> wr_gray_next -> full. Icarus
    // Verilog doesn't detect this and just spins forever evaluating delta
    // cycles without simulation time advancing (that's exactly what happened
    // the first time this was simulated -- vvp hung with no output). Cummings'
    // original paper registers this flag for the same reason; the fix here is
    // to gate the *next* pointer with the previously-registered `full`, and
    // compute the *new* `full` for next cycle from that.
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_bin  <= {(ADDR_WIDTH+1){1'b0}};
            wr_gray <= {(ADDR_WIDTH+1){1'b0}};
            full    <= 1'b0;
        end else begin
            wr_bin  <= wr_bin_next;
            wr_gray <= wr_gray_next;
            full    <= (wr_gray_next == {~rd_gray_sync[ADDR_WIDTH:ADDR_WIDTH-1],
                                           rd_gray_sync[ADDR_WIDTH-2:0]});
        end
    end

    always @(posedge wr_clk) begin
        if (wr_en && !full)
            mem[wr_bin[ADDR_WIDTH-1:0]] <= wr_data;
    end

    // almost_full: one slot remaining. Built from wr_bin (native to this
    // domain, safe) and rd_bin_sync (recovered from the already-synchronized
    // Gray pointer, NOT the raw rd_bin -- crossing raw binary counters
    // between clock domains is the classic CDC bug this project is meant to
    // avoid).
    reg [ADDR_WIDTH:0] rd_bin_sync;
    integer k;
    always @(*) begin
        rd_bin_sync[ADDR_WIDTH] = rd_gray_sync[ADDR_WIDTH];
        for (k = ADDR_WIDTH-1; k >= 0; k = k - 1)
            rd_bin_sync[k] = rd_bin_sync[k+1] ^ rd_gray_sync[k];
    end

    wire [ADDR_WIDTH:0] wr_fill_level = wr_bin - rd_bin_sync;
    assign almost_full = (wr_fill_level >= (DEPTH - 1)) && !full;

    // ---------------------------------------------------------------
    // Read domain
    // ---------------------------------------------------------------
    // Same registered-flag reasoning as `full` above, mirrored for `empty`.
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_bin  <= {(ADDR_WIDTH+1){1'b0}};
            rd_gray <= {(ADDR_WIDTH+1){1'b0}};
            empty   <= 1'b1;
        end else begin
            rd_bin  <= rd_bin_next;
            rd_gray <= rd_gray_next;
            empty   <= (rd_gray_next == wr_gray_sync);
        end
    end

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n)
            rd_data <= {DATA_WIDTH{1'b0}};
        else if (rd_en && !empty)
            rd_data <= mem[rd_bin[ADDR_WIDTH-1:0]];
    end

    // Symmetric construction for almost_empty, using wr_bin recovered from
    // the synchronized write-domain Gray pointer.
    reg [ADDR_WIDTH:0] wr_bin_sync;
    integer m;
    always @(*) begin
        wr_bin_sync[ADDR_WIDTH] = wr_gray_sync[ADDR_WIDTH];
        for (m = ADDR_WIDTH-1; m >= 0; m = m - 1)
            wr_bin_sync[m] = wr_bin_sync[m+1] ^ wr_gray_sync[m];
    end

    wire [ADDR_WIDTH:0] rd_fill_level = wr_bin_sync - rd_bin;
    assign almost_empty = (rd_fill_level <= 1) && !empty;

    // ---------------------------------------------------------------
    // CDC synchronizers: each domain sees the OTHER domain's pointer
    // ---------------------------------------------------------------
    gray_sync #(.WIDTH(ADDR_WIDTH+1)) sync_wr2rd (
        .dest_clk   (rd_clk),
        .dest_rst_n (rd_rst_n),
        .gray_in    (wr_gray),
        .gray_out   (wr_gray_sync)
    );

    gray_sync #(.WIDTH(ADDR_WIDTH+1)) sync_rd2wr (
        .dest_clk   (wr_clk),
        .dest_rst_n (wr_rst_n),
        .gray_in    (rd_gray),
        .gray_out   (rd_gray_sync)
    );

`ifdef SIM_ASSERTIONS
    // Lightweight simulation-only checks (immediate assertions). These are
    // guarded so they never affect synthesis.
    always @(posedge wr_clk) begin
        if (wr_en && full)
            $error("[ASSERT] write asserted while FIFO full at time %0t", $time);
    end
    always @(posedge rd_clk) begin
        if (rd_en && empty)
            $error("[ASSERT] read asserted while FIFO empty at time %0t", $time);
    end
`endif

endmodule
