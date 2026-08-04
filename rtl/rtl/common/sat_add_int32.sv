`timescale 1ns/1ps

module sat_add_int32 (
  input  logic signed [31:0] a_i,
  input  logic signed [31:0] b_i,
  output logic signed [31:0] sum_o,
  output logic               saturated_o
);
  localparam logic signed [32:0] INT32_MAX_W = 33'sd2147483647;
  localparam logic signed [32:0] INT32_MIN_W = -33'sd2147483648;

  logic signed [32:0] wide_sum;

  always_comb begin
    wide_sum    = $signed({a_i[31], a_i}) + $signed({b_i[31], b_i});
    saturated_o = 1'b0;

    if (wide_sum > INT32_MAX_W) begin
      sum_o       = 32'sh7fff_ffff;
      saturated_o = 1'b1;
    end else if (wide_sum < INT32_MIN_W) begin
      sum_o       = 32'sh8000_0000;
      saturated_o = 1'b1;
    end else begin
      sum_o = wide_sum[31:0];
    end
  end
endmodule

