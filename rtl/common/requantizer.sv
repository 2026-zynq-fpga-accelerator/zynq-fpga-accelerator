`timescale 1ns/1ps

module requantizer (
  input  logic               clk_i,
  input  logic               aresetn_i,
  input  logic               clear_i,
  input  logic               mul_enable_i,
  input  logic               round_enable_i,
  input  logic signed [31:0] accumulator_i,
  input  logic        [15:0] multiplier_i,
  input  logic        [15:0] shift_i,
  output logic signed [49:0] requantized_o,
  output logic               product_valid_o,
  output logic               requantized_valid_o
);
  logic signed [16:0] multiplier_signed;
  logic signed [48:0] product_next;
  logic signed [48:0] product_q;
  logic signed [49:0] product_ext;
  logic        [49:0] magnitude;
  logic        [49:0] rounding_offset;
  logic        [49:0] rounded_magnitude;
  logic signed [49:0] rounded_signed_next;
  logic        [15:0] shift_q;

  always_comb begin
    multiplier_signed = $signed({1'b0, multiplier_i});
    product_next      = $signed(accumulator_i) * $signed(multiplier_signed);
    product_ext       = $signed({product_q[48], product_q});

    if (product_ext < 0)
      magnitude = $unsigned(-product_ext);
    else
      magnitude = $unsigned(product_ext);

    rounding_offset   = 50'd0;
    rounded_magnitude = magnitude;

    if (shift_q != 16'd0) begin
      rounding_offset   = 50'd1 << (shift_q - 16'd1);
      rounded_magnitude = (magnitude + rounding_offset) >> shift_q;
    end

    if (product_ext < 0)
      rounded_signed_next = -$signed(rounded_magnitude);
    else
      rounded_signed_next = $signed(rounded_magnitude);
  end

  always_ff @(posedge clk_i) begin
    if (!aresetn_i) begin
      product_q           <= 49'sd0;
      shift_q             <= 16'd0;
      requantized_o       <= 50'sd0;
      product_valid_o     <= 1'b0;
      requantized_valid_o <= 1'b0;
    end else if (clear_i) begin
      product_valid_o     <= 1'b0;
      requantized_valid_o <= 1'b0;
    end else begin
      if (mul_enable_i) begin
        product_q           <= product_next;
        shift_q             <= shift_i;
        product_valid_o     <= 1'b1;
        requantized_valid_o <= 1'b0;
      end

      if (round_enable_i && product_valid_o) begin
        requantized_o       <= rounded_signed_next;
        product_valid_o     <= 1'b0;
        requantized_valid_o <= 1'b1;
      end
    end
  end
endmodule
