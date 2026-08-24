set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
set build_root [file join $repo_root build]
set project_dir [file join $build_root package_resnet_accel_ip]
set ip_root [file join $build_root ip_repo resnet_accel_1_0]

if {$argc > 1} {
  puts stderr "Usage: vivado -mode batch -source scripts/vivado/package_resnet_accel_ip.tcl ?-tclargs <ip-root>?"
  exit 2
}
if {$argc == 1} {
  set ip_root [file normalize [lindex $argv 0]]
}

set build_root [file normalize $build_root]
if {$ip_root eq $build_root || [string first "$build_root/" "$ip_root/"] != 0} {
  puts stderr "ERROR: generated IP root must stay below $build_root"
  exit 2
}

proc add_port_map {bus_if logical_name physical_name} {
  set port_map [ipx::add_port_map $logical_name $bus_if]
  set_property physical_name $physical_name $port_map
}

proc add_bus_parameter {bus_if name value} {
  set parameter [ipx::add_bus_parameter $name $bus_if]
  set_property value $value $parameter
}

proc require_equal {description actual expected} {
  if {$actual ne $expected} {
    error "$description: expected '$expected', got '$actual'"
  }
  puts "CHECK PASS: $description = $expected"
}

proc require_port_maps {bus_if expected_maps} {
  foreach {logical_name physical_name} $expected_maps {
    set port_map [ipx::get_port_maps $logical_name -of_objects $bus_if]
    if {[llength $port_map] != 1} {
      error "[get_property name $bus_if] must have exactly one $logical_name port map"
    }
    require_equal \
      "[get_property name $bus_if].$logical_name" \
      [get_property physical_name $port_map] \
      $physical_name
  }
}

file mkdir [file dirname $project_dir]
file mkdir [file dirname $ip_root]
file delete -force $project_dir
file delete -force $ip_root

create_project -force package_resnet_accel_ip $project_dir -part xc7z020clg400-1
set_property target_language Verilog [current_project]

set rtl_sources [list \
  rtl/common/accel_pkg.sv \
  rtl/common/sat_add_int32.sv \
  rtl/common/requantizer.sv \
  rtl/common/relu_clamp.sv \
  rtl/compute/tensor_buffers.sv \
  rtl/compute/conv_engine.sv \
  rtl/compute/gap_engine.sv \
  rtl/compute/residual_add_engine.sv \
  rtl/stream/axis_packet_loader.sv \
  rtl/stream/axis_output_streamer.sv \
  rtl/control/axi_lite_regs.sv \
  rtl/control/controller_fsm.sv \
  rtl/control/error_ctrl.sv \
  rtl/control/cycle_counter.sv \
  rtl/top/resnet_accel_top.sv \
  rtl/integration/resnet_accel_ip_wrapper.sv]

set absolute_sources {}
foreach source $rtl_sources {
  lappend absolute_sources [file join $repo_root $source]
}
add_files -norecurse $absolute_sources
set_property top resnet_accel_ip_wrapper [current_fileset]
update_compile_order -fileset sources_1

ipx::package_project \
  -root_dir $ip_root \
  -vendor jmhwang.local \
  -library npu \
  -taxonomy /UserIP/Accelerators \
  -import_files \
  -set_current true

set core [ipx::current_core]
set_property name resnet_accel $core
set_property version 1.0 $core
set_property display_name {ResNet OP_CONV Accelerator} $core
set_property description {Bit-exact single OP_CONV accelerator with AXI4-Lite control and AXI4-Stream data} $core
set_property vendor_display_name {jmhwang.local} $core
set_property company_url {} $core
set_property supported_families {zynq Production} $core

# Remove any inferred interfaces before installing the checked, deterministic
# interface metadata below.
foreach bus_if [ipx::get_bus_interfaces -of_objects $core] {
  ipx::remove_bus_interface [get_property name $bus_if] $core
}
foreach memory_map [ipx::get_memory_maps -of_objects $core] {
  ipx::remove_memory_map [get_property name $memory_map] $core
}

