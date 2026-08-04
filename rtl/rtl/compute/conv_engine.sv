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
  typedef enum logic [3:0] {
    ENG_IDLE,
    ENG_ADDR_INIT,
    ENG_PREPARE_OUTPUT,
    ENG_READ_TAP,
    ENG_MAC_PRODUCT,
    ENG_ACCUMULATE,
    ENG_ADD_BIAS,
    ENG_REQUANT_MUL,
    ENG_REQUANT_ROUND_ADD,
    ENG_REQUANT_SHIFT,
    ENG_WRITE_OUTPUT
  } engine_state_t;

  engine_state_t state_q;

  // The controller validates the 32-bit operational configuration before start_i.
  // Existing counters remain 32-bit; only capacity-bounded address arithmetic is narrowed.
  logic [31:0] out_h_q;
  logic [31:0] out_w_q;
  logic [31:0] out_c_q;
  logic [31:0] kernel_h_q;
  logic [31:0] kernel_w_q;
  logic [31:0] in_c_q;
  logic signed [31:0] accumulator_q;

  logic [27:0] input_row_stride_calc;
  logic [13:0] output_x_step_q;
  logic [15:0] output_y_step_q;
  logic signed [16:0] kernel_row_advance_q;

  logic signed [16:0] input_row_base_q;
  logic signed [16:0] input_patch_base_q;
  logic signed [16:0] patch_origin_y_q;
  logic signed [16:0] patch_origin_x_q;

  logic signed [16:0] tap_input_y_q;
  logic signed [16:0] tap_input_x_q;
  logic signed [16:0] tap_input_element_q;
  logic               tap_padding_q;
  logic               tap_valid_q;
  logic        [15:0] weight_element_q;
  logic        [13:0] output_element_q;
  logic               address_init_valid_q;

  logic signed [16:0] tap_x_next;
  logic signed [16:0] tap_y_next;
  logic               patch_padding_now;
  logic               tap_x_next_padding;
  logic               tap_row_next_padding;

  logic signed [15:0] product;
  logic signed [15:0] mac_product_q;
  logic               mac_product_valid_q;
  logic               mac_product_last_tap_q;
  logic signed [31:0] product_extended;
  logic signed [31:0] mac_sum;
  logic               mac_saturated;
  logic signed [31:0] bias_sum;
  logic               bias_saturated;
  logic signed [49:0] requantized;
  logic signed  [7:0] clamped_output;
  logic               requant_product_valid;
  logic               requant_round_add_valid;
  logic               requantized_valid;
  logic               requant_clear;
  logic               requant_mul_enable;
  logic               requant_round_add_enable;
  logic               requant_shift_enable;
  logic               last_tap;
  logic               last_output;
  logic [$clog2(MAX_OUTPUT_WORDS)-1:0] output_waddr_q;
  logic [1:0]                                output_wbyte_sel_q;
  logic                                      last_output_q;
  logic                                      relu_enable_q;
  logic                                      postprocess_valid_q;
  logic signed [31:0]                        requant_accumulator_q;

  function automatic logic coordinate_is_padding(
    input logic signed [16:0] coordinate_y,
    input logic signed [16:0] coordinate_x,
    input logic        [14:0] input_height,
    input logic        [14:0] input_width
  );
    begin
      coordinate_is_padding = (coordinate_y < 0)
                           || (coordinate_x < 0)
                           || ($unsigned(coordinate_y) >= {2'b00, input_height})
                           || ($unsigned(coordinate_x) >= {2'b00, input_width});
    end
  endfunction

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
    .clk_i(clk_i),
    .aresetn_i(aresetn_i),
    .clear_i(requant_clear),
    .mul_enable_i(requant_mul_enable),
    .round_add_enable_i(requant_round_add_enable),
    .shift_enable_i(requant_shift_enable),
    .accumulator_i(requant_accumulator_q),
    .multiplier_i(multiplier_i),
    .shift_i(shift_i),
    .requantized_o(requantized),
    .product_valid_o(requant_product_valid),
    .round_add_valid_o(requant_round_add_valid),
    .requantized_valid_o(requantized_valid)
  );

  relu_clamp u_relu_clamp (
    .value_i(requantized),
    .relu_enable_i(relu_enable_q),
    .value_o(clamped_output)
  );

  always_comb begin
    // This is the only variable multiplication in the address generator. Its result
    // is captured once in ENG_ADDR_INIT and is not in the runtime tap-to-BRAM path.
    input_row_stride_calc = input_width_i[14:0] * in_channels_i[12:0];

    tap_x_next = tap_input_x_q + 17'sd1;
    tap_y_next = tap_input_y_q + 17'sd1;
    patch_padding_now = coordinate_is_padding(
      patch_origin_y_q, patch_origin_x_q,
      input_height_i[14:0], input_width_i[14:0]
    );
    tap_x_next_padding = coordinate_is_padding(
      tap_input_y_q, tap_x_next,
      input_height_i[14:0], input_width_i[14:0]
    );
    tap_row_next_padding = coordinate_is_padding(
      tap_y_next, patch_origin_x_q,
      input_height_i[14:0], input_width_i[14:0]
    );

    input_rd_en_o        = (state_q == ENG_READ_TAP) && tap_valid_q
                          && !tap_padding_q && !abort_i;
    input_rd_word_addr_o = tap_input_element_q[$clog2(MAX_INPUT_WORDS)+1:2];
    input_rd_byte_sel_o  = tap_input_element_q[1:0];

    weight_rd_en_o        = (state_q == ENG_READ_TAP) && tap_valid_q && !abort_i;
    weight_rd_word_addr_o = weight_element_q[$clog2(MAX_WEIGHT_WORDS)+1:2];
    weight_rd_byte_sel_o  = weight_element_q[1:0];

    last_tap = (kernel_h_q == 32'd2)
            && (kernel_w_q == 32'd2)
            && (in_c_q == (in_channels_i - 32'd1));

    bias_rd_en_o   = (state_q == ENG_ACCUMULATE)
                  && mac_product_valid_q && mac_product_last_tap_q && !abort_i;
    bias_rd_addr_o = out_c_q[$clog2(MAX_BIAS_WORDS)-1:0];

    requant_clear        = abort_i
                         || ((state_q == ENG_WRITE_OUTPUT)
                             && postprocess_valid_q && requantized_valid);
    requant_mul_enable       = (state_q == ENG_REQUANT_MUL) && !abort_i;
    requant_round_add_enable = (state_q == ENG_REQUANT_ROUND_ADD)
                             && requant_product_valid && !abort_i;
    requant_shift_enable     = (state_q == ENG_REQUANT_SHIFT)
                             && requant_round_add_valid && !abort_i;

    output_we_o        = (state_q == ENG_WRITE_OUTPUT)
                      && postprocess_valid_q
                      && requantized_valid
                      && !abort_i;
    output_waddr_o     = output_waddr_q;
    output_wbyte_sel_o = output_wbyte_sel_q;
    output_wdata_o     = clamped_output;

    last_output = (out_h_q == (output_height_i - 32'd1))
               && (out_w_q == (output_width_i - 32'd1))
               && (out_c_q == (out_channels_i - 32'd1));

    if (tap_padding_q)
      product = 16'sd0;
    else
      product = $signed(input_rd_data_i) * $signed(weight_rd_data_i);

    product_extended = $signed({{16{mac_product_q[15]}}, mac_product_q});
    busy_o = (state_q != ENG_IDLE);
  end

  always_ff @(posedge clk_i) begin
    if (!aresetn_i) begin
      state_q                 <= ENG_IDLE;
      out_h_q                 <= 32'd0;
      out_w_q                 <= 32'd0;
      out_c_q                 <= 32'd0;
      kernel_h_q              <= 32'd0;
      kernel_w_q              <= 32'd0;
      in_c_q                  <= 32'd0;
      accumulator_q           <= 32'sd0;
      mac_product_q           <= 16'sd0;
      mac_product_valid_q     <= 1'b0;
      mac_product_last_tap_q  <= 1'b0;
      requant_accumulator_q   <= 32'sd0;
      output_x_step_q         <= 14'd0;
      output_y_step_q         <= 16'd0;
      kernel_row_advance_q    <= 17'sd0;
      input_row_base_q        <= 17'sd0;
      input_patch_base_q      <= 17'sd0;
      patch_origin_y_q        <= 17'sd0;
      patch_origin_x_q        <= 17'sd0;
      tap_input_y_q           <= 17'sd0;
      tap_input_x_q           <= 17'sd0;
      tap_input_element_q     <= 17'sd0;
      tap_padding_q           <= 1'b0;
      tap_valid_q             <= 1'b0;
      weight_element_q        <= 16'd0;
      output_element_q        <= 14'd0;
      address_init_valid_q    <= 1'b0;
      output_waddr_q          <= '0;
      output_wbyte_sel_q      <= 2'd0;
      last_output_q           <= 1'b0;
      relu_enable_q           <= 1'b0;
      postprocess_valid_q     <= 1'b0;
      done_o                  <= 1'b0;
      overflow_event_o        <= 1'b0;
    end else if (abort_i) begin
      state_q                 <= ENG_IDLE;
      out_h_q                 <= 32'd0;
      out_w_q                 <= 32'd0;
      out_c_q                 <= 32'd0;
      kernel_h_q              <= 32'd0;
      kernel_w_q              <= 32'd0;
      in_c_q                  <= 32'd0;
      accumulator_q           <= 32'sd0;
      mac_product_q           <= 16'sd0;
      mac_product_valid_q     <= 1'b0;
      mac_product_last_tap_q  <= 1'b0;
      requant_accumulator_q   <= 32'sd0;
      output_x_step_q         <= 14'd0;
      output_y_step_q         <= 16'd0;
      kernel_row_advance_q    <= 17'sd0;
      input_row_base_q        <= 17'sd0;
      input_patch_base_q      <= 17'sd0;
      patch_origin_y_q        <= 17'sd0;
      patch_origin_x_q        <= 17'sd0;
      tap_input_y_q           <= 17'sd0;
      tap_input_x_q           <= 17'sd0;
      tap_input_element_q     <= 17'sd0;
      tap_padding_q           <= 1'b0;
      tap_valid_q             <= 1'b0;
      weight_element_q        <= 16'd0;
      output_element_q        <= 14'd0;
      address_init_valid_q    <= 1'b0;
      output_waddr_q          <= '0;
      output_wbyte_sel_q      <= 2'd0;
      last_output_q           <= 1'b0;
      relu_enable_q           <= 1'b0;
      postprocess_valid_q     <= 1'b0;
      done_o                  <= 1'b0;
      overflow_event_o        <= 1'b0;
    end else begin
      done_o           <= 1'b0;
      overflow_event_o <= 1'b0;

      case (state_q)
        ENG_IDLE: begin
          if (start_i) begin
            out_h_q              <= 32'd0;
            out_w_q              <= 32'd0;
            out_c_q              <= 32'd0;
            kernel_h_q           <= 32'd0;
            kernel_w_q           <= 32'd0;
            in_c_q               <= 32'd0;
            accumulator_q        <= 32'sd0;
            mac_product_q        <= 16'sd0;
            mac_product_valid_q  <= 1'b0;
            mac_product_last_tap_q <= 1'b0;
            requant_accumulator_q <= 32'sd0;
            output_element_q     <= 14'd0;
            address_init_valid_q <= 1'b0;
            tap_valid_q          <= 1'b0;
            postprocess_valid_q  <= 1'b0;
            state_q              <= ENG_ADDR_INIT;
          end
        end

        ENG_ADDR_INIT: begin
          output_x_step_q <= (stride_i == 8'd2)
                           ? {in_channels_i[12:0], 1'b0}
                           : {1'b0, in_channels_i[12:0]};
          output_y_step_q <= (stride_i == 8'd2)
                           ? {input_row_stride_calc[14:0], 1'b0}
                           : {1'b0, input_row_stride_calc[14:0]};
          kernel_row_advance_q <= $signed({2'b00, input_row_stride_calc[14:0]})
                                - $signed({4'b0000, in_channels_i[12:0]})
                                - $signed({4'b0000, in_channels_i[12:0]})
                                - $signed({4'b0000, in_channels_i[12:0]})
                                + 17'sd1;

          if (padding_i == 8'd1) begin
            input_row_base_q <= -$signed({2'b00, input_row_stride_calc[14:0]})
                                - $signed({4'b0000, in_channels_i[12:0]});
            input_patch_base_q <= -$signed({2'b00, input_row_stride_calc[14:0]})
                                  - $signed({4'b0000, in_channels_i[12:0]});
            patch_origin_y_q <= -17'sd1;
            patch_origin_x_q <= -17'sd1;
          end else begin
            input_row_base_q   <= 17'sd0;
            input_patch_base_q <= 17'sd0;
            patch_origin_y_q   <= 17'sd0;
            patch_origin_x_q   <= 17'sd0;
          end
          address_init_valid_q <= 1'b1;
          state_q <= ENG_PREPARE_OUTPUT;
        end

        ENG_PREPARE_OUTPUT: begin
          if (address_init_valid_q) begin
            kernel_h_q          <= 32'd0;
            kernel_w_q          <= 32'd0;
            in_c_q              <= 32'd0;
            tap_input_y_q       <= patch_origin_y_q;
            tap_input_x_q       <= patch_origin_x_q;
            tap_input_element_q <= input_patch_base_q;
            tap_padding_q       <= patch_padding_now;
            weight_element_q    <= {10'd0, out_c_q[5:0]};
            tap_valid_q         <= 1'b1;
            state_q             <= ENG_READ_TAP;
          end
        end

        ENG_READ_TAP: begin
          state_q <= ENG_MAC_PRODUCT;
        end

        ENG_MAC_PRODUCT: begin
          mac_product_q          <= tap_padding_q ? 16'sd0 : product;
          mac_product_valid_q    <= 1'b1;
          mac_product_last_tap_q <= last_tap;
          state_q                <= ENG_ACCUMULATE;
        end

        ENG_ACCUMULATE: begin
          if (mac_product_valid_q) begin
            accumulator_q       <= mac_sum;
            mac_product_valid_q <= 1'b0;
            if (mac_saturated)
              overflow_event_o <= 1'b1;

            if (mac_product_last_tap_q) begin
              tap_valid_q <= 1'b0;
              state_q <= ENG_ADD_BIAS;
            end else begin
              weight_element_q <= weight_element_q + {9'd0, out_channels_i[6:0]};
              if (in_c_q + 32'd1 < in_channels_i) begin
                in_c_q              <= in_c_q + 32'd1;
                tap_input_element_q <= tap_input_element_q + 17'sd1;
              end else begin
                in_c_q <= 32'd0;
                if (kernel_w_q < 32'd2) begin
                  kernel_w_q          <= kernel_w_q + 32'd1;
                  tap_input_x_q       <= tap_x_next;
                  tap_input_element_q <= tap_input_element_q + 17'sd1;
                  tap_padding_q       <= tap_x_next_padding;
                end else begin
                  kernel_w_q          <= 32'd0;
                  kernel_h_q          <= kernel_h_q + 32'd1;
                  tap_input_y_q       <= tap_y_next;
                  tap_input_x_q       <= patch_origin_x_q;
                  tap_input_element_q <= tap_input_element_q + kernel_row_advance_q;
                  tap_padding_q       <= tap_row_next_padding;
                end
              end
              state_q <= ENG_READ_TAP;
            end
          end
        end

        ENG_ADD_BIAS: begin
          accumulator_q         <= bias_sum;
          requant_accumulator_q <= bias_sum;
          output_waddr_q      <= output_element_q[$clog2(MAX_OUTPUT_WORDS)+1:2];
          output_wbyte_sel_q  <= output_element_q[1:0];
          last_output_q       <= last_output;
          relu_enable_q       <= relu_enable_i;
          postprocess_valid_q <= 1'b1;
          if (bias_saturated)
            overflow_event_o <= 1'b1;
          state_q <= ENG_REQUANT_MUL;
        end

        ENG_REQUANT_MUL: begin
          state_q <= ENG_REQUANT_ROUND_ADD;
        end

        ENG_REQUANT_ROUND_ADD: begin
          if (requant_product_valid)
            state_q <= ENG_REQUANT_SHIFT;
        end

        ENG_REQUANT_SHIFT: begin
          if (requant_round_add_valid)
            state_q <= ENG_WRITE_OUTPUT;
        end

        ENG_WRITE_OUTPUT: begin
          if (postprocess_valid_q && requantized_valid) begin
            postprocess_valid_q <= 1'b0;
            tap_valid_q <= 1'b0;
            if (last_output_q) begin
              done_o  <= 1'b1;
              state_q <= ENG_IDLE;
            end else begin
              output_element_q <= output_element_q + 14'd1;
              accumulator_q <= 32'sd0;

              // NHWC traversal: OC changes reuse the same input patch; X/Y changes
              // advance the registered patch bases by precomputed stride values.
              if (out_c_q + 32'd1 < out_channels_i) begin
                out_c_q <= out_c_q + 32'd1;
              end else begin
                out_c_q <= 32'd0;
                if (out_w_q + 32'd1 < output_width_i) begin
                  out_w_q <= out_w_q + 32'd1;
                  input_patch_base_q <= input_patch_base_q
                                        + $signed({3'b000, output_x_step_q});
                  patch_origin_x_q <= patch_origin_x_q
                                      + $signed({15'd0, stride_i[1:0]});
                end else begin
                  out_w_q <= 32'd0;
                  out_h_q <= out_h_q + 32'd1;
                  input_row_base_q <= input_row_base_q
                                      + $signed({1'b0, output_y_step_q});
                  input_patch_base_q <= input_row_base_q
                                        + $signed({1'b0, output_y_step_q});
                  patch_origin_y_q <= patch_origin_y_q
                                      + $signed({15'd0, stride_i[1:0]});
                  patch_origin_x_q <= (padding_i == 8'd1) ? -17'sd1 : 17'sd0;
                end
              end
              state_q <= ENG_PREPARE_OUTPUT;
            end
          end
        end

        default: state_q <= ENG_IDLE;
      endcase
    end
  end
endmodule
