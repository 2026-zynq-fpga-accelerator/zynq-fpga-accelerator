`timescale 1ns/1ps

module conv_engine #(
  parameter integer MAX_WEIGHT_WORDS = 9216,
  parameter integer MAX_BIAS_WORDS   = 64,
  parameter integer MAX_INPUT_WORDS  = 4096,
  parameter integer MAX_OUTPUT_WORDS = 4096
) (
  input  logic clk_i,
  input  logic aresetn_i,
  input  logic start_i,
  input  logic abort_i,

  input  logic [31:0] input_height_i,
  input  logic [31:0] input_width_i,
  input  logic [31:0] in_channels_i,
  input  logic [31:0] out_channels_i,
  input  logic [31:0] output_height_i,
  input  logic [31:0] output_width_i,
  input  logic  [7:0] stride_i,
  input  logic  [7:0] padding_i,
  input  logic        relu_enable_i,
  input  logic [15:0] multiplier_i,
  input  logic [15:0] shift_i,

  output logic busy_o,
  output logic done_o,
  output logic overflow_event_o,

  output logic                                      input_rd_en_o,
  output logic [$clog2(MAX_INPUT_WORDS)-1:0]        input_rd_word_addr_o,
  output logic [1:0]                                input_rd_byte_sel_o,
  input  logic signed [7:0]                         input_rd_data_i,

  output logic                                      weight_rd_en_o,
  output logic [$clog2(MAX_WEIGHT_WORDS)-1:0]       weight_rd_word_addr_o,
  output logic [1:0]                                weight_rd_byte_sel_o,
  input  logic signed [7:0]                         weight_rd_data_i,

  output logic                                      bias_rd_en_o,
  output logic [$clog2(MAX_BIAS_WORDS)-1:0]         bias_rd_addr_o,
  input  logic signed [31:0]                        bias_rd_data_i,

  output logic                                      output_we_o,
  output logic [$clog2(MAX_OUTPUT_WORDS)-1:0]       output_waddr_o,
  output logic [1:0]                                output_wbyte_sel_o,
  output logic signed [7:0]                         output_wdata_o
);
  typedef enum logic [2:0] {
    ENG_IDLE,
    ENG_READ_TAP,
    ENG_ACCUMULATE,
    ENG_ADD_BIAS,
    ENG_POSTPROCESS
  } engine_state_t;

  engine_state_t state_q;

  logic [31:0] out_h_q;
  logic [31:0] out_w_q;
  logic [31:0] out_c_q;
  logic [31:0] kernel_h_q;
  logic [31:0] kernel_w_q;
  logic [31:0] in_c_q;
  logic signed [31:0] accumulator_q;
  logic padding_pending_q;

  logic signed [63:0] input_y_calc;
  logic signed [63:0] input_x_calc;
  logic               padding_now;
  logic        [63:0] input_element_index;
  logic        [63:0] weight_element_index;
  logic        [63:0] output_element_index;

  logic signed [15:0] product;
  logic signed [31:0] product_extended;
  logic signed [31:0] mac_sum;
  logic               mac_saturated;
  logic signed [31:0] bias_sum;
  logic               bias_saturated;
  logic signed [49:0] requantized;
  logic signed  [7:0] clamped_output;
  logic               last_tap;
  logic               last_output;

  sat_add_int32 u_mac_add (
    .a_i(accumulator_q),
    .b_i(product_extended),
    .sum_o(mac_sum),
    .saturated_o(mac_saturated)
  );

  sat_add_int32 u_bias_add (
    .a_i(accumulator_q),
    .b_i(bias_rd_data_i),
    .sum_o(bias_sum),
    .saturated_o(bias_saturated)
  );

  requantizer u_requantizer (
    .accumulator_i(accumulator_q),
    .multiplier_i(multiplier_i),
    .shift_i(shift_i),
    .requantized_o(requantized)
  );

  relu_clamp u_relu_clamp (
    .value_i(requantized),
    .relu_enable_i(relu_enable_i),
    .value_o(clamped_output)
  );

  always_comb begin
    input_y_calc = ($signed({32'd0, out_h_q}) * $signed({56'd0, stride_i}))
                 + $signed({32'd0, kernel_h_q})
                 - $signed({56'd0, padding_i});
    input_x_calc = ($signed({32'd0, out_w_q}) * $signed({56'd0, stride_i}))
                 + $signed({32'd0, kernel_w_q})
                 - $signed({56'd0, padding_i});

    padding_now = (input_y_calc < 0)
               || (input_x_calc < 0)
               || ($unsigned(input_y_calc) >= {32'd0, input_height_i})
               || ($unsigned(input_x_calc) >= {32'd0, input_width_i});

    input_element_index = (($unsigned(input_y_calc) * {32'd0, input_width_i})
                          + $unsigned(input_x_calc))
                          * {32'd0, in_channels_i}
                          + {32'd0, in_c_q};

    weight_element_index = (((({32'd0, kernel_h_q} * 64'd3)
                            + {32'd0, kernel_w_q})
                            * {32'd0, in_channels_i})
                            + {32'd0, in_c_q})
                            * {32'd0, out_channels_i}
                            + {32'd0, out_c_q};

    output_element_index = (({32'd0, out_h_q} * {32'd0, output_width_i})
                         + {32'd0, out_w_q})
                         * {32'd0, out_channels_i}
                         + {32'd0, out_c_q};

    input_rd_en_o        = (state_q == ENG_READ_TAP) && !padding_now;
    input_rd_word_addr_o = input_element_index[$clog2(MAX_INPUT_WORDS)+1:2];
    input_rd_byte_sel_o  = input_element_index[1:0];

    weight_rd_en_o        = (state_q == ENG_READ_TAP);
    weight_rd_word_addr_o = weight_element_index[$clog2(MAX_WEIGHT_WORDS)+1:2];
    weight_rd_byte_sel_o  = weight_element_index[1:0];

    last_tap = (kernel_h_q == 32'd2)
            && (kernel_w_q == 32'd2)
            && (in_c_q == (in_channels_i - 32'd1));

    bias_rd_en_o = (state_q == ENG_ACCUMULATE) && last_tap;
    bias_rd_addr_o = out_c_q[$clog2(MAX_BIAS_WORDS)-1:0];

    output_we_o        = (state_q == ENG_POSTPROCESS);
    output_waddr_o     = output_element_index[$clog2(MAX_OUTPUT_WORDS)+1:2];
    output_wbyte_sel_o = output_element_index[1:0];
    output_wdata_o     = clamped_output;

    last_output = (out_h_q == (output_height_i - 32'd1))
               && (out_w_q == (output_width_i - 32'd1))
               && (out_c_q == (out_channels_i - 32'd1));

    if (padding_pending_q)
      product = 16'sd0;
    else
      product = $signed(input_rd_data_i) * $signed(weight_rd_data_i);

    product_extended = $signed({{16{product[15]}}, product});
    busy_o = (state_q != ENG_IDLE);
  end

  always_ff @(posedge clk_i) begin
    if (!aresetn_i) begin
      state_q          <= ENG_IDLE;
      out_h_q          <= 32'd0;
      out_w_q          <= 32'd0;
      out_c_q          <= 32'd0;
      kernel_h_q       <= 32'd0;
      kernel_w_q       <= 32'd0;
      in_c_q           <= 32'd0;
      accumulator_q    <= 32'sd0;
      padding_pending_q <= 1'b0;
      done_o           <= 1'b0;
      overflow_event_o <= 1'b0;
    end else if (abort_i) begin
      state_q           <= ENG_IDLE;
      out_h_q           <= 32'd0;
      out_w_q           <= 32'd0;
      out_c_q           <= 32'd0;
      kernel_h_q        <= 32'd0;
      kernel_w_q        <= 32'd0;
      in_c_q            <= 32'd0;
      accumulator_q     <= 32'sd0;
      padding_pending_q <= 1'b0;
      done_o            <= 1'b0;
      overflow_event_o  <= 1'b0;
    end else begin
      done_o           <= 1'b0;
      overflow_event_o <= 1'b0;

      case (state_q)
        ENG_IDLE: begin
          if (start_i) begin
            out_h_q           <= 32'd0;
            out_w_q           <= 32'd0;
            out_c_q           <= 32'd0;
            kernel_h_q        <= 32'd0;
            kernel_w_q        <= 32'd0;
            in_c_q            <= 32'd0;
            accumulator_q     <= 32'sd0;
            padding_pending_q <= 1'b0;
            state_q           <= ENG_READ_TAP;
          end
        end

        ENG_READ_TAP: begin
          padding_pending_q <= padding_now;
          state_q           <= ENG_ACCUMULATE;
        end

        ENG_ACCUMULATE: begin
          accumulator_q <= mac_sum;
          if (mac_saturated)
            overflow_event_o <= 1'b1;

          if (last_tap) begin
            state_q <= ENG_ADD_BIAS;
          end else begin
            if (in_c_q + 32'd1 < in_channels_i) begin
              in_c_q <= in_c_q + 32'd1;
            end else begin
              in_c_q <= 32'd0;
              if (kernel_w_q < 32'd2)
                kernel_w_q <= kernel_w_q + 32'd1;
              else begin
                kernel_w_q <= 32'd0;
                kernel_h_q <= kernel_h_q + 32'd1;
              end
            end
            state_q <= ENG_READ_TAP;
          end
        end

        ENG_ADD_BIAS: begin
          accumulator_q <= bias_sum;
          if (bias_saturated)
            overflow_event_o <= 1'b1;
          state_q <= ENG_POSTPROCESS;
        end

        ENG_POSTPROCESS: begin
          if (last_output) begin
            done_o  <= 1'b1;
            state_q <= ENG_IDLE;
          end else begin
            if (out_c_q + 32'd1 < out_channels_i) begin
              out_c_q <= out_c_q + 32'd1;
            end else begin
              out_c_q <= 32'd0;
              if (out_w_q + 32'd1 < output_width_i)
                out_w_q <= out_w_q + 32'd1;
              else begin
                out_w_q <= 32'd0;
                out_h_q <= out_h_q + 32'd1;
              end
            end
            kernel_h_q    <= 32'd0;
            kernel_w_q    <= 32'd0;
            in_c_q        <= 32'd0;
            accumulator_q <= 32'sd0;
            state_q       <= ENG_READ_TAP;
          end
        end

        default: state_q <= ENG_IDLE;
      endcase
    end
  end
endmodule

