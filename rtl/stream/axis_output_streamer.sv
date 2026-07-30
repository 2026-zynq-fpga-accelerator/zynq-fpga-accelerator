`timescale 1ns/1ps

module axis_output_streamer #(
  parameter integer MAX_OUTPUT_WORDS = 4096
) (
  input  logic clk_i,
  input  logic aresetn_i,
  input  logic start_i,
  input  logic abort_i,
  input  logic [31:0] output_bytes_i,

  output logic                                      output_rd_en_o,
  output logic [$clog2(MAX_OUTPUT_WORDS)-1:0]       output_rd_addr_o,
  input  logic [31:0]                               output_rd_data_i,

  output logic [31:0] m_axis_tdata_o,
  output logic  [3:0] m_axis_tkeep_o,
  output logic        m_axis_tlast_o,
  output logic        m_axis_tvalid_o,
  input  logic        m_axis_tready_i,

  output logic busy_o,
  output logic done_o
);
  typedef enum logic [1:0] {
    OUT_IDLE,
    OUT_READ,
    OUT_SEND
  } output_state_t;

  output_state_t state_q;
  logic [31:0] word_index_q;
  logic [31:0] word_count_q;

  always_comb begin
    output_rd_en_o   = (state_q == OUT_READ);
    output_rd_addr_o = word_index_q[$clog2(MAX_OUTPUT_WORDS)-1:0];

    m_axis_tdata_o  = output_rd_data_i;
    m_axis_tkeep_o  = 4'b1111;
    m_axis_tlast_o  = (word_index_q == (word_count_q - 32'd1));
    m_axis_tvalid_o = (state_q == OUT_SEND);
    busy_o          = (state_q != OUT_IDLE);
  end

  always_ff @(posedge clk_i) begin
    if (!aresetn_i) begin
      state_q      <= OUT_IDLE;
      word_index_q <= 32'd0;
      word_count_q <= 32'd0;
      done_o       <= 1'b0;
    end else if (abort_i) begin
      state_q      <= OUT_IDLE;
      word_index_q <= 32'd0;
      word_count_q <= 32'd0;
      done_o       <= 1'b0;
    end else begin
      done_o <= 1'b0;

      case (state_q)
        OUT_IDLE: begin
          if (start_i) begin
            word_index_q <= 32'd0;
            word_count_q <= output_bytes_i >> 2;
            state_q      <= OUT_READ;
          end
        end

        OUT_READ: state_q <= OUT_SEND;

        OUT_SEND: begin
          if (m_axis_tvalid_o && m_axis_tready_i) begin
            if (word_index_q + 32'd1 == word_count_q) begin
              done_o  <= 1'b1;
              state_q <= OUT_IDLE;
            end else begin
              word_index_q <= word_index_q + 32'd1;
              state_q      <= OUT_READ;
            end
          end
        end

        default: state_q <= OUT_IDLE;
      endcase
    end
  end
endmodule

