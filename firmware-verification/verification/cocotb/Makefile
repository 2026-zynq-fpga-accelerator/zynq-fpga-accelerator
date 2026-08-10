# cocotb regression against real RTL (verification/../rtl/, integration/zybo-bootbin
# branch). Was accel_ref_model.sv (the behavioral reference model, still kept at
# verification/rtl_ref/ as a golden comparison point); swap back by restoring the single-file
# VERILOG_SOURCES/TOPLEVEL below if a regression against the golden model is needed again.
SIM ?= icarus
TOPLEVEL_LANG ?= verilog

RTL_DIR = $(shell pwd)/../../../rtl/rtl
VERILOG_SOURCES = $(RTL_DIR)/common/accel_pkg.sv \
                   $(RTL_DIR)/common/relu_clamp.sv \
                   $(RTL_DIR)/common/requantizer.sv \
                   $(RTL_DIR)/common/sat_add_int32.sv \
                   $(RTL_DIR)/compute/tensor_buffers.sv \
                   $(RTL_DIR)/compute/conv_engine.sv \
                   $(RTL_DIR)/compute/residual_add_engine.sv \
                   $(RTL_DIR)/control/axi_lite_regs.sv \
                   $(RTL_DIR)/control/error_ctrl.sv \
                   $(RTL_DIR)/control/cycle_counter.sv \
                   $(RTL_DIR)/control/controller_fsm.sv \
                   $(RTL_DIR)/stream/axis_packet_loader.sv \
                   $(RTL_DIR)/stream/axis_output_streamer.sv \
                   $(RTL_DIR)/top/resnet_accel_top.sv
TOPLEVEL = resnet_accel_top
MODULE = test_accel_conv

COCOTB_HDL_TIMEUNIT = 1ns
COCOTB_HDL_TIMEPRECISION = 1ps

COMPILE_ARGS += -g2012

include $(shell cocotb-config --makefiles)/Makefile.sim
