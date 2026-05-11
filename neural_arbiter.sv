
// =============================================================================
//  3. NEURAL ARBITER 
// =============================================================================
module neural_arbiter #(
    parameter VC_NUM_P = 2
)(
    input  logic       rst,
    input  logic       clk,
    input  logic  [4:0][VC_NUM_P-1:0]  request_i,
    input  logic  [4:0]                congested_i,
    input  logic  [2:0]                out_port_i [0:4][0:VC_NUM_P-1],
    output logic  [4:0][VC_NUM_P-1:0]  grant_o
);
    import noc_params::*;

    localparam LP_PORT_NUM = 5;
    localparam LP_VC_NUM   = VC_NUM_P;
    localparam VC_PTR_W    = (LP_VC_NUM > 1) ? $clog2(LP_VC_NUM) : 1;
    localparam PORT_PTR_W  = $clog2(LP_PORT_NUM);

    logic [VC_PTR_W-1:0]   rr_in  [0:LP_PORT_NUM-1];
    logic [PORT_PTR_W-1:0] rr_out [0:LP_PORT_NUM-1];

    localparam logic [7:0] W_REQ  = 8'd16;
    localparam logic [7:0] W_CONG = 8'd8;
    localparam logic [7:0] W_RR   = 8'd4;

    logic [8:0] na_score [0:LP_PORT_NUM-1][0:LP_VC_NUM-1];

    logic [8:0] stg1_best     [0:LP_PORT_NUM-1];
    int         stg1_best_vc  [0:LP_PORT_NUM-1];
    logic       stg1_valid    [0:LP_PORT_NUM-1];

    logic [8:0] stg2_best     [0:LP_PORT_NUM-1];
    int         stg2_best_ip  [0:LP_PORT_NUM-1];
    logic       stg2_valid    [0:LP_PORT_NUM-1];

    logic [LP_PORT_NUM-1:0] out_req   [0:LP_PORT_NUM-1];
    logic [LP_PORT_NUM-1:0] ip_grant  [0:LP_PORT_NUM-1];

    int scan_vc, scan_ip;

    always_comb begin
        for (int ip = 0; ip < LP_PORT_NUM; ip++)
            for (int vc = 0; vc < LP_VC_NUM; vc++) begin
                na_score[ip][vc] = 9'd0;
                if (request_i[ip][vc]) begin
                    na_score[ip][vc] = {1'b0, W_REQ};
                    if (!congested_i[out_port_i[ip][vc]])
                        na_score[ip][vc] = na_score[ip][vc] + {1'b0, W_CONG};
                    if (vc[VC_PTR_W-1:0] == rr_in[ip])
                        na_score[ip][vc] = na_score[ip][vc] + {1'b0, W_RR};
                end
            end
    end

    always_comb begin
        for (int ip = 0; ip < LP_PORT_NUM; ip++) begin
            stg1_best[ip]=9'd0; stg1_best_vc[ip]=0; stg1_valid[ip]=1'b0;
        end
        for (int op = 0; op < LP_PORT_NUM; op++) begin
            out_req[op]='0; ip_grant[op]='0;
            stg2_best[op]=9'd0; stg2_best_ip[op]=0; stg2_valid[op]=1'b0;
        end
        grant_o = '0;

        for (int ip = 0; ip < LP_PORT_NUM; ip++) begin
            for (int k = 0; k < LP_VC_NUM; k++) begin
                scan_vc = (rr_in[ip] + k) % LP_VC_NUM;
                if (request_i[ip][scan_vc] && na_score[ip][scan_vc] >= stg1_best[ip]) begin
                    stg1_best[ip]=na_score[ip][scan_vc];
                    stg1_best_vc[ip]=scan_vc;
                    stg1_valid[ip]=1'b1;
                end
            end
            if (stg1_valid[ip])
                out_req[out_port_i[ip][stg1_best_vc[ip]]][ip] = 1'b1;
        end

        for (int op = 0; op < LP_PORT_NUM; op++) begin
            for (int k = 0; k < LP_PORT_NUM; k++) begin
                scan_ip = (rr_out[op] + k) % LP_PORT_NUM;
                if (out_req[op][scan_ip] && stg1_best[scan_ip] >= stg2_best[op]) begin
                    stg2_best[op]=stg1_best[scan_ip];
                    stg2_best_ip[op]=scan_ip;
                    stg2_valid[op]=1'b1;
                end
            end
            if (stg2_valid[op])
                ip_grant[op][stg2_best_ip[op]] = 1'b1;
        end

        for (int op = 0; op < LP_PORT_NUM; op++)
            for (int ip = 0; ip < LP_PORT_NUM; ip++)
                if (ip_grant[op][ip] && stg1_valid[ip])
                    grant_o[ip][stg1_best_vc[ip]] = 1'b1;
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            for (int ip = 0; ip < LP_PORT_NUM; ip++) rr_in[ip]  <= '0;
            for (int op = 0; op < LP_PORT_NUM; op++) rr_out[op] <= '0;
        end else begin
            for (int ip = 0; ip < LP_PORT_NUM; ip++)
                for (int vc = 0; vc < LP_VC_NUM; vc++)
                    if (grant_o[ip][vc]) rr_in[ip] <= rr_in[ip] + 1;
            for (int op = 0; op < LP_PORT_NUM; op++)
                for (int ip = 0; ip < LP_PORT_NUM; ip++)
                    if (ip_grant[op][ip]) rr_out[op] <= rr_out[op] + 1;
        end
    end

endmodule