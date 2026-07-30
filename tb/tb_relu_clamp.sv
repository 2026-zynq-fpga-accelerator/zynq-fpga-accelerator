`timescale 1ns/1ps

module tb_relu_clamp;
  logic signed [49:0] value;
  logic               relu_enable;
  logic signed  [7:0] result;
  integer             checks;

  relu_clamp dut (
    .value_i(value),
    .relu_enable_i(relu_enable),
    .value_o(result)
  );

  task automatic check(
    input logic signed [49:0] test_value,
    input logic               test_relu,
    input logic signed  [7:0] expected,
    input string              name
  );
    begin
      value       = test_value;
      relu_enable = test_relu;
      #1;
      checks = checks + 1;
      if (result !== expected)
        $fatal(1, "RELU_CLAMP FAIL %s: value=%0d relu=%0b got=%0d expected=%0d",
               name, test_value, test_relu, result, expected);
      $display("TEST relu_clamp %-24s PASS", name);
    end
  endtask

  initial begin
    checks = 0;
    check(-50'sd17, 1'b0, -8'sd17,  "negative ReLU disabled");
    check(-50'sd17, 1'b1,  8'sd0,   "negative ReLU enabled");
    check( 50'sd127,1'b0,  8'sd127, "positive boundary");
    check( 50'sd128,1'b0,  8'sd127, "positive clamp");
    check(-50'sd128,1'b0, -8'sd128, "negative boundary");
    check(-50'sd129,1'b0, -8'sd128, "negative clamp");
    check( 50'sd999,1'b1,  8'sd127, "ReLU positive clamp");
    $display("UNIT PASS: relu_clamp (%0d checks)", checks);
    $finish;
  end
endmodule
