`timescale 1ns/1ps

module tb_requantizer;
  logic signed [31:0] accumulator;
  logic        [15:0] multiplier;
  logic        [15:0] shift;
  logic signed [49:0] result;
  integer             checks;

  requantizer dut (
    .accumulator_i(accumulator),
    .multiplier_i(multiplier),
    .shift_i(shift),
    .requantized_o(result)
  );

  function automatic logic signed [49:0] reference(
    input logic signed [31:0] acc,
    input logic        [15:0] mult,
    input logic        [15:0] sh
  );
    logic signed [63:0] product;
    logic        [63:0] magnitude;
    logic        [63:0] rounded;
    begin
      product = $signed(acc);
      product = product * $signed({1'b0, mult});
      if (product < 0)
        magnitude = $unsigned(-product);
      else
        magnitude = $unsigned(product);
      if (sh == 0)
        rounded = magnitude;
      else
        rounded = (magnitude + (64'd1 << (sh - 1))) >> sh;
      if (product < 0)
        reference = -$signed(rounded[49:0]);
      else
        reference = $signed(rounded[49:0]);
    end
  endfunction

  task automatic check(
    input logic signed [31:0] test_acc,
    input logic        [15:0] test_mult,
    input logic        [15:0] test_shift,
    input string              name
  );
    logic signed [49:0] expected;
    begin
      accumulator = test_acc;
      multiplier  = test_mult;
      shift       = test_shift;
      expected    = reference(test_acc, test_mult, test_shift);
      #1;
      checks = checks + 1;
      if (result !== expected)
        $fatal(1, "REQUANT FAIL %s: acc=%0d M=%0d N=%0d got=%0d expected=%0d",
               name, test_acc, test_mult, test_shift, result, expected);
      $display("TEST requantizer %-25s PASS", name);
    end
  endtask

  initial begin
    checks = 0;
    check(32'sd37,          16'd1,     16'd0,  "N=0");
    check(32'sd10,          16'd1,     16'd2,  "positive ordinary");
    check(-32'sd10,         16'd1,     16'd2,  "negative ordinary");
    check(32'sd1,           16'd1,     16'd1,  "positive half tie");
    check(-32'sd1,          16'd1,     16'd1,  "negative half tie");
    check(32'sd3,           16'd1,     16'd1,  "positive three halves");
    check(-32'sd3,          16'd1,     16'd1,  "negative three halves");
    check(32'sd7,           16'd5,     16'd2,  "multiplier greater one");
    check(32'sh8000_0000,   16'hffff,  16'd0,  "negative magnitude width");
    check(32'sh8000_0000,   16'hffff,  16'd16, "wide negative rounded");
    $display("UNIT PASS: requantizer (%0d checks)", checks);
    $finish;
  end
endmodule
