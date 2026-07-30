`timescale 1ns/1ps

module controller_fsm #(
  parameter integer MAX_WEIGHT_WORDS = 9216,
  parameter integer MAX_BIAS_WORDS   = 64,
  parameter integer MAX_INPUT_WORDS  = 4096,
  parameter integer MAX_OUTPUT_WORDS = 4096
) (
  input  logic clk_i,
  input  logic aresetn_i,
  input  logic start_pulse_i,
  input  logic abort_pulse_i,

  input  logic [31:0] operation_i,
  input  logic [31:0] input_height_i,
  input  logic [31:0] input_width_i,
  input  logic [31:0] in_channels_i,
  input  logic [31:0] out_channels_i,
  input  logic [31:0] conv_config_i,
  input  logic [31:0] output_scale_i,
  input  logic [31:0] input_bytes_i,
  input  logic [31:0] weight_bytes_i,
  input  logic [31:0] bias_bytes_i,
  input  logic [31:0] skip_bytes_i,
  input  logic [31:0] output_bytes_i,

  input  logic packet_done_i,
  input  logic packet_length_error_i,
  input  logic tlast_error_i,
  input  logic conv_done_i,
  input  logic output_done_i,

  output logic idle_o,
  output logic busy_o,
  output logic [3:0] debug_state_o,
  output logic operation_accept_o,
  output logic operation_done_o,
  output logic cancel_pulse_o,

  output logic packet_active_o,
  output logic packet_start_o,
  output logic [1:0] packet_select_o,
  output logic [31:0] expected_packet_bytes_o,
  output logic conv_start_o,
  output logic output_start_o,

  output logic invalid_operation_event_o,
  output logic invalid_config_event_o,
  output logic internal_error_event_o,

  output logic [31:0] snap_input_height_o,
  output logic [31:0] snap_input_width_o,
  output logic [31:0] snap_in_channels_o,
  output logic [31:0] snap_out_channels_o,
  output logic [31:0] snap_output_height_o,
  output logic [31:0] snap_output_width_o,
  output logic  [7:0] snap_stride_o,
  output logic  [7:0] snap_padding_o,
  output logic        snap_relu_enable_o,
  output logic [15:0] snap_multiplier_o,
  output logic [15:0] snap_shift_o,
  output logic [31:0] snap_weight_bytes_o,
  output logic [31:0] snap_bias_bytes_o,
  output logic [31:0] snap_input_bytes_o,
  output logic [31:0] snap_output_bytes_o
);
  import accel_pkg::*;

  logic [3:0] state_q;
  logic [7:0] kernel_size;
  logic [7:0] stride;
  logic [7:0] padding;
  logic       relu_enable;

  logic [63:0] padded_height;
  logic [63:0] padded_width;
  logic [63:0] output_height_calc;
  logic [63:0] output_width_calc;
  logic [63:0] weight_bytes_calc;
  logic [63:0] bias_bytes_calc;
  logic [63:0] input_bytes_calc;
  logic [63:0] output_bytes_calc;
  logic        dimensions_valid;
  logic        configuration_valid;

  always_comb begin
    kernel_size = conv_config_i[7:0];
    stride      = conv_config_i[15:8];
    padding     = conv_config_i[23:16];
    relu_enable = conv_config_i[24];

    padded_height = {32'd0, input_height_i} + ({56'd0, padding} << 1);
    padded_width  = {32'd0, input_width_i}  + ({56'd0, padding} << 1);

    dimensions_valid = (input_height_i != 32'd0)
                    && (input_width_i != 32'd0)
                    && (in_channels_i != 32'd0)
                    && (out_channels_i != 32'd0)
                    && (padded_height >= 64'd3)
                    && (padded_width >= 64'd3);

    if (stride == 8'd2) begin
      output_height_calc = ((padded_height - 64'd3) >> 1) + 64'd1;
      output_width_calc  = ((padded_width  - 64'd3) >> 1) + 64'd1;
    end else begin
      output_height_calc = (padded_height - 64'd3) + 64'd1;
      output_width_calc  = (padded_width  - 64'd3) + 64'd1;
    end

    weight_bytes_calc = 64'd9 * in_channels_i * out_channels_i;
    bias_bytes_calc   = 64'd4 * out_channels_i;
    input_bytes_calc  = {32'd0, input_height_i}
                      * {32'd0, input_width_i}
                      * {32'd0, in_channels_i};
    output_bytes_calc = output_height_calc * output_width_calc * out_channels_i;

    configuration_valid = dimensions_valid
                       && (kernel_size == 8'd3)
                       && ((stride == 8'd1) || (stride == 8'd2))
                       && ((padding == 8'd0) || (padding == 8'd1))
                       && (conv_config_i[31:25] == 7'd0)
                       && (output_scale_i[31:16] <= 16'd31)
                       && (skip_bytes_i == 32'd0)
                       && (weight_bytes_calc == {32'd0, weight_bytes_i})
                       && (bias_bytes_calc == {32'd0, bias_bytes_i})
                       && (input_bytes_calc == {32'd0, input_bytes_i})
                       && (output_bytes_calc == {32'd0, output_bytes_i})
                       && (weight_bytes_calc <= (MAX_WEIGHT_WORDS * 64'd4))
                       && (bias_bytes_calc <= (MAX_BIAS_WORDS * 64'd4))
                       && (input_bytes_calc <= (MAX_INPUT_WORDS * 64'd4))
                       && (output_bytes_calc <= (MAX_OUTPUT_WORDS * 64'd4))
                       && (weight_bytes_calc[1:0] == 2'b00)
                       && (bias_bytes_calc[1:0] == 2'b00)
                       && (input_bytes_calc[1:0] == 2'b00)
                       && (output_bytes_calc[1:0] == 2'b00);

    idle_o        = (state_q == DBG_IDLE) || (state_q == DBG_COMPLETE);
    busy_o        = (state_q != DBG_IDLE) && (state_q != DBG_COMPLETE);
    debug_state_o = state_q;

    packet_active_o = (state_q == DBG_LOAD_WEIGHT)
                   || (state_q == DBG_LOAD_BIAS)
                   || (state_q == DBG_LOAD_INPUT);

    case (state_q)
      DBG_LOAD_WEIGHT: begin
        packet_select_o         = 2'd0;
        expected_packet_bytes_o = snap_weight_bytes_o;
      end
      DBG_LOAD_BIAS: begin
        packet_select_o         = 2'd1;
        expected_packet_bytes_o = snap_bias_bytes_o;
      end
      default: begin
        packet_select_o         = 2'd2;
        expected_packet_bytes_o = snap_input_bytes_o;
      end
    endcase
  end

  always_ff @(posedge clk_i) begin
    if (!aresetn_i) begin
      state_q                    <= DBG_RESET;
      operation_accept_o         <= 1'b0;
      operation_done_o           <= 1'b0;
      cancel_pulse_o             <= 1'b0;
      packet_start_o             <= 1'b0;
      conv_start_o               <= 1'b0;
      output_start_o             <= 1'b0;
      invalid_operation_event_o  <= 1'b0;
      invalid_config_event_o     <= 1'b0;
      internal_error_event_o     <= 1'b0;
      snap_input_height_o        <= 32'd0;
      snap_input_width_o         <= 32'd0;
      snap_in_channels_o         <= 32'd0;
      snap_out_channels_o        <= 32'd0;
      snap_output_height_o       <= 32'd0;
      snap_output_width_o        <= 32'd0;
      snap_stride_o              <= 8'd0;
      snap_padding_o             <= 8'd0;
      snap_relu_enable_o         <= 1'b0;
      snap_multiplier_o          <= 16'd0;
      snap_shift_o               <= 16'd0;
      snap_weight_bytes_o        <= 32'd0;
      snap_bias_bytes_o          <= 32'd0;
      snap_input_bytes_o         <= 32'd0;
      snap_output_bytes_o        <= 32'd0;
    end else begin
      operation_accept_o        <= 1'b0;
      operation_done_o          <= 1'b0;
      cancel_pulse_o            <= 1'b0;
      packet_start_o            <= 1'b0;
      conv_start_o              <= 1'b0;
      output_start_o            <= 1'b0;
      invalid_operation_event_o <= 1'b0;
      invalid_config_event_o    <= 1'b0;
      internal_error_event_o    <= 1'b0;

      if (state_q == DBG_RESET) begin
        state_q <= DBG_IDLE;
      end else if (abort_pulse_i && busy_o) begin
        state_q        <= DBG_IDLE;
        cancel_pulse_o <= 1'b1;
      end else if (packet_length_error_i || tlast_error_i) begin
        state_q        <= DBG_IDLE;
        cancel_pulse_o <= 1'b1;
      end else begin
        case (state_q)
          DBG_IDLE,
          DBG_COMPLETE: begin
            if (start_pulse_i) begin
              if (operation_i != OP_CONV) begin
                invalid_operation_event_o <= 1'b1;
              end else if (!configuration_valid) begin
                invalid_config_event_o <= 1'b1;
              end else begin
                snap_input_height_o  <= input_height_i;
                snap_input_width_o   <= input_width_i;
                snap_in_channels_o   <= in_channels_i;
                snap_out_channels_o  <= out_channels_i;
                snap_output_height_o <= output_height_calc[31:0];
                snap_output_width_o  <= output_width_calc[31:0];
                snap_stride_o        <= stride;
                snap_padding_o       <= padding;
                snap_relu_enable_o   <= relu_enable;
                snap_multiplier_o    <= output_scale_i[15:0];
                snap_shift_o         <= output_scale_i[31:16];
                snap_weight_bytes_o  <= weight_bytes_i;
                snap_bias_bytes_o    <= bias_bytes_i;
                snap_input_bytes_o   <= input_bytes_i;
                snap_output_bytes_o  <= output_bytes_i;
                operation_accept_o   <= 1'b1;
                packet_start_o       <= 1'b1;
                state_q              <= DBG_LOAD_WEIGHT;
              end
            end else if (state_q == DBG_COMPLETE)
              state_q <= DBG_IDLE;
          end

          DBG_LOAD_WEIGHT: begin
            if (packet_done_i) begin
              packet_start_o <= 1'b1;
              state_q        <= DBG_LOAD_BIAS;
            end
          end

          DBG_LOAD_BIAS: begin
            if (packet_done_i) begin
              packet_start_o <= 1'b1;
              state_q        <= DBG_LOAD_INPUT;
            end
          end

          DBG_LOAD_INPUT: begin
            if (packet_done_i) begin
              conv_start_o <= 1'b1;
              state_q      <= DBG_COMPUTE;
            end
          end

          DBG_COMPUTE: begin
            if (conv_done_i) begin
              output_start_o <= 1'b1;
              state_q        <= DBG_SEND_OUTPUT;
            end
          end

          DBG_SEND_OUTPUT: begin
            if (output_done_i) begin
              operation_done_o <= 1'b1;
              state_q          <= DBG_COMPLETE;
            end
          end

          default: begin
            internal_error_event_o <= 1'b1;
            cancel_pulse_o         <= 1'b1;
            state_q                <= DBG_IDLE;
          end
        endcase
      end
    end
  end
endmodule

