`timescale 1ns/1ps

module tb_requantizer;
  logic clk;
  logic aresetn;
  logic clear;
  logic mul_enable;
  logic round_add_enable;
  logic shift_enable;
  logic signed [31:0] accumulator;
  logic        [15:0] multiplier;
  logic        [15:0] shift;
  logic signed [49:0] result;
  logic product_valid;
  logic round_add_valid;
  logic result_valid;
  integer checks;

  requantizer dut (
    .clk_i(clk),
    .aresetn_i(aresetn),
    .clear_i(clear),
    .mul_enable_i(mul_enable),
    .round_add_enable_i(round_add_enable),
    .shift_enable_i(shift_enable),
    .accumulator_i(accumulator),
    .multiplier_i(multiplier),
    .shift_i(shift),
    .requantized_o(result),
    .product_valid_o(product_valid),
    .round_add_valid_o(round_add_valid),
    .requantized_valid_o(result_valid)
  );

  always #5 clk = ~clk;

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

  task automatic check_transaction(
    input logic signed [31:0] test_acc,
    input logic        [15:0] test_mult,
    input logic        [15:0] test_shift,
    input string              name
  );
    logic signed [49:0] expected;
    logic expected_negative;
    begin
      expected = reference(test_acc, test_mult, test_shift);
      expected_negative = (test_acc < 0) && (test_mult != 0);
      @(negedge clk);
      accumulator = test_acc;
      multiplier = test_mult;
      shift = test_shift;
      mul_enable = 1'b1;
      round_add_enable = 1'b0;
      shift_enable = 1'b0;

      @(posedge clk); #1;
      mul_enable = 1'b0;
      if (!product_valid || round_add_valid || result_valid)
        $fatal(1, "REQUANT PIPELINE FAIL %s after MUL: valid=%0b/%0b/%0b",
               name, product_valid, round_add_valid, result_valid);

      // Change live inputs to prove that product and shift metadata were snapped at MUL.
      @(negedge clk);
      accumulator = ~test_acc;
      multiplier = 16'd0;
      shift = (test_shift == 16'd31) ? 16'd0 : 16'd31;
      round_add_enable = 1'b1;
      @(posedge clk); #1;
      round_add_enable = 1'b0;
      if (product_valid || !round_add_valid || result_valid)
        $fatal(1, "REQUANT PIPELINE FAIL %s after ROUND_ADD: valid=%0b/%0b/%0b",
               name, product_valid, round_add_valid, result_valid);
      if ((dut.product_negative_q !== expected_negative)
          || (dut.round_shift_q !== test_shift[4:0]))
        $fatal(1, "REQUANT metadata snapshot FAIL %s sign=%0b/%0b shift=%0d/%0d",
               name, dut.product_negative_q, expected_negative,
               dut.round_shift_q, test_shift[4:0]);

      @(negedge clk);
      shift_enable = 1'b1;
      @(posedge clk); #1;
      shift_enable = 1'b0;
      checks = checks + 1;
      if (product_valid || round_add_valid || !result_valid)
        $fatal(1, "REQUANT PIPELINE FAIL %s after SHIFT_SIGN: valid=%0b/%0b/%0b",
               name, product_valid, round_add_valid, result_valid);
      if (result !== expected)
        $fatal(1, "REQUANT FAIL %s: acc=%0d M=%0d N=%0d got=%0d expected=%0d",
               name, test_acc, test_mult, test_shift, result, expected);
      $display("TEST requantizer %-25s PASS", name);
    end
  endtask

  initial begin
    logic signed [49:0] held_result;
    logic        [49:0] held_rounded;
    logic               held_negative;
    logic         [4:0] held_shift;

    clk = 1'b0;
    aresetn = 1'b0;
    clear = 1'b0;
    mul_enable = 1'b0;
    round_add_enable = 1'b0;
    shift_enable = 1'b0;
    accumulator = 32'sd0;
    multiplier = 16'd0;
    shift = 16'd0;
    checks = 0;

    repeat (3) @(posedge clk);
    if (product_valid || round_add_valid || result_valid || (result !== 50'sd0))
      $fatal(1, "REQUANT reset state invalid");
    @(negedge clk);
    aresetn = 1'b1;

    check_transaction(32'sd123456,       16'd0,     16'd7,  "M=0");
    check_transaction(32'sd37,           16'd1,     16'd0,  "M=1 N=0");
    check_transaction(32'sd1,            16'd1,     16'd1,  "positive half tie");
    check_transaction(-32'sd1,           16'd1,     16'd1,  "negative half tie");
    check_transaction(32'sd3,            16'd1,     16'd1,  "positive three halves");
    check_transaction(-32'sd3,           16'd1,     16'd1,  "negative three halves");
    check_transaction(32'sd7,            16'hffff,  16'd2,  "M=65535");
    check_transaction(32'sh7fff_ffff,    16'hffff,  16'd0,  "INT32_MAX x 65535");
    check_transaction(32'sh8000_0000,    16'hffff,  16'd0,  "INT32_MIN x 65535");
    check_transaction(32'sh7fff_ffff,    16'hffff,  16'd31, "N=31 positive");
    check_transaction(32'sh8000_0000,    16'hffff,  16'd31, "N=31 negative");

    held_result = result;
    held_rounded = dut.rounded_magnitude_q;
    held_negative = dut.product_negative_q;
    held_shift = dut.round_shift_q;
    repeat (2) begin
      @(posedge clk); #1;
      if ((result !== held_result) || !result_valid
          || (dut.rounded_magnitude_q !== held_rounded)
          || (dut.product_negative_q !== held_negative)
          || (dut.round_shift_q !== held_shift))
        $fatal(1, "REQUANT state changed while enables were inactive");
    end
    checks = checks + 1;
    $display("TEST requantizer %-25s PASS", "disabled hold");

    @(negedge clk);
    clear = 1'b1;
    @(posedge clk); #1;
    clear = 1'b0;
    if (product_valid || round_add_valid || result_valid
        || (dut.rounded_magnitude_q != 50'd0)
        || dut.product_negative_q || (dut.round_shift_q != 5'd0))
      $fatal(1, "REQUANT clear did not remove valid/metadata state");
    checks = checks + 1;
    $display("TEST requantizer %-25s PASS", "clear completed result");

    // Clear a pending ROUND_ADD result before SHIFT_SIGN can consume it.
    @(negedge clk);
    accumulator = -32'sd3; multiplier = 16'd1; shift = 16'd1;
    mul_enable = 1'b1;
    @(posedge clk); #1;
    mul_enable = 1'b0;
    @(negedge clk);
    round_add_enable = 1'b1;
    @(posedge clk); #1;
    round_add_enable = 1'b0;
    if (!round_add_valid)
      $fatal(1, "REQUANT pending ROUND_ADD setup failed");
    @(negedge clk);
    clear = 1'b1;
    @(posedge clk); #1;
    clear = 1'b0;
    if (product_valid || round_add_valid || result_valid)
      $fatal(1, "REQUANT clear left pending ROUND_ADD state");
    checks = checks + 1;
    $display("TEST requantizer %-25s PASS", "clear pending round add");

    check_transaction(32'sd5,  16'd3, 16'd1, "consecutive transaction A");
    check_transaction(-32'sd5, 16'd3, 16'd1, "consecutive transaction B");

    @(negedge clk);
    aresetn = 1'b0;
    @(posedge clk); #1;
    if (product_valid || round_add_valid || result_valid || (result !== 50'sd0))
      $fatal(1, "REQUANT reset after traffic failed");
    checks = checks + 1;
    $display("TEST requantizer %-25s PASS", "reset after traffic");

    $display("UNIT PASS: requantizer (%0d checks)", checks);
    $finish;
  end
endmodule