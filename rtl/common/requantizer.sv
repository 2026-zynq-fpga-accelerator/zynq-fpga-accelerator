`timescale 1ns/1ps

module requantizer (
  input  logic signed [31:0] accumulator_i,
  input  logic        [15:0] multiplier_i,
  input  logic        [15:0] shift_i,
  output logic signed [49:0] requantized_o
);
  logic signed [16:0] multiplier_signed;
  logic signed [48:0] product;
  logic signed [49:0] product_ext;
  logic        [49:0] magnitude;
  logic        [49:0] rounding_offset;
  logic        [49:0] rounded_magnitude;

  always_comb begin
    multiplier_signed = $signed({1'b0, multiplier_i});
    product           = $signed(accumulator_i) * $signed(multiplier_signed);
    product_ext       = $signed({product[48], product});

    if (product_ext < 0)
      magnitude = $unsigned(-product_ext);
    else
      magnitude = $unsigned(product_ext);

    rounding_offset  = 50'd0;
    rounded_magnitude = magnitude;

    if (shift_i != 16'd0) begin
      rounding_offset   = 50'd1 << (shift_i - 16'd1);
      rounded_magnitude = (magnitude + rounding_offset) >> shift_i;
    end

    if (product_ext < 0)
      requantized_o = -$signed(rounded_magnitude);
    else
      requantized_o = $signed(rounded_magnitude);
  end
endmodule

