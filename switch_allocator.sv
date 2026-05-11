// =============================================================================
//  4. SWITCH ALLOCATOR AI
// =============================================================================
module switch_allocator_ai (
    input  logic       rst,
    input  logic       clk,
    input  logic [4:0][1:0]  on_off_i,
    input  logic [4:0]       congested_ports,
    input_block2switch_allocator.switch_allocator ib_if,
    switch_allocator2crossbar.switch_allocator    xbar_if,
    output logic [4:0]       valid_flit_o
);
    import noc_params::*;

    logic [PORT_NUM-1:0][VC_NUM-1:0] request_cmd;
    logic [PORT_NUM-1:0][VC_NUM-1:0] grant;
    logic [2:0] na_out_port [0:PORT_NUM-1][0:VC_NUM-1];

    always_comb
        for (int p = 0; p < PORT_NUM; p++)
            for (int v = 0; v < VC_NUM; v++)
                na_out_port[p][v] = ib_if.out_port[p][v];

    neural_arbiter #(.VC_NUM_P(VC_NUM)) neural_arbiter_inst (
        .rst(rst), .clk(clk),
        .request_i(request_cmd), .out_port_i(na_out_port),
        .congested_i(congested_ports), .grant_o(grant)
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
//  5. AI INPUT BUFFER
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
            ss<=IDLE; out_port_o<=LOCAL; downstream_vc_o<=0;
            end_packet<=0; vc_allocatable_o<=0; error_o<=0;
        end else begin
            ss<=ss_next; out_port_o<=out_port_next;
            downstream_vc_o<=downstream_vc_next;
            end_packet<=end_packet_next;
            vc_allocatable_o<=vc_allocatable_next; error_o<=error_next;
        end
    end

    always_comb begin
        data_o.flit_label=read_flit.flit_label;
        data_o.vc_id=downstream_vc_o;
        data_o.data=read_flit.data;
        ss_next=ss; out_port_next=out_port_o;
        downstream_vc_next=downstream_vc_o;
        read_cmd=0; write_cmd=0;
        end_packet_next=end_packet; error_next=0;
        vc_request_o=0; switch_request_o=0; vc_allocatable_next=0;

        unique case(ss)
            IDLE: begin
                if((data_i.flit_label==HEAD|data_i.flit_label==HEADTAIL)&write_i&is_empty_o) begin
                    out_port_next=out_port_i; write_cmd=1;
                    if(data_i.flit_label==HEADTAIL) begin
                        ss_next=SA; downstream_vc_next=0; end_packet_next=1;
                    end else ss_next=VA;
                end
                if(vc_valid_i|read_i|((data_i.flit_label==BODY|data_i.flit_label==TAIL)&write_i)|~is_empty_o)
                    error_next=1;
                if(write_i&data_i.flit_label==HEADTAIL) end_packet_next=1;
            end
            VA: begin
                if(vc_valid_i) begin ss_next=SA; downstream_vc_next=vc_new_i; end
                vc_request_o=1;
                if(write_i&(data_i.flit_label==BODY|data_i.flit_label==TAIL)&~end_packet) write_cmd=1;
                if((write_i&(end_packet|data_i.flit_label==HEAD|data_i.flit_label==HEADTAIL))|read_i)
                    error_next=1;
                if(write_i&data_i.flit_label==TAIL) end_packet_next=1;
            end
            SA: begin
                if(read_i&(data_o.flit_label==TAIL|data_o.flit_label==HEADTAIL)) begin
                    ss_next=IDLE; vc_allocatable_next=1; end_packet_next=0;
                end
                if(~is_empty_o) switch_request_o=1;
                read_cmd=read_i;
                if(write_i&(data_i.flit_label==BODY|data_i.flit_label==TAIL)&~end_packet) write_cmd=1;
                if((write_i&(end_packet|data_i.flit_label==HEAD|data_i.flit_label==HEADTAIL))|vc_valid_i)
                    error_next=1;
                if(write_i&data_i.flit_label==TAIL) end_packet_next=1;
            end
            default: begin ss_next=IDLE; vc_allocatable_next=1; error_next=1; end_packet_next=0; end
        endcase
    end
endmodule


// =============================================================================
//  6. AI INPUT PORT
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
    output logic [VC_NUM-1:0] is_on_off_o,
    output logic [VC_NUM-1:0] is_allocatable_vc_o,
    output logic [VC_NUM-1:0] va_request_o,
    output logic sa_request_o [VC_NUM-1:0],
    output logic [VC_SIZE-1:0] sa_downstream_vc_o [VC_NUM-1:0],
    output port_t [VC_NUM-1:0] out_port_o,
    output logic [VC_NUM-1:0] is_full_o,
    output logic [VC_NUM-1:0] is_empty_o,
    output logic [VC_NUM-1:0] error_o
);
    import noc_params::*;
    flit_novc_t data_cmd;
    flit_t [VC_NUM-1:0] data_out;
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
        data_cmd.flit_label=data_i.flit_label; data_cmd.data=data_i.data;
        write_cmd={VC_NUM{1'b0}};
        if(valid_flit_i) write_cmd[data_i.vc_id]=1;
        read_cmd={VC_NUM{1'b0}};
        if(sa_valid_i) read_cmd[sa_sel_vc_i]=1;
        xb_flit_o=data_out[sa_sel_vc_i];
    end
endmodule