set ctrl_if [ipx::add_bus_interface S_AXI_CTRL $core]
set_property interface_mode slave $ctrl_if
set_property bus_type_vlnv xilinx.com:interface:aximm:1.0 $ctrl_if
set_property abstraction_type_vlnv xilinx.com:interface:aximm_rtl:1.0 $ctrl_if
require_port_maps $ctrl_if {}
foreach {logical physical} {
  AWADDR  s_axi_ctrl_awaddr
  AWPROT  s_axi_ctrl_awprot
  AWVALID s_axi_ctrl_awvalid
  AWREADY s_axi_ctrl_awready
  WDATA   s_axi_ctrl_wdata
  WSTRB   s_axi_ctrl_wstrb
  WVALID  s_axi_ctrl_wvalid
  WREADY  s_axi_ctrl_wready
  BRESP   s_axi_ctrl_bresp
  BVALID  s_axi_ctrl_bvalid
  BREADY  s_axi_ctrl_bready
  ARADDR  s_axi_ctrl_araddr
  ARPROT  s_axi_ctrl_arprot
  ARVALID s_axi_ctrl_arvalid
  ARREADY s_axi_ctrl_arready
  RDATA   s_axi_ctrl_rdata
  RRESP   s_axi_ctrl_rresp
  RVALID  s_axi_ctrl_rvalid
  RREADY  s_axi_ctrl_rready
} {
  add_port_map $ctrl_if $logical $physical
}
add_bus_parameter $ctrl_if DATA_WIDTH 32
add_bus_parameter $ctrl_if PROTOCOL AXI4LITE

set ctrl_map [ipx::add_memory_map S_AXI_CTRL $core]
set ctrl_block [ipx::add_address_block Reg $ctrl_map]
set_property base_address 0 $ctrl_block
set_property range 128 $ctrl_block
set_property width 32 $ctrl_block
set_property usage register $ctrl_block
set_property slave_memory_map_ref S_AXI_CTRL $ctrl_if

set input_if [ipx::add_bus_interface S_AXIS_INPUT $core]
set_property interface_mode slave $input_if
set_property bus_type_vlnv xilinx.com:interface:axis:1.0 $input_if
set_property abstraction_type_vlnv xilinx.com:interface:axis_rtl:1.0 $input_if
foreach {logical physical} {
  TDATA  s_axis_input_tdata
  TKEEP  s_axis_input_tkeep
  TLAST  s_axis_input_tlast
  TVALID s_axis_input_tvalid
  TREADY s_axis_input_tready
} {
  add_port_map $input_if $logical $physical
}
add_bus_parameter $input_if TDATA_NUM_BYTES 4

set output_if [ipx::add_bus_interface M_AXIS_OUTPUT $core]
set_property interface_mode master $output_if
set_property bus_type_vlnv xilinx.com:interface:axis:1.0 $output_if
set_property abstraction_type_vlnv xilinx.com:interface:axis_rtl:1.0 $output_if
foreach {logical physical} {
  TDATA  m_axis_output_tdata
  TKEEP  m_axis_output_tkeep
  TLAST  m_axis_output_tlast
  TVALID m_axis_output_tvalid
  TREADY m_axis_output_tready
} {
  add_port_map $output_if $logical $physical
}
add_bus_parameter $output_if TDATA_NUM_BYTES 4

set clock_if [ipx::add_bus_interface aclk $core]
set_property interface_mode slave $clock_if
set_property bus_type_vlnv xilinx.com:signal:clock:1.0 $clock_if
set_property abstraction_type_vlnv xilinx.com:signal:clock_rtl:1.0 $clock_if
add_port_map $clock_if CLK aclk
add_bus_parameter $clock_if ASSOCIATED_BUSIF {S_AXI_CTRL:S_AXIS_INPUT:M_AXIS_OUTPUT}
add_bus_parameter $clock_if ASSOCIATED_RESET aresetn
add_bus_parameter $clock_if FREQ_HZ 100000000

