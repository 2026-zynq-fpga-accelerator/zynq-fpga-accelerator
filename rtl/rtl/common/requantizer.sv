`timescale 1ns/1ps

module requantizer (
  input  logic               clk_i,
  input  logic               aresetn_i,
  input  logic               clear_i,
  input  logic               mul_enable_i,
  input  logic               round_add_enable_i,
  input  logic               shift_enable_i,
  input  logic signed [31:0] accumulator_i,
  input  logic        [15:0] multiplier_i,
  input  logic        [15:0] shift_i,
  output logic signed [49:0] requantized_o,
  output logic               product_valid_o,
  output logic               round_add_valid_o,
  output logic               requantized_valid_o
);
  logic signed [16:0] multiplier_signed;
  logic signed [48:0] product_next;
  logic signed [48:0] product_q;
  logic signed [49:0] product_ext;
  logic        [49:0] magnitude;
  logic        [49:0] rounding_offset;
  logic        [49:0] rounded_magnitude_next;
  logic        [49:0] rounded_magnitude_q;
  logic signed [49:0] shifted_signed_next;
  logic         [4:0] shift_q;
  logic         [4:0] round_shift_q;
  logic               product_negative_q;

  always_comb begin
    multiplier_signed = $signed({1'b0, multiplier_i});
    product_next      = $signed(accumulator_i) * $signed(multiplier_signed);
    product_ext       = $signed({product_q[48], product_q});

    if (product_ext < 0)
      magnitude = $unsigned(-product_ext);
    else
      magnitude = $unsigned(product_ext);

    rounding_offset        = 50'd0;
    rounded_magnitude_next = magnitude;
    if (shift_q != 5'd0) begin
      rounding_offset        = 50'd1 << (shift_q - 5'd1);
      rounded_magnitude_next = magnitude + rounding_offset;
    end

    if (round_shift_q == 5'd0)
      shifted_signed_next = $signed(rounded_magnitude_q);
    else
      shifted_signed_next = $signed(rounded_magnitude_q >> round_shift_q);

    if (product_negative_q)
      shifted_signed_next = -shifted_signed_next;
  end

  always_ff @(posedge clk_i) begin
    if (!aresetn_i) begin
      product_q           <= 49'sd0;
      shift_q             <= 5'd0;
      rounded_magnitude_q <= 50'd0;
      product_negative_q  <= 1'b0;
      round_shift_q       <= 5'd0;
      requantized_o       <= 50'sd0;
      product_valid_o     <= 1'b0;
      round_add_valid_o   <= 1'b0;
      requantized_valid_o <= 1'b0;
    end else if (clear_i) begin
      product_q           <= 49'sd0;
      shift_q             <= 5'd0;
      rounded_magnitude_q <= 50'd0;
      product_negative_q  <= 1'b0;
      round_shift_q       <= 5'd0;
      product_valid_o     <= 1'b0;
      round_add_valid_o   <= 1'b0;
      requantized_valid_o <= 1'b0;
    end else begin
      if (mul_enable_i) begin
        product_q           <= product_next;
        // The controller rejects shift values above 31 before operation start.
        shift_q             <= shift_i[4:0];
        product_valid_o     <= 1'b1;
        round_add_valid_o   <= 1'b0;
        requantized_valid_o <= 1'b0;
      end

      if (round_add_enable_i && product_valid_o) begin
        rounded_magnitude_q <= rounded_magnitude_next;
        product_negative_q  <= (product_ext < 0);
        round_shift_q       <= shift_q;
        product_valid_o     <= 1'b0;
        round_add_valid_o   <= 1'b1;
        requantized_valid_o <= 1'b0;
      end

      if (shift_enable_i && round_add_valid_o) begin
        requantized_o       <= shifted_signed_next;
        round_add_valid_o   <= 1'b0;
        requantized_valid_o <= 1'b1;
      end
    end
  end
endmodule
