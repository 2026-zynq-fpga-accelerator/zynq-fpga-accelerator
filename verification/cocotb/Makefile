# cocotb regression against verification/rtl_ref/accel_ref_model.sv (the behavioral
# reference model, see that file's header comment). Swap VERILOG_SOURCES/TOPLEVEL to
# 황정민 학생's real RTL once it lands in this repo and re-run as regression.
SIM ?= icarus
TOPLEVEL_LANG ?= verilog

VERILOG_SOURCES = $(shell pwd)/../rtl_ref/accel_ref_model.sv
TOPLEVEL = accel_ref_model
MODULE = test_accel_conv

COCOTB_HDL_TIMEUNIT = 1ns
COCOTB_HDL_TIMEPRECISION = 1ps

COMPILE_ARGS += -g2012

include $(shell cocotb-config --makefiles)/Makefile.sim
