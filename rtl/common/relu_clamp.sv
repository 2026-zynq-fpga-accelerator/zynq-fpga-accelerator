`timescale 1ns/1ps

module relu_clamp (
  input  logic signed [49:0] value_i,
  input  logic               relu_enable_i,
  output logic signed  [7:0] value_o
);
  always_comb begin
    if (relu_enable_i && (value_i < 0))
      value_o = 8'sd0;
    else if (value_i > 50'sd127)
      value_o = 8'sd127;
    else if (value_i < -50'sd128)
      value_o = -8'sd128;
    else
      value_o = value_i[7:0];
  end
endmodule

