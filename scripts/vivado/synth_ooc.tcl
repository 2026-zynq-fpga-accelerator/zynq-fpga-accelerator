set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]

if {$argc >= 1 && [string length [lindex $argv 0]] > 0} {
  set fpga_part [lindex $argv 0]
} elseif {[info exists ::env(FPGA_PART)] && [string length $::env(FPGA_PART)] > 0} {
  set fpga_part $::env(FPGA_PART)
} else {
  puts stderr "ERROR: FPGA_PART is required as tclargs argument 1 or environment variable FPGA_PART"
  exit 2
}

if {$argc >= 2 && [string length [lindex $argv 1]] > 0} {
  set clock_period_ns [lindex $argv 1]
} elseif {[info exists ::env(CLK_PERIOD_NS)] && [string length $::env(CLK_PERIOD_NS)] > 0} {
  set clock_period_ns $::env(CLK_PERIOD_NS)
} else {
  puts stderr "ERROR: CLK_PERIOD_NS is required as tclargs argument 2 or environment variable CLK_PERIOD_NS"
  exit 3
}

if {![string is double -strict $clock_period_ns] || $clock_period_ns <= 0} {
  puts stderr "ERROR: CLK_PERIOD_NS must be a positive number, got '$clock_period_ns'"
  exit 4
}

set rtl_sources [list \
  rtl/common/accel_pkg.sv \
  rtl/common/sat_add_int32.sv \
  rtl/common/requantizer.sv \
  rtl/common/relu_clamp.sv \
  rtl/compute/tensor_buffers.sv \
  rtl/compute/conv_engine.sv \
  rtl/stream/axis_packet_loader.sv \
  rtl/stream/axis_output_streamer.sv \
  rtl/control/axi_lite_regs.sv \
  rtl/control/controller_fsm.sv \
  rtl/control/error_ctrl.sv \
  rtl/control/cycle_counter.sv \
  rtl/top/resnet_accel_top.sv]

cd $repo_root
set safe_part [string map {"/" "_" "\\" "_" ":" "_"} $fpga_part]
set output_dir [file normalize [file join $repo_root build synth_ooc $safe_part]]
file mkdir $output_dir

foreach source $rtl_sources {
  read_verilog -sv $source
}

puts "INFO: OOC synthesis top=resnet_accel_top part=$fpga_part clock=${clock_period_ns}ns"
synth_design -top resnet_accel_top -part $fpga_part -mode out_of_context
create_clock -name aclk -period $clock_period_ns [get_ports aclk]

write_checkpoint -force [file join $output_dir resnet_accel_top_synth.dcp]
report_utilization -hierarchical -file [file join $output_dir utilization_hierarchical.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
  -file [file join $output_dir timing_summary.rpt]
report_methodology -file [file join $output_dir methodology.rpt]

set inference_file [open [file join $output_dir ram_dsp_inference.rpt] w]
set bram_cells [get_cells -quiet -hierarchical -filter {REF_NAME =~ RAMB*}]
set dsp_cells [get_cells -quiet -hierarchical -filter {REF_NAME =~ DSP*}]
puts $inference_file "FPGA_PART=$fpga_part"
puts $inference_file "CLK_PERIOD_NS=$clock_period_ns"
puts $inference_file "BRAM_CELL_COUNT=[llength $bram_cells]"
puts $inference_file "DSP_CELL_COUNT=[llength $dsp_cells]"
puts $inference_file "BRAM_CELLS=$bram_cells"
puts $inference_file "DSP_CELLS=$dsp_cells"
close $inference_file

puts "INFO: OOC synthesis reports written to $output_dir"
exit 0
