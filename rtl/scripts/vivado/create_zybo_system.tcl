set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
set build_root [file normalize [file join $repo_root build]]
set project_dir [file join $build_root vivado_zybo resnet_accel_zybo]
set project_file [file join $project_dir resnet_accel_zybo.xpr]
set ip_repo [file join $build_root ip_repo]
set component_xml [file join $ip_repo resnet_accel_1_0 component.xml]
set package_script [file join $script_dir package_resnet_accel_ip.tcl]
set validate_script [file join $script_dir validate_zybo_system.tcl]
set board_repo /home/jmhwang/tools/digilent-vivado-boards/new/board_files
set board_part digilentinc.com:zybo-z7-20:part0:1.2
set fpga_part xc7z020clg400-1
set bd_name zybo_resnet_system

proc fail {message} {
  puts stderr "ERROR: $message"
  exit 2
}

if {$project_dir eq $build_root ||
    [string first "$build_root/" "$project_dir/"] != 0} {
  fail "generated project directory must stay below $build_root"
}

if {![file isdirectory $board_repo]} {
  fail "board repository not found: $board_repo"
}
set_param board.repoPaths [list $board_repo]

set board_matches [get_board_parts -quiet $board_part]
if {[llength $board_matches] != 1} {
  fail "expected one board part '$board_part', found [llength $board_matches]"
}
set part_matches [get_parts -quiet $fpga_part]
if {[llength $part_matches] != 1} {
  fail "expected one FPGA part '$fpga_part', found [llength $part_matches]"
}

if {![file isfile $component_xml]} {
  puts "INFO: packaged accelerator is missing; generating it first"
  set vivado_command [list vivado -mode batch -nolog -nojournal \
    -source $package_script]
  if {[catch {exec {*}$vivado_command} package_result]} {
    puts stderr $package_result
    fail "accelerator IP packaging failed"
  }
  puts $package_result
}
if {![file isfile $component_xml]} {
  fail "packaging completed without creating $component_xml"
}

file delete -force $project_dir
file mkdir $project_dir

create_project -force resnet_accel_zybo $project_dir -part $fpga_part
set_property board_part $board_part [current_project]
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property ip_repo_paths [list $ip_repo] [current_project]
update_ip_catalog

set accel_defs [get_ipdefs -all -quiet jmhwang.local:npu:resnet_accel:1.0]
if {[llength $accel_defs] != 1} {
  fail "packaged accelerator VLNV was not found in the IP catalog"
}

create_bd_design $bd_name

set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 \
  processing_system7_0]
if {[catch {
  apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {apply_board_preset "1" make_external "FIXED_IO, DDR" \
      Master "Disable" Slave "Disable"} $ps7
} preset_result]} {
  puts stderr $preset_result
  fail "Zybo Z7-20 processing-system board preset failed"
}
puts $preset_result

set_property -dict [list \
  CONFIG.PCW_USE_M_AXI_GP0 {1} \
  CONFIG.PCW_USE_S_AXI_HP0 {1} \
  CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100.000000}] $ps7

foreach external_interface {DDR FIXED_IO} {
  if {[llength [get_bd_intf_ports -quiet $external_interface]] != 1} {
    fail "board preset did not create external $external_interface"
  }
}

set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0]
set_property -dict [list \
  CONFIG.c_include_sg {0} \
  CONFIG.c_include_mm2s {1} \
  CONFIG.c_include_s2mm {1} \
  CONFIG.c_include_mm2s_dre {0} \
  CONFIG.c_include_s2mm_dre {0} \
  CONFIG.c_m_axis_mm2s_tdata_width {32} \
  CONFIG.c_s_axis_s2mm_tdata_width {32}] $dma

set reset [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 \
  proc_sys_reset_0]

set control_ic [create_bd_cell -type ip -vlnv \
  xilinx.com:ip:smartconnect:1.0 control_smartconnect]
set_property -dict [list \
  CONFIG.NUM_SI {1} \
  CONFIG.NUM_MI {2} \
  CONFIG.NUM_CLKS {1}] $control_ic

