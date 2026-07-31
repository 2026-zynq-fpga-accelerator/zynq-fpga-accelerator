`timescale 1ns/1ps

module resnet_accel_top #(
  parameter integer AXI_ADDR_WIDTH    = 7,
  parameter integer MAX_WEIGHT_WORDS  = 9216,
  parameter integer MAX_BIAS_WORDS    = 64,
  parameter integer MAX_INPUT_WORDS   = 4096,
  parameter integer MAX_OUTPUT_WORDS  = 4096
) (
  input  logic                      aclk,
  input  logic                      aresetn,

  input  logic [AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
  input  logic                      s_axi_awvalid,
  output logic                      s_axi_awready,
  input  logic [31:0]               s_axi_wdata,
  input  logic  [3:0]               s_axi_wstrb,
  input  logic                      s_axi_wvalid,
  output logic                      s_axi_wready,
  output logic  [1:0]               s_axi_bresp,
  output logic                      s_axi_bvalid,
  input  logic                      s_axi_bready,
  input  logic [AXI_ADDR_WIDTH-1:0] s_axi_araddr,
  input  logic                      s_axi_arvalid,
  output logic                      s_axi_arready,
  output logic [31:0]               s_axi_rdata,
  output logic  [1:0]               s_axi_rresp,
  output logic                      s_axi_rvalid,
  input  logic                      s_axi_rready,

  input  logic [31:0]               s_axis_tdata,
  input  logic  [3:0]               s_axis_tkeep,
  input  logic                      s_axis_tlast,
  input  logic                      s_axis_tvalid,
  output logic                      s_axis_tready,

  output logic [31:0]               m_axis_tdata,
  output logic  [3:0]               m_axis_tkeep,
  output logic                      m_axis_tlast,
  output logic                      m_axis_tvalid,
  input  logic                      m_axis_tready
);
  logic idle;
  logic busy;
  logic admission_active;
  logic command_lock;
  logic done;
  logic error;
  logic [31:0] cycle_count;
  logic [31:0] error_code;
  logic [3:0] debug_state;

  logic start_pulse;
  logic abort_pulse;
  logic done_clear_pulse;
  logic error_clear_pulse;
  logic start_while_busy_event;
  logic config_write_busy_event;
  logic invalid_address_event;
  logic abort_error_event;

  logic [31:0] operation;
  logic [31:0] input_height;
  logic [31:0] input_width;
  logic [31:0] in_channels;
  logic [31:0] out_channels;
  logic [31:0] conv_config;
  logic [31:0] output_scale;
  logic [31:0] input_bytes;
  logic [31:0] weight_bytes;
  logic [31:0] bias_bytes;
  logic [31:0] skip_bytes;
  logic [31:0] output_bytes;

  logic operation_accept;
  logic operation_done;
  logic cancel_pulse;
  logic packet_active;
  logic packet_start;
  logic [1:0] packet_select;
  logic [31:0] expected_packet_bytes;
  logic conv_start;
  logic output_start;
  logic invalid_operation_event;
  logic invalid_config_event;
  logic internal_error_event;

  logic [31:0] snap_input_height;
  logic [31:0] snap_input_width;
  logic [31:0] snap_in_channels;
  logic [31:0] snap_out_channels;
  logic [31:0] snap_output_height;
  logic [31:0] snap_output_width;
  logic [7:0]  snap_stride;
  logic [7:0]  snap_padding;
  logic        snap_relu_enable;
  logic [15:0] snap_multiplier;
  logic [15:0] snap_shift;
  logic [31:0] snap_weight_bytes;
  logic [31:0] snap_bias_bytes;
  logic [31:0] snap_input_bytes;
  logic [31:0] snap_output_bytes;

  logic packet_done;
  logic packet_length_error;
  logic tlast_error;

  logic weight_we;
  logic [$clog2(MAX_WEIGHT_WORDS)-1:0] weight_waddr;
  logic [31:0] weight_wdata;
  logic bias_we;
  logic [$clog2(MAX_BIAS_WORDS)-1:0] bias_waddr;
  logic [31:0] bias_wdata;
  logic input_we;
  logic [$clog2(MAX_INPUT_WORDS)-1:0] input_waddr;
  logic [31:0] input_wdata;

  logic input_rd_en;
  logic [$clog2(MAX_INPUT_WORDS)-1:0] input_rd_word_addr;
  logic [1:0] input_rd_byte_sel;
  logic signed [7:0] input_rd_data;
  logic weight_rd_en;
  logic [$clog2(MAX_WEIGHT_WORDS)-1:0] weight_rd_word_addr;
  logic [1:0] weight_rd_byte_sel;
  logic signed [7:0] weight_rd_data;
  logic bias_rd_en;
  logic [$clog2(MAX_BIAS_WORDS)-1:0] bias_rd_addr;
  logic signed [31:0] bias_rd_data;

  logic output_we;
  logic [$clog2(MAX_OUTPUT_WORDS)-1:0] output_waddr;
  logic [1:0] output_wbyte_sel;
  logic signed [7:0] output_wdata;
  logic output_rd_en;
  logic [$clog2(MAX_OUTPUT_WORDS)-1:0] output_rd_addr;
  logic [31:0] output_rd_data;

  logic conv_busy;
  logic conv_done;
  logic accumulator_overflow_event;
  logic output_stream_busy;
  logic output_stream_done;
  logic engine_abort;

  assign command_lock = busy | admission_active;
  assign engine_abort = cancel_pulse | (abort_pulse & busy);

  axi_lite_regs #(
    .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH)
  ) u_axi_lite_regs (
    .aclk_i(aclk),
    .aresetn_i(aresetn),
    .s_axi_awaddr_i(s_axi_awaddr),
    .s_axi_awvalid_i(s_axi_awvalid),
    .s_axi_awready_o(s_axi_awready),
    .s_axi_wdata_i(s_axi_wdata),
    .s_axi_wstrb_i(s_axi_wstrb),
    .s_axi_wvalid_i(s_axi_wvalid),
    .s_axi_wready_o(s_axi_wready),
    .s_axi_bresp_o(s_axi_bresp),
    .s_axi_bvalid_o(s_axi_bvalid),
    .s_axi_bready_i(s_axi_bready),
    .s_axi_araddr_i(s_axi_araddr),
    .s_axi_arvalid_i(s_axi_arvalid),
    .s_axi_arready_o(s_axi_arready),
    .s_axi_rdata_o(s_axi_rdata),
    .s_axi_rresp_o(s_axi_rresp),
    .s_axi_rvalid_o(s_axi_rvalid),
    .s_axi_rready_i(s_axi_rready),
    .idle_i(idle),
    .busy_i(busy),
    .command_lock_i(command_lock),
    .done_i(done),
    .error_i(error),
    .cycle_count_i(cycle_count),
    .error_code_i(error_code),
    .debug_state_i(debug_state),
    .start_pulse_o(start_pulse),
    .abort_pulse_o(abort_pulse),
    .done_clear_pulse_o(done_clear_pulse),
    .error_clear_pulse_o(error_clear_pulse),
    .start_while_busy_event_o(start_while_busy_event),
    .config_write_busy_event_o(config_write_busy_event),
    .invalid_address_event_o(invalid_address_event),
    .abort_error_event_o(abort_error_event),
    .operation_o(operation),
    .input_height_o(input_height),
    .input_width_o(input_width),
    .in_channels_o(in_channels),
    .out_channels_o(out_channels),
    .conv_config_o(conv_config),
    .output_scale_o(output_scale),
    .input_bytes_o(input_bytes),
    .weight_bytes_o(weight_bytes),
    .bias_bytes_o(bias_bytes),
    .skip_bytes_o(skip_bytes),
    .output_bytes_o(output_bytes)
  );

  controller_fsm #(
    .MAX_WEIGHT_WORDS(MAX_WEIGHT_WORDS),
    .MAX_BIAS_WORDS(MAX_BIAS_WORDS),
    .MAX_INPUT_WORDS(MAX_INPUT_WORDS),
    .MAX_OUTPUT_WORDS(MAX_OUTPUT_WORDS)
  ) u_controller (
    .clk_i(aclk),
    .aresetn_i(aresetn),
    .start_pulse_i(start_pulse),
    .abort_pulse_i(abort_pulse),
    .operation_i(operation),
    .input_height_i(input_height),
    .input_width_i(input_width),
    .in_channels_i(in_channels),
    .out_channels_i(out_channels),
    .conv_config_i(conv_config),
    .output_scale_i(output_scale),
    .input_bytes_i(input_bytes),
    .weight_bytes_i(weight_bytes),
    .bias_bytes_i(bias_bytes),
    .skip_bytes_i(skip_bytes),
    .output_bytes_i(output_bytes),
    .packet_done_i(packet_done),
    .packet_length_error_i(packet_length_error),
    .tlast_error_i(tlast_error),
    .conv_done_i(conv_done),
    .output_done_i(output_stream_done),
    .idle_o(idle),
    .busy_o(busy),
    .admission_active_o(admission_active),
    .debug_state_o(debug_state),
    .operation_accept_o(operation_accept),
    .operation_done_o(operation_done),
    .cancel_pulse_o(cancel_pulse),
    .packet_active_o(packet_active),
    .packet_start_o(packet_start),
    .packet_select_o(packet_select),
    .expected_packet_bytes_o(expected_packet_bytes),
    .conv_start_o(conv_start),
    .output_start_o(output_start),
    .invalid_operation_event_o(invalid_operation_event),
    .invalid_config_event_o(invalid_config_event),
    .internal_error_event_o(internal_error_event),
    .snap_input_height_o(snap_input_height),
    .snap_input_width_o(snap_input_width),
    .snap_in_channels_o(snap_in_channels),
    .snap_out_channels_o(snap_out_channels),
    .snap_output_height_o(snap_output_height),
    .snap_output_width_o(snap_output_width),
    .snap_stride_o(snap_stride),
    .snap_padding_o(snap_padding),
    .snap_relu_enable_o(snap_relu_enable),
    .snap_multiplier_o(snap_multiplier),
    .snap_shift_o(snap_shift),
    .snap_weight_bytes_o(snap_weight_bytes),
    .snap_bias_bytes_o(snap_bias_bytes),
    .snap_input_bytes_o(snap_input_bytes),
    .snap_output_bytes_o(snap_output_bytes)
  );

  axis_packet_loader #(
    .MAX_WEIGHT_WORDS(MAX_WEIGHT_WORDS),
    .MAX_BIAS_WORDS(MAX_BIAS_WORDS),
    .MAX_INPUT_WORDS(MAX_INPUT_WORDS)
  ) u_packet_loader (
    .clk_i(aclk),
    .aresetn_i(aresetn),
    .packet_active_i(packet_active),
    .packet_start_i(packet_start),
    .packet_select_i(packet_select),
    .expected_bytes_i(expected_packet_bytes),
    .s_axis_tdata_i(s_axis_tdata),
    .s_axis_tkeep_i(s_axis_tkeep),
    .s_axis_tlast_i(s_axis_tlast),
    .s_axis_tvalid_i(s_axis_tvalid),
    .s_axis_tready_o(s_axis_tready),
    .packet_done_o(packet_done),
    .packet_length_error_o(packet_length_error),
    .tlast_error_o(tlast_error),
    .weight_we_o(weight_we),
    .weight_waddr_o(weight_waddr),
    .weight_wdata_o(weight_wdata),
    .bias_we_o(bias_we),
    .bias_waddr_o(bias_waddr),
    .bias_wdata_o(bias_wdata),
    .input_we_o(input_we),
    .input_waddr_o(input_waddr),
    .input_wdata_o(input_wdata)
  );

  tensor_buffers #(
    .MAX_WEIGHT_WORDS(MAX_WEIGHT_WORDS),
    .MAX_BIAS_WORDS(MAX_BIAS_WORDS),
    .MAX_INPUT_WORDS(MAX_INPUT_WORDS),
    .MAX_OUTPUT_WORDS(MAX_OUTPUT_WORDS)
  ) u_buffers (
    .clk_i(aclk),
    .weight_we_i(weight_we),
    .weight_waddr_i(weight_waddr),
    .weight_wdata_i(weight_wdata),
    .bias_we_i(bias_we),
    .bias_waddr_i(bias_waddr),
    .bias_wdata_i(bias_wdata),
    .input_we_i(input_we),
    .input_waddr_i(input_waddr),
    .input_wdata_i(input_wdata),
    .input_rd_en_i(input_rd_en),
    .input_rd_word_addr_i(input_rd_word_addr),
    .input_rd_byte_sel_i(input_rd_byte_sel),
    .input_rd_data_o(input_rd_data),
    .weight_rd_en_i(weight_rd_en),
    .weight_rd_word_addr_i(weight_rd_word_addr),
    .weight_rd_byte_sel_i(weight_rd_byte_sel),
    .weight_rd_data_o(weight_rd_data),
    .bias_rd_en_i(bias_rd_en),
    .bias_rd_addr_i(bias_rd_addr),
    .bias_rd_data_o(bias_rd_data),
    .output_we_i(output_we),
    .output_waddr_i(output_waddr),
    .output_wbyte_sel_i(output_wbyte_sel),
    .output_wdata_i(output_wdata),
    .output_rd_en_i(output_rd_en),
    .output_rd_addr_i(output_rd_addr),
    .output_rd_data_o(output_rd_data)
  );

  conv_engine #(
    .MAX_WEIGHT_WORDS(MAX_WEIGHT_WORDS),
    .MAX_BIAS_WORDS(MAX_BIAS_WORDS),
    .MAX_INPUT_WORDS(MAX_INPUT_WORDS),
    .MAX_OUTPUT_WORDS(MAX_OUTPUT_WORDS)
  ) u_conv_engine (
    .clk_i(aclk),
    .aresetn_i(aresetn),
    .start_i(conv_start),
    .abort_i(engine_abort),
    .input_height_i(snap_input_height),
    .input_width_i(snap_input_width),
    .in_channels_i(snap_in_channels),
    .out_channels_i(snap_out_channels),
    .output_height_i(snap_output_height),
    .output_width_i(snap_output_width),
    .stride_i(snap_stride),
    .padding_i(snap_padding),
    .relu_enable_i(snap_relu_enable),
    .multiplier_i(snap_multiplier),
    .shift_i(snap_shift),
    .busy_o(conv_busy),
    .done_o(conv_done),
    .overflow_event_o(accumulator_overflow_event),
    .input_rd_en_o(input_rd_en),
    .input_rd_word_addr_o(input_rd_word_addr),
    .input_rd_byte_sel_o(input_rd_byte_sel),
    .input_rd_data_i(input_rd_data),
    .weight_rd_en_o(weight_rd_en),
    .weight_rd_word_addr_o(weight_rd_word_addr),
    .weight_rd_byte_sel_o(weight_rd_byte_sel),
    .weight_rd_data_i(weight_rd_data),
    .bias_rd_en_o(bias_rd_en),
    .bias_rd_addr_o(bias_rd_addr),
    .bias_rd_data_i(bias_rd_data),
    .output_we_o(output_we),
    .output_waddr_o(output_waddr),
    .output_wbyte_sel_o(output_wbyte_sel),
    .output_wdata_o(output_wdata)
  );

  axis_output_streamer #(
    .MAX_OUTPUT_WORDS(MAX_OUTPUT_WORDS)
  ) u_output_streamer (
    .clk_i(aclk),
    .aresetn_i(aresetn),
    .start_i(output_start),
    .abort_i(engine_abort),
    .output_bytes_i(snap_output_bytes),
    .output_rd_en_o(output_rd_en),
    .output_rd_addr_o(output_rd_addr),
    .output_rd_data_i(output_rd_data),
    .m_axis_tdata_o(m_axis_tdata),
    .m_axis_tkeep_o(m_axis_tkeep),
    .m_axis_tlast_o(m_axis_tlast),
    .m_axis_tvalid_o(m_axis_tvalid),
    .m_axis_tready_i(m_axis_tready),
    .busy_o(output_stream_busy),
    .done_o(output_stream_done)
  );

  error_ctrl u_error_ctrl (
    .clk_i(aclk),
    .aresetn_i(aresetn),
    .done_clear_i(done_clear_pulse),
    .error_clear_i(error_clear_pulse),
    .operation_done_i(operation_done),
    .start_while_busy_i(start_while_busy_event),
    .config_write_busy_i(config_write_busy_event),
    .invalid_address_i(invalid_address_event),
    .accumulator_overflow_i(accumulator_overflow_event),
    .invalid_operation_i(invalid_operation_event),
    .invalid_config_i(invalid_config_event),
    .packet_length_i(packet_length_error),
    .tlast_position_i(tlast_error),
    .aborted_i(abort_error_event),
    .internal_error_i(internal_error_event),
    .done_o(done),
    .error_o(error),
    .error_code_o(error_code)
  );

  cycle_counter u_cycle_counter (
    .clk_i(aclk),
    .aresetn_i(aresetn),
    .operation_accept_i(operation_accept),
    .busy_i(busy),
    .cycle_count_o(cycle_count)
  );
endmodule

