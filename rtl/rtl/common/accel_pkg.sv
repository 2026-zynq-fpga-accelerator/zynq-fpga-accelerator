`timescale 1ns/1ps

package accel_pkg;
  localparam logic [31:0] INTERFACE_VERSION = 32'h0001_0001;

  localparam logic [31:0] OP_CONV = 32'd0;
  localparam logic [31:0] OP_RESIDUAL_ADD = 32'd2;
  localparam logic [31:0] OP_GLOBAL_AVG_POOL = 32'd3;

  localparam logic [1:0] PACKET_WEIGHT = 2'd0;
  localparam logic [1:0] PACKET_BIAS   = 2'd1;
  localparam logic [1:0] PACKET_INPUT  = 2'd2;
  localparam logic [1:0] PACKET_SKIP   = 2'd3;

  localparam logic [31:0] ERR_NONE              = 32'd0;
  localparam logic [31:0] ERR_START_WHILE_BUSY  = 32'd1;
  localparam logic [31:0] ERR_INVALID_OPERATION = 32'd2;
  localparam logic [31:0] ERR_INVALID_CONFIG    = 32'd3;
  localparam logic [31:0] ERR_PACKET_LENGTH     = 32'd4;
  localparam logic [31:0] ERR_TLAST_POSITION    = 32'd5;
  localparam logic [31:0] ERR_ACC_OVERFLOW      = 32'd6;
  localparam logic [31:0] ERR_ABORTED           = 32'd7;
  localparam logic [31:0] ERR_CONFIG_WRITE_BUSY = 32'd8;
  localparam logic [31:0] ERR_INTERNAL          = 32'd9;
  localparam logic [31:0] ERR_INVALID_ADDRESS   = 32'd10;

  localparam logic [3:0] DBG_RESET       = 4'd0;
  localparam logic [3:0] DBG_IDLE        = 4'd1;
  localparam logic [3:0] DBG_LOAD_WEIGHT = 4'd2;
  localparam logic [3:0] DBG_LOAD_BIAS   = 4'd3;
  localparam logic [3:0] DBG_LOAD_INPUT  = 4'd4;
  localparam logic [3:0] DBG_COMPUTE     = 4'd5;
  localparam logic [3:0] DBG_SEND_OUTPUT = 4'd6;
  localparam logic [3:0] DBG_COMPLETE    = 4'd7;
  localparam logic [3:0] DBG_LOAD_SKIP   = 4'd8;

  localparam logic [6:0] REG_CONTROL      = 7'h00;
  localparam logic [6:0] REG_STATUS       = 7'h04;
  localparam logic [6:0] REG_OPERATION    = 7'h08;
  localparam logic [6:0] REG_INPUT_HEIGHT = 7'h0c;
  localparam logic [6:0] REG_INPUT_WIDTH  = 7'h10;
  localparam logic [6:0] REG_IN_CHANNELS  = 7'h14;
  localparam logic [6:0] REG_OUT_CHANNELS = 7'h18;
  localparam logic [6:0] REG_CONV_CONFIG  = 7'h1c;
  localparam logic [6:0] REG_OUTPUT_SCALE = 7'h20;
  localparam logic [6:0] REG_INPUT_BYTES  = 7'h24;
  localparam logic [6:0] REG_WEIGHT_BYTES = 7'h28;
  localparam logic [6:0] REG_BIAS_BYTES   = 7'h2c;
  localparam logic [6:0] REG_SKIP_BYTES   = 7'h30;
  localparam logic [6:0] REG_OUTPUT_BYTES = 7'h34;
  localparam logic [6:0] REG_CYCLE_COUNT  = 7'h38;
  localparam logic [6:0] REG_ERROR_CODE   = 7'h3c;
  localparam logic [6:0] REG_VERSION      = 7'h40;
  localparam logic [6:0] REG_DEBUG_STATE  = 7'h44;
endpackage

