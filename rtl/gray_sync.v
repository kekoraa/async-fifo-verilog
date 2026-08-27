// -----------------------------------------------------------------------------
// gray_sync.v
// Two-flop synchronizer for a Gray-coded pointer crossing clock domains.
// This is the standard Cummings/Clifford Cummings CDC primitive: registering
// the signal twice in the destination domain reduces the probability of a
// metastable value propagating downstream to acceptably low levels (MTBF is
// exponential in the number of synchronizer stages).
// -----------------------------------------------------------------------------
module gray_sync #(
    parameter WIDTH = 4
) (
    input  wire             dest_clk,
    input  wire             dest_rst_n,
    input  wire [WIDTH-1:0] gray_in,
    output reg  [WIDTH-1:0] gray_out
);

    reg [WIDTH-1:0] sync_stage1;

    always @(posedge dest_clk or negedge dest_rst_n) begin
        if (!dest_rst_n) begin
            sync_stage1 <= {WIDTH{1'b0}};
            gray_out    <= {WIDTH{1'b0}};
        end else begin
            sync_stage1 <= gray_in;      // 1st flop: absorbs metastability
            gray_out    <= sync_stage1;  // 2nd flop: safe to use downstream
        end
    end

endmodule
