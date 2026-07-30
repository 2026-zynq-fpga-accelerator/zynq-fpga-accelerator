`timescale 1ns/1ps

module error_ctrl (
  input  logic clk_i,
  input  logic aresetn_i,
  input  logic done_clear_i,
  input  logic error_clear_i,
  input  logic operation_done_i,

  input  logic start_while_busy_i,
  input  logic config_write_busy_i,
  input  logic invalid_address_i,
  input  logic accumulator_overflow_i,
  input  logic invalid_operation_i,
  input  logic invalid_config_i,
  input  logic packet_length_i,
  input  logic tlast_position_i,
  input  logic aborted_i,
  input  logic internal_error_i,

  output logic done_o,
  output logic error_o,
  output logic [31:0] error_code_o
);
  import accel_pkg::*;

  logic        selected_valid;
  logic        selected_fatal;
  logic [31:0] selected_code;

  function automatic logic code_is_fatal(input logic [31:0] code);
    begin
      case (code)
        ERR_INVALID_OPERATION,
        ERR_INVALID_CONFIG,
        ERR_PACKET_LENGTH,
        ERR_TLAST_POSITION,
        ERR_ABORTED,
        ERR_INTERNAL: code_is_fatal = 1'b1;
        default:      code_is_fatal = 1'b0;
      endcase
    end
  endfunction

  always_comb begin
    selected_valid = 1'b0;
    selected_fatal = 1'b0;
    selected_code  = ERR_NONE;

    if (internal_error_i) begin
      selected_valid = 1'b1;
      selected_fatal = 1'b1;
      selected_code  = ERR_INTERNAL;
    end else if (aborted_i) begin
      selected_valid = 1'b1;
      selected_fatal = 1'b1;
      selected_code  = ERR_ABORTED;
    end else if (tlast_position_i) begin
      selected_valid = 1'b1;
      selected_fatal = 1'b1;
      selected_code  = ERR_TLAST_POSITION;
    end else if (packet_length_i) begin
      selected_valid = 1'b1;
      selected_fatal = 1'b1;
      selected_code  = ERR_PACKET_LENGTH;
    end else if (invalid_config_i) begin
      selected_valid = 1'b1;
      selected_fatal = 1'b1;
      selected_code  = ERR_INVALID_CONFIG;
    end else if (invalid_operation_i) begin
      selected_valid = 1'b1;
      selected_fatal = 1'b1;
      selected_code  = ERR_INVALID_OPERATION;
    end else if (accumulator_overflow_i) begin
      selected_valid = 1'b1;
      selected_code  = ERR_ACC_OVERFLOW;
    end else if (start_while_busy_i) begin
      selected_valid = 1'b1;
      selected_code  = ERR_START_WHILE_BUSY;
    end else if (config_write_busy_i) begin
      selected_valid = 1'b1;
      selected_code  = ERR_CONFIG_WRITE_BUSY;
    end else if (invalid_address_i) begin
      selected_valid = 1'b1;
      selected_code  = ERR_INVALID_ADDRESS;
    end
  end

  always_ff @(posedge clk_i) begin
    if (!aresetn_i) begin
      done_o       <= 1'b0;
      error_o      <= 1'b0;
      error_code_o <= ERR_NONE;
    end else begin
      if (done_clear_i)
        done_o <= 1'b0;
      if (operation_done_i)
        done_o <= 1'b1;

      if (error_clear_i) begin
        error_o      <= 1'b0;
        error_code_o <= ERR_NONE;
      end

      if (selected_valid) begin
        error_o <= 1'b1;
        if (!error_o || error_clear_i)
          error_code_o <= selected_code;
        else if (selected_fatal && !code_is_fatal(error_code_o))
          error_code_o <= selected_code;
      end
    end
  end
endmodule