set memory_ic [create_bd_cell -type ip -vlnv \
  xilinx.com:ip:smartconnect:1.0 memory_smartconnect]
set_property -dict [list \
  CONFIG.NUM_SI {2} \
  CONFIG.NUM_MI {1} \
  CONFIG.NUM_CLKS {1}] $memory_ic

set accel [create_bd_cell -type ip -vlnv \
  jmhwang.local:npu:resnet_accel:1.0 resnet_accel_0]

# Control topology: PS GP0 -> 1x2 SmartConnect -> accelerator and DMA.
connect_bd_intf_net [get_bd_intf_pins $ps7/M_AXI_GP0] \
  [get_bd_intf_pins $control_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $control_ic/M00_AXI] \
  [get_bd_intf_pins $accel/S_AXI_CTRL]
connect_bd_intf_net [get_bd_intf_pins $control_ic/M01_AXI] \
  [get_bd_intf_pins $dma/S_AXI_LITE]

# DDR topology: two DMA masters -> 2x1 SmartConnect -> PS HP0.
connect_bd_intf_net [get_bd_intf_pins $dma/M_AXI_MM2S] \
  [get_bd_intf_pins $memory_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $dma/M_AXI_S2MM] \
  [get_bd_intf_pins $memory_ic/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins $memory_ic/M00_AXI] \
  [get_bd_intf_pins $ps7/S_AXI_HP0]

# Direct 32-bit streams. No FIFO, converter, or register slice is inserted.
connect_bd_intf_net [get_bd_intf_pins $dma/M_AXIS_MM2S] \
  [get_bd_intf_pins $accel/S_AXIS_INPUT]
connect_bd_intf_net [get_bd_intf_pins $accel/M_AXIS_OUTPUT] \
  [get_bd_intf_pins $dma/S_AXIS_S2MM]

set fclk [get_bd_pins $ps7/FCLK_CLK0]
connect_bd_net $fclk \
  [get_bd_pins $ps7/M_AXI_GP0_ACLK] \
  [get_bd_pins $ps7/S_AXI_HP0_ACLK] \
  [get_bd_pins $control_ic/aclk] \
  [get_bd_pins $memory_ic/aclk] \
  [get_bd_pins $dma/s_axi_lite_aclk] \
  [get_bd_pins $dma/m_axi_mm2s_aclk] \
  [get_bd_pins $dma/m_axi_s2mm_aclk] \
  [get_bd_pins $accel/aclk] \
  [get_bd_pins $reset/slowest_sync_clk]

connect_bd_net [get_bd_pins $ps7/FCLK_RESET0_N] \
  [get_bd_pins $reset/ext_reset_in]

set peripheral_resetn [get_bd_pins $reset/peripheral_aresetn]
connect_bd_net $peripheral_resetn \
  [get_bd_pins $control_ic/aresetn] \
  [get_bd_pins $memory_ic/aresetn] \
  [get_bd_pins $dma/axi_resetn] \
  [get_bd_pins $accel/aresetn]

# Preferred fixed control addresses.
assign_bd_address -offset 0x40400000 -range 64K \
  -target_address_space [get_bd_addr_spaces $ps7/Data] \
  [get_bd_addr_segs $dma/S_AXI_LITE/Reg] -force
assign_bd_address -offset 0x43C00000 -range 64K \
  -target_address_space [get_bd_addr_spaces $ps7/Data] \
  [get_bd_addr_segs $accel/S_AXI_CTRL/Reg] -force

# Map both DMA data masters to the PS DDR aperture exposed by HP0.
set hp0_ddr [get_bd_addr_segs -quiet $ps7/S_AXI_HP0/HP0_DDR_LOWOCM]
if {[llength $hp0_ddr] != 1} {
  fail "expected one PS7 HP0 DDR/Low-OCM address segment"
}
assign_bd_address -target_address_space [get_bd_addr_spaces $dma/Data_MM2S] \
  $hp0_ddr -force
assign_bd_address -target_address_space [get_bd_addr_spaces $dma/Data_S2MM] \
  $hp0_ddr -force

save_bd_design
source $validate_script
