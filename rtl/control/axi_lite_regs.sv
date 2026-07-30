`timescale 1ns/1ps

module axi_lite_regs #(
  parameter integer AXI_ADDR_WIDTH = 7
) (
  input  logic                      aclk_i,
  input  logic                      aresetn_i,

  input  logic [AXI_ADDR_WIDTH-1:0] s_axi_awaddr_i,
  input  logic                      s_axi_awvalid_i,
  output logic                      s_axi_awready_o,
  input  logic [31:0]               s_axi_wdata_i,
  input  logic  [3:0]               s_axi_wstrb_i,
  input  logic                      s_axi_wvalid_i,
  output logic                      s_axi_wready_o,
  output logic  [1:0]               s_axi_bresp_o,
  output logic                      s_axi_bvalid_o,
  input  logic                      s_axi_bready_i,

  input  logic [AXI_ADDR_WIDTH-1:0] s_axi_araddr_i,
  input  logic                      s_axi_arvalid_i,
  output logic                      s_axi_arready_o,
  output logic [31:0]               s_axi_rdata_o,
  output logic  [1:0]               s_axi_rresp_o,
  output logic                      s_axi_rvalid_o,
  input  logic                      s_axi_rready_i,

  input  logic                      idle_i,
  input  logic                      busy_i,
  input  logic                      done_i,
  input  logic                      error_i,
  input  logic [31:0]               cycle_count_i,
  input  logic [31:0]               error_code_i,
  input  logic  [3:0]               debug_state_i,

  output logic                      start_pulse_o,
  output logic                      abort_pulse_o,
  output logic                      done_clear_pulse_o,
  output logic                      error_clear_pulse_o,
  output logic                      start_while_busy_event_o,
  output logic                      config_write_busy_event_o,
  output logic                      invalid_address_event_o,
  output logic                      abort_error_event_o,

  output logic [31:0]               operation_o,
  output logic [31:0]               input_height_o,
  output logic [31:0]               input_width_o,
  output logic [31:0]               in_channels_o,
  output logic [31:0]               out_channels_o,
  output logic [31:0]               conv_config_o,
  output logic [31:0]               output_scale_o,
  output logic [31:0]               input_bytes_o,
  output logic [31:0]               weight_bytes_o,
  output logic [31:0]               bias_bytes_o,
  output logic [31:0]               skip_bytes_o,
  output logic [31:0]               output_bytes_o
);
  import accel_pkg::*;

  logic [AXI_ADDR_WIDTH-1:0] awaddr_hold_q;
  logic [31:0]               wdata_hold_q;
  logic  [3:0]               wstrb_hold_q;
  logic                      aw_hold_valid_q;
  logic                      w_hold_valid_q;
  logic [31:0]               read_data_mux;

  function automatic logic [31:0] apply_wstrb(
    input logic [31:0] old_value,
    input logic [31:0] new_value,
    input logic  [3:0] strobes
  );
    logic [31:0] merged;
    integer byte_index;
    begin
      merged = old_value;
      for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
        if (strobes[byte_index])
          merged[byte_index*8 +: 8] = new_value[byte_index*8 +: 8];
      apply_wstrb = merged;
    end
  endfunction

  always_comb begin
    s_axi_awready_o = !aw_hold_valid_q && !s_axi_bvalid_o;
    s_axi_wready_o  = !w_hold_valid_q && !s_axi_bvalid_o;
    s_axi_bresp_o   = 2'b00;
    s_axi_arready_o = !s_axi_rvalid_o;
    s_axi_rresp_o   = 2'b00;

    case (s_axi_araddr_i[6:0])
      REG_CONTROL:      read_data_mux = 32'd0;
      REG_STATUS:       read_data_mux = {28'd0, error_i, done_i, busy_i, idle_i};
      REG_OPERATION:    read_data_mux = operation_o;
      REG_INPUT_HEIGHT: read_data_mux = input_height_o;
      REG_INPUT_WIDTH:  read_data_mux = input_width_o;
      REG_IN_CHANNELS:  read_data_mux = in_channels_o;
      REG_OUT_CHANNELS: read_data_mux = out_channels_o;
      REG_CONV_CONFIG:  read_data_mux = conv_config_o;
      REG_OUTPUT_SCALE: read_data_mux = output_scale_o;
      REG_INPUT_BYTES:  read_data_mux = input_bytes_o;
      REG_WEIGHT_BYTES: read_data_mux = weight_bytes_o;
      REG_BIAS_BYTES:   read_data_mux = bias_bytes_o;
      REG_SKIP_BYTES:   read_data_mux = skip_bytes_o;
      REG_OUTPUT_BYTES: read_data_mux = output_bytes_o;
      REG_CYCLE_COUNT:  read_data_mux = cycle_count_i;
      REG_ERROR_CODE:   read_data_mux = error_code_i;
      REG_VERSION:      read_data_mux = INTERFACE_VERSION;
      REG_DEBUG_STATE:  read_data_mux = {28'd0, debug_state_i};
      default:          read_data_mux = 32'd0;
    endcase
  end

  always_ff @(posedge aclk_i) begin
    if (!aresetn_i) begin
      awaddr_hold_q              <= '0;
      wdata_hold_q               <= 32'd0;
      wstrb_hold_q               <= 4'd0;
      aw_hold_valid_q            <= 1'b0;
      w_hold_valid_q             <= 1'b0;
      s_axi_bvalid_o             <= 1'b0;
      s_axi_rdata_o              <= 32'd0;
      s_axi_rvalid_o             <= 1'b0;

      start_pulse_o              <= 1'b0;
      abort_pulse_o              <= 1'b0;
      done_clear_pulse_o         <= 1'b0;
      error_clear_pulse_o        <= 1'b0;
      start_while_busy_event_o   <= 1'b0;
      config_write_busy_event_o  <= 1'b0;
      invalid_address_event_o    <= 1'b0;
      abort_error_event_o        <= 1'b0;

      operation_o                <= 32'd0;
      input_height_o             <= 32'd0;
      input_width_o              <= 32'd0;
      in_channels_o              <= 32'd0;
      out_channels_o             <= 32'd0;
      conv_config_o              <= 32'd0;
      output_scale_o             <= 32'd0;
      input_bytes_o              <= 32'd0;
      weight_bytes_o             <= 32'd0;
      bias_bytes_o               <= 32'd0;
      skip_bytes_o               <= 32'd0;
      output_bytes_o             <= 32'd0;
    end else begin
      start_pulse_o             <= 1'b0;
      abort_pulse_o             <= 1'b0;
      done_clear_pulse_o        <= 1'b0;
      error_clear_pulse_o       <= 1'b0;
      start_while_busy_event_o  <= 1'b0;
      config_write_busy_event_o <= 1'b0;
      invalid_address_event_o   <= 1'b0;
      abort_error_event_o       <= 1'b0;

      if (s_axi_awvalid_i && s_axi_awready_o) begin
        awaddr_hold_q   <= s_axi_awaddr_i;
        aw_hold_valid_q <= 1'b1;
      end

      if (s_axi_wvalid_i && s_axi_wready_o) begin
        wdata_hold_q    <= s_axi_wdata_i;
        wstrb_hold_q    <= s_axi_wstrb_i;
        w_hold_valid_q  <= 1'b1;
      end

      if (aw_hold_valid_q && w_hold_valid_q && !s_axi_bvalid_o) begin
        aw_hold_valid_q <= 1'b0;
        w_hold_valid_q  <= 1'b0;
        s_axi_bvalid_o  <= 1'b1;

        case (awaddr_hold_q[6:0])
          REG_CONTROL: begin
            if (wstrb_hold_q[0]) begin
              if (wdata_hold_q[1]) begin
                abort_pulse_o <= 1'b1;
                if (busy_i || wdata_hold_q[0])
                  abort_error_event_o <= 1'b1;
              end else if (wdata_hold_q[0]) begin
                if (busy_i)
                  start_while_busy_event_o <= 1'b1;
                else
                  start_pulse_o <= 1'b1;
              end
            end
          end

          REG_STATUS: begin
            if (wstrb_hold_q[0]) begin
              if (wdata_hold_q[2])
                done_clear_pulse_o <= 1'b1;
              if (wdata_hold_q[3])
                error_clear_pulse_o <= 1'b1;
            end
          end

          REG_OPERATION: begin
            if (busy_i)
              config_write_busy_event_o <= 1'b1;
            else
              operation_o <= apply_wstrb(operation_o, wdata_hold_q, wstrb_hold_q);
          end

          REG_INPUT_HEIGHT: begin
            if (busy_i)
              config_write_busy_event_o <= 1'b1;
            else
              input_height_o <= apply_wstrb(input_height_o, wdata_hold_q, wstrb_hold_q);
          end

          REG_INPUT_WIDTH: begin
            if (busy_i)
              config_write_busy_event_o <= 1'b1;
            else
              input_width_o <= apply_wstrb(input_width_o, wdata_hold_q, wstrb_hold_q);
          end

          REG_IN_CHANNELS: begin
            if (busy_i)
              config_write_busy_event_o <= 1'b1;
            else
              in_channels_o <= apply_wstrb(in_channels_o, wdata_hold_q, wstrb_hold_q);
          end

          REG_OUT_CHANNELS: begin
            if (busy_i)
              config_write_busy_event_o <= 1'b1;
            else
              out_channels_o <= apply_wstrb(out_channels_o, wdata_hold_q, wstrb_hold_q);
          end

          REG_CONV_CONFIG: begin
            if (busy_i)
              config_write_busy_event_o <= 1'b1;
            else
              conv_config_o <= apply_wstrb(conv_config_o, wdata_hold_q, wstrb_hold_q);
          end

          REG_OUTPUT_SCALE: begin
            if (busy_i)
              config_write_busy_event_o <= 1'b1;
            else
              output_scale_o <= apply_wstrb(output_scale_o, wdata_hold_q, wstrb_hold_q);
          end

          REG_INPUT_BYTES: begin
            if (busy_i)
              config_write_busy_event_o <= 1'b1;
            else
              input_bytes_o <= apply_wstrb(input_bytes_o, wdata_hold_q, wstrb_hold_q);
          end

          REG_WEIGHT_BYTES: begin
            if (busy_i)
              config_write_busy_event_o <= 1'b1;
            else
              weight_bytes_o <= apply_wstrb(weight_bytes_o, wdata_hold_q, wstrb_hold_q);
          end

          REG_BIAS_BYTES: begin
            if (busy_i)
              config_write_busy_event_o <= 1'b1;
            else
              bias_bytes_o <= apply_wstrb(bias_bytes_o, wdata_hold_q, wstrb_hold_q);
          end

          REG_SKIP_BYTES: begin
            if (busy_i)
              config_write_busy_event_o <= 1'b1;
            else
              skip_bytes_o <= apply_wstrb(skip_bytes_o, wdata_hold_q, wstrb_hold_q);
          end

          REG_OUTPUT_BYTES: begin
            if (busy_i)
              config_write_busy_event_o <= 1'b1;
            else
              output_bytes_o <= apply_wstrb(output_bytes_o, wdata_hold_q, wstrb_hold_q);
          end

          REG_CYCLE_COUNT,
          REG_ERROR_CODE,
          REG_VERSION,
          REG_DEBUG_STATE: begin
            // Read-only writes are ignored with an OKAY response.
          end

          default: invalid_address_event_o <= 1'b1;
        endcase
      end

      if (s_axi_bvalid_o && s_axi_bready_i)
        s_axi_bvalid_o <= 1'b0;

      if (s_axi_arvalid_i && s_axi_arready_o) begin
        s_axi_rdata_o  <= read_data_mux;
        s_axi_rvalid_o <= 1'b1;
      end else if (s_axi_rvalid_o && s_axi_rready_i) begin
        s_axi_rvalid_o <= 1'b0;
      end
    end
  end
endmodule

