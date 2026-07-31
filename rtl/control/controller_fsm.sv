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
  output logic admission_active_o,
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

  localparam logic [31:0] WEIGHT_CAP_BYTES = MAX_WEIGHT_WORDS * 4;
  localparam logic [31:0] BIAS_CAP_BYTES   = MAX_BIAS_WORDS * 4;
  localparam logic [31:0] INPUT_CAP_BYTES  = MAX_INPUT_WORDS * 4;
  localparam logic [31:0] OUTPUT_CAP_BYTES = MAX_OUTPUT_WORDS * 4;
  localparam logic [31:0] WEIGHT_CHANNEL_LIMIT = WEIGHT_CAP_BYTES / 9;

  typedef enum logic [3:0] {
    VAL_IDLE,
    VAL_FIELDS,
    VAL_DIMS,
    VAL_INPUT_AREA,
    VAL_INPUT_CHANNELS,
    VAL_WEIGHT_CHANNELS,
    VAL_OUTPUT_AREA,
    VAL_OUTPUT_CHANNELS,
    VAL_COMPARE,
    VAL_ACCEPT,
    VAL_REJECT
  } validator_state_t;

  logic [3:0] state_q;
  validator_state_t validator_state_q;

  logic [31:0] pending_operation_q;
  logic [31:0] pending_input_height_q;
  logic [31:0] pending_input_width_q;
  logic [31:0] pending_in_channels_q;
  logic [31:0] pending_out_channels_q;
  logic [31:0] pending_conv_config_q;
  logic [31:0] pending_output_scale_q;
  logic [31:0] pending_input_bytes_q;
  logic [31:0] pending_weight_bytes_q;
  logic [31:0] pending_bias_bytes_q;
  logic [31:0] pending_skip_bytes_q;
  logic [31:0] pending_output_bytes_q;

  logic [14:0] validated_input_height_q;
  logic [14:0] validated_input_width_q;
  logic [12:0] validated_in_channels_q;
  logic  [6:0] validated_out_channels_q;
  logic [14:0] validated_output_height_q;
  logic [14:0] validated_output_width_q;
  logic [14:0] calculated_input_bytes_q;
  logic [15:0] calculated_weight_bytes_q;
  logic  [8:0] calculated_bias_bytes_q;
  logic [14:0] calculated_output_bytes_q;

  logic reject_operation_q;
  logic mul_running_q;
  logic mul_over_limit_q;
  logic [31:0] mul_accumulator_q;
  logic [31:0] mul_multiplicand_q;
  logic [31:0] mul_multiplier_q;
  logic [31:0] mul_limit_q;
  logic [31:0] mul_accumulator_next;
  logic [31:0] mul_multiplicand_next;
  logic        mul_over_limit_next;

  logic [15:0] padded_height_calc;
  logic [15:0] padded_width_calc;
  logic [15:0] output_height_calc_wide;
  logic [15:0] output_width_calc_wide;
  logic [14:0] output_height_calc;
  logic [14:0] output_width_calc;

  always_comb begin
    padded_height_calc = {1'b0, pending_input_height_q[14:0]}
                       + (pending_conv_config_q[16] ? 16'd2 : 16'd0);
    padded_width_calc  = {1'b0, pending_input_width_q[14:0]}
                       + (pending_conv_config_q[16] ? 16'd2 : 16'd0);

    if (pending_conv_config_q[15:8] == 8'd2) begin
      output_height_calc_wide = ((padded_height_calc - 16'd3) >> 1) + 16'd1;
      output_width_calc_wide  = ((padded_width_calc  - 16'd3) >> 1) + 16'd1;
    end else begin
      output_height_calc_wide = padded_height_calc - 16'd2;
      output_width_calc_wide  = padded_width_calc  - 16'd2;
    end
    output_height_calc = output_height_calc_wide[14:0];
    output_width_calc  = output_width_calc_wide[14:0];

    mul_accumulator_next = mul_accumulator_q;
    mul_over_limit_next  = mul_over_limit_q;
    if (mul_multiplier_q[0] && !mul_over_limit_q) begin
      if ((mul_multiplicand_q > mul_limit_q)
          || (mul_accumulator_q > (mul_limit_q - mul_multiplicand_q))) begin
        mul_over_limit_next = 1'b1;
      end else begin
        mul_accumulator_next = mul_accumulator_q + mul_multiplicand_q;
      end
    end

    if (mul_multiplicand_q > (mul_limit_q >> 1))
      mul_multiplicand_next = mul_limit_q + 32'd1;
    else
      mul_multiplicand_next = mul_multiplicand_q << 1;

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
      validator_state_q          <= VAL_IDLE;
      admission_active_o         <= 1'b0;
      operation_accept_o         <= 1'b0;
      operation_done_o           <= 1'b0;
      cancel_pulse_o             <= 1'b0;
      packet_start_o             <= 1'b0;
      conv_start_o               <= 1'b0;
      output_start_o             <= 1'b0;
      invalid_operation_event_o  <= 1'b0;
      invalid_config_event_o     <= 1'b0;
      internal_error_event_o     <= 1'b0;
      pending_operation_q        <= 32'd0;
      pending_input_height_q     <= 32'd0;
      pending_input_width_q      <= 32'd0;
      pending_in_channels_q      <= 32'd0;
      pending_out_channels_q     <= 32'd0;
      pending_conv_config_q      <= 32'd0;
      pending_output_scale_q     <= 32'd0;
      pending_input_bytes_q      <= 32'd0;
      pending_weight_bytes_q     <= 32'd0;
      pending_bias_bytes_q       <= 32'd0;
      pending_skip_bytes_q       <= 32'd0;
      pending_output_bytes_q     <= 32'd0;
      validated_input_height_q   <= 15'd0;
      validated_input_width_q    <= 15'd0;
      validated_in_channels_q    <= 13'd0;
      validated_out_channels_q   <= 7'd0;
      validated_output_height_q  <= 15'd0;
      validated_output_width_q   <= 15'd0;
      calculated_input_bytes_q   <= 15'd0;
      calculated_weight_bytes_q  <= 16'd0;
      calculated_bias_bytes_q    <= 9'd0;
      calculated_output_bytes_q  <= 15'd0;
      reject_operation_q         <= 1'b0;
      mul_running_q              <= 1'b0;
      mul_over_limit_q           <= 1'b0;
      mul_accumulator_q          <= 32'd0;
      mul_multiplicand_q         <= 32'd0;
      mul_multiplier_q           <= 32'd0;
      mul_limit_q                <= 32'd0;
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
      end else if (abort_pulse_i && (busy_o || admission_active_o)) begin
        state_q            <= DBG_IDLE;
        validator_state_q  <= VAL_IDLE;
        admission_active_o <= 1'b0;
        mul_running_q      <= 1'b0;
        cancel_pulse_o     <= 1'b1;
      end else if (packet_length_error_i || tlast_error_i) begin
        state_q            <= DBG_IDLE;
        validator_state_q  <= VAL_IDLE;
        admission_active_o <= 1'b0;
        mul_running_q      <= 1'b0;
        cancel_pulse_o     <= 1'b1;
      end else if (admission_active_o) begin
        case (validator_state_q)
          VAL_FIELDS: begin
            reject_operation_q <= 1'b0;
            if (pending_operation_q != OP_CONV) begin
              reject_operation_q <= 1'b1;
              validator_state_q  <= VAL_REJECT;
            end else if ((pending_input_height_q == 32'd0)
                      || (pending_input_width_q == 32'd0)
                      || (pending_in_channels_q == 32'd0)
                      || (pending_out_channels_q == 32'd0)
                      || (pending_input_height_q > 32'd16384)
                      || (pending_input_width_q > 32'd16384)
                      || (pending_in_channels_q > 32'd4096)
                      || (pending_out_channels_q > 32'd64)
                      || (pending_input_height_q > INPUT_CAP_BYTES)
                      || (pending_input_width_q > INPUT_CAP_BYTES)
                      || (pending_in_channels_q > WEIGHT_CHANNEL_LIMIT)
                      || (pending_out_channels_q > MAX_BIAS_WORDS)
                      || (pending_conv_config_q[7:0] != 8'd3)
                      || ((pending_conv_config_q[15:8] != 8'd1)
                       && (pending_conv_config_q[15:8] != 8'd2))
                      || ((pending_conv_config_q[23:16] != 8'd0)
                       && (pending_conv_config_q[23:16] != 8'd1))
                      || (pending_conv_config_q[31:25] != 7'd0)
                      || (pending_output_scale_q[31:16] > 16'd31)
                      || (pending_skip_bytes_q != 32'd0)) begin
              validator_state_q <= VAL_REJECT;
            end else begin
              validated_input_height_q <= pending_input_height_q[14:0];
              validated_input_width_q  <= pending_input_width_q[14:0];
              validated_in_channels_q  <= pending_in_channels_q[12:0];
              validated_out_channels_q <= pending_out_channels_q[6:0];
              validator_state_q        <= VAL_DIMS;
            end
          end

          VAL_DIMS: begin
            if ((padded_height_calc < 16'd3) || (padded_width_calc < 16'd3)
             || output_height_calc_wide[15] || output_width_calc_wide[15]) begin
              validator_state_q <= VAL_REJECT;
            end else begin
              validated_output_height_q <= output_height_calc;
              validated_output_width_q  <= output_width_calc;
              mul_running_q             <= 1'b0;
              validator_state_q         <= VAL_INPUT_AREA;
            end
          end

          VAL_INPUT_AREA: begin
            if (!mul_running_q) begin
              mul_accumulator_q  <= 32'd0;
              mul_multiplicand_q <= {17'd0, validated_input_height_q};
              mul_multiplier_q   <= {17'd0, validated_input_width_q};
              mul_limit_q        <= INPUT_CAP_BYTES;
              mul_over_limit_q   <= 1'b0;
              mul_running_q      <= 1'b1;
            end else if (mul_multiplier_q <= 32'd1) begin
              mul_running_q <= 1'b0;
              if (mul_over_limit_next)
                validator_state_q <= VAL_REJECT;
              else begin
                mul_accumulator_q <= mul_accumulator_next;
                validator_state_q <= VAL_INPUT_CHANNELS;
              end
            end else begin
              mul_accumulator_q  <= mul_accumulator_next;
              mul_multiplicand_q <= mul_multiplicand_next;
              mul_multiplier_q   <= mul_multiplier_q >> 1;
              mul_over_limit_q   <= mul_over_limit_next;
            end
          end

          VAL_INPUT_CHANNELS: begin
            if (!mul_running_q) begin
              mul_multiplicand_q <= mul_accumulator_q;
              mul_multiplier_q   <= {19'd0, validated_in_channels_q};
              mul_accumulator_q  <= 32'd0;
              mul_limit_q        <= INPUT_CAP_BYTES;
              mul_over_limit_q   <= 1'b0;
              mul_running_q      <= 1'b1;
            end else if (mul_multiplier_q <= 32'd1) begin
              mul_running_q <= 1'b0;
              if (mul_over_limit_next)
                validator_state_q <= VAL_REJECT;
              else begin
                calculated_input_bytes_q <= mul_accumulator_next[14:0];
                validator_state_q        <= VAL_WEIGHT_CHANNELS;
              end
            end else begin
              mul_accumulator_q  <= mul_accumulator_next;
              mul_multiplicand_q <= mul_multiplicand_next;
              mul_multiplier_q   <= mul_multiplier_q >> 1;
              mul_over_limit_q   <= mul_over_limit_next;
            end
          end

          VAL_WEIGHT_CHANNELS: begin
            if (!mul_running_q) begin
              mul_accumulator_q  <= 32'd0;
              mul_multiplicand_q <= {19'd0, validated_in_channels_q};
              mul_multiplier_q   <= {25'd0, validated_out_channels_q};
              mul_limit_q        <= WEIGHT_CHANNEL_LIMIT;
              mul_over_limit_q   <= 1'b0;
              mul_running_q      <= 1'b1;
            end else if (mul_multiplier_q <= 32'd1) begin
              mul_running_q <= 1'b0;
              if (mul_over_limit_next)
                validator_state_q <= VAL_REJECT;
              else begin
                calculated_weight_bytes_q <= mul_accumulator_next[15:0]
                                           + (mul_accumulator_next[15:0] << 3);
                calculated_bias_bytes_q   <= {validated_out_channels_q, 2'b00};
                validator_state_q         <= VAL_OUTPUT_AREA;
              end
            end else begin
              mul_accumulator_q  <= mul_accumulator_next;
              mul_multiplicand_q <= mul_multiplicand_next;
              mul_multiplier_q   <= mul_multiplier_q >> 1;
              mul_over_limit_q   <= mul_over_limit_next;
            end
          end

          VAL_OUTPUT_AREA: begin
            if (!mul_running_q) begin
              mul_accumulator_q  <= 32'd0;
              mul_multiplicand_q <= {17'd0, validated_output_height_q};
              mul_multiplier_q   <= {17'd0, validated_output_width_q};
              mul_limit_q        <= OUTPUT_CAP_BYTES;
              mul_over_limit_q   <= 1'b0;
              mul_running_q      <= 1'b1;
            end else if (mul_multiplier_q <= 32'd1) begin
              mul_running_q <= 1'b0;
              if (mul_over_limit_next)
                validator_state_q <= VAL_REJECT;
              else begin
                mul_accumulator_q <= mul_accumulator_next;
                validator_state_q <= VAL_OUTPUT_CHANNELS;
              end
            end else begin
              mul_accumulator_q  <= mul_accumulator_next;
              mul_multiplicand_q <= mul_multiplicand_next;
              mul_multiplier_q   <= mul_multiplier_q >> 1;
              mul_over_limit_q   <= mul_over_limit_next;
            end
          end

          VAL_OUTPUT_CHANNELS: begin
            if (!mul_running_q) begin
              mul_multiplicand_q <= mul_accumulator_q;
              mul_multiplier_q   <= {25'd0, validated_out_channels_q};
              mul_accumulator_q  <= 32'd0;
              mul_limit_q        <= OUTPUT_CAP_BYTES;
              mul_over_limit_q   <= 1'b0;
              mul_running_q      <= 1'b1;
            end else if (mul_multiplier_q <= 32'd1) begin
              mul_running_q <= 1'b0;
              if (mul_over_limit_next)
                validator_state_q <= VAL_REJECT;
              else begin
                calculated_output_bytes_q <= mul_accumulator_next[14:0];
                validator_state_q         <= VAL_COMPARE;
              end
            end else begin
              mul_accumulator_q  <= mul_accumulator_next;
              mul_multiplicand_q <= mul_multiplicand_next;
              mul_multiplier_q   <= mul_multiplier_q >> 1;
              mul_over_limit_q   <= mul_over_limit_next;
            end
          end

          VAL_COMPARE: begin
            if ((pending_weight_bytes_q != {16'd0, calculated_weight_bytes_q})
             || (pending_bias_bytes_q != {23'd0, calculated_bias_bytes_q})
             || (pending_input_bytes_q != {17'd0, calculated_input_bytes_q})
             || (pending_output_bytes_q != {17'd0, calculated_output_bytes_q})
             || ({16'd0, calculated_weight_bytes_q} > WEIGHT_CAP_BYTES)
             || ({23'd0, calculated_bias_bytes_q} > BIAS_CAP_BYTES)
             || ({17'd0, calculated_input_bytes_q} > INPUT_CAP_BYTES)
             || ({17'd0, calculated_output_bytes_q} > OUTPUT_CAP_BYTES)
             || (calculated_weight_bytes_q[1:0] != 2'b00)
             || (calculated_bias_bytes_q[1:0] != 2'b00)
             || (calculated_input_bytes_q[1:0] != 2'b00)
             || (calculated_output_bytes_q[1:0] != 2'b00))
              validator_state_q <= VAL_REJECT;
            else
              validator_state_q <= VAL_ACCEPT;
          end

          VAL_ACCEPT: begin
            snap_input_height_o  <= {17'd0, validated_input_height_q};
            snap_input_width_o   <= {17'd0, validated_input_width_q};
            snap_in_channels_o   <= {19'd0, validated_in_channels_q};
            snap_out_channels_o  <= {25'd0, validated_out_channels_q};
            snap_output_height_o <= {17'd0, validated_output_height_q};
            snap_output_width_o  <= {17'd0, validated_output_width_q};
            snap_stride_o        <= pending_conv_config_q[15:8];
            snap_padding_o       <= pending_conv_config_q[23:16];
            snap_relu_enable_o   <= pending_conv_config_q[24];
            snap_multiplier_o    <= pending_output_scale_q[15:0];
            snap_shift_o         <= pending_output_scale_q[31:16];
            snap_weight_bytes_o  <= pending_weight_bytes_q;
            snap_bias_bytes_o    <= pending_bias_bytes_q;
            snap_input_bytes_o   <= pending_input_bytes_q;
            snap_output_bytes_o  <= pending_output_bytes_q;
            operation_accept_o   <= 1'b1;
            packet_start_o       <= 1'b1;
            state_q              <= DBG_LOAD_WEIGHT;
            validator_state_q    <= VAL_IDLE;
            admission_active_o   <= 1'b0;
          end

          VAL_REJECT: begin
            if (reject_operation_q)
              invalid_operation_event_o <= 1'b1;
            else
              invalid_config_event_o <= 1'b1;
            validator_state_q  <= VAL_IDLE;
            admission_active_o <= 1'b0;
            mul_running_q      <= 1'b0;
            state_q            <= DBG_IDLE;
          end

          default: begin
            internal_error_event_o <= 1'b1;
            validator_state_q      <= VAL_IDLE;
            admission_active_o     <= 1'b0;
            mul_running_q          <= 1'b0;
            state_q                <= DBG_IDLE;
          end
        endcase
      end else begin
        case (state_q)
          DBG_IDLE,
          DBG_COMPLETE: begin
            if (start_pulse_i) begin
              pending_operation_q    <= operation_i;
              pending_input_height_q <= input_height_i;
              pending_input_width_q  <= input_width_i;
              pending_in_channels_q  <= in_channels_i;
              pending_out_channels_q <= out_channels_i;
              pending_conv_config_q  <= conv_config_i;
              pending_output_scale_q <= output_scale_i;
              pending_input_bytes_q  <= input_bytes_i;
              pending_weight_bytes_q <= weight_bytes_i;
              pending_bias_bytes_q   <= bias_bytes_i;
              pending_skip_bytes_q   <= skip_bytes_i;
              pending_output_bytes_q <= output_bytes_i;
              reject_operation_q     <= 1'b0;
              validator_state_q      <= VAL_FIELDS;
              admission_active_o     <= 1'b1;
              mul_running_q          <= 1'b0;
              state_q                <= DBG_IDLE;
            end else if (state_q == DBG_COMPLETE) begin
              state_q <= DBG_IDLE;
            end
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
