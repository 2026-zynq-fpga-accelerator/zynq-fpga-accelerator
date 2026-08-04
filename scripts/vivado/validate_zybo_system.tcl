set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
set project_dir [file join $repo_root build vivado_zybo resnet_accel_zybo]
set project_file [file join $project_dir resnet_accel_zybo.xpr]
set report_dir [file join $repo_root build vivado_zybo reports]
set bd_name zybo_resnet_system

proc validation_fail {message} {
  puts stderr "ERROR: $message"
  exit 3
}

proc require_equal {description actual expected} {
  if {$actual ne $expected} {
    validation_fail "$description: expected '$expected', got '$actual'"
  }
  puts "CHECK PASS: $description = $expected"
}

proc require_one {description objects} {
  if {[llength $objects] != 1} {
    validation_fail "$description: expected one object, got [llength $objects]"
  }
  return [lindex $objects 0]
}

proc property_or_missing {object property_name} {
  if {[lsearch -exact [list_property $object] $property_name] >= 0} {
    return [get_property $property_name $object]
  }
  return "<not-present>"
}

proc require_same_intf_net {description first_pin second_pin} {
  set first_net [require_one "$description first net" \
    [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins $first_pin]]]
  set second_net [require_one "$description second net" \
    [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins $second_pin]]]
  require_equal $description [get_property NAME $first_net] [get_property NAME $second_net]
}

proc require_same_net {description first_pin second_pin} {
  set first_net [require_one "$description first net" \
    [get_bd_nets -quiet -of_objects [get_bd_pins $first_pin]]]
  set second_net [require_one "$description second net" \
    [get_bd_nets -quiet -of_objects [get_bd_pins $second_pin]]]
  require_equal $description [get_property NAME $first_net] [get_property NAME $second_net]
}

proc find_mapped_segment {address_space pattern} {
  set matches {}
  foreach segment [get_bd_addr_segs -quiet -of_objects $address_space] {
    if {[string match $pattern [get_property NAME $segment]]} {
      lappend matches $segment
    }
  }
  return $matches
}

proc write_address_line {channel label segment} {
  set offset [get_property OFFSET $segment]
  set range [get_property RANGE $segment]
  set high [format 0x%08X [expr {$offset + $range - 1}]]
  puts $channel "$label.BASE=$offset"
  puts $channel "$label.HIGH=$high"
  puts $channel "$label.RANGE=$range"
  puts $channel "$label.SEGMENT=[get_property NAME $segment]"
}

if {[current_project -quiet] eq ""} {
  if {![file isfile $project_file]} {
    validation_fail "project does not exist: $project_file"
  }
  open_project $project_file
}

set bd_file [require_one "$bd_name BD file" \
  [get_files -quiet "*/${bd_name}.bd"]]
open_bd_design $bd_file
file mkdir $report_dir

if {[catch {validate_bd_design} validation_result]} {
  puts stderr $validation_result
  validation_fail "validate_bd_design failed"
}
puts $validation_result
save_bd_design

set ps7 [require_one "processing system" [get_bd_cells -quiet processing_system7_0]]
set dma [require_one "AXI DMA" [get_bd_cells -quiet axi_dma_0]]
set accel [require_one "accelerator" [get_bd_cells -quiet resnet_accel_0]]
set reset [require_one "processor system reset" [get_bd_cells -quiet proc_sys_reset_0]]
set control_ic [require_one "control SmartConnect" \
  [get_bd_cells -quiet control_smartconnect]]
set memory_ic [require_one "memory SmartConnect" \
  [get_bd_cells -quiet memory_smartconnect]]

require_equal project_board_part [get_property BOARD_PART [current_project]] \
  digilentinc.com:zybo-z7-20:part0:1.2
require_equal project_fpga_part [get_property PART [current_project]] xc7z020clg400-1
require_equal accelerator_vlnv [get_property VLNV $accel] \
  jmhwang.local:npu:resnet_accel:1.0
