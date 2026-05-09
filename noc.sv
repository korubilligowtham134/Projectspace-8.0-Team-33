// Code your design here
// Code your design here

// Code your design here
package noc_params;

	localparam int MESH_SIZE_X = 5;
	localparam int MESH_SIZE_Y = 5;

	localparam int DEST_ADDR_SIZE_X = $clog2(MESH_SIZE_X);
	localparam int DEST_ADDR_SIZE_Y = $clog2(MESH_SIZE_Y);

	localparam int VC_NUM = 2;
	localparam int VC_SIZE = $clog2(VC_NUM);

	localparam int HEAD_PAYLOAD_SIZE = 16;

	localparam int FLIT_DATA_SIZE = DEST_ADDR_SIZE_X+DEST_ADDR_SIZE_Y+HEAD_PAYLOAD_SIZE;

	typedef enum logic [2:0] {LOCAL, NORTH, SOUTH, WEST, EAST} port_t;
	localparam int PORT_NUM = 5;
	localparam int PORT_SIZE = $clog2(PORT_NUM);

	typedef enum logic [1:0] {HEAD, BODY, TAIL, HEADTAIL} flit_label_t;

	typedef struct packed
	{
		logic [DEST_ADDR_SIZE_X-1 : 0] 	x_dest;
		logic [DEST_ADDR_SIZE_Y-1 : 0] 	y_dest;
		logic [HEAD_PAYLOAD_SIZE-1: 0] 	head_pl;
	} head_data_t;

	typedef struct packed
	{
		flit_label_t			flit_label;
		logic [VC_SIZE-1 : 0] 	vc_id;
		union packed
		{
			head_data_t 		head_data;
			logic [FLIT_DATA_SIZE-1 : 0] bt_pl;
		} data;
	} flit_t;

    typedef struct packed
    {
        flit_label_t flit_label;
        union packed
        {
            head_data_t head_data;
            logic [FLIT_DATA_SIZE-1 : 0] bt_pl;
        } data;
    } flit_novc_t;

endpackage

import noc_params::*;

interface input_block2crossbar;

  flit_t flit[PORT_NUM-1:0];

    modport input_block (
        output flit
    );

    modport crossbar (
        input flit
    );

endinterface

interface input_block2switch_allocator;

    port_t [VC_NUM-1:0] out_port [PORT_NUM-1:0];
    logic [VC_SIZE-1:0] vc_sel [PORT_NUM-1:0];
    logic valid_sel [PORT_NUM-1:0];
    logic [VC_SIZE-1:0] downstream_vc [PORT_NUM-1:0][VC_NUM-1:0];
    logic switch_request [PORT_NUM-1:0][VC_NUM-1:0];    //from Input Buffer, asserted when in SA state
    
    modport input_block (
        input vc_sel,
        input valid_sel,
        output out_port,
        output downstream_vc,
        output switch_request
    );

    modport switch_allocator (
        output vc_sel,
        output valid_sel,
        input out_port,
        input downstream_vc,
        input switch_request
    );

endinterface

interface switch_allocator2crossbar;

    logic [PORT_SIZE-1:0] input_vc_sel [PORT_NUM-1:0];

    modport switch_allocator (
        output input_vc_sel
    );

    modport crossbar (
        input input_vc_sel
    );

endinterface

interface input_block2vc_allocator;

    logic [VC_SIZE-1:0] vc_new [PORT_NUM-1:0] [VC_NUM-1:0];
    logic [VC_NUM-1:0] vc_valid [PORT_NUM-1:0];
    logic [VC_NUM-1:0] vc_request [PORT_NUM-1:0];
    port_t [VC_NUM-1:0] out_port [PORT_NUM-1:0];

    modport input_block (
        input vc_new,
        input vc_valid,
        output vc_request,
        output out_port
    );

    modport vc_allocator (
        output vc_new,
        output vc_valid,
        input vc_request,
        input out_port
    );

endinterface

interface router2router;

    flit_t data;
    logic is_valid;
    logic [VC_NUM-1:0] is_on_off;
    logic [VC_NUM-1:0] is_allocatable;

    modport upstream (
        output data,
        output is_valid,
        input is_on_off,
        input is_allocatable
    );

    modport downstream (
        input data,
        input is_valid,
        output is_on_off,
        output is_allocatable
    );

endinterface

