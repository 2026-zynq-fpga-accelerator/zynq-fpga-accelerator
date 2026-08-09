`timescale 1ns/1ps

module residual_add_engine #(
  parameter integer MAX_TENSOR_WORDS = 4096
) (
  input  logic clk_i,
  input  logic aresetn_i,
  input  logic start_i,
  input  logic abort_i,
  input  logic [31:0] tensor_bytes_i,
  input  logic relu_enable_i,

  output logic busy_o,
  output logic done_o,

  output logic                                      main_rd_en_o,
  output logic [$clog2(MAX_TENSOR_WORDS)-1:0]       main_rd_addr_o,
  input  logic [31:0]                               main_rd_data_i,
  output logic                                      skip_rd_en_o,
  output logic [$clog2(MAX_TENSOR_WORDS)-1:0]       skip_rd_addr_o,
  input  logic [31:0]                               skip_rd_data_i,

  output logic                                      output_we_o,
  output logic [$clog2(MAX_TENSOR_WORDS)-1:0]       output_waddr_o,
  output logic [31:0]                               output_wdata_o
);
  typedef enum logic [1:0] {
    RES_IDLE,
    RES_READ,
    RES_WRITE
  } residual_state_t;

  residual_state_t state_q;
  logic [$clog2(MAX_TENSOR_WORDS)-1:0] word_index_q;
  logic [31:0] word_count_q;

  function automatic logic [7:0] add_lane(
    input logic [7:0] main_lane,
    input logic [7:0] skip_lane,
    input logic       relu_enable
  );
    logic signed [31:0] main_i32;
    logic signed [31:0] skip_i32;
    logic signed [31:0] sum_i32;
    begin
      main_i32 = {{24{main_lane[7]}}, main_lane};
      skip_i32 = {{24{skip_lane[7]}}, skip_lane};
      sum_i32  = main_i32 + skip_i32;

      if (relu_enable && (sum_i32 < 0))
        add_lane = 8'h00;
      else if (sum_i32 > 32'sd127)
        add_lane = 8'h7f;
      else if (sum_i32 < -32'sd128)
        add_lane = 8'h80;
      else
        add_lane = sum_i32[7:0];
    end
  endfunction

  always_comb begin
    busy_o = (state_q != RES_IDLE);

    main_rd_en_o   = (state_q == RES_READ);
    main_rd_addr_o = word_index_q;
    skip_rd_en_o   = (state_q == RES_READ);
    skip_rd_addr_o = word_index_q;

    output_we_o    = (state_q == RES_WRITE);
    output_waddr_o = word_index_q;
    output_wdata_o = {
      add_lane(main_rd_data_i[31:24], skip_rd_data_i[31:24], relu_enable_i),
      add_lane(main_rd_data_i[23:16], skip_rd_data_i[23:16], relu_enable_i),
      add_lane(main_rd_data_i[15:8],  skip_rd_data_i[15:8],  relu_enable_i),
      add_lane(main_rd_data_i[7:0],   skip_rd_data_i[7:0],   relu_enable_i)
    };
  end

  always_ff @(posedge clk_i) begin
    if (!aresetn_i) begin
      state_q      <= RES_IDLE;
      word_index_q <= '0;
      word_count_q <= 32'd0;
      done_o       <= 1'b0;
    end else if (abort_i) begin
      state_q      <= RES_IDLE;
      word_index_q <= '0;
      word_count_q <= 32'd0;
      done_o       <= 1'b0;
    end else begin
      done_o <= 1'b0;
      case (state_q)
        RES_IDLE: begin
          if (start_i) begin
            word_index_q <= '0;
            word_count_q <= tensor_bytes_i >> 2;
            state_q      <= RES_READ;
          end
        end

        RES_READ: state_q <= RES_WRITE;

        RES_WRITE: begin
          if ({1'b0, word_index_q} + 1 >= word_count_q) begin
            done_o <= 1'b1;
            state_q <= RES_IDLE;
          end else begin
            word_index_q <= word_index_q + 1'b1;
            state_q      <= RES_READ;
          end
        end

        default: state_q <= RES_IDLE;
      endcase
    end
  end
endmodule
