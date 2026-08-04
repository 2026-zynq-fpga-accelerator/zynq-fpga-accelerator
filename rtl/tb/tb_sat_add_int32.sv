`timescale 1ns/1ps

module tb_sat_add_int32;
  logic signed [31:0] a;
  logic signed [31:0] b;
  logic signed [31:0] sum;
  logic               saturated;
  integer             checks;

  sat_add_int32 dut (
    .a_i(a),
    .b_i(b),
    .sum_o(sum),
    .saturated_o(saturated)
  );

  task automatic check(
    input logic signed [31:0] test_a,
    input logic signed [31:0] test_b,
    input logic signed [31:0] expected_sum,
    input logic               expected_saturated,
    input string              name
  );
    begin
      a = test_a;
      b = test_b;
      #1;
      checks = checks + 1;
      if ((sum !== expected_sum) || (saturated !== expected_saturated))
        $fatal(1, "SAT_ADD FAIL %s: a=%0d b=%0d got=%0d sat=%0b expected=%0d sat=%0b",
               name, test_a, test_b, sum, saturated, expected_sum, expected_saturated);
      $display("TEST sat_add %-28s PASS", name);
    end
  endtask

  initial begin
    checks = 0;
    check(32'sd0,          32'sd0,          32'sd0,          1'b0, "zero");
    check(32'sd123456,     32'sd654321,     32'sd777777,     1'b0, "positive");
    check(-32'sd123456,    -32'sd654321,    -32'sd777777,    1'b0, "negative");
    check(32'sh7fff_ffff,  32'sd1,          32'sh7fff_ffff,  1'b1, "positive saturation");
    check(32'sh8000_0000, -32'sd1,          32'sh8000_0000,  1'b1, "negative saturation");
    check(32'sh7fff_ffff, -32'sd1,          32'sh7fff_fffe,  1'b0, "mixed sign max");
    check(32'sh8000_0000,  32'sd1,          32'sh8000_0001,  1'b0, "mixed sign min");
    check(32'sh7fff_ffff,  32'sd42,         32'sh7fff_ffff,  1'b1, "bias positive saturation");
    check(32'sh8000_0000, -32'sd42,         32'sh8000_0000,  1'b1, "bias negative saturation");
    $display("UNIT PASS: sat_add_int32 (%0d checks)", checks);
    $finish;
  end
endmodule
