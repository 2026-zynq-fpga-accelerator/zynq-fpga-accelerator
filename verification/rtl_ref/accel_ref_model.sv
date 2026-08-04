// Behavioral reference model of the OP_CONV accelerator, HW_SW_Interface_v1.1_FINAL.md.
//
// This is NOT synthesizable RTL. It is a spec-conformant
// stand-in DUT so the cocotb verification environment (verification/cocotb/) can be built
// and run before the real RTL lands in this repo. Swap TOPLEVEL in
// verification/cocotb/Makefile to the real module (matching this port list, or update the
// cocotb BFMs to match) once it is available, then re-run the same test suite as regression.
//
// Register map: §8. AXI4-Stream packing: §6. Fixed-point/requant rules: §5. Controller FSM: §12.

module accel_ref_model #(
    parameter int MAX_BYTES = 65536
) (
    input  logic        clk,
    input  logic        aresetn, // active-low, PS7 FCLK_RESET0_N convention

    // AXI4-Lite slave (32-bit)
    input  logic [31:0] s_axi_awaddr,
    input  logic         s_axi_awvalid,
    output logic         s_axi_awready,
    input  logic [31:0] s_axi_wdata,
    input  logic [3:0]  s_axi_wstrb,
    input  logic         s_axi_wvalid,
    output logic         s_axi_wready,
    output logic [1:0]  s_axi_bresp,
    output logic         s_axi_bvalid,
    input  logic         s_axi_bready,
    input  logic [31:0] s_axi_araddr,
    input  logic         s_axi_arvalid,
    output logic         s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic         s_axi_rvalid,
    input  logic         s_axi_rready,

    // AXI4-Stream slave: Weight -> Bias -> Input packets (§7.1)
    input  logic [31:0] s_axis_tdata,
    input  logic [3:0]  s_axis_tkeep,
    input  logic         s_axis_tlast,
    input  logic         s_axis_tvalid,
    output logic         s_axis_tready,

    // AXI4-Stream master: Output packet
    output logic [31:0] m_axis_tdata,
    output logic [3:0]  m_axis_tkeep,
    output logic         m_axis_tlast,
    output logic         m_axis_tvalid,
    input  logic         m_axis_tready
);

    // ---- Register offsets (accel_regs.h / §8.2) ----
    localparam logic [7:0]
        OFF_CONTROL      = 8'h00,
        OFF_STATUS       = 8'h04,
        OFF_OPERATION    = 8'h08,
        OFF_INPUT_HEIGHT = 8'h0C,
        OFF_INPUT_WIDTH  = 8'h10,
        OFF_IN_CHANNELS  = 8'h14,
        OFF_OUT_CHANNELS = 8'h18,
        OFF_CONV_CONFIG  = 8'h1C,
        OFF_OUTPUT_SCALE = 8'h20,
        OFF_INPUT_BYTES  = 8'h24,
        OFF_WEIGHT_BYTES = 8'h28,
        OFF_BIAS_BYTES   = 8'h2C,
        OFF_SKIP_BYTES   = 8'h30,
        OFF_OUTPUT_BYTES = 8'h34,
        OFF_CYCLE_COUNT  = 8'h38,
        OFF_ERROR_CODE   = 8'h3C,
        OFF_VERSION      = 8'h40,
        OFF_DEBUG_STATE  = 8'h44;

    localparam logic [31:0] VERSION_VALUE = 32'h0001_0001;

    typedef enum logic [3:0] {
        ST_RESET       = 4'd0,
        ST_IDLE        = 4'd1,
        ST_LOAD_WEIGHT = 4'd2,
        ST_LOAD_BIAS   = 4'd3,
        ST_LOAD_INPUT  = 4'd4,
        ST_COMPUTE     = 4'd5,
        ST_SEND_OUTPUT = 4'd6,
        ST_COMPLETE    = 4'd7
    } fsm_state_t;

    typedef enum logic [3:0] {
        ERR_NONE              = 4'd0,
        ERR_START_WHILE_BUSY  = 4'd1,
        ERR_INVALID_OPERATION = 4'd2,
        ERR_INVALID_CONFIG    = 4'd3,
        ERR_PACKET_LENGTH     = 4'd4,
        ERR_TLAST_POSITION    = 4'd5,
        ERR_ACC_OVERFLOW      = 4'd6,
        ERR_ABORTED           = 4'd7,
        ERR_CONFIG_WRITE_BUSY = 4'd8,
        ERR_INTERNAL          = 4'd9,
        ERR_INVALID_ADDRESS   = 4'd10
    } error_code_t;

    function automatic bit is_fatal(error_code_t code);
        case (code)
            ERR_INVALID_OPERATION, ERR_INVALID_CONFIG, ERR_PACKET_LENGTH,
            ERR_TLAST_POSITION, ERR_ABORTED, ERR_INTERNAL: is_fatal = 1'b1;
            default: is_fatal = 1'b0;
        endcase
    endfunction

    // §10.4 priority: first error wins unless a later one is fatal and the stored one isn't.
    function automatic error_code_t next_error_code(error_code_t cur, error_code_t incoming);
        if (cur == ERR_NONE || (!is_fatal(cur) && is_fatal(incoming)))
            next_error_code = incoming;
        else
            next_error_code = cur;
    endfunction

    // ---- Register file ----
    fsm_state_t  state, state_n;
    logic        busy, done_sticky, error_sticky;
    error_code_t error_code_reg;
    logic [31:0] operation_reg, input_height_reg, input_width_reg, in_channels_reg,
                 out_channels_reg, conv_config_reg, output_scale_reg,
                 input_bytes_reg, weight_bytes_reg, bias_bytes_reg, skip_bytes_reg,
                 output_bytes_reg, cycle_count_reg;

    wire [7:0]  kernel_size = conv_config_reg[7:0];
    wire [7:0]  stride      = conv_config_reg[15:8];
    wire [7:0]  padding     = conv_config_reg[23:16];
    wire        relu_enable = conv_config_reg[24];
    wire [15:0] mult_m      = output_scale_reg[15:0];
    wire [15:0] shift_n     = output_scale_reg[31:16];

    // ---- AXI4-Lite write channel (Xilinx-style combined AW/W handshake) ----
    logic axi_awready, axi_wready;
    logic [7:0] axi_awaddr_latched;
    logic axi_bvalid;

    assign s_axi_awready = axi_awready;
    assign s_axi_wready  = axi_wready;
    assign s_axi_bvalid  = axi_bvalid;
    assign s_axi_bresp   = 2'b00; // OKAY, always (§9.1)

    always_ff @(posedge clk) begin
        if (!aresetn) begin
            axi_awready <= 1'b0;
            axi_wready  <= 1'b0;
            axi_bvalid  <= 1'b0;
            axi_awaddr_latched <= '0;
        end else begin
            if (!axi_awready && s_axi_awvalid && s_axi_wvalid) begin
                axi_awready <= 1'b1;
                axi_wready  <= 1'b1;
                axi_awaddr_latched <= s_axi_awaddr[7:0];
            end else begin
                axi_awready <= 1'b0;
                axi_wready  <= 1'b0;
            end

            if (axi_bvalid && s_axi_bready)
                axi_bvalid <= 1'b0;
            else if (axi_awready && s_axi_awvalid && axi_wready && s_axi_wvalid)
                axi_bvalid <= 1'b1;
        end
    end

    wire do_reg_write = axi_awready && s_axi_awvalid && axi_wready && s_axi_wvalid;
    wire [7:0] waddr = axi_awaddr_latched;
    wire [31:0] wdata = s_axi_wdata;

    // ---- AXI4-Lite read channel ----
    logic axi_arready, axi_rvalid;
    logic [7:0] axi_araddr_latched;
    logic [31:0] axi_rdata;

    assign s_axi_arready = axi_arready;
    assign s_axi_rvalid  = axi_rvalid;
    assign s_axi_rdata   = axi_rdata;
    assign s_axi_rresp   = 2'b00; // OKAY (§9.3)

    always_ff @(posedge clk) begin
        if (!aresetn) begin
            axi_arready <= 1'b0;
            axi_rvalid  <= 1'b0;
            axi_araddr_latched <= '0;
        end else begin
            if (!axi_arready && s_axi_arvalid && !axi_rvalid) begin
                axi_arready <= 1'b1;
                axi_araddr_latched <= s_axi_araddr[7:0];
            end else begin
                axi_arready <= 1'b0;
            end

            if (axi_arready && s_axi_arvalid)
                axi_rvalid <= 1'b1;
            else if (axi_rvalid && s_axi_rready)
                axi_rvalid <= 1'b0;
        end
    end

    always_comb begin
        case (axi_araddr_latched)
            OFF_CONTROL:      axi_rdata = '0; // W1P, reads back 0
            OFF_STATUS:       axi_rdata = {28'b0, error_sticky, done_sticky, busy, ~busy};
            OFF_OPERATION:    axi_rdata = operation_reg;
            OFF_INPUT_HEIGHT: axi_rdata = input_height_reg;
            OFF_INPUT_WIDTH:  axi_rdata = input_width_reg;
            OFF_IN_CHANNELS:  axi_rdata = in_channels_reg;
            OFF_OUT_CHANNELS: axi_rdata = out_channels_reg;
            OFF_CONV_CONFIG:  axi_rdata = conv_config_reg;
            OFF_OUTPUT_SCALE: axi_rdata = output_scale_reg;
            OFF_INPUT_BYTES:  axi_rdata = input_bytes_reg;
            OFF_WEIGHT_BYTES: axi_rdata = weight_bytes_reg;
            OFF_BIAS_BYTES:   axi_rdata = bias_bytes_reg;
            OFF_SKIP_BYTES:   axi_rdata = skip_bytes_reg;
            OFF_OUTPUT_BYTES: axi_rdata = output_bytes_reg;
            OFF_CYCLE_COUNT:  axi_rdata = cycle_count_reg;
            OFF_ERROR_CODE:   axi_rdata = {28'b0, error_code_reg};
            OFF_VERSION:      axi_rdata = VERSION_VALUE;
            OFF_DEBUG_STATE:  axi_rdata = {28'b0, state};
            default:          axi_rdata = 32'h0; // §9.3 undefined offset reads 0
        endcase
    end

    // ---- Weight/Bias/Input/Output storage ----
    byte weight_mem [0:MAX_BYTES-1];
    byte input_mem  [0:MAX_BYTES-1];
    byte output_mem [0:MAX_BYTES-1];
    logic signed [31:0] bias_mem [0:16383];

    logic [31:0] load_byte_cnt;
    logic [31:0] send_byte_cnt;
    logic [31:0] out_h_reg, out_w_reg;
    logic [31:0] m_axis_tdata_reg; // registered, not a continuous-assign array index (iverilog 12.0 workaround)

    logic start_pulse, abort_pulse;
    logic start_accept_valid;
    error_code_t start_reject_code;

    // §11.2 START accept validation (combinational, evaluated when a START is requested)
    always_comb begin
        logic [31:0] oh, ow;
        bit shape_ok;
        oh = 0; ow = 0; shape_ok = 1'b0;
        start_reject_code = ERR_NONE;

        if (operation_reg != 32'd0) begin
            start_reject_code = ERR_INVALID_OPERATION;
        end else if (input_height_reg == 0 || input_width_reg == 0 ||
                     in_channels_reg == 0 || out_channels_reg == 0 ||
                     kernel_size == 0 || (stride != 8'd1 && stride != 8'd2) ||
                     shift_n > 16'd31 ||
                     (input_height_reg + 2*padding) < kernel_size ||
                     (input_width_reg + 2*padding) < kernel_size) begin
            start_reject_code = ERR_INVALID_CONFIG;
        end else begin
            oh = (input_height_reg + 2*padding - kernel_size) / stride + 1;
            ow = (input_width_reg + 2*padding - kernel_size) / stride + 1;
            if (weight_bytes_reg != kernel_size*kernel_size*in_channels_reg*out_channels_reg ||
                bias_bytes_reg   != out_channels_reg*4 ||
                input_bytes_reg  != input_height_reg*input_width_reg*in_channels_reg ||
                output_bytes_reg != oh*ow*out_channels_reg) begin
                start_reject_code = ERR_INVALID_CONFIG;
            end else begin
                shape_ok = 1'b1;
            end
        end
        start_accept_valid = shape_ok && (start_reject_code == ERR_NONE);
    end

    // ---- Controller FSM + register writes ----
    integer i, kh, kw, ic, oc, oh_i, ow_i;
    integer ih, iw, wi;
    byte signed wv, iv;
    longint acc, wide, prod, p_val, q_val;
    logic overflow_seen;

    always_ff @(posedge clk) begin
        if (!aresetn) begin
            state <= ST_RESET;
            busy <= 1'b0;
            done_sticky <= 1'b0;
            error_sticky <= 1'b0;
            error_code_reg <= ERR_NONE;
            operation_reg <= '0;
            input_height_reg <= '0;
            input_width_reg <= '0;
            in_channels_reg <= '0;
            out_channels_reg <= '0;
            conv_config_reg <= '0;
            output_scale_reg <= '0;
            input_bytes_reg <= '0;
            weight_bytes_reg <= '0;
            bias_bytes_reg <= '0;
            skip_bytes_reg <= '0;
            output_bytes_reg <= '0;
            cycle_count_reg <= '0;
            load_byte_cnt <= '0;
            send_byte_cnt <= '0;
            m_axis_tdata_reg <= '0;
            state <= ST_IDLE; // reset is combinational-instant in this behavioral model
        end else begin
            state <= state; // default hold; overridden below
            start_pulse = do_reg_write && (waddr == OFF_CONTROL) && wdata[0];
            abort_pulse = do_reg_write && (waddr == OFF_CONTROL) && wdata[1];

            // ---- STATUS W1C ----
            if (do_reg_write && waddr == OFF_STATUS) begin
                if (wdata[2]) done_sticky <= 1'b0;
                if (wdata[3]) begin
                    error_sticky <= 1'b0;
                    error_code_reg <= ERR_NONE;
                end
            end

            // ---- Config register writes: only when not BUSY (§9.2) ----
            if (do_reg_write && !busy) begin
                case (waddr)
                    OFF_OPERATION:    operation_reg    <= wdata;
                    OFF_INPUT_HEIGHT: input_height_reg <= wdata;
                    OFF_INPUT_WIDTH:  input_width_reg  <= wdata;
                    OFF_IN_CHANNELS:  in_channels_reg  <= wdata;
                    OFF_OUT_CHANNELS: out_channels_reg <= wdata;
                    OFF_CONV_CONFIG:  conv_config_reg  <= wdata;
                    OFF_OUTPUT_SCALE: output_scale_reg <= wdata;
                    OFF_INPUT_BYTES:  input_bytes_reg  <= wdata;
                    OFF_WEIGHT_BYTES: weight_bytes_reg <= wdata;
                    OFF_BIAS_BYTES:   bias_bytes_reg   <= wdata;
                    OFF_SKIP_BYTES:   skip_bytes_reg   <= wdata;
                    OFF_OUTPUT_BYTES: output_bytes_reg <= wdata;
                    default: ; // CONTROL/STATUS handled separately, RO regs ignored
                endcase
            end else if (do_reg_write && busy) begin
                case (waddr)
                    OFF_CONTROL, OFF_STATUS: ; // allowed during BUSY
                    OFF_OPERATION, OFF_INPUT_HEIGHT, OFF_INPUT_WIDTH, OFF_IN_CHANNELS,
                    OFF_OUT_CHANNELS, OFF_CONV_CONFIG, OFF_OUTPUT_SCALE, OFF_INPUT_BYTES,
                    OFF_WEIGHT_BYTES, OFF_BIAS_BYTES, OFF_SKIP_BYTES, OFF_OUTPUT_BYTES: begin
                        error_code_reg <= next_error_code(error_code_reg, ERR_CONFIG_WRITE_BUSY);
                        error_sticky <= 1'b1;
                    end
                    default: ; // RO/undefined handled below
                endcase
            end

            // ---- Undefined offset write (any BUSY state), §9.3 ----
            if (do_reg_write && waddr != OFF_CONTROL && waddr != OFF_STATUS &&
                waddr != OFF_OPERATION && waddr != OFF_INPUT_HEIGHT && waddr != OFF_INPUT_WIDTH &&
                waddr != OFF_IN_CHANNELS && waddr != OFF_OUT_CHANNELS && waddr != OFF_CONV_CONFIG &&
                waddr != OFF_OUTPUT_SCALE && waddr != OFF_INPUT_BYTES && waddr != OFF_WEIGHT_BYTES &&
                waddr != OFF_BIAS_BYTES && waddr != OFF_SKIP_BYTES && waddr != OFF_OUTPUT_BYTES) begin
                error_code_reg <= next_error_code(error_code_reg, ERR_INVALID_ADDRESS);
                error_sticky <= 1'b1;
            end

            // ---- ABORT (priority over START, allowed even in IDLE where it's a no-op) ----
            if (abort_pulse && busy) begin
                busy <= 1'b0;
                done_sticky <= 1'b0;
                error_code_reg <= next_error_code(error_code_reg, ERR_ABORTED);
                error_sticky <= 1'b1;
                state <= ST_IDLE;
            end else if (start_pulse && !busy) begin
                if (start_accept_valid) begin
                    busy <= 1'b1;
                    cycle_count_reg <= '0;
                    load_byte_cnt <= '0;
                    state <= ST_LOAD_WEIGHT;
                end else begin
                    error_code_reg <= next_error_code(error_code_reg, start_reject_code);
                    error_sticky <= 1'b1;
                end
            end else if (start_pulse && busy) begin
                error_code_reg <= next_error_code(error_code_reg, ERR_START_WHILE_BUSY);
                error_sticky <= 1'b1;
            end

            if (busy) cycle_count_reg <= cycle_count_reg + 1;

            // ---- Stream loads ----
            unique case (state)
                ST_LOAD_WEIGHT: if (s_axis_tvalid && s_axis_tready) begin
                    weight_mem[load_byte_cnt+0] <= s_axis_tdata[7:0];
                    weight_mem[load_byte_cnt+1] <= s_axis_tdata[15:8];
                    weight_mem[load_byte_cnt+2] <= s_axis_tdata[23:16];
                    weight_mem[load_byte_cnt+3] <= s_axis_tdata[31:24];
                    if (load_byte_cnt + 4 >= weight_bytes_reg) begin
                        if (!s_axis_tlast) begin
                            error_code_reg <= next_error_code(error_code_reg, ERR_TLAST_POSITION);
                            error_sticky <= 1'b1; busy <= 1'b0; state <= ST_IDLE;
                        end else begin
                            load_byte_cnt <= '0;
                            state <= ST_LOAD_BIAS;
                        end
                    end else begin
                        if (s_axis_tlast) begin
                            error_code_reg <= next_error_code(error_code_reg, ERR_TLAST_POSITION);
                            error_sticky <= 1'b1; busy <= 1'b0; state <= ST_IDLE;
                        end else begin
                            load_byte_cnt <= load_byte_cnt + 4;
                        end
                    end
                end

                ST_LOAD_BIAS: if (s_axis_tvalid && s_axis_tready) begin
                    bias_mem[load_byte_cnt >> 2] <= $signed(s_axis_tdata);
                    if (load_byte_cnt + 4 >= bias_bytes_reg) begin
                        if (!s_axis_tlast) begin
                            error_code_reg <= next_error_code(error_code_reg, ERR_TLAST_POSITION);
                            error_sticky <= 1'b1; busy <= 1'b0; state <= ST_IDLE;
                        end else begin
                            load_byte_cnt <= '0;
                            state <= ST_LOAD_INPUT;
                        end
                    end else begin
                        if (s_axis_tlast) begin
                            error_code_reg <= next_error_code(error_code_reg, ERR_TLAST_POSITION);
                            error_sticky <= 1'b1; busy <= 1'b0; state <= ST_IDLE;
                        end else begin
                            load_byte_cnt <= load_byte_cnt + 4;
                        end
                    end
                end

                ST_LOAD_INPUT: if (s_axis_tvalid && s_axis_tready) begin
                    input_mem[load_byte_cnt+0] <= s_axis_tdata[7:0];
                    input_mem[load_byte_cnt+1] <= s_axis_tdata[15:8];
                    input_mem[load_byte_cnt+2] <= s_axis_tdata[23:16];
                    input_mem[load_byte_cnt+3] <= s_axis_tdata[31:24];
                    if (load_byte_cnt + 4 >= input_bytes_reg) begin
                        if (!s_axis_tlast) begin
                            error_code_reg <= next_error_code(error_code_reg, ERR_TLAST_POSITION);
                            error_sticky <= 1'b1; busy <= 1'b0; state <= ST_IDLE;
                        end else begin
                            state <= ST_COMPUTE;
                        end
                    end else begin
                        if (s_axis_tlast) begin
                            error_code_reg <= next_error_code(error_code_reg, ERR_TLAST_POSITION);
                            error_sticky <= 1'b1; busy <= 1'b0; state <= ST_IDLE;
                        end else begin
                            load_byte_cnt <= load_byte_cnt + 4;
                        end
                    end
                end

                ST_COMPUTE: begin
                    // §5: signed INT8 MAC, per-step INT32 saturation, M/N requant, ReLU, INT8 clamp.
                    out_h_reg = (input_height_reg + 2*padding - kernel_size) / stride + 1;
                    out_w_reg = (input_width_reg + 2*padding - kernel_size) / stride + 1;
                    overflow_seen = 1'b0;

                    for (oh_i = 0; oh_i < out_h_reg; oh_i++) begin
                        for (ow_i = 0; ow_i < out_w_reg; ow_i++) begin
                            for (oc = 0; oc < out_channels_reg; oc++) begin
                                acc = 64'sd0;
                                for (kh = 0; kh < kernel_size; kh++) begin
                                    for (kw = 0; kw < kernel_size; kw++) begin
                                        ih = oh_i*stride - padding + kh;
                                        iw = ow_i*stride - padding + kw;
                                        for (ic = 0; ic < in_channels_reg; ic++) begin
                                            wi = (((kh*kernel_size)+kw)*in_channels_reg+ic)*out_channels_reg+oc;
                                            wv = weight_mem[wi];
                                            if (ih >= 0 && ih < input_height_reg && iw >= 0 && iw < input_width_reg)
                                                iv = input_mem[(ih*input_width_reg+iw)*in_channels_reg+ic];
                                            else
                                                iv = 8'sd0;
                                            prod = $signed({{48{iv[7]}}, iv}) * $signed({{48{wv[7]}}, wv});
                                            wide = acc + prod;
                                            if (wide > 64'sd2147483647) begin acc = 64'sd2147483647; overflow_seen = 1'b1; end
                                            else if (wide < -64'sd2147483648) begin acc = -64'sd2147483648; overflow_seen = 1'b1; end
                                            else acc = wide;
                                        end
                                    end
                                end
                                wide = acc + bias_mem[oc];
                                if (wide > 64'sd2147483647) begin acc = 64'sd2147483647; overflow_seen = 1'b1; end
                                else if (wide < -64'sd2147483648) begin acc = -64'sd2147483648; overflow_seen = 1'b1; end
                                else acc = wide;

                                p_val = acc * $signed({1'b0, mult_m});
                                if (shift_n == 0) q_val = p_val;
                                else if (p_val >= 0) q_val = (p_val + (64'sd1 <<< (shift_n-1))) >>> shift_n;
                                else q_val = -(((-p_val) + (64'sd1 <<< (shift_n-1))) >>> shift_n);

                                if (relu_enable && q_val < 0) q_val = 0;
                                if (q_val > 127) q_val = 127;
                                else if (q_val < -128) q_val = -128;

                                output_mem[(oh_i*out_w_reg+ow_i)*out_channels_reg+oc] = q_val[7:0];
                            end
                        end
                    end

                    if (overflow_seen) begin
                        error_code_reg <= next_error_code(error_code_reg, ERR_ACC_OVERFLOW);
                        error_sticky <= 1'b1;
                    end
                    send_byte_cnt <= '0;
                    m_axis_tdata_reg <= {output_mem[3], output_mem[2], output_mem[1], output_mem[0]};
                    state <= ST_SEND_OUTPUT;
                end

                ST_SEND_OUTPUT: if (m_axis_tvalid && m_axis_tready) begin
                    if (send_byte_cnt + 4 >= output_bytes_reg) begin
                        busy <= 1'b0;
                        done_sticky <= 1'b1;
                        state <= ST_COMPLETE;
                    end else begin
                        send_byte_cnt <= send_byte_cnt + 4;
                        m_axis_tdata_reg <= {output_mem[send_byte_cnt+7], output_mem[send_byte_cnt+6],
                                              output_mem[send_byte_cnt+5], output_mem[send_byte_cnt+4]};
                    end
                end

                ST_COMPLETE: state <= ST_IDLE;

                default: ;
            endcase
        end
    end

    assign s_axis_tready = (state == ST_LOAD_WEIGHT || state == ST_LOAD_BIAS || state == ST_LOAD_INPUT);

    assign m_axis_tvalid = (state == ST_SEND_OUTPUT);
    assign m_axis_tkeep  = 4'b1111;
    assign m_axis_tdata  = m_axis_tdata_reg;
    assign m_axis_tlast  = (state == ST_SEND_OUTPUT) && (send_byte_cnt + 4 >= output_bytes_reg);

endmodule
