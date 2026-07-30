`timescale 1ns/1ps

module cycle_counter (
  input  logic clk_i,
  input  logic aresetn_i,
  input  logic operation_accept_i,
  input  logic busy_i,
  output logic [31:0] cycle_count_o
);
  always_ff @(posedge clk_i) begin
    if (!aresetn_i)
      cycle_count_o <= 32'd0;
    else if (operation_accept_i)
      cycle_count_o <= 32'd0;
    else if (busy_i)
      cycle_count_o <= cycle_count_o + 32'd1;
  end
endmodule