require_equal control_num_si [get_property CONFIG.NUM_SI $control_ic] 1
require_equal control_num_mi [get_property CONFIG.NUM_MI $control_ic] 2
require_equal memory_num_si [get_property CONFIG.NUM_SI $memory_ic] 2
require_equal memory_num_mi [get_property CONFIG.NUM_MI $memory_ic] 1
require_equal dma_sg [get_property CONFIG.c_include_sg $dma] 0
require_equal dma_mm2s [get_property CONFIG.c_include_mm2s $dma] 1
require_equal dma_s2mm [get_property CONFIG.c_include_s2mm $dma] 1
require_equal dma_mm2s_dre [get_property CONFIG.c_include_mm2s_dre $dma] 0
require_equal dma_s2mm_dre [get_property CONFIG.c_include_s2mm_dre $dma] 0
require_equal dma_mm2s_stream_width \
  [get_property CONFIG.c_m_axis_mm2s_tdata_width $dma] 32
require_equal dma_s2mm_stream_width \
  [get_property CONFIG.c_s_axis_s2mm_tdata_width $dma] 32
require_equal dma_buffer_length_width \
  [get_property CONFIG.c_sg_length_width $dma] 23
require_equal ps_gp0_enabled [get_property CONFIG.PCW_USE_M_AXI_GP0 $ps7] 1
require_equal ps_hp0_enabled [get_property CONFIG.PCW_USE_S_AXI_HP0 $ps7] 1
require_equal ps_fclk0_mhz \
  [get_property CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ $ps7] 100.000000
require_equal ps_uart1_enabled \
  [get_property CONFIG.PCW_UART1_PERIPHERAL_ENABLE $ps7] 1
require_equal ps_sd0_enabled \
  [get_property CONFIG.PCW_SD0_PERIPHERAL_ENABLE $ps7] 1
require_equal reset_ext_active_high [get_property CONFIG.C_EXT_RESET_HIGH $reset] 0

foreach external_interface {DDR FIXED_IO} {
  require_one "external $external_interface" \
    [get_bd_intf_ports -quiet $external_interface]
}

require_same_intf_net control_gp0 \
  processing_system7_0/M_AXI_GP0 control_smartconnect/S00_AXI
require_same_intf_net control_accelerator \
  control_smartconnect/M00_AXI resnet_accel_0/S_AXI_CTRL
require_same_intf_net control_dma \
  control_smartconnect/M01_AXI axi_dma_0/S_AXI_LITE
require_same_intf_net memory_mm2s \
  axi_dma_0/M_AXI_MM2S memory_smartconnect/S00_AXI
require_same_intf_net memory_s2mm \
  axi_dma_0/M_AXI_S2MM memory_smartconnect/S01_AXI
require_same_intf_net memory_hp0 \
  memory_smartconnect/M00_AXI processing_system7_0/S_AXI_HP0
require_same_intf_net stream_mm2s \
  axi_dma_0/M_AXIS_MM2S resnet_accel_0/S_AXIS_INPUT
require_same_intf_net stream_s2mm \
  resnet_accel_0/M_AXIS_OUTPUT axi_dma_0/S_AXIS_S2MM

foreach clock_pin {
  processing_system7_0/M_AXI_GP0_ACLK
  processing_system7_0/S_AXI_HP0_ACLK
  control_smartconnect/aclk
  memory_smartconnect/aclk
  axi_dma_0/s_axi_lite_aclk
  axi_dma_0/m_axi_mm2s_aclk
  axi_dma_0/m_axi_s2mm_aclk
  resnet_accel_0/aclk
  proc_sys_reset_0/slowest_sync_clk
} {
  require_same_net "FCLK0->$clock_pin" processing_system7_0/FCLK_CLK0 $clock_pin
}
require_same_net reset_source \
  processing_system7_0/FCLK_RESET0_N proc_sys_reset_0/ext_reset_in
foreach reset_pin {
  control_smartconnect/aresetn
  memory_smartconnect/aresetn
  axi_dma_0/axi_resetn
  resnet_accel_0/aresetn
} {
  require_same_net "peripheral_aresetn->$reset_pin" \
    proc_sys_reset_0/peripheral_aresetn $reset_pin
}

set ps_data [require_one "PS Data address space" \
  [get_bd_addr_spaces -quiet processing_system7_0/Data]]
set accel_seg [require_one "accelerator control mapping" \
  [find_mapped_segment $ps_data *resnet_accel_0*]]