module round_robin_arbiter #(
    parameter AGENTS_NUM = 4
)(
    input rst,
    input clk,
    input [AGENTS_NUM-1:0] requests_i,
    output logic [AGENTS_NUM-1:0] grants_o
);

    localparam [31:0] AGENTS_PTR_SIZE = $clog2(AGENTS_NUM);

    logic [AGENTS_PTR_SIZE-1:0] highest_priority, highest_priority_next;

    /*
    Sequential logic:
    - reset on the rising edge of the rst input;
    - update the agent with the highest priority with
      respect to the Round-Robin arbitration policy.
    */
    always_ff@(posedge clk, posedge rst)
    begin
        if(rst)
        begin
            highest_priority <= 0;
        end
        else
        begin
            highest_priority <= highest_priority_next;
        end
    end

    /*
    Combinational logic:
    - among all the agents requesting for the shared resource,
      grant the first one in ascending order starting
      from the current highest priority agent;
    - set as the next highest priority agent
      the one following the granted agent.
    */

    always_comb
    begin
        grants_o = {AGENTS_NUM{1'b0}};
        highest_priority_next = highest_priority;
        for(int i = 0; i < AGENTS_NUM; i = i + 1)
        begin
            if(requests_i[(highest_priority + i) % AGENTS_NUM])
            begin
                grants_o[(highest_priority + i) % AGENTS_NUM] = 1'b1;
                highest_priority_next = (highest_priority + i + 1) % AGENTS_NUM;
                break;
            end
        end
    end

endmodule

module switch_allocator #(
)(
    input rst,
    input clk,
    input [PORT_NUM-1:0][VC_NUM-1:0] on_off_i,
    input_block2switch_allocator.switch_allocator ib_if,
    switch_allocator2crossbar.switch_allocator xbar_if,
    output logic [PORT_NUM-1:0] valid_flit_o
);

    logic [PORT_NUM-1:0][VC_NUM-1:0] request_cmd;
    logic [PORT_NUM-1:0][VC_NUM-1:0] grant;

    separable_input_first_allocator #(
        .VC_NUM(VC_NUM)
    )
    separable_input_first_allocator (
        .rst(rst),
        .clk(clk),
        .request_i(request_cmd),
        .out_port_i(ib_if.out_port),
        .grant_o(grant)
    );

    /*
    Combinational logic:
    - compute the request matrix for the internal Separable Input-First
      Allocator, by setting to 1 the upstream Virtual Channels which are
      requesting for the allocation of a downstream Virtual Channel and
      whose associated downstream Virtual Channel is available from
      the on/off flow control point of view;
    - compute the outputs of the module from the grants matrix obtained
      from the Separable Input-First allocator.
    */
    always_comb
    begin
        for(int port = 0; port < PORT_NUM ; port = port + 1)
        begin
            ib_if.valid_sel[port] = 1'b0;
            valid_flit_o[port] = 1'b0;
            ib_if.vc_sel[port] = {VC_SIZE{1'b0}};
            xbar_if.input_vc_sel[port] = {PORT_SIZE{1'b0}};
            request_cmd[port]={VC_NUM{1'b0}};
        end

        for(int up_port = 0; up_port < PORT_NUM; up_port = up_port + 1)
        begin
            for(int up_vc = 0; up_vc < VC_NUM; up_vc = up_vc + 1)
            begin
                if(ib_if.switch_request[up_port][up_vc] & on_off_i[ib_if.out_port[up_port][up_vc]][ib_if.downstream_vc[up_port][up_vc]])
                begin
                    request_cmd[up_port][up_vc] = 1'b1;
                end
            end
        end

        for(int up_port = 0; up_port < PORT_NUM; up_port = up_port + 1)
        begin
            for(int up_vc = 0; up_vc < VC_NUM; up_vc = up_vc + 1)
            begin
                if(grant[up_port][up_vc])
                begin
                    ib_if.vc_sel[up_port] = up_vc;
                    ib_if.valid_sel[up_port] = 1'b1;
                    valid_flit_o[ib_if.out_port[up_port][up_vc]] = 1'b1;
                    xbar_if.input_vc_sel[ib_if.out_port[up_port][up_vc]] = up_port;
                end
            end
        end
        
    end

endmodule

module separable_input_first_allocator #(
    parameter VC_NUM = 2
)(
    input rst,
    input clk,
    input [PORT_NUM-1:0][VC_NUM-1:0] request_i,
    input port_t [VC_NUM-1:0] out_port_i [PORT_NUM-1:0],
    output logic [PORT_NUM-1:0][VC_NUM-1:0] grant_o
);

    logic [PORT_NUM-1:0][PORT_NUM-1:0] out_request;
    logic [PORT_NUM-1:0][PORT_NUM-1:0] ip_grant;
    logic [PORT_NUM-1:0][VC_NUM-1:0] vc_grant;

    /*
    First stage:
    At each Input Port, Round-Robin arbitration is performed between the
    Virtual Channels requesting for the allocation of any Output Port.
    */
    genvar in_arb;
    generate
        for(in_arb=0; in_arb<PORT_NUM; in_arb++)
        begin: generate_input_round_robin_arbiters
            round_robin_arbiter #(
                .AGENTS_NUM(VC_NUM)
            )
            round_robin_arbiter (
                .rst(rst),
                .clk(clk),
                .requests_i(request_i[in_arb]),
                .grants_o(vc_grant[in_arb])
            );
        end
    endgenerate

    /*
    Second stage:
    At each Output Port, Round-Robin arbitration is performed
    between the Input Ports requesting for its allocation.
    */
    genvar out_arb;
    generate
        for(out_arb=0; out_arb<PORT_NUM; out_arb++)
        begin: generate_output_round_robin_arbiters
            round_robin_arbiter #(
                .AGENTS_NUM(PORT_NUM)
            )
            round_robin_arbiter (
                .rst(rst),
                .clk(clk),
                .requests_i(out_request[out_arb]),
                .grants_o(ip_grant[out_arb])
            );
        end
    endgenerate

    /*
    Combinational logic:
    - compute the request vectors for the second stage arbiters from
      the grants of the first order arbiters; i.e., the Input Ports
      will request the Output Port associated to the Virtual Channel
      winning the first stage arbitration (if there was anyone requesting);
    - compute the output grant matrix from the results of both the first
      and second stage arbiters; i.e., to the VCs winning first stage
      arbitration from Input Ports winning second stage arbitration
      will correspond a 1 in the output grant matrix.
    */
    always_comb
    begin
        out_request = {PORT_NUM*PORT_NUM{1'b0}};
        grant_o= {PORT_NUM*VC_NUM{1'b0}};

        for(int in_port = 0; in_port < PORT_NUM; in_port = in_port + 1)
        begin
            for(int in_vc = 0; in_vc < VC_NUM; in_vc = in_vc + 1)
            begin
                if(vc_grant[in_port][in_vc])
                begin
                    out_request[out_port_i[in_port][in_vc]][in_port] = 1'b1;
                    break;
                end
            end
        end

        for(int out_port = 0; out_port < PORT_NUM; out_port = out_port + 1)
        begin
            for(int in_port = 0; in_port < PORT_NUM; in_port = in_port + 1)
            begin
                for(int in_vc = 0; in_vc < VC_NUM; in_vc = in_vc + 1)
                begin
                    if(ip_grant[out_port][in_port] & vc_grant[in_port][in_vc])
                    begin
                        grant_o[in_port][in_vc] = 1'b1;
                        break;
                    end
                end
            end
        end

    end

endmodule


module vc_allocator #(
)(
    input rst,
    input clk,
    input [PORT_NUM-1:0][VC_NUM-1:0] idle_downstream_vc_i,
    input_block2vc_allocator.vc_allocator ib_if
);

    logic [PORT_NUM-1:0][VC_NUM-1:0] request_cmd;
    logic [PORT_NUM-1:0][VC_NUM-1:0] grant;

    logic [PORT_NUM-1:0][VC_NUM-1:0] is_available_vc, is_available_vc_next;

    separable_input_first_allocator #(
        .VC_NUM(VC_NUM)
    )
    separable_input_first_allocator (
        .rst(rst),
        .clk(clk),
        .request_i(request_cmd),
        .out_port_i(ib_if.out_port),
        .grant_o(grant)
    );

    /*
    Sequential logic:
    - reset on the rising edge of the rst input;
    - update the availability of downstream Virtual Channels.
    */
    always_ff@(posedge clk, posedge rst)
    begin
        if(rst)
        begin
            is_available_vc <= {PORT_NUM*VC_NUM{1'b1}};
        end
        else
        begin
            is_available_vc <= is_available_vc_next;
        end
    end

    /*
    Combinational logic:
    - compute the request matrix for the internal Separable Input-First
      Allocator, by setting to 1 the upstream Virtual Channels which are
      requesting for the allocation of a downstream Virtual Channel and
      whose associated downstream Input Port has at least one available
      Virtual Channel;
    - compute the outputs of the module from the grants matrix obtained
      from the Separable Input-First allocator and update the next
      value for the availability of downstream Virtual Channels if
      they have just been allocated;
    - update the next value for the availability of downstream Virtual
      Channels after their eventual deallocations.
    */
    always_comb
    begin
        is_available_vc_next = is_available_vc;
        for(int up_port = 0; up_port < PORT_NUM; up_port = up_port + 1)
        begin
            for(int up_vc = 0; up_vc < VC_NUM; up_vc = up_vc + 1)
            begin
                request_cmd[up_port][up_vc] = 1'b0;
                ib_if.vc_valid[up_port][up_vc] = 1'b0;
                ib_if.vc_new[up_port][up_vc] = {VC_SIZE{1'bx}};
            end
        end

        for(int up_port = 0; up_port < PORT_NUM; up_port = up_port + 1)
        begin
            for(int up_vc = 0; up_vc < VC_NUM; up_vc = up_vc + 1)
            begin
                if(ib_if.vc_request[up_port][up_vc] & is_available_vc[ib_if.out_port[up_port][up_vc]])
                begin
                    request_cmd[up_port][up_vc] = 1'b1;
                end
            end
        end

        for(int up_port = 0; up_port < PORT_NUM; up_port = up_port + 1)
        begin
            for(int up_vc = 0; up_vc < VC_NUM; up_vc = up_vc + 1)
            begin
                if(grant[up_port][up_vc])
                begin
                    ib_if.vc_new[up_port][up_vc] = assign_downstream_vc(ib_if.out_port[up_port][up_vc]);
                    ib_if.vc_valid[up_port][up_vc] = 1'b1;
                    is_available_vc_next[ib_if.out_port[up_port][up_vc]][ib_if.vc_new[up_port][up_vc]] = 1'b0;
                end
            end
        end

        for(int down_port = 0; down_port < PORT_NUM; down_port = down_port + 1)
        begin
            for(int down_vc = 0; down_vc < VC_NUM; down_vc = down_vc + 1)
            begin
                if(~is_available_vc[down_port][down_vc] & idle_downstream_vc_i[down_port][down_vc])
                begin
                    is_available_vc_next[down_port][down_vc] = 1'b1;
                end
            end
        end
        
    end

    /*
    Returns the first (starting from 0, without any Round-Robin
    mechanism) Virtual Channel available for allocation from
    the downstream Input Port specified as a parameter.
    */
    function logic [VC_SIZE-1:0] assign_downstream_vc (input port_t port);
        assign_downstream_vc = {VC_SIZE{1'bx}};
        for(int vc = 0; vc < VC_NUM; vc = vc + 1)
        begin
            if(is_available_vc[port][vc])
            begin
                assign_downstream_vc = vc;
                break;
            end
        end
    endfunction

endmodule

module crossbar #(
)(
    input_block2crossbar.crossbar ib_if,
    switch_allocator2crossbar.crossbar sa_if,
    output flit_t data_o [PORT_NUM-1:0]
);

    /*
    Combinational logic:
    on each output, propagate the corresponding input
    according to the current selection
    */
    always_comb
    begin
        for(int ip = 0; ip < PORT_NUM; ip = ip + 1)
        begin
            data_o[ip] = ib_if.flit[sa_if.input_vc_sel[ip]];
        end
    end

endmodule


module circular_buffer #(
    parameter BUFFER_SIZE = 8
)(
    input flit_novc_t data_i,
    input read_i,
    input write_i,
    input rst,
    input clk,
    output flit_novc_t data_o,
    output logic is_full_o,
    output logic is_empty_o,
    output logic on_off_o
);

    localparam ON_OFF_LATENCY = 4;
    localparam [31:0] POINTER_SIZE = $clog2(BUFFER_SIZE);

    flit_novc_t memory[BUFFER_SIZE-1:0];

    logic [POINTER_SIZE-1:0] read_ptr;
    logic [POINTER_SIZE-1:0] write_ptr;

    logic [POINTER_SIZE-1:0] read_ptr_next;
    logic [POINTER_SIZE-1:0] write_ptr_next;
    logic is_full_next;
    logic is_empty_next;
    logic on_off_next;

    logic [POINTER_SIZE:0] num_flits;
    logic [POINTER_SIZE:0] num_flits_next;
    
    /*
    Sequential logic:
    - reset on the rising edge of the rst input;
    - when the write_i input is asserted on the rising edge of the clock,
      new data is added to the buffer if the buffer is not full
      or a simultaneous read is performed (i.e., the read_i input is asserted).
    */
    always_ff@(posedge clk or posedge rst)
    begin
        if (rst)
        begin
            read_ptr    <= 0;
            write_ptr   <= 0;
            num_flits   <= 0;
            is_full_o   <= 0;
            is_empty_o  <= 1;
            on_off_o    <= 1;  
        end
        else
        begin
            read_ptr    <= read_ptr_next;
            write_ptr   <= write_ptr_next;
            num_flits   <= num_flits_next;
            is_full_o   <= is_full_next;
            is_empty_o  <= is_empty_next;
            on_off_o    <= on_off_next;
            if((~read_i & write_i & ~is_full_o) | (read_i & write_i))
                memory[write_ptr] <= data_i;
        end
    end

    /*
    Combinational logic:
    - the following operations are accepted:
        * read while the buffer is not empty
        * write while the buffer is not full
        * simultaneously read and write while the buffer is not empty
      and, accordingly to the requested operation:
        * full and empty flags are eventually updated
        * read and write pointers are eventually incremented
        * the number of stored flits is updated
    - otherwise, the buffer next status doesn't change
    - additionally, the flit pointed by the read pointer is output
      and the on/off flag for the flow control is updated
    */
    always_comb
    begin
        data_o = memory [read_ptr];
        unique if(read_i & ~write_i & ~is_empty_o)
        begin: read_not_empty
            read_ptr_next = increase_ptr(read_ptr);
            write_ptr_next = write_ptr;
            is_full_next = 0;
            update_empty_on_read();
            num_flits_next = num_flits - 1;
        end
        else if(~read_i & write_i & ~is_full_o)
        begin: write_not_full
            read_ptr_next = read_ptr;
            write_ptr_next = increase_ptr(write_ptr);
            update_full_on_write();
            is_empty_next = 0;
            num_flits_next = num_flits + 1;
        end
        else if(read_i & write_i & ~is_empty_o)
        begin: read_write_not_empty
            read_ptr_next = increase_ptr(read_ptr);
            write_ptr_next = increase_ptr(write_ptr);
            is_full_next = is_full_o;
            is_empty_next = is_empty_o;
            num_flits_next = num_flits;
        end
        else
        begin: do_nothing
            read_ptr_next = read_ptr;
            write_ptr_next = write_ptr;
            is_full_next = is_full_o;
            is_empty_next = is_empty_o;
            num_flits_next = num_flits;
        end
        begin: update_on_off_flag
            unique if(num_flits > num_flits_next & num_flits_next < ON_OFF_LATENCY)
                on_off_next = 1;
            else if(num_flits < num_flits_next & num_flits_next > BUFFER_SIZE - ON_OFF_LATENCY)
                on_off_next = 0;
            else
                on_off_next = on_off_o;
        end
    end

    function logic [POINTER_SIZE-1:0] increase_ptr (input logic [POINTER_SIZE-1:0] ptr);
        if(ptr == BUFFER_SIZE-1)
            increase_ptr = 0;
        else
            increase_ptr = ptr+1;
    endfunction

    function void update_empty_on_read ();
        if(read_ptr_next == write_ptr)
            is_empty_next = 1;
        else
            is_empty_next = 0;
    endfunction

    function void update_full_on_write ();
        if(write_ptr_next == read_ptr)
            is_full_next = 1;
        else
            is_full_next = 0;
    endfunction

endmodule


module input_block #(
    parameter PORT_NUM = 5,
    parameter BUFFER_SIZE = 8,
    parameter X_CURRENT = MESH_SIZE_X/2,
    parameter Y_CURRENT = MESH_SIZE_Y/2
)(
    input flit_t data_i [PORT_NUM-1:0],
    input valid_flit_i [PORT_NUM-1:0],
    input rst,
    input clk,
    input_block2crossbar.input_block crossbar_if,
    input_block2switch_allocator.input_block sa_if,
    input_block2vc_allocator.input_block va_if,
    output logic [VC_NUM-1:0] on_off_o [PORT_NUM-1:0],
    output logic [VC_NUM-1:0] vc_allocatable_o [PORT_NUM-1:0],
    output logic [VC_NUM-1:0] error_o [PORT_NUM-1:0]
);
    
    logic [VC_NUM-1:0] is_full [PORT_NUM-1:0];
    logic [VC_NUM-1:0] is_empty [PORT_NUM-1:0];

    port_t [VC_NUM-1:0] out_port [PORT_NUM-1:0];

    assign va_if.out_port = out_port;
    assign sa_if.out_port = out_port;

    /*
    The Input Block module contains all the PORT_NUM
    Input Ports composing the Router, making it easier
    to connect all of them through one single interface
    per each other module, i.e., the Crossbar, the
    Virtual Channel Allocator and the Switch Allocator.
    */
    genvar ip;
    generate
        for(ip=0; ip<PORT_NUM; ip++)
        begin: generate_input_ports
            input_port #(
                .BUFFER_SIZE(BUFFER_SIZE),
                .X_CURRENT(X_CURRENT),
                .Y_CURRENT(Y_CURRENT)
            )
            input_port (
                .data_i(data_i[ip]),
                .valid_flit_i(valid_flit_i[ip]),
                .rst(rst),
                .clk(clk),
                .sa_sel_vc_i(sa_if.vc_sel[ip]),
                .va_new_vc_i(va_if.vc_new[ip]),
                .va_valid_i(va_if.vc_valid[ip]),
                .sa_valid_i(sa_if.valid_sel[ip]),
                .xb_flit_o(crossbar_if.flit[ip]),
                .is_on_off_o(on_off_o[ip]),
                .is_allocatable_vc_o(vc_allocatable_o[ip]),
                .va_request_o(va_if.vc_request[ip]),
                .sa_request_o(sa_if.switch_request[ip]),
                .sa_downstream_vc_o(sa_if.downstream_vc[ip]),
                .out_port_o(out_port[ip]),
                .is_full_o(is_full[ip]),
                .is_empty_o(is_empty[ip]),
                .error_o(error_o[ip])
            );
        end
    endgenerate

endmodule


module input_buffer #(
    parameter BUFFER_SIZE = 8
)(
    input flit_novc_t data_i,
    input read_i,
    input write_i,
    input [VC_SIZE-1:0] vc_new_i,
    input vc_valid_i,
    input port_t out_port_i,
    input rst,
    input clk,
    output flit_t data_o,
    output logic is_full_o,
    output logic is_empty_o,
    output logic on_off_o,
    output port_t out_port_o,
    output logic vc_request_o,
    output logic switch_request_o,
    output logic vc_allocatable_o,
    output logic [VC_SIZE-1:0] downstream_vc_o,
    output logic error_o
);

    enum logic [1:0] {IDLE, VA, SA} ss, ss_next;

    logic [VC_SIZE-1:0] downstream_vc_next;

    logic read_cmd, write_cmd;
    logic end_packet, end_packet_next;
    logic vc_allocatable_next;
    logic error_next;

    flit_novc_t read_flit;

    port_t out_port_next;

    circular_buffer #(
        .BUFFER_SIZE(BUFFER_SIZE)
    )
    circular_buffer (
        .data_i(data_i),
        .read_i(read_cmd),
        .write_i(write_cmd),
        .rst(rst),
        .clk(clk),
        .data_o(read_flit),
        .is_full_o(is_full_o),
        .is_empty_o(is_empty_o),
        .on_off_o(on_off_o)
    );

    /*
    Sequential logic:
    - on the rising edge of the reset input signal, reset the state of the
      finite state machine, the next hop destination and the downstream virtual
      channel identifier;
    - on the rising edge of the clock input signal, update the state,
      the next hop destination and the downstream virtual channel identifier.
    */
    always_ff @(posedge clk, posedge rst)
    begin
        if(rst)
        begin
            ss                  <= IDLE;
            out_port_o          <= LOCAL;
            downstream_vc_o     <= 0;
            end_packet          <= 0;
            vc_allocatable_o    <= 0;
            error_o             <= 0;
        end
        else
        begin
            ss                  <= ss_next;
            out_port_o          <= out_port_next;
            downstream_vc_o     <= downstream_vc_next;
            end_packet          <= end_packet_next;
            vc_allocatable_o    <= vc_allocatable_next;
            error_o             <= error_next;
        end
    end

    /*
    Combinational logic:
    - in Idle state, when the input flit is an Head one, the write command is
      asserted and the buffer is empty, then the next hop destination received
      in input and associated to the flit is stored, and the next state is set
      to be Virtual Channel Allocation;
    - in Virtual Channel Allocation state, when the virtual channel for the
      downstream router is valid, i.e., the corresponding validity signal is
      asserted, then the virtual channel identifier is stored and the next
      state is set to be Switch Allocation;
    - in Switch Allocation state, when the last flit to read is the Tail one
      and the read command is asserted, then the next state is set to be Idle.
    */
    always_comb
    begin
        data_o.flit_label = read_flit.flit_label;
		data_o.vc_id = downstream_vc_o;
		data_o.data = read_flit.data;

        ss_next = ss;
        out_port_next = out_port_o;
        downstream_vc_next = downstream_vc_o;

        read_cmd = 0;
        write_cmd = 0;

        end_packet_next = end_packet;
        error_next = 0;

        vc_request_o = 0;
        switch_request_o = 0;
        vc_allocatable_next = 0;

        unique case(ss)
            IDLE:
            begin
                if((data_i.flit_label == HEAD | data_i.flit_label == HEADTAIL) & write_i & is_empty_o)
                begin
                    ss_next = VA;
                    out_port_next = out_port_i;
                    write_cmd = 1;
                end

                if(vc_valid_i | read_i | ((data_i.flit_label == BODY | data_i.flit_label == TAIL) & write_i) | ~is_empty_o)
                begin
                    error_next = 1;
                end
                if(write_i & data_i.flit_label == HEADTAIL)
                begin
                    end_packet_next = 1;
                end
            end

            VA:
            begin
                if(vc_valid_i)
                begin
                    ss_next = SA;
                    downstream_vc_next = vc_new_i;
                end

                vc_request_o = 1;
                if(write_i & (data_i.flit_label == BODY | data_i.flit_label == TAIL) & ~end_packet)
                begin
                    write_cmd = 1;
                end

                if((write_i & (end_packet | data_i.flit_label == HEAD | data_i.flit_label == HEADTAIL)) | read_i)
                begin
                    error_next = 1;
                end
                if(write_i & data_i.flit_label == TAIL)
                begin
                    end_packet_next = 1;
                end
            end

            SA:
            begin
                if(read_i & (data_o.flit_label == TAIL | data_o.flit_label == HEADTAIL))
                begin
                    ss_next = IDLE;
                    vc_allocatable_next = 1;
                    end_packet_next = 0;
                end

                if(~is_empty_o)
                begin
                    switch_request_o = 1;
                end
                    
                read_cmd = read_i;
                if(write_i & (data_i.flit_label == BODY | data_i.flit_label == TAIL) & ~end_packet)
                begin
                    write_cmd = 1;
                end

                if((write_i & (end_packet | data_i.flit_label == HEAD | data_i.flit_label == HEADTAIL)) | vc_valid_i)
                begin
                    error_next = 1;
                end
                if(write_i & data_i.flit_label == TAIL)
                begin
                    end_packet_next = 1;
                end
            end

            default:
            begin
                ss_next = IDLE;
                vc_allocatable_next = 1;
                error_next = 1;
                end_packet_next = 0;
            end

        endcase
    end

endmodule


module input_port #(
    parameter BUFFER_SIZE = 8,
    parameter X_CURRENT = MESH_SIZE_X/2,
    parameter Y_CURRENT = MESH_SIZE_Y/2
)(
    input flit_t data_i,
    input valid_flit_i,
    input rst,
    input clk,
    input [VC_SIZE-1:0] sa_sel_vc_i,
    input [VC_SIZE-1:0] va_new_vc_i [VC_NUM-1:0],
    input [VC_NUM-1:0] va_valid_i,
    input sa_valid_i,
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

    flit_novc_t data_cmd;
    flit_t [VC_NUM-1:0] data_out;

    port_t out_port_cmd;

    logic [VC_NUM-1:0] read_cmd;
    logic [VC_NUM-1:0] write_cmd;

    genvar vc;
    generate
        for(vc=0; vc<VC_NUM; vc++)
        begin: generate_virtual_channels
            input_buffer #(
                .BUFFER_SIZE(BUFFER_SIZE)
            )
            input_buffer (
                .data_i(data_cmd),
                .read_i(read_cmd[vc]),
                .write_i(write_cmd[vc]),
                .vc_new_i(va_new_vc_i[vc]),
                .vc_valid_i(va_valid_i[vc]),
                .out_port_i(out_port_cmd),
                .rst(rst),
                .clk(clk),
                .data_o(data_out[vc]),
                .is_full_o(is_full_o[vc]),
                .is_empty_o(is_empty_o[vc]),
                .on_off_o(is_on_off_o[vc]),
                .out_port_o(out_port_o[vc]),
                .vc_request_o(va_request_o[vc]),
                .switch_request_o(sa_request_o[vc]),
                .vc_allocatable_o(is_allocatable_vc_o[vc]),
                .downstream_vc_o(sa_downstream_vc_o[vc]),
                .error_o(error_o[vc])
            );
        end
    endgenerate

    rc_unit #(
        .X_CURRENT(X_CURRENT),
        .Y_CURRENT(Y_CURRENT),
        .DEST_ADDR_SIZE_X(DEST_ADDR_SIZE_X),
        .DEST_ADDR_SIZE_Y(DEST_ADDR_SIZE_Y)
    )
    rc_unit (
        .x_dest_i(data_i.data.head_data.x_dest),
        .y_dest_i(data_i.data.head_data.y_dest),
        .out_port_o(out_port_cmd)
    );

    /*
    Combinational logic:
    - if the input flit is valid, assert the write command of the corresponding
      virtual channel buffer where the flit has to be stored;
    - assert the read command of the virtual channel buffer selected by the
      interfaced switch allocator and propagate at the crossbar interface the
      corresponding flit.
    */
    always_comb
    begin
        data_cmd.flit_label = data_i.flit_label;
        data_cmd.data = data_i.data;
        
        write_cmd = {VC_NUM{1'b0}};
        if(valid_flit_i)
            write_cmd[data_i.vc_id] = 1;

        read_cmd = {VC_NUM{1'b0}};
        if(sa_valid_i)
            read_cmd[sa_sel_vc_i] = 1;
        xb_flit_o = data_out[sa_sel_vc_i];
    end

endmodule


module rc_unit #(
    parameter X_CURRENT = 0,
    parameter Y_CURRENT = 0,
    parameter DEST_ADDR_SIZE_X = 4,
    parameter DEST_ADDR_SIZE_Y = 4
)(
    input logic [DEST_ADDR_SIZE_X-1 : 0] x_dest_i,
    input logic [DEST_ADDR_SIZE_Y-1 : 0] y_dest_i,
    output port_t out_port_o
);

    wire signed [DEST_ADDR_SIZE_X-1 : 0] x_offset;
    wire signed [DEST_ADDR_SIZE_Y-1 : 0] y_offset;

    assign x_offset = x_dest_i - X_CURRENT;
    assign y_offset = y_dest_i - Y_CURRENT;

    /*
    Combinational logic:
    - the route computation follows a DOR (Dimension-Order Routing) algorithm,
      with the nodes of the Network-on-Chip arranged in a 2D mesh structure,
      hence with 5 inputs and 5 outputs per node (except for boundary routers),
      i.e., both for input and output:
        * left, right, up and down links to the adjacent nodes
        * one link to the end node
    - the 2D Mesh coordinates scheme is mapped as following:
        * X increasing from Left to Right
        * Y increasing from  Up  to Down
    */
    always_comb
    begin
        unique if (x_offset < 0)
        begin
            out_port_o = WEST;
        end
        else if (x_offset > 0)
        begin
            out_port_o = EAST;
        end
        else if (x_offset == 0 & y_offset < 0)
        begin
            out_port_o = NORTH;
        end
        else if (x_offset == 0 & y_offset > 0)
        begin
            out_port_o = SOUTH;
        end
        else
        begin
            out_port_o = LOCAL;
        end
    end

endmodule


module node_link (
    router2router.upstream router_if_up,
    router2router.downstream router_if_down,
    //upstream connections
    input flit_t data_i,
    input is_valid_i,
    output logic [VC_NUM-1:0] is_on_off_o,
    output logic [VC_NUM-1:0] is_allocatable_o,
    //downstream connections
    output flit_t data_o,
    output logic is_valid_o,
    input [VC_NUM-1:0] is_on_off_i,
    input [VC_NUM-1:0] is_allocatable_i
);

    always_comb
    begin
        router_if_up.data = data_i;
        router_if_up.is_valid = is_valid_i;
        is_on_off_o = router_if_up.is_on_off;
        is_allocatable_o = router_if_up.is_allocatable;
        data_o = router_if_down.data;
        is_valid_o = router_if_down.is_valid;
        router_if_down.is_on_off = is_on_off_i;
        router_if_down.is_allocatable = is_allocatable_i;
    end

endmodule


module mesh #(
    parameter BUFFER_SIZE = 8,
    parameter MESH_SIZE_X = 2,
    parameter MESH_SIZE_Y = 3
)(
    input clk,
    input rst,
    output logic [VC_NUM-1:0] error_o [MESH_SIZE_X-1:0][MESH_SIZE_Y-1:0][PORT_NUM-1:0],
    //connections to all local Router interfaces
    output flit_t [MESH_SIZE_X-1:0][MESH_SIZE_Y-1:0] data_o,
    output logic [MESH_SIZE_X-1:0][MESH_SIZE_Y-1:0] is_valid_o,
    input [MESH_SIZE_X-1:0][MESH_SIZE_Y-1:0][VC_NUM-1:0] is_on_off_i,
    input [MESH_SIZE_X-1:0][MESH_SIZE_Y-1:0][VC_NUM-1:0] is_allocatable_i,
    input flit_t [MESH_SIZE_X-1:0][MESH_SIZE_Y-1:0] data_i,
    input [MESH_SIZE_X-1:0][MESH_SIZE_Y-1:0] is_valid_i,
    output logic [MESH_SIZE_X-1:0][MESH_SIZE_Y-1:0][VC_NUM-1:0] is_on_off_o,
    output logic [MESH_SIZE_X-1:0][MESH_SIZE_Y-1:0][VC_NUM-1:0] is_allocatable_o
);

    genvar row, col;
    generate
        for(row=0; row<MESH_SIZE_Y; row++)
        begin: mesh_row
            for(col=0; col<MESH_SIZE_X; col++)
            begin: mesh_col
                //interfaces instantiation
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
                //router instantiation
                router #(
                    .BUFFER_SIZE(BUFFER_SIZE),
                    .X_CURRENT(col),
                    .Y_CURRENT(row)
                )
                router (
                    .clk(clk),
                    .rst(rst),
                    //upstream interfaces connections 
                    .router_if_local_up(local_up),
                    .router_if_north_up(north_up),
                    .router_if_south_up(south_up),
                    .router_if_west_up(west_up),
                    .router_if_east_up(east_up),
                    //downstream interfaces connections
                    .router_if_local_down(local_down),
                    .router_if_north_down(north_down),
                    .router_if_south_down(south_down),
                    .router_if_west_down(west_down),
                    .router_if_east_down(east_down),
                    .error_o(error_o[col][row])
                );
            end
        end

        for(row=0; row<MESH_SIZE_Y-1; row++)
        begin: vertical_links_row
            for(col=0; col<MESH_SIZE_X; col++)
            begin: vertical_links_col
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

        for(row=0; row<MESH_SIZE_Y; row++)
        begin: horizontal_links_row
            for(col=0; col<MESH_SIZE_X-1; col++)
            begin: horizontal_links_col
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

        for(row=0; row<MESH_SIZE_Y; row++)
        begin: node_connection_row
            for(col=0; col<MESH_SIZE_X; col++)
            begin: node_connection_col
                node_link node_link (
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

module router_link (
    router2router.upstream router_if_up,
    router2router.downstream router_if_down
);

    always_comb
    begin
        router_if_up.data = router_if_down.data;
        router_if_up.is_valid = router_if_down.is_valid;
        router_if_down.is_on_off = router_if_up.is_on_off;
        router_if_down.is_allocatable = router_if_up.is_allocatable;
    end

endmodule


module router #(
    parameter BUFFER_SIZE = 8,
    parameter X_CURRENT = MESH_SIZE_X/2,
    parameter Y_CURRENT = MESH_SIZE_Y/2
)(
    input clk,
    input rst,
    router2router.upstream router_if_local_up,
    router2router.upstream router_if_north_up,
    router2router.upstream router_if_south_up,
    router2router.upstream router_if_west_up,
    router2router.upstream router_if_east_up,
    router2router.downstream router_if_local_down,
    router2router.downstream router_if_north_down,
    router2router.downstream router_if_south_down,
    router2router.downstream router_if_west_down,
    router2router.downstream router_if_east_down,
    output logic [VC_NUM-1:0] error_o [PORT_NUM-1:0]
);

    //connections from upstream
    flit_t data_out [PORT_NUM-1:0];
    logic  [PORT_NUM-1:0] is_valid_out;
    logic  [PORT_NUM-1:0] [VC_NUM-1:0] is_on_off_in;
    logic  [PORT_NUM-1:0] [VC_NUM-1:0] is_allocatable_in;

    //connections from downstream
    flit_t data_in [PORT_NUM-1:0];
    logic  is_valid_in [PORT_NUM-1:0];
    logic  [VC_NUM-1:0] is_on_off_out [PORT_NUM-1:0];
    logic  [VC_NUM-1:0] is_allocatable_out [PORT_NUM-1:0];
    initial begin  $display("router2router interface compiled"); end
    always_comb
    begin
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

    input_block #(
        .BUFFER_SIZE(BUFFER_SIZE),
        .X_CURRENT(X_CURRENT),
        .Y_CURRENT(Y_CURRENT)
    )
    input_block (
        .rst(rst),
        .clk(clk),
        .data_i(data_in),
        .valid_flit_i(is_valid_in),
        .crossbar_if(ib2xbar_if),
        .sa_if(ib2sa_if),
        .va_if(ib2va_if),
        .on_off_o(is_on_off_out),
        .vc_allocatable_o(is_allocatable_out),
        .error_o(error_o)
    );

    crossbar #(
    )
    crossbar (
        .ib_if(ib2xbar_if),
        .sa_if(sa2xbar_if),
        .data_o(data_out)
    );

    switch_allocator #(
    )
    switch_allocator (
        .rst(rst),
        .clk(clk),
        .on_off_i(is_on_off_in),
        .ib_if(ib2sa_if),
        .xbar_if(sa2xbar_if),
        .valid_flit_o(is_valid_out)
    );
    
    vc_allocator #(
    )
    vc_allocator (
        .rst(rst),
        .clk(clk),
        .idle_downstream_vc_i(is_allocatable_in),
        .ib_if(ib2va_if)
    );

endmodule
