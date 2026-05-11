module congestion_predictor #(
    parameter HISTORY_DEPTH = 4,
    parameter THRESHOLD     = 24
)(
    input  logic       clk,
    input  logic       rst,
    input  logic [4:0][1:0] on_off_i,
    input  logic [4:0][1:0] allocatable_i,
    output logic [4:0]      congested_o
);
    import noc_params::*;

    localparam FEAT_W = 2 * VC_NUM;

    logic [HISTORY_DEPTH-1:0][PORT_NUM-1:0][FEAT_W-1:0] history;

    // FIX: was localparam int W[...] which cannot be bit-sliced
    logic [8:0] W [0:HISTORY_DEPTH-1][0:FEAT_W-1];
    initial begin
        W[0][0]=9'd12; W[0][1]=9'd12; W[0][2]=9'd10; W[0][3]=9'd10;
        W[1][0]=9'd8;  W[1][1]=9'd8;  W[1][2]=9'd6;  W[1][3]=9'd6;
        W[2][0]=9'd4;  W[2][1]=9'd4;  W[2][2]=9'd3;  W[2][3]=9'd3;
        W[3][0]=9'd2;  W[3][1]=9'd2;  W[3][2]=9'd1;  W[3][3]=9'd1;
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            for (int t = 0; t < HISTORY_DEPTH; t++)
                for (int p = 0; p < PORT_NUM; p++)
                    history[t][p] <= '0;
        end else begin
            for (int t = HISTORY_DEPTH-1; t > 0; t--)
                history[t] <= history[t-1];
            for (int p = 0; p < PORT_NUM; p++) begin
                history[0][p][VC_NUM-1:0]      <= ~on_off_i[p];
                history[0][p][FEAT_W-1:VC_NUM] <= ~allocatable_i[p];
            end
        end
    end

    logic [8:0] cp_score [0:PORT_NUM-1];

    always_comb begin
        for (int p = 0; p < PORT_NUM; p++) begin
            cp_score[p] = 9'd0;
            for (int t = 0; t < HISTORY_DEPTH; t++)
                for (int f = 0; f < FEAT_W; f++)
                    if (history[t][p][f])
                        cp_score[p] = cp_score[p] + W[t][f]; // legal now
            congested_o[p] = (cp_score[p] >= THRESHOLD);
        end
    end

endmodule


