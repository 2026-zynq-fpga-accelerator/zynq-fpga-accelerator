`timescale 1ns/1ps

// OP_GLOBAL_AVG_POOL: per-channel sum over all H*W spatial positions (NHWC layout, so
// consecutive positions for a fixed channel are exactly IN_CHANNELS bytes apart), then a single
// M/N requantization + INT8 clamp per channel. No weight/bias/kernel loop -- structurally closer
// to conv_engine's post-accumulate tail (ADD_BIAS..WRITE_OUTPUT) than to its MAC pipeline.
module gap_engine #(
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
  input  logic [15:0] multiplier_i,
  input  logic [15:0] shift_i,

  output logic busy_o,
  output logic done_o,
  output logic overflow_event_o,

  output logic                                      input_rd_en_o,
  output logic [$clog2(MAX_INPUT_WORDS)-1:0]        input_rd_word_addr_o,
  output logic [1:0]                                input_rd_byte_sel_o,
  input  logic signed [7:0]                         input_rd_data_i,

  output logic                                      output_we_o,
  output logic [$clog2(MAX_OUTPUT_WORDS)-1:0]       output_waddr_o,
  output logic [1:0]                                output_wbyte_sel_o,
  output logic signed [7:0]                         output_wdata_o
);
  typedef enum logic [2:0] {
    GAP_IDLE,
    GAP_READ,
    GAP_ACCUMULATE,
    GAP_REQUANT_MUL,
    GAP_REQUANT_ROUND_ADD,
    GAP_REQUANT_SHIFT,
    GAP_WRITE_OUTPUT
  } gap_state_t;

  gap_state_t state_q;

  logic [31:0] h_q;
  logic [31:0] w_q;
  logic [31:0] c_q;
  logic [16:0] element_q;
  logic signed [31:0] accumulator_q;
  logic signed [31:0] requant_accumulator_q;

  logic signed [31:0] input_extended;
  logic signed [31:0] accumulator_sum;
  logic               accumulator_saturated;
  logic               last_position;
  logic               last_channel;

  logic signed [49:0] requantized;
  logic signed  [7:0] clamped_output;
  logic               requant_product_valid;
  logic               requant_round_add_valid;
  logic               requantized_valid;
  logic               requant_clear;
  logic               requant_mul_enable;
  logic               requant_round_add_enable;
  logic               requant_shift_enable;

  sat_add_int32 u_sat_add (
    .a_i(accumulator_q),
    .b_i(input_extended),
    .sum_o(accumulator_sum),
    .saturated_o(accumulator_saturated)
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
    .relu_enable_i(1'b0),
    .value_o(clamped_output)
  );

  always_comb begin
    input_extended = {{24{input_rd_data_i[7]}}, input_rd_data_i};

    last_position = (h_q == (input_height_i - 32'd1))
                 && (w_q == (input_width_i  - 32'd1));
    last_channel  = (c_q == (in_channels_i - 32'd1));

    input_rd_en_o        = (state_q == GAP_READ) && !abort_i;
    input_rd_word_addr_o = element_q[$clog2(MAX_INPUT_WORDS)+1:2];
    input_rd_byte_sel_o  = element_q[1:0];

    requant_clear            = abort_i || (state_q == GAP_WRITE_OUTPUT);
    requant_mul_enable       = (state_q == GAP_REQUANT_MUL) && !abort_i;
    requant_round_add_enable = (state_q == GAP_REQUANT_ROUND_ADD)
                             && requant_product_valid && !abort_i;
    requant_shift_enable     = (state_q == GAP_REQUANT_SHIFT)
                             && requant_round_add_valid && !abort_i;

    output_we_o        = (state_q == GAP_WRITE_OUTPUT) && requantized_valid && !abort_i;
    output_waddr_o      = c_q[$clog2(MAX_OUTPUT_WORDS)+1:2];
    output_wbyte_sel_o  = c_q[1:0];
    output_wdata_o      = clamped_output;

    busy_o = (state_q != GAP_IDLE);
  end

  always_ff @(posedge clk_i) begin
    if (!aresetn_i) begin
      state_q                <= GAP_IDLE;
      h_q                    <= 32'd0;
      w_q                    <= 32'd0;
      c_q                    <= 32'd0;
      element_q              <= 17'd0;
      accumulator_q          <= 32'sd0;
      requant_accumulator_q  <= 32'sd0;
      done_o                 <= 1'b0;
      overflow_event_o       <= 1'b0;
    end else if (abort_i) begin
      state_q                <= GAP_IDLE;
      h_q                    <= 32'd0;
      w_q                    <= 32'd0;
      c_q                    <= 32'd0;
      element_q              <= 17'd0;
      accumulator_q          <= 32'sd0;
      requant_accumulator_q  <= 32'sd0;
      done_o                 <= 1'b0;
      overflow_event_o       <= 1'b0;
    end else begin
      done_o           <= 1'b0;
      overflow_event_o <= 1'b0;

      case (state_q)
        GAP_IDLE: begin
          if (start_i) begin
            h_q           <= 32'd0;
            w_q           <= 32'd0;
            c_q           <= 32'd0;
            element_q     <= 17'd0;
            accumulator_q <= 32'sd0;
            state_q       <= GAP_READ;
          end
        end

        GAP_READ: state_q <= GAP_ACCUMULATE;

        GAP_ACCUMULATE: begin
          accumulator_q <= accumulator_sum;
          if (accumulator_saturated)
            overflow_event_o <= 1'b1;

          if (last_position) begin
            requant_accumulator_q <= accumulator_sum;
            state_q                <= GAP_REQUANT_MUL;
          end else begin
            if (w_q + 32'd1 < input_width_i) begin
              w_q <= w_q + 32'd1;
            end else begin
              w_q <= 32'd0;
              h_q <= h_q + 32'd1;
            end
            element_q <= element_q + in_channels_i[16:0];
            state_q   <= GAP_READ;
          end
        end

        GAP_REQUANT_MUL: state_q <= GAP_REQUANT_ROUND_ADD;

        GAP_REQUANT_ROUND_ADD: begin
          if (requant_product_valid)
            state_q <= GAP_REQUANT_SHIFT;
        end

        GAP_REQUANT_SHIFT: begin
          if (requant_round_add_valid)
            state_q <= GAP_WRITE_OUTPUT;
        end

        GAP_WRITE_OUTPUT: begin
          if (requantized_valid) begin
            if (last_channel) begin
              done_o  <= 1'b1;
              state_q <= GAP_IDLE;
            end else begin
              c_q           <= c_q + 32'd1;
              h_q           <= 32'd0;
              w_q           <= 32'd0;
              // Next channel's (h=0,w=0) NHWC offset is simply its channel index.
              element_q     <= c_q[16:0] + 17'd1;
              accumulator_q <= 32'sd0;
              state_q       <= GAP_READ;
            end
          end
        end

        default: state_q <= GAP_IDLE;
      endcase
    end
  end
endmodule
