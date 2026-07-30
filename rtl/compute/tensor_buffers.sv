`timescale 1ns/1ps

module tensor_buffers #(
  parameter integer MAX_WEIGHT_WORDS = 9216,
  parameter integer MAX_BIAS_WORDS   = 64,
  parameter integer MAX_INPUT_WORDS  = 4096,
  parameter integer MAX_OUTPUT_WORDS = 4096
) (
  input  logic clk_i,

  input  logic                                      weight_we_i,
  input  logic [$clog2(MAX_WEIGHT_WORDS)-1:0]       weight_waddr_i,
  input  logic [31:0]                               weight_wdata_i,
  input  logic                                      bias_we_i,
  input  logic [$clog2(MAX_BIAS_WORDS)-1:0]         bias_waddr_i,
  input  logic [31:0]                               bias_wdata_i,
  input  logic                                      input_we_i,
  input  logic [$clog2(MAX_INPUT_WORDS)-1:0]        input_waddr_i,
  input  logic [31:0]                               input_wdata_i,

  input  logic                                      input_rd_en_i,
  input  logic [$clog2(MAX_INPUT_WORDS)-1:0]        input_rd_word_addr_i,
  input  logic [1:0]                                input_rd_byte_sel_i,
  output logic signed [7:0]                         input_rd_data_o,

  input  logic                                      weight_rd_en_i,
  input  logic [$clog2(MAX_WEIGHT_WORDS)-1:0]       weight_rd_word_addr_i,
  input  logic [1:0]                                weight_rd_byte_sel_i,
  output logic signed [7:0]                         weight_rd_data_o,

  input  logic                                      bias_rd_en_i,
  input  logic [$clog2(MAX_BIAS_WORDS)-1:0]         bias_rd_addr_i,
  output logic signed [31:0]                        bias_rd_data_o,

  input  logic                                      output_we_i,
  input  logic [$clog2(MAX_OUTPUT_WORDS)-1:0]       output_waddr_i,
  input  logic [1:0]                                output_wbyte_sel_i,
  input  logic signed [7:0]                         output_wdata_i,

  input  logic                                      output_rd_en_i,
  input  logic [$clog2(MAX_OUTPUT_WORDS)-1:0]       output_rd_addr_i,
  output logic [31:0]                               output_rd_data_o
);
  logic [31:0] weight_mem [0:MAX_WEIGHT_WORDS-1];
  logic [31:0] bias_mem   [0:MAX_BIAS_WORDS-1];
  logic [31:0] input_mem  [0:MAX_INPUT_WORDS-1];
  logic [31:0] output_mem [0:MAX_OUTPUT_WORDS-1];

  always_ff @(posedge clk_i) begin
    if (weight_we_i)
      weight_mem[weight_waddr_i] <= weight_wdata_i;

    if (bias_we_i)
      bias_mem[bias_waddr_i] <= bias_wdata_i;

    if (input_we_i)
      input_mem[input_waddr_i] <= input_wdata_i;

    if (input_rd_en_i) begin
      case (input_rd_byte_sel_i)
        2'd0: input_rd_data_o <= $signed(input_mem[input_rd_word_addr_i][7:0]);
        2'd1: input_rd_data_o <= $signed(input_mem[input_rd_word_addr_i][15:8]);
        2'd2: input_rd_data_o <= $signed(input_mem[input_rd_word_addr_i][23:16]);
        default: input_rd_data_o <= $signed(input_mem[input_rd_word_addr_i][31:24]);
      endcase
    end

    if (weight_rd_en_i) begin
      case (weight_rd_byte_sel_i)
        2'd0: weight_rd_data_o <= $signed(weight_mem[weight_rd_word_addr_i][7:0]);
        2'd1: weight_rd_data_o <= $signed(weight_mem[weight_rd_word_addr_i][15:8]);
        2'd2: weight_rd_data_o <= $signed(weight_mem[weight_rd_word_addr_i][23:16]);
        default: weight_rd_data_o <= $signed(weight_mem[weight_rd_word_addr_i][31:24]);
      endcase
    end

    if (bias_rd_en_i)
      bias_rd_data_o <= $signed(bias_mem[bias_rd_addr_i]);

    if (output_we_i) begin
      case (output_wbyte_sel_i)
        2'd0: output_mem[output_waddr_i][7:0]   <= output_wdata_i;
        2'd1: output_mem[output_waddr_i][15:8]  <= output_wdata_i;
        2'd2: output_mem[output_waddr_i][23:16] <= output_wdata_i;
        default: output_mem[output_waddr_i][31:24] <= output_wdata_i;
      endcase
    end

    if (output_rd_en_i)
      output_rd_data_o <= output_mem[output_rd_addr_i];
  end
endmodule

