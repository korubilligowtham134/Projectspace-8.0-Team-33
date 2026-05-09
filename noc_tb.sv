`timescale 1ns/1ps

import noc_params::*;

module noc_tb;

  // =========================
  // PARAMETERS
  // =========================
  parameter MESH_X = 2;
  parameter MESH_Y = 3;

  // =========================
  // CLOCK / RESET
  // =========================
  logic clk;
  logic rst;

  initial clk = 0;
  always #5 clk = ~clk;

  // =========================
  // DUT SIGNALS
  // =========================
  flit_t [MESH_X-1:0][MESH_Y-1:0] data_i;
  flit_t [MESH_X-1:0][MESH_Y-1:0] data_o;
  
  logic [MESH_X-1:0][MESH_Y-1:0] is_valid_i;
  logic [MESH_X-1:0][MESH_Y-1:0] is_valid_o;

  logic [MESH_X-1:0][MESH_Y-1:0][VC_NUM-1:0] is_on_off_i;
  logic [MESH_X-1:0][MESH_Y-1:0][VC_NUM-1:0] is_allocatable_i;

  logic [MESH_X-1:0][MESH_Y-1:0][VC_NUM-1:0] is_on_off_o;
  logic [MESH_X-1:0][MESH_Y-1:0][VC_NUM-1:0] is_allocatable_o;

  // Unpacked array to match mesh port
  logic [VC_NUM-1:0] error_o [MESH_X-1:0][MESH_Y-1:0][PORT_NUM-1:0];

  // =========================
  // DUT — ORIGINAL MESH (buffer=8)
  // =========================
  mesh #(
    .BUFFER_SIZE(8),
    .MESH_SIZE_X(MESH_X),
    .MESH_SIZE_Y(MESH_Y)
  ) DUT (
    .clk(clk),
    .rst(rst),
    .error_o(error_o),
    .data_o(data_o),
    .is_valid_o(is_valid_o),
    .is_on_off_i(is_on_off_i),
    .is_allocatable_i(is_allocatable_i),
    .data_i(data_i),
    .is_valid_i(is_valid_i),
    .is_on_off_o(is_on_off_o),
    .is_allocatable_o(is_allocatable_o)
  );

  // =========================
  // METRICS
  // =========================
  typedef struct {
    int id;
    time inject_time;
  } pkt_t;

  pkt_t pkt_store [2000];
  int pkt_id = 0;

  time total_latency;
  int latency_count;

  int total_packets;
  time start_time, end_time;

  real avg_latency;
  real throughput;

  integer file;

  // =========================
  // RESET
  // =========================
  task reset_dut();
      rst = 1;
      repeat(5) @(posedge clk);
      rst = 0;
  endtask

  // =========================
  // SEND PACKET (with VC select)
  // =========================
  task send_packet_vc(int x, int y, int dest_x, int dest_y, int vc);
      @(posedge clk);
      data_i[x][y].flit_label = HEADTAIL;
      data_i[x][y].vc_id = vc;
      data_i[x][y].data.head_data.x_dest = dest_x;
      data_i[x][y].data.head_data.y_dest = dest_y;
      data_i[x][y].data.head_data.head_pl = pkt_id;
      is_valid_i[x][y] = 1;
      pkt_store[pkt_id].id = pkt_id;
      pkt_store[pkt_id].inject_time = $time;
      pkt_id++;
      @(posedge clk);
      is_valid_i[x][y] = 0;
  endtask

  task send_packet(int x, int y, int dest_x, int dest_y);
      send_packet_vc(x, y, dest_x, dest_y, 0);
  endtask

  // =========================
  // TRAFFIC — same patterns as AI testbench
  // =========================
  task random_traffic(int num);
    int sx, sy, dx, dy, vc;
    for (int i = 0; i < num; i++) begin
      sx = $urandom_range(0, MESH_X-1);
      sy = $urandom_range(0, MESH_Y-1);
      dx = $urandom_range(0, MESH_X-1);
      dy = $urandom_range(0, MESH_Y-1);
      vc = $urandom_range(0, VC_NUM-1);
      send_packet_vc(sx, sy, dx, dy, vc);
      repeat(1) @(posedge clk);
    end
  endtask

  task hotspot_traffic(int rounds);
    int cx, cy;
    cx = MESH_X / 2;
    cy = MESH_Y / 2;
    for (int r = 0; r < rounds; r++) begin
      for (int x = 0; x < MESH_X; x++) begin
        for (int y = 0; y < MESH_Y; y++) begin
          if (x != cx || y != cy)
            send_packet_vc(x, y, cx, cy, r % VC_NUM);
        end
      end
      repeat(1) @(posedge clk);
    end
  endtask

  // =========================
  // MONITOR
  // =========================
  int    mon_id;
  time   mon_latency;

  always @(posedge clk) begin
    for (int x = 0; x < MESH_X; x++) begin
      for (int y = 0; y < MESH_Y; y++) begin
        if (is_valid_o[x][y]) begin
          mon_id = data_o[x][y].data.head_data.head_pl;
          mon_latency = $time - pkt_store[mon_id].inject_time;
          total_latency += mon_latency;
          latency_count++;
          total_packets++;
          $display("Packet %0d latency = %0t", mon_id, mon_latency);
          $fwrite(file, "%0d,%0t\n", mon_id, mon_latency);
        end
      end
    end
  end

  // =========================
  // INITIAL — same traffic as AI testbench
  // =========================
  initial begin
    for (int x = 0; x < MESH_X; x++) begin
      for (int y = 0; y < MESH_Y; y++) begin
        is_valid_i[x][y] = 0;
        is_on_off_i[x][y] = '1;
        is_allocatable_i[x][y] = '1;
      end
    end

    total_latency = 0;
    latency_count = 0;
    total_packets = 0;

    file = $fopen("latency.csv", "w");

    reset_dut();
    start_time = $time;

    // Phase 1: Directed (2 packets)
    send_packet(0, 0, 1, 2);
    send_packet(1, 1, 0, 0);

    // Phase 2: Random traffic (49 packets)
    random_traffic(49);

    // Drain
    repeat(100) @(posedge clk);

    end_time = $time;

    // Results
    avg_latency = total_latency * 1.0 / latency_count;
    throughput  = total_packets * 1.0 / (end_time - start_time);

    $display("\n==== NORMAL XY ROUTING RESULTS ====");
    $display("Packets        = %0d", total_packets);
    $display("Avg Latency    = %0f ns", avg_latency);
    $display("Throughput     = %0f packets/ns", throughput);
    $display("===================================\n");

    $fclose(file);
    #50;
    $finish;
  end

endmodule





// =============================================================================
//  AI BLOCKS FOR NOC ROUTER — Fixed for Cadence ncvlog -sv
// =============================================================================

// =============================================================================
//  BLOCK 1 : CONGESTION PREDICTOR
// =============================================================================
module congestion_predictor #(
    parameter HISTORY_DEPTH = 4,
    parameter THRESHOLD     = 24
)(
    input  logic       clk,
    input  logic       rst,
    input  logic [4:0][1:0] on_off_i,       // [PORT_NUM-1:0][VC_NUM-1:0]
    input  logic [4:0][1:0] allocatable_i,  // [PORT_NUM-1:0][VC_NUM-1:0]
    output logic [4:0]      congested_o     // [PORT_NUM-1:0]
);

    import noc_params::*;

    localparam FEAT_W = 2 * VC_NUM;  // = 4

    logic [HISTORY_DEPTH-1:0][PORT_NUM-1:0][FEAT_W-1:0] history;

    localparam int W [0:HISTORY_DEPTH-1][0:FEAT_W-1] = '{
        '{12, 12, 10, 10},
        '{8,  8,  6,  6 },
        '{4,  4,  3,  3 },
        '{2,  2,  1,  1 }
    };

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
                        cp_score[p] = cp_score[p] + W[t][f][8:0];
            congested_o[p] = (cp_score[p] >= THRESHOLD);
        end
    end

endmodule


// =============================================================================
//  BLOCK 2 : NEURAL ARBITER
// =============================================================================
module neural_arbiter #(
    parameter VC_NUM_P = 2
)(
    input  logic       rst,
    input  logic       clk,
    input  logic  [4:0][VC_NUM_P-1:0]  request_i,    // [PORT_NUM-1:0][VC_NUM-1:0]
    input  logic  [4:0]                congested_i,   // [PORT_NUM-1:0]
    input  logic  [2:0]                out_port_i [0:4][0:VC_NUM_P-1], // port per in-port per VC
    output logic  [4:0][VC_NUM_P-1:0]  grant_o        // [PORT_NUM-1:0][VC_NUM-1:0]
);

    import noc_params::*;

    localparam LP_PORT_NUM = 5;
    localparam LP_VC_NUM   = VC_NUM_P;
    localparam VC_PTR_W    = (LP_VC_NUM > 1) ? $clog2(LP_VC_NUM) : 1;
    localparam PORT_PTR_W  = $clog2(LP_PORT_NUM);

    // RR pointers
    logic [VC_PTR_W-1:0]   rr_in  [0:LP_PORT_NUM-1];
    logic [PORT_PTR_W-1:0] rr_out [0:LP_PORT_NUM-1];

    // Neural weights
    localparam logic [7:0] W_REQ  = 8'd16;
    localparam logic [7:0] W_CONG = 8'd8;
    localparam logic [7:0] W_RR   = 8'd4;

    // Score per (in_port, vc)
    logic [8:0] na_score [0:LP_PORT_NUM-1][0:LP_VC_NUM-1];

    // Stage 1 variables
    logic [8:0]           stg1_best     [0:LP_PORT_NUM-1];
    int                   stg1_best_vc  [0:LP_PORT_NUM-1];
    logic                 stg1_valid    [0:LP_PORT_NUM-1];

    // Stage 2 variables
    logic [8:0]           stg2_best     [0:LP_PORT_NUM-1];
    int                   stg2_best_ip  [0:LP_PORT_NUM-1];
    logic                 stg2_valid    [0:LP_PORT_NUM-1];

    // Per output-port request vector
    logic [LP_PORT_NUM-1:0] out_req   [0:LP_PORT_NUM-1];
    logic [LP_PORT_NUM-1:0] ip_grant  [0:LP_PORT_NUM-1];

    int scan_vc, scan_ip;

    // Stage 0: compute scores
    always_comb begin
        for (int ip = 0; ip < LP_PORT_NUM; ip++) begin
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
    end

    // Stage 1+2: two-stage allocation
    always_comb begin
        for (int ip = 0; ip < LP_PORT_NUM; ip++) begin
            stg1_best[ip]    = 9'd0;
            stg1_best_vc[ip] = 0;
            stg1_valid[ip]   = 1'b0;
        end
        for (int op = 0; op < LP_PORT_NUM; op++) begin
            out_req[op]    = '0;
            ip_grant[op]   = '0;
            stg2_best[op]  = 9'd0;
            stg2_best_ip[op] = 0;
            stg2_valid[op] = 1'b0;
        end
        grant_o = '0;

        // First stage: best VC per input port
        for (int ip = 0; ip < LP_PORT_NUM; ip++) begin
            for (int k = 0; k < LP_VC_NUM; k++) begin
                scan_vc = (rr_in[ip] + k) % LP_VC_NUM;
                if (request_i[ip][scan_vc] && na_score[ip][scan_vc] >= stg1_best[ip]) begin
                    stg1_best[ip]    = na_score[ip][scan_vc];
                    stg1_best_vc[ip] = scan_vc;
                    stg1_valid[ip]   = 1'b1;
                end
            end
            if (stg1_valid[ip])
                out_req[out_port_i[ip][stg1_best_vc[ip]]][ip] = 1'b1;
        end

        // Second stage: best input port per output port
        for (int op = 0; op < LP_PORT_NUM; op++) begin
            for (int k = 0; k < LP_PORT_NUM; k++) begin
                scan_ip = (rr_out[op] + k) % LP_PORT_NUM;
                if (out_req[op][scan_ip] && stg1_best[scan_ip] >= stg2_best[op]) begin
                    stg2_best[op]    = stg1_best[scan_ip];
                    stg2_best_ip[op] = scan_ip;
                    stg2_valid[op]   = 1'b1;
                end
            end
            if (stg2_valid[op])
                ip_grant[op][stg2_best_ip[op]] = 1'b1;
        end

        // Compose grant_o
        for (int op = 0; op < LP_PORT_NUM; op++)
            for (int ip = 0; ip < LP_PORT_NUM; ip++)
                if (ip_grant[op][ip] && stg1_valid[ip])
                    grant_o[ip][stg1_best_vc[ip]] = 1'b1;
    end

    // Sequential: update RR pointers
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            for (int ip = 0; ip < LP_PORT_NUM; ip++) rr_in[ip]  <= '0;
            for (int op = 0; op < LP_PORT_NUM; op++) rr_out[op] <= '0;
        end else begin
            for (int ip = 0; ip < LP_PORT_NUM; ip++)
                for (int vc = 0; vc < LP_VC_NUM; vc++)
                    if (grant_o[ip][vc])
                        rr_in[ip] <= (rr_in[ip] + 1);
            for (int op = 0; op < LP_PORT_NUM; op++)
                for (int ip = 0; ip < LP_PORT_NUM; ip++)
                    if (ip_grant[op][ip])
                        rr_out[op] <= (rr_out[op] + 1);
        end
    end

endmodule


// =============================================================================
//  MODIFIED switch_allocator using neural_arbiter
// =============================================================================
module switch_allocator_ai #(
)(
    input  logic       rst,
    input  logic       clk,
    input  logic [4:0][1:0]  on_off_i,        // [PORT_NUM-1:0][VC_NUM-1:0]
    input  logic [4:0]       congested_ports,  // [PORT_NUM-1:0]
    input_block2switch_allocator.switch_allocator ib_if,
    switch_allocator2crossbar.switch_allocator    xbar_if,
    output logic [4:0]       valid_flit_o       // [PORT_NUM-1:0]
);

    import noc_params::*;

    logic [PORT_NUM-1:0][VC_NUM-1:0] request_cmd;
    logic [PORT_NUM-1:0][VC_NUM-1:0] grant;

    // Re-pack out_port for neural_arbiter interface
    logic [2:0] na_out_port [0:PORT_NUM-1][0:VC_NUM-1];

    always_comb begin
        for (int p = 0; p < PORT_NUM; p++)
            for (int v = 0; v < VC_NUM; v++)
                na_out_port[p][v] = ib_if.out_port[p][v];
    end

    neural_arbiter #(
        .VC_NUM_P(VC_NUM)
    ) neural_arbiter_inst (
        .rst        (rst),
        .clk        (clk),
        .request_i  (request_cmd),
        .out_port_i (na_out_port),
        .congested_i(congested_ports),
        .grant_o    (grant)
    );

    always_comb begin
        for (int port = 0; port < PORT_NUM; port++) begin
            ib_if.valid_sel[port]      = 1'b0;
            valid_flit_o[port]         = 1'b0;
            ib_if.vc_sel[port]         = {VC_SIZE{1'b0}};
            xbar_if.input_vc_sel[port] = {PORT_SIZE{1'b0}};
            request_cmd[port]          = {VC_NUM{1'b0}};
        end

        for (int up_port = 0; up_port < PORT_NUM; up_port++)
            for (int up_vc = 0; up_vc < VC_NUM; up_vc++)
                if (ib_if.switch_request[up_port][up_vc] &
                    on_off_i[ib_if.out_port[up_port][up_vc]][ib_if.downstream_vc[up_port][up_vc]])
                    request_cmd[up_port][up_vc] = 1'b1;

        for (int up_port = 0; up_port < PORT_NUM; up_port++)
            for (int up_vc = 0; up_vc < VC_NUM; up_vc++)
                if (grant[up_port][up_vc]) begin
                    ib_if.vc_sel[up_port]    = up_vc;
                    ib_if.valid_sel[up_port] = 1'b1;
                    valid_flit_o[ib_if.out_port[up_port][up_vc]] = 1'b1;
                    xbar_if.input_vc_sel[ib_if.out_port[up_port][up_vc]] = up_port;
                end
    end

endmodule


// =============================================================================
//  AI INPUT BUFFER — HEADTAIL packets skip VA (IDLE→SA fast path)
// =============================================================================
module input_buffer_ai #(
    parameter BUFFER_SIZE = 8
)(
    input flit_novc_t data_i,
    input read_i, input write_i,
    input [VC_SIZE-1:0] vc_new_i,
    input vc_valid_i,
    input port_t out_port_i,
    input rst, input clk,
    output flit_t data_o,
    output logic is_full_o, output logic is_empty_o, output logic on_off_o,
    output port_t out_port_o,
    output logic vc_request_o, output logic switch_request_o,
    output logic vc_allocatable_o,
    output logic [VC_SIZE-1:0] downstream_vc_o,
    output logic error_o
);
    import noc_params::*;
    enum logic [1:0] {IDLE, VA, SA} ss, ss_next;
    logic [VC_SIZE-1:0] downstream_vc_next;
    logic read_cmd, write_cmd;
    logic end_packet, end_packet_next;
    logic vc_allocatable_next, error_next;
    flit_novc_t read_flit;
    port_t out_port_next;

    circular_buffer #(.BUFFER_SIZE(BUFFER_SIZE)) circular_buffer (
        .data_i(data_i), .read_i(read_cmd), .write_i(write_cmd),
        .rst(rst), .clk(clk), .data_o(read_flit),
        .is_full_o(is_full_o), .is_empty_o(is_empty_o), .on_off_o(on_off_o)
    );

    always_ff @(posedge clk, posedge rst) begin
        if(rst) begin
            ss <= IDLE; out_port_o <= LOCAL; downstream_vc_o <= 0;
            end_packet <= 0; vc_allocatable_o <= 0; error_o <= 0;
        end else begin
            ss <= ss_next; out_port_o <= out_port_next;
            downstream_vc_o <= downstream_vc_next;
            end_packet <= end_packet_next;
            vc_allocatable_o <= vc_allocatable_next; error_o <= error_next;
        end
    end

    always_comb begin
        data_o.flit_label = read_flit.flit_label;
        data_o.vc_id = downstream_vc_o;
        data_o.data = read_flit.data;
        ss_next = ss; out_port_next = out_port_o;
        downstream_vc_next = downstream_vc_o;
        read_cmd = 0; write_cmd = 0;
        end_packet_next = end_packet; error_next = 0;
        vc_request_o = 0; switch_request_o = 0; vc_allocatable_next = 0;

        unique case(ss)
            IDLE: begin
                if((data_i.flit_label == HEAD | data_i.flit_label == HEADTAIL) & write_i & is_empty_o) begin
                    out_port_next = out_port_i;
                    write_cmd = 1;
                    // === AI FAST PATH: HEADTAIL skips VA, goes to SA ===
                    if (data_i.flit_label == HEADTAIL) begin
                        ss_next = SA;
                        downstream_vc_next = 0;  // pre-allocate VC 0
                        end_packet_next = 1;
                    end else begin
                        ss_next = VA;
                    end
                end
                if(vc_valid_i | read_i | ((data_i.flit_label == BODY | data_i.flit_label == TAIL) & write_i) | ~is_empty_o)
                    error_next = 1;
                if(write_i & data_i.flit_label == HEADTAIL)
                    end_packet_next = 1;
            end

            VA: begin
                if(vc_valid_i) begin
                    ss_next = SA; downstream_vc_next = vc_new_i;
                end
                vc_request_o = 1;
                if(write_i & (data_i.flit_label == BODY | data_i.flit_label == TAIL) & ~end_packet)
                    write_cmd = 1;
                if((write_i & (end_packet | data_i.flit_label == HEAD | data_i.flit_label == HEADTAIL)) | read_i)
                    error_next = 1;
                if(write_i & data_i.flit_label == TAIL) end_packet_next = 1;
            end

            SA: begin
                if(read_i & (data_o.flit_label == TAIL | data_o.flit_label == HEADTAIL)) begin
                    ss_next = IDLE; vc_allocatable_next = 1; end_packet_next = 0;
                end
                if(~is_empty_o) switch_request_o = 1;
                read_cmd = read_i;
                if(write_i & (data_i.flit_label == BODY | data_i.flit_label == TAIL) & ~end_packet)
                    write_cmd = 1;
                if((write_i & (end_packet | data_i.flit_label == HEAD | data_i.flit_label == HEADTAIL)) | vc_valid_i)
                    error_next = 1;
                if(write_i & data_i.flit_label == TAIL) end_packet_next = 1;
            end

            default: begin
                ss_next = IDLE; vc_allocatable_next = 1; error_next = 1; end_packet_next = 0;
            end
        endcase
    end
endmodule

// =============================================================================
//  AI INPUT PORT — uses input_buffer_ai
// =============================================================================
module input_port_ai #(
    parameter BUFFER_SIZE = 8,
    parameter X_CURRENT = MESH_SIZE_X/2,
    parameter Y_CURRENT = MESH_SIZE_Y/2
)(
    input flit_t data_i, input valid_flit_i, input rst, input clk,
    input [VC_SIZE-1:0] sa_sel_vc_i,
    input [VC_SIZE-1:0] va_new_vc_i [VC_NUM-1:0],
    input [VC_NUM-1:0] va_valid_i, input sa_valid_i,
    output flit_t xb_flit_o,
    output logic [VC_NUM-1:0] is_on_off_o, output logic [VC_NUM-1:0] is_allocatable_vc_o,
    output logic [VC_NUM-1:0] va_request_o,
    output logic sa_request_o [VC_NUM-1:0],
    output logic [VC_SIZE-1:0] sa_downstream_vc_o [VC_NUM-1:0],
    output port_t [VC_NUM-1:0] out_port_o,
    output logic [VC_NUM-1:0] is_full_o, output logic [VC_NUM-1:0] is_empty_o,
    output logic [VC_NUM-1:0] error_o
);
    import noc_params::*;
    flit_novc_t data_cmd; flit_t [VC_NUM-1:0] data_out;
    port_t out_port_cmd;
    logic [VC_NUM-1:0] read_cmd, write_cmd;

    genvar vc;
    generate for(vc=0; vc<VC_NUM; vc++) begin: gen_vc
        input_buffer_ai #(.BUFFER_SIZE(BUFFER_SIZE)) ib (
            .data_i(data_cmd), .read_i(read_cmd[vc]), .write_i(write_cmd[vc]),
            .vc_new_i(va_new_vc_i[vc]), .vc_valid_i(va_valid_i[vc]),
            .out_port_i(out_port_cmd), .rst(rst), .clk(clk),
            .data_o(data_out[vc]), .is_full_o(is_full_o[vc]),
            .is_empty_o(is_empty_o[vc]), .on_off_o(is_on_off_o[vc]),
            .out_port_o(out_port_o[vc]), .vc_request_o(va_request_o[vc]),
            .switch_request_o(sa_request_o[vc]),
            .vc_allocatable_o(is_allocatable_vc_o[vc]),
            .downstream_vc_o(sa_downstream_vc_o[vc]), .error_o(error_o[vc])
        );
    end endgenerate

    rc_unit #(.X_CURRENT(X_CURRENT),.Y_CURRENT(Y_CURRENT),
              .DEST_ADDR_SIZE_X(DEST_ADDR_SIZE_X),.DEST_ADDR_SIZE_Y(DEST_ADDR_SIZE_Y))
    rc_unit (.x_dest_i(data_i.data.head_data.x_dest),
             .y_dest_i(data_i.data.head_data.y_dest), .out_port_o(out_port_cmd));

    always_comb begin
        data_cmd.flit_label = data_i.flit_label; data_cmd.data = data_i.data;
        write_cmd = {VC_NUM{1'b0}};
        if(valid_flit_i) write_cmd[data_i.vc_id] = 1;
        read_cmd = {VC_NUM{1'b0}};
        if(sa_valid_i) read_cmd[sa_sel_vc_i] = 1;
        xb_flit_o = data_out[sa_sel_vc_i];
    end
endmodule

// =============================================================================
//  AI INPUT BLOCK — uses input_port_ai
// =============================================================================
module input_block_ai #(
    parameter PORT_NUM = 5, parameter BUFFER_SIZE = 8,
    parameter X_CURRENT = MESH_SIZE_X/2, parameter Y_CURRENT = MESH_SIZE_Y/2
)(
    input flit_t data_i [PORT_NUM-1:0], input valid_flit_i [PORT_NUM-1:0],
    input rst, input clk,
    input_block2crossbar.input_block crossbar_if,
    input_block2switch_allocator.input_block sa_if,
    input_block2vc_allocator.input_block va_if,
    output logic [VC_NUM-1:0] on_off_o [PORT_NUM-1:0],
    output logic [VC_NUM-1:0] vc_allocatable_o [PORT_NUM-1:0],
    output logic [VC_NUM-1:0] error_o [PORT_NUM-1:0]
);
    import noc_params::*;
    logic [VC_NUM-1:0] is_full [PORT_NUM-1:0], is_empty [PORT_NUM-1:0];
    port_t [VC_NUM-1:0] out_port [PORT_NUM-1:0];
    assign va_if.out_port = out_port; assign sa_if.out_port = out_port;

    genvar ip;
    generate for(ip=0; ip<PORT_NUM; ip++) begin: gen_ip
        input_port_ai #(.BUFFER_SIZE(BUFFER_SIZE),.X_CURRENT(X_CURRENT),.Y_CURRENT(Y_CURRENT))
        input_port (.data_i(data_i[ip]), .valid_flit_i(valid_flit_i[ip]),
            .rst(rst), .clk(clk), .sa_sel_vc_i(sa_if.vc_sel[ip]),
            .va_new_vc_i(va_if.vc_new[ip]), .va_valid_i(va_if.vc_valid[ip]),
            .sa_valid_i(sa_if.valid_sel[ip]), .xb_flit_o(crossbar_if.flit[ip]),
            .is_on_off_o(on_off_o[ip]), .is_allocatable_vc_o(vc_allocatable_o[ip]),
            .va_request_o(va_if.vc_request[ip]), .sa_request_o(sa_if.switch_request[ip]),
            .sa_downstream_vc_o(sa_if.downstream_vc[ip]), .out_port_o(out_port[ip]),
            .is_full_o(is_full[ip]), .is_empty_o(is_empty[ip]), .error_o(error_o[ip])
        );
    end endgenerate
endmodule

// =============================================================================
//  AI-ENHANCED ROUTER — uses input_block_ai with fast-path
// =============================================================================
module router_ai #(
    parameter BUFFER_SIZE = 16,
    parameter X_CURRENT   = 1,
    parameter Y_CURRENT   = 1
)(
    input clk, input rst,
    router2router.upstream   router_if_local_up,
    router2router.upstream   router_if_north_up,
    router2router.upstream   router_if_south_up,
    router2router.upstream   router_if_west_up,
    router2router.upstream   router_if_east_up,
    router2router.downstream router_if_local_down,
    router2router.downstream router_if_north_down,
    router2router.downstream router_if_south_down,
    router2router.downstream router_if_west_down,
    router2router.downstream router_if_east_down,
    output logic [1:0] error_o [0:4]
);
    import noc_params::*;

    flit_t data_out [PORT_NUM-1:0];
    logic  [PORT_NUM-1:0] is_valid_out;
    logic  [PORT_NUM-1:0][VC_NUM-1:0] is_on_off_in;
    logic  [PORT_NUM-1:0][VC_NUM-1:0] is_allocatable_in;
    flit_t data_in [PORT_NUM-1:0];
    logic  is_valid_in [PORT_NUM-1:0];
    logic  [VC_NUM-1:0] is_on_off_out [PORT_NUM-1:0];
    logic  [VC_NUM-1:0] is_allocatable_out [PORT_NUM-1:0];
    logic [PORT_NUM-1:0] congested_ports;

    always_comb begin
        router_if_local_up.data = data_out[LOCAL];
        router_if_north_up.data = data_out[NORTH];
        router_if_south_up.data = data_out[SOUTH];
        router_if_west_up.data  = data_out[WEST];
        router_if_east_up.data  = data_out[EAST];
        router_if_local_up.is_valid = is_valid_out[LOCAL];
        router_if_north_up.is_valid = is_valid_out[NORTH];
        router_if_south_up.is_valid = is_valid_out[SOUTH];
        router_if_west_up.is_valid  = is_valid_out[WEST];
        router_if_east_up.is_valid  = is_valid_out[EAST];
        is_on_off_in[LOCAL] = router_if_local_up.is_on_off;
        is_on_off_in[NORTH] = router_if_north_up.is_on_off;
        is_on_off_in[SOUTH] = router_if_south_up.is_on_off;
        is_on_off_in[WEST]  = router_if_west_up.is_on_off;
        is_on_off_in[EAST]  = router_if_east_up.is_on_off;
        is_allocatable_in[LOCAL] = router_if_local_up.is_allocatable;
        is_allocatable_in[NORTH] = router_if_north_up.is_allocatable;
        is_allocatable_in[SOUTH] = router_if_south_up.is_allocatable;
        is_allocatable_in[WEST]  = router_if_west_up.is_allocatable;
        is_allocatable_in[EAST]  = router_if_east_up.is_allocatable;
        data_in[LOCAL] = router_if_local_down.data;
        data_in[NORTH] = router_if_north_down.data;
        data_in[SOUTH] = router_if_south_down.data;
        data_in[WEST]  = router_if_west_down.data;
        data_in[EAST]  = router_if_east_down.data;
        is_valid_in[LOCAL] = router_if_local_down.is_valid;
        is_valid_in[NORTH] = router_if_north_down.is_valid;
        is_valid_in[SOUTH] = router_if_south_down.is_valid;
        is_valid_in[WEST]  = router_if_west_down.is_valid;
        is_valid_in[EAST]  = router_if_east_down.is_valid;
        router_if_local_down.is_on_off = is_on_off_out[LOCAL];
        router_if_north_down.is_on_off = is_on_off_out[NORTH];
        router_if_south_down.is_on_off = is_on_off_out[SOUTH];
        router_if_west_down.is_on_off  = is_on_off_out[WEST];
        router_if_east_down.is_on_off  = is_on_off_out[EAST];
        router_if_local_down.is_allocatable = is_allocatable_out[LOCAL];
        router_if_north_down.is_allocatable = is_allocatable_out[NORTH];
        router_if_south_down.is_allocatable = is_allocatable_out[SOUTH];
        router_if_west_down.is_allocatable  = is_allocatable_out[WEST];
        router_if_east_down.is_allocatable  = is_allocatable_out[EAST];
    end

    input_block2crossbar ib2xbar_if();
    input_block2switch_allocator ib2sa_if();
    input_block2vc_allocator ib2va_if();
    switch_allocator2crossbar sa2xbar_if();

    // === CHANGED: uses input_block_ai with fast-path ===
    input_block_ai #(
        .BUFFER_SIZE(BUFFER_SIZE),
        .X_CURRENT(X_CURRENT),
        .Y_CURRENT(Y_CURRENT)
    ) input_block_inst (
        .rst(rst), .clk(clk),
        .data_i(data_in), .valid_flit_i(is_valid_in),
        .crossbar_if(ib2xbar_if), .sa_if(ib2sa_if), .va_if(ib2va_if),
        .on_off_o(is_on_off_out), .vc_allocatable_o(is_allocatable_out),
        .error_o(error_o)
    );

    crossbar crossbar_inst (
        .ib_if(ib2xbar_if),
        .sa_if(sa2xbar_if),
        .data_o(data_out)
    );

    congestion_predictor #(
        .HISTORY_DEPTH(4),
        .THRESHOLD(24)
    ) congestion_predictor_inst (
        .clk(clk), .rst(rst),
        .on_off_i(is_on_off_in),
        .allocatable_i(is_allocatable_in),
        .congested_o(congested_ports)
    );

    switch_allocator_ai switch_allocator_ai_inst (
        .rst(rst), .clk(clk),
        .on_off_i(is_on_off_in),
        .congested_ports(congested_ports),
        .ib_if(ib2sa_if),
        .xbar_if(sa2xbar_if),
        .valid_flit_o(is_valid_out)
    );

    vc_allocator vc_allocator_inst (
        .rst(rst), .clk(clk),
        .idle_downstream_vc_i(is_allocatable_in),
        .ib_if(ib2va_if)
    );

endmodule


// =============================================================================
//  AI-ENHANCED MESH
// =============================================================================
module mesh_ai #(
    parameter BUFFER_SIZE  = 16,
    parameter MESH_SIZE_X  = 2,
    parameter MESH_SIZE_Y  = 3
)(
    input clk,
    input rst,
    output logic [1:0] error_o [0:MESH_SIZE_X-1][0:MESH_SIZE_Y-1][0:4],
    output flit_t [MESH_SIZE_X-1:0][MESH_SIZE_Y-1:0] data_o,
    output logic [MESH_SIZE_X-1:0][MESH_SIZE_Y-1:0] is_valid_o,
    input [MESH_SIZE_X-1:0][MESH_SIZE_Y-1:0][1:0] is_on_off_i,
    input [MESH_SIZE_X-1:0][MESH_SIZE_Y-1:0][1:0] is_allocatable_i,
    input flit_t [MESH_SIZE_X-1:0][MESH_SIZE_Y-1:0] data_i,
    input [MESH_SIZE_X-1:0][MESH_SIZE_Y-1:0] is_valid_i,
    output logic [MESH_SIZE_X-1:0][MESH_SIZE_Y-1:0][1:0] is_on_off_o,
    output logic [MESH_SIZE_X-1:0][MESH_SIZE_Y-1:0][1:0] is_allocatable_o
);

    import noc_params::*;

    genvar row, col;
    generate
        for (row=0; row<MESH_SIZE_Y; row++) begin: mesh_row
            for (col=0; col<MESH_SIZE_X; col++) begin: mesh_col
                router2router local_up();
                router2router north_up();
                router2router south_up();
                router2router west_up();
                router2router east_up();
                router2router local_down();
                router2router north_down();
                router2router south_down();
                router2router west_down();
                router2router east_down();

                router_ai #(
                    .BUFFER_SIZE(BUFFER_SIZE),
                    .X_CURRENT(col),
                    .Y_CURRENT(row)
                ) router_inst (
                    .clk(clk), .rst(rst),
                    .router_if_local_up(local_up),
                    .router_if_north_up(north_up),
                    .router_if_south_up(south_up),
                    .router_if_west_up(west_up),
                    .router_if_east_up(east_up),
                    .router_if_local_down(local_down),
                    .router_if_north_down(north_down),
                    .router_if_south_down(south_down),
                    .router_if_west_down(west_down),
                    .router_if_east_down(east_down),
                    .error_o(error_o[col][row])
                );
            end
        end

        for (row=0; row<MESH_SIZE_Y-1; row++) begin: vertical_links_row
            for (col=0; col<MESH_SIZE_X; col++) begin: vertical_links_col
                router_link link_one (
                    .router_if_up(mesh_row[row].mesh_col[col].south_down),
                    .router_if_down(mesh_row[row+1].mesh_col[col].north_up)
                );
                router_link link_two (
                    .router_if_up(mesh_row[row+1].mesh_col[col].north_down),
                    .router_if_down(mesh_row[row].mesh_col[col].south_up)
                );
            end
        end

        for (row=0; row<MESH_SIZE_Y; row++) begin: horizontal_links_row
            for (col=0; col<MESH_SIZE_X-1; col++) begin: horizontal_links_col
                router_link link_one (
                    .router_if_up(mesh_row[row].mesh_col[col].east_down),
                    .router_if_down(mesh_row[row].mesh_col[col+1].west_up)
                );
                router_link link_two (
                    .router_if_up(mesh_row[row].mesh_col[col+1].west_down),
                    .router_if_down(mesh_row[row].mesh_col[col].east_up)
                );
            end
        end

        for (row=0; row<MESH_SIZE_Y; row++) begin: node_connection_row
            for (col=0; col<MESH_SIZE_X; col++) begin: node_connection_col
                node_link node_link_inst (
                    .router_if_up(mesh_row[row].mesh_col[col].local_down),
                    .router_if_down(mesh_row[row].mesh_col[col].local_up),
                    .data_i(data_i[col][row]),
                    .is_valid_i(is_valid_i[col][row]),
                    .is_on_off_o(is_on_off_o[col][row]),
                    .is_allocatable_o(is_allocatable_o[col][row]),
                    .data_o(data_o[col][row]),
                    .is_valid_o(is_valid_o[col][row]),
                    .is_on_off_i(is_on_off_i[col][row]),
                    .is_allocatable_i(is_allocatable_i[col][row])
                );
            end
        end
    endgenerate

endmodule


// =============================================================================
//  TESTBENCH FOR AI-ENHANCED NOC  — Heavy Traffic
// =============================================================================
module ai_noc_tb;

    import noc_params::*;

    parameter MESH_X = 2;
    parameter MESH_Y = 3;

    // Clock / Reset
    logic clk;
    logic rst;

    initial clk = 0;
    always #5 clk = ~clk;

    // DUT signals
    flit_t [MESH_X-1:0][MESH_Y-1:0] data_i;
    flit_t [MESH_X-1:0][MESH_Y-1:0] data_o;

    logic [MESH_X-1:0][MESH_Y-1:0] is_valid_i;
    logic [MESH_X-1:0][MESH_Y-1:0] is_valid_o;

    logic [MESH_X-1:0][MESH_Y-1:0][VC_NUM-1:0] is_on_off_i;
    logic [MESH_X-1:0][MESH_Y-1:0][VC_NUM-1:0] is_allocatable_i;

    logic [MESH_X-1:0][MESH_Y-1:0][VC_NUM-1:0] is_on_off_o;
    logic [MESH_X-1:0][MESH_Y-1:0][VC_NUM-1:0] is_allocatable_o;

    logic [VC_NUM-1:0] error_o [0:MESH_X-1][0:MESH_Y-1][0:4];

    // DUT — AI mesh with larger buffers
    mesh_ai #(
        .BUFFER_SIZE(16),
        .MESH_SIZE_X(MESH_X),
        .MESH_SIZE_Y(MESH_Y)
    ) DUT (
        .clk(clk),
        .rst(rst),
        .error_o(error_o),
        .data_o(data_o),
        .is_valid_o(is_valid_o),
        .is_on_off_i(is_on_off_i),
        .is_allocatable_i(is_allocatable_i),
        .data_i(data_i),
        .is_valid_i(is_valid_i),
        .is_on_off_o(is_on_off_o),
        .is_allocatable_o(is_allocatable_o)
    );

    // Metrics
    typedef struct {
        int id;
        time inject_time;
    } pkt_t;

    pkt_t pkt_store [2000];
    int pkt_id = 0;

    time total_latency;
    int latency_count;
    int total_packets;
    time start_time, end_time;
    real avg_latency;
    real throughput;
    integer file;

    // Reset task
    task reset_dut();
        rst = 1;
        repeat(5) @(posedge clk);
        rst = 0;
    endtask

    // Send packet on specified VC
    task send_packet_vc(int x, int y, int dest_x, int dest_y, int vc);
        @(posedge clk);
        data_i[x][y].flit_label = HEADTAIL;
        data_i[x][y].vc_id = vc;
        data_i[x][y].data.head_data.x_dest = dest_x;
        data_i[x][y].data.head_data.y_dest = dest_y;
        data_i[x][y].data.head_data.head_pl = pkt_id;
        is_valid_i[x][y] = 1;
        pkt_store[pkt_id].id = pkt_id;
        pkt_store[pkt_id].inject_time = $time;
        pkt_id++;
        @(posedge clk);
        is_valid_i[x][y] = 0;
    endtask

    // Send packet (default VC=0)
    task send_packet(int x, int y, int dest_x, int dest_y);
        send_packet_vc(x, y, dest_x, dest_y, 0);
    endtask

    // Heavy random traffic — minimal gap, both VCs
    task random_traffic(int num);
        int sx, sy, dx, dy, vc;
        for (int i = 0; i < num; i++) begin
            sx = $urandom_range(0, MESH_X-1);
            sy = $urandom_range(0, MESH_Y-1);
            dx = $urandom_range(0, MESH_X-1);
            dy = $urandom_range(0, MESH_Y-1);
            vc = $urandom_range(0, VC_NUM-1);
            send_packet_vc(sx, sy, dx, dy, vc);
            repeat(1) @(posedge clk);  // minimal gap
        end
    endtask

    // Hotspot traffic — all nodes send to center
    task hotspot_traffic(int rounds);
        int cx, cy;
        cx = MESH_X / 2;
        cy = MESH_Y / 2;
        for (int r = 0; r < rounds; r++) begin
            for (int x = 0; x < MESH_X; x++) begin
                for (int y = 0; y < MESH_Y; y++) begin
                    if (x != cx || y != cy)
                        send_packet_vc(x, y, cx, cy, r % VC_NUM);
                end
            end
            repeat(1) @(posedge clk);
        end
    endtask

    // Monitor — variables at module scope
    int  mon_id;
    time mon_latency;

    always @(posedge clk) begin
        for (int x = 0; x < MESH_X; x++) begin
            for (int y = 0; y < MESH_Y; y++) begin
                if (is_valid_o[x][y]) begin
                    mon_id = data_o[x][y].data.head_data.head_pl;
                    mon_latency = $time - pkt_store[mon_id].inject_time;
                    total_latency += mon_latency;
                    latency_count++;
                    total_packets++;
                    $display("Packet %0d latency = %0t", mon_id, mon_latency);
                    $fwrite(file, "%0d,%0t\n", mon_id, mon_latency);
                end
            end
        end
    end

    // Main test
    initial begin
        for (int x = 0; x < MESH_X; x++) begin
            for (int y = 0; y < MESH_Y; y++) begin
                is_valid_i[x][y] = 0;
                is_on_off_i[x][y] = '1;
                is_allocatable_i[x][y] = '1;
            end
        end

        total_latency = 0;
        latency_count = 0;
        total_packets = 0;

        file = $fopen("ai_latency.csv", "w");

        reset_dut();
        start_time = $time;

        // Phase 1: Directed packets (2)
        send_packet(0, 0, 1, 2);
        send_packet(1, 1, 0, 0);

        // Phase 2: Random traffic (49 packets, both VCs, minimal gap)
        random_traffic(49);

        // Wait for all packets to drain
        repeat(100) @(posedge clk);

        end_time = $time;

        // Results
        avg_latency = total_latency * 1.0 / latency_count;
        throughput  = total_packets * 1.0 / (end_time - start_time);

        $display("\n==== AI-ENHANCED NOC RESULTS ====");
        $display("Packets        = %0d", total_packets);
        $display("Avg Latency    = %0f ns", avg_latency);
        $display("Throughput     = %0f packets/ns", throughput);
        $display("=================================\n");

        $fclose(file);
        #50;
        $finish;
    end

endmodule