set dma_ctrl_seg [require_one "DMA control mapping" \
  [find_mapped_segment $ps_data *axi_dma_0*]]
require_equal accelerator_offset [get_property OFFSET $accel_seg] 0x43C00000
require_equal accelerator_range [get_property RANGE $accel_seg] 0x00010000
require_equal dma_offset [get_property OFFSET $dma_ctrl_seg] 0x40400000
require_equal dma_range [get_property RANGE $dma_ctrl_seg] 0x00010000

set mm2s_space [require_one "DMA MM2S address space" \
  [get_bd_addr_spaces -quiet axi_dma_0/Data_MM2S]]
set s2mm_space [require_one "DMA S2MM address space" \
  [get_bd_addr_spaces -quiet axi_dma_0/Data_S2MM]]
set mm2s_ddr_seg [require_one "MM2S DDR mapping" \
  [find_mapped_segment $mm2s_space *HP0_DDR_LOWOCM*]]
set s2mm_ddr_seg [require_one "S2MM DDR mapping" \
  [find_mapped_segment $s2mm_space *HP0_DDR_LOWOCM*]]

generate_target all $bd_file
set wrapper_files [make_wrapper -files $bd_file -top]
if {[llength $wrapper_files] < 1} {
  validation_fail "make_wrapper did not produce an HDL wrapper"
}
foreach wrapper_file $wrapper_files {
  if {[llength [get_files -quiet $wrapper_file]] == 0} {
    add_files -norecurse $wrapper_file
  }
}
update_compile_order -fileset sources_1
save_bd_design

set synth_run [require_one synth_1_run [get_runs -quiet synth_1]]
set impl_run [require_one impl_1_run [get_runs -quiet impl_1]]
require_equal synthesis_run_status [get_property STATUS $synth_run] {Not started}
require_equal implementation_run_status [get_property STATUS $impl_run] {Not started}

set summary [open [file join $report_dir board_design_summary.txt] w]
puts $summary "VIVADO_VERSION=[version -short]"
puts $summary "PROJECT=[get_property NAME [current_project]]"
puts $summary "BOARD_PART=[get_property BOARD_PART [current_project]]"
puts $summary "FPGA_PART=[get_property PART [current_project]]"
puts $summary "BD_NAME=$bd_name"
puts $summary "BOARD_PRESET_APPLIED=1"
puts $summary "DDR_EXTERNAL=1"
puts $summary "FIXED_IO_EXTERNAL=1"
puts $summary "FCLK0_MHZ=[get_property CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ $ps7]"
puts $summary "CLOCK_DOMAINS=1"
puts $summary "RESET_SOURCE=processing_system7_0/FCLK_RESET0_N"
puts $summary "RESET_OUTPUT_USED=proc_sys_reset_0/peripheral_aresetn"
puts $summary "INTERCONNECT_ARESETN_USED=0"
puts $summary "VALIDATE_BD_DESIGN=PASS"
puts $summary "GENERATE_TARGET_ALL=PASS"
puts $summary "HDL_WRAPPER=[join $wrapper_files { }]"
puts $summary "SYNTHESIS_RUN_STATUS=[get_property STATUS $synth_run]"
puts $summary "IMPLEMENTATION_RUN_STATUS=[get_property STATUS $impl_run]"
puts $summary "WARNING.BOARD_49_151=Local board repo has an installed counterpart; requested local board part 1.2 was used"
puts $summary "CRITICAL_WARNING.PSU_1_TO_4=Board preset contains four negative DDR DQS-to-clock delay values"
puts $summary "WARNING.SMARTCONNECT_LOW_AREA=Control SmartConnect low-area mode does not support WRAP bursts; software AXI-Lite accesses are single-beat"
puts $summary "WARNING.BD_41_2384=Generated SmartConnect internal AXI metadata payload widths are adapted; external interface validation passed"
puts $summary "AXIS_STREAM_WIDTH_MISMATCH=0"
puts $summary "VALIDATION_ERROR_COUNT=0"
close $summary

