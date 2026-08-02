`timescale 1ns/1ps

// Preserve the existing smoke and full-convolution test bodies. This adapter
// presents the legacy core port names used by those tests while routing every
// transaction through the packaged-IP wrapper. Non-zero protection values also
// verify that AWPROT/ARPROT do not alter the v1.1 register behavior.
module resnet_accel_wrapper_test_adapter #(
  parameter integer AXI_ADDR_WIDTH    = 7,
  parameter integer MAX_WEIGHT_WORDS  = 9216,
  parameter integer MAX_BIAS_WORDS    = 64,
  parameter integer MAX_INPUT_WORDS   = 4096,
  parameter integer MAX_OUTPUT_WORDS  = 4096
) (
  input  logic                      aclk,
  input  logic                      aresetn,
  input  logic [AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
  input  logic                      s_axi_awvalid,
  output logic                      s_axi_awready,
  input  logic [31:0]               s_axi_wdata,
  input  logic [3:0]                s_axi_wstrb,
  input  logic                      s_axi_wvalid,
  output logic                      s_axi_wready,
  output logic [1:0]                s_axi_bresp,
  output logic                      s_axi_bvalid,
  input  logic                      s_axi_bready,
  input  logic [AXI_ADDR_WIDTH-1:0] s_axi_araddr,
  input  logic                      s_axi_arvalid,
  output logic                      s_axi_arready,
  output logic [31:0]               s_axi_rdata,
  output logic [1:0]                s_axi_rresp,
  output logic                      s_axi_rvalid,
  input  logic                      s_axi_rready,
  input  logic [31:0]               s_axis_tdata,
  input  logic [3:0]                s_axis_tkeep,
  input  logic                      s_axis_tlast,
  input  logic                      s_axis_tvalid,
  output logic                      s_axis_tready,
  output logic [31:0]               m_axis_tdata,
  output logic [3:0]                m_axis_tkeep,
  output logic                      m_axis_tlast,
  output logic                      m_axis_tvalid,
  input  logic                      m_axis_tready
);
  logic busy;
  logic done;
  logic error;
  logic [3:0] debug_state;

  resnet_accel_ip_wrapper #(
    .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
    .MAX_WEIGHT_WORDS(MAX_WEIGHT_WORDS),
    .MAX_BIAS_WORDS(MAX_BIAS_WORDS),
    .MAX_INPUT_WORDS(MAX_INPUT_WORDS),
    .MAX_OUTPUT_WORDS(MAX_OUTPUT_WORDS)
  ) dut_wrapper (
    .aclk(aclk),
    .aresetn(aresetn),
    .s_axi_ctrl_awaddr(s_axi_awaddr),
    .s_axi_ctrl_awprot(3'b101),
    .s_axi_ctrl_awvalid(s_axi_awvalid),
    .s_axi_ctrl_awready(s_axi_awready),
    .s_axi_ctrl_wdata(s_axi_wdata),
    .s_axi_ctrl_wstrb(s_axi_wstrb),
    .s_axi_ctrl_wvalid(s_axi_wvalid),
    .s_axi_ctrl_wready(s_axi_wready),
    .s_axi_ctrl_bresp(s_axi_bresp),
    .s_axi_ctrl_bvalid(s_axi_bvalid),
    .s_axi_ctrl_bready(s_axi_bready),
    .s_axi_ctrl_araddr(s_axi_araddr),
    .s_axi_ctrl_arprot(3'b010),
    .s_axi_ctrl_arvalid(s_axi_arvalid),
    .s_axi_ctrl_arready(s_axi_arready),
    .s_axi_ctrl_rdata(s_axi_rdata),
    .s_axi_ctrl_rresp(s_axi_rresp),
    .s_axi_ctrl_rvalid(s_axi_rvalid),
    .s_axi_ctrl_rready(s_axi_rready),
    .s_axis_input_tdata(s_axis_tdata),
    .s_axis_input_tkeep(s_axis_tkeep),
    .s_axis_input_tlast(s_axis_tlast),
    .s_axis_input_tvalid(s_axis_tvalid),
    .s_axis_input_tready(s_axis_tready),
    .m_axis_output_tdata(m_axis_tdata),
    .m_axis_output_tkeep(m_axis_tkeep),
    .m_axis_output_tlast(m_axis_tlast),
    .m_axis_output_tvalid(m_axis_tvalid),
    .m_axis_output_tready(m_axis_tready)
  );

  assign busy = dut_wrapper.u_core.busy;
  assign done = dut_wrapper.u_core.done;
  assign error = dut_wrapper.u_core.error;
  assign debug_state = dut_wrapper.u_core.debug_state;
endmodule

`include "tb/tb_resnet_accel_top.sv"
`include "tb/tb_full_conv.sv"

config tb_resnet_accel_ip_wrapper;
  design work.tb_resnet_accel_top;
  instance tb_resnet_accel_top.dut
    use work.resnet_accel_wrapper_test_adapter;
endconfig

config tb_resnet_accel_ip_wrapper_full_conv;
  design work.tb_full_conv;
  instance tb_full_conv.dut
    use work.resnet_accel_wrapper_test_adapter;
endconfig
