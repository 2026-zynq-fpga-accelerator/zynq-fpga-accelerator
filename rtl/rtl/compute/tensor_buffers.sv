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
  input  logic                                      skip_we_i,
  input  logic [$clog2(MAX_INPUT_WORDS)-1:0]        skip_waddr_i,
  input  logic [31:0]                               skip_wdata_i,

  input  logic                                      input_rd_en_i,
  input  logic [$clog2(MAX_INPUT_WORDS)-1:0]        input_rd_word_addr_i,
  input  logic [1:0]                                input_rd_byte_sel_i,
  output logic signed [7:0]                         input_rd_data_o,
  input  logic                                      main_word_rd_en_i,
  input  logic [$clog2(MAX_INPUT_WORDS)-1:0]        main_word_rd_addr_i,
  output logic [31:0]                               main_word_rd_data_o,
  input  logic                                      skip_rd_en_i,
  input  logic [$clog2(MAX_INPUT_WORDS)-1:0]        skip_rd_addr_i,
  output logic [31:0]                               skip_rd_data_o,

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
  input  logic                                      output_word_we_i,
  input  logic [$clog2(MAX_OUTPUT_WORDS)-1:0]       output_word_waddr_i,
  input  logic [31:0]                               output_word_wdata_i,

  input  logic                                      output_rd_en_i,
  input  logic [$clog2(MAX_OUTPUT_WORDS)-1:0]       output_rd_addr_i,
  output logic [31:0]                               output_rd_data_o
);
  (* ram_style = "block" *)
  logic [31:0] weight_mem [0:MAX_WEIGHT_WORDS-1];
  logic [31:0] bias_mem   [0:MAX_BIAS_WORDS-1];
  (* ram_style = "block" *)
  logic [31:0] input_mem  [0:MAX_INPUT_WORDS-1];
  (* ram_style = "block" *)
  logic [31:0] skip_mem   [0:MAX_INPUT_WORDS-1];
  (* ram_style = "block" *)
  logic [31:0] output_mem [0:MAX_OUTPUT_WORDS-1];

  logic [31:0] input_rd_word_q;
  logic [31:0] weight_rd_word_q;
  logic [1:0]  input_rd_byte_sel_q;
  logic [1:0]  weight_rd_byte_sel_q;

  // Single unified byte-write-enable port onto output_mem: conv's byte-select write
  // (output_we_i) and residual's full-word write (output_word_we_i) are mutually exclusive
  // at runtime (only one operation ever runs at a time), but textually distinct
  // mem[addr_a]<=...; else mem[addr_b]<=...; writes on the same array don't match Vivado's
  // single-write-port RAM inference template -- it instead falls back to a full distributed
  // (LUT) RAM for the whole array. Muxing address/data/byte-enable down to one write site
  // (a standard byte-write-enable BRAM template) restores clean Block RAM inference.
  logic [3:0]                          output_mem_we;
  logic [$clog2(MAX_OUTPUT_WORDS)-1:0] output_mem_waddr;
  logic [31:0]                         output_mem_wdata;

  always_comb begin
    if (output_word_we_i) begin
      output_mem_we    = 4'b1111;
      output_mem_waddr = output_word_waddr_i;
      output_mem_wdata = output_word_wdata_i;
    end else begin
      output_mem_we    = output_we_i ? (4'b0001 << output_wbyte_sel_i) : 4'b0000;
      output_mem_waddr = output_waddr_i;
      output_mem_wdata = {4{output_wdata_i}};
    end
  end

  always_ff @(posedge clk_i) begin
    if (weight_we_i)
      weight_mem[weight_waddr_i] <= weight_wdata_i;

    if (bias_we_i)
      bias_mem[bias_waddr_i] <= bias_wdata_i;

    if (input_we_i)
      input_mem[input_waddr_i] <= input_wdata_i;

    if (skip_we_i)
      skip_mem[skip_waddr_i] <= skip_wdata_i;

    if (input_rd_en_i) begin
      input_rd_word_q     <= input_mem[input_rd_word_addr_i];
      input_rd_byte_sel_q <= input_rd_byte_sel_i;
    end

    if (main_word_rd_en_i)
      main_word_rd_data_o <= input_mem[main_word_rd_addr_i];

    if (skip_rd_en_i)
      skip_rd_data_o <= skip_mem[skip_rd_addr_i];

    if (weight_rd_en_i) begin
      weight_rd_word_q     <= weight_mem[weight_rd_word_addr_i];
      weight_rd_byte_sel_q <= weight_rd_byte_sel_i;
    end

    if (bias_rd_en_i)
      bias_rd_data_o <= $signed(bias_mem[bias_rd_addr_i]);

    if (output_mem_we[0]) output_mem[output_mem_waddr][7:0]   <= output_mem_wdata[7:0];
    if (output_mem_we[1]) output_mem[output_mem_waddr][15:8]  <= output_mem_wdata[15:8];
    if (output_mem_we[2]) output_mem[output_mem_waddr][23:16] <= output_mem_wdata[23:16];
    if (output_mem_we[3]) output_mem[output_mem_waddr][31:24] <= output_mem_wdata[31:24];

    if (output_rd_en_i)
      output_rd_data_o <= output_mem[output_rd_addr_i];
  end

  always_comb begin
    case (input_rd_byte_sel_q)
      2'd0: input_rd_data_o = $signed(input_rd_word_q[7:0]);
      2'd1: input_rd_data_o = $signed(input_rd_word_q[15:8]);
      2'd2: input_rd_data_o = $signed(input_rd_word_q[23:16]);
      default: input_rd_data_o = $signed(input_rd_word_q[31:24]);
    endcase

    case (weight_rd_byte_sel_q)
      2'd0: weight_rd_data_o = $signed(weight_rd_word_q[7:0]);
      2'd1: weight_rd_data_o = $signed(weight_rd_word_q[15:8]);
      2'd2: weight_rd_data_o = $signed(weight_rd_word_q[23:16]);
      default: weight_rd_data_o = $signed(weight_rd_word_q[31:24]);
    endcase
  end
endmodule