set reset_if [ipx::add_bus_interface aresetn $core]
set_property interface_mode slave $reset_if
set_property bus_type_vlnv xilinx.com:signal:reset:1.0 $reset_if
set_property abstraction_type_vlnv xilinx.com:signal:reset_rtl:1.0 $reset_if
add_port_map $reset_if RST aresetn
add_bus_parameter $reset_if POLARITY ACTIVE_LOW

ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::save_core $core

# Acceptance checks are intentionally explicit so a Vivado metadata/API change
# fails the packaging job instead of producing a subtly malformed component.
require_equal VLNV [get_property vlnv $core] {jmhwang.local:npu:resnet_accel:1.0}
require_equal bus_interface_count [llength [ipx::get_bus_interfaces -of_objects $core]] 5
require_equal S_AXI_CTRL_mode [get_property interface_mode $ctrl_if] slave
require_equal S_AXIS_INPUT_mode [get_property interface_mode $input_if] slave
require_equal M_AXIS_OUTPUT_mode [get_property interface_mode $output_if] master
require_equal ctrl_range [get_property range $ctrl_block] 128
require_equal ctrl_width [get_property width $ctrl_block] 32
require_equal axi_addr_left [get_property size_left [ipx::get_ports s_axi_ctrl_awaddr -of_objects $core]] 6
require_equal axi_addr_right [get_property size_right [ipx::get_ports s_axi_ctrl_awaddr -of_objects $core]] 0
require_equal axi_data_left [get_property size_left [ipx::get_ports s_axi_ctrl_wdata -of_objects $core]] 31
require_equal axi_data_right [get_property size_right [ipx::get_ports s_axi_ctrl_wdata -of_objects $core]] 0
require_equal associated_busif \
  [get_property value [ipx::get_bus_parameters ASSOCIATED_BUSIF -of_objects $clock_if]] \
  {S_AXI_CTRL:S_AXIS_INPUT:M_AXIS_OUTPUT}
require_equal associated_reset \
  [get_property value [ipx::get_bus_parameters ASSOCIATED_RESET -of_objects $clock_if]] \
  aresetn
require_equal reset_polarity \
  [get_property value [ipx::get_bus_parameters POLARITY -of_objects $reset_if]] \
  ACTIVE_LOW
require_equal input_tdata_num_bytes \
  [get_property value [ipx::get_bus_parameters TDATA_NUM_BYTES -of_objects $input_if]] \
  4
require_equal output_tdata_num_bytes \
  [get_property value [ipx::get_bus_parameters TDATA_NUM_BYTES -of_objects $output_if]] \
  4

require_port_maps $ctrl_if {
  AWADDR s_axi_ctrl_awaddr AWPROT s_axi_ctrl_awprot
  WDATA s_axi_ctrl_wdata WSTRB s_axi_ctrl_wstrb
  ARADDR s_axi_ctrl_araddr ARPROT s_axi_ctrl_arprot
  RDATA s_axi_ctrl_rdata
}
require_port_maps $input_if {
  TDATA s_axis_input_tdata TKEEP s_axis_input_tkeep TLAST s_axis_input_tlast
  TVALID s_axis_input_tvalid TREADY s_axis_input_tready
}
require_port_maps $output_if {
  TDATA m_axis_output_tdata TKEEP m_axis_output_tkeep TLAST m_axis_output_tlast
  TVALID m_axis_output_tvalid TREADY m_axis_output_tready
}

if {[catch {ipx::check_integrity -quiet $core} integrity_result]} {
  puts stderr $integrity_result
  exit 3
}
require_equal integrity_status $integrity_result 1
ipx::save_core $core

puts "IP PACKAGE PASS: [get_property vlnv $core]"
puts "IP PACKAGE ROOT: $ip_root"
close_project
exit 0