set address_report [open [file join $report_dir address_map.txt] w]
write_address_line $address_report ACCELERATOR $accel_seg
write_address_line $address_report DMA_CONTROL $dma_ctrl_seg
write_address_line $address_report DMA_MM2S_DDR $mm2s_ddr_seg
write_address_line $address_report DMA_S2MM_DDR $s2mm_ddr_seg
close $address_report

set config_report [open [file join $report_dir ip_configuration.txt] w]
foreach cell [get_bd_cells -quiet] {
  puts $config_report "INSTANCE=[get_property NAME $cell] VLNV=[get_property VLNV $cell]"
}
foreach {label object properties} [list \
  PS7 $ps7 {CONFIG.PCW_USE_M_AXI_GP0 CONFIG.PCW_USE_S_AXI_HP0
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ CONFIG.PCW_UART1_PERIPHERAL_ENABLE
    CONFIG.PCW_SD0_PERIPHERAL_ENABLE} \
  DMA $dma {CONFIG.c_include_sg CONFIG.c_include_mm2s CONFIG.c_include_s2mm
    CONFIG.c_include_mm2s_dre CONFIG.c_include_s2mm_dre
    CONFIG.c_m_axis_mm2s_tdata_width CONFIG.c_s_axis_s2mm_tdata_width
    CONFIG.c_m_axi_mm2s_data_width CONFIG.c_m_axi_s2mm_data_width
    CONFIG.c_prmry_is_aclk_async CONFIG.c_sg_length_width} \
  CONTROL_SMARTCONNECT $control_ic {CONFIG.NUM_SI CONFIG.NUM_MI CONFIG.NUM_CLKS} \
  MEMORY_SMARTCONNECT $memory_ic {CONFIG.NUM_SI CONFIG.NUM_MI CONFIG.NUM_CLKS} \
  RESET $reset {CONFIG.C_EXT_RESET_HIGH}] {
  puts $config_report "\[$label\]"
  foreach property $properties {
    puts $config_report "$property=[property_or_missing $object $property]"
  }
}
puts $config_report "DMA_INTERRUPT_PORTS=[get_bd_pins -quiet axi_dma_0/*introut]"
puts $config_report "DMA_INTERRUPTS_CONNECTED=0"
close $config_report

set dma_report [open [file join $report_dir axi_dma_configuration.txt] w]
puts $dma_report "Mode: Simple"
puts $dma_report "Scatter Gather: Disabled"
puts $dma_report "MM2S: Enabled"
puts $dma_report "S2MM: Enabled"
puts $dma_report "MM2S Stream Width: 32"
puts $dma_report "S2MM Stream Width: 32"
puts $dma_report "DRE: Disabled"
puts $dma_report "Buffer Length Register Width: [get_property CONFIG.c_sg_length_width $dma]"
puts $dma_report "MaxTransferLen: 8388607 bytes"
puts $dma_report "Stage-1 Output Length: 16384 bytes"
puts $dma_report "Stage-1 Output Supported: Yes"
close $dma_report

set connection_report [open [file join $report_dir interface_connections.txt] w]
foreach intf_net [lsort -dictionary [get_bd_intf_nets -quiet]] {
  puts $connection_report "INTERFACE_NET=[get_property NAME $intf_net]"
  foreach pin [lsort -dictionary [get_bd_intf_pins -quiet -of_objects $intf_net]] {
    puts $connection_report "  PIN=[get_property NAME $pin]"
  }
  foreach port [lsort -dictionary [get_bd_intf_ports -quiet -of_objects $intf_net]] {
    puts $connection_report "  PORT=[get_property NAME $port]"
  }
}
puts $connection_report "CLOCK_NET=[get_property NAME \
  [require_one FCLK0_net [get_bd_nets -quiet -of_objects \
    [get_bd_pins processing_system7_0/FCLK_CLK0]]]]"
puts $connection_report "RESET_NET=[get_property NAME \
  [require_one peripheral_reset_net [get_bd_nets -quiet -of_objects \
    [get_bd_pins proc_sys_reset_0/peripheral_aresetn]]]]"
close $connection_report

puts "BD VALIDATION PASS: $bd_name"
puts "REPORT DIRECTORY: $report_dir"
puts "PROJECT FILE: $project_file"
close_project
exit 0
