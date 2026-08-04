`timescale 1ns/1ps

module axis_packet_loader #(
  parameter integer MAX_WEIGHT_WORDS = 9216,
  parameter integer MAX_BIAS_WORDS   = 64,
  parameter integer MAX_INPUT_WORDS  = 4096
) (
  input  logic clk_i,
  input  logic aresetn_i,

  input  logic        packet_active_i,
  input  logic        packet_start_i,
  input  logic  [1:0] packet_select_i,
  input  logic [31:0] expected_bytes_i,

  input  logic [31:0] s_axis_tdata_i,
  input  logic  [3:0] s_axis_tkeep_i,
  input  logic        s_axis_tlast_i,
  input  logic        s_axis_tvalid_i,
  output logic        s_axis_tready_o,

  output logic packet_done_o,
  output logic packet_length_error_o,
  output logic tlast_error_o,

  output logic                                      weight_we_o,
  output logic [$clog2(MAX_WEIGHT_WORDS)-1:0]       weight_waddr_o,
  output logic [31:0]                               weight_wdata_o,
  output logic                                      bias_we_o,
  output logic [$clog2(MAX_BIAS_WORDS)-1:0]         bias_waddr_o,
  output logic [31:0]                               bias_wdata_o,
  output logic                                      input_we_o,
  output logic [$clog2(MAX_INPUT_WORDS)-1:0]        input_waddr_o,
  output logic [31:0]                               input_wdata_o
);
  localparam logic [1:0] PACKET_WEIGHT = 2'd0;
  localparam logic [1:0] PACKET_BIAS   = 2'd1;
  localparam logic [1:0] PACKET_INPUT  = 2'd2;

  logic [31:0] byte_count_q;
  logic [31:0] base_count;
  logic [32:0] next_count;
  logic        transfer;
  logic        count_valid;
  logic        expected_last;

  always_comb begin
    s_axis_tready_o = packet_active_i && !packet_start_i;
    transfer        = s_axis_tvalid_i && s_axis_tready_o;
    base_count      = packet_start_i ? 32'd0 : byte_count_q;
    next_count      = {1'b0, base_count} + 33'd4;
    count_valid     = (s_axis_tkeep_i == 4'b1111)
                   && (next_count <= {1'b0, expected_bytes_i});
    expected_last   = (next_count == {1'b0, expected_bytes_i});

    weight_we_o    = transfer && count_valid && (packet_select_i == PACKET_WEIGHT);
    weight_waddr_o = base_count[$clog2(MAX_WEIGHT_WORDS)+1:2];
    weight_wdata_o = s_axis_tdata_i;

    bias_we_o    = transfer && count_valid && (packet_select_i == PACKET_BIAS);
    bias_waddr_o = base_count[$clog2(MAX_BIAS_WORDS)+1:2];
    bias_wdata_o = s_axis_tdata_i;

    input_we_o    = transfer && count_valid && (packet_select_i == PACKET_INPUT);
    input_waddr_o = base_count[$clog2(MAX_INPUT_WORDS)+1:2];
    input_wdata_o = s_axis_tdata_i;
  end

  always_ff @(posedge clk_i) begin
    if (!aresetn_i) begin
      byte_count_q         <= 32'd0;
      packet_done_o        <= 1'b0;
      packet_length_error_o <= 1'b0;
      tlast_error_o        <= 1'b0;
    end else begin
      packet_done_o         <= 1'b0;
      packet_length_error_o <= 1'b0;
      tlast_error_o         <= 1'b0;

      if (packet_start_i)
        byte_count_q <= 32'd0;

      if (transfer) begin
        if (!count_valid) begin
          packet_length_error_o <= 1'b1;
        end else begin
          byte_count_q <= next_count[31:0];
          if (s_axis_tlast_i != expected_last)
            tlast_error_o <= 1'b1;
          else if (expected_last)
            packet_done_o <= 1'b1;
        end
      end
    end
  end
endmodule

