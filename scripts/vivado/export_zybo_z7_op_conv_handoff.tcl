set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
set project_file [file join $repo_root build vivado_zybo resnet_accel_zybo resnet_accel_zybo.xpr]
set build_report_dir [file join $repo_root build vivado_zybo reports]
set ooc_dir [file join $repo_root build synth_ooc xc7z020clg400-1]
set report_dir [file join $repo_root vivado reports]
set export_dir [file join $repo_root vivado zybo_z7_op_conv]
set output_dir [file join $repo_root vivado output]
set artifact_dir [file join $repo_root build vivado_zybo artifacts]
set bd_name zybo_resnet_system
set run_name impl_performance_postroute_physopt

proc export_fail {message} {
  puts stderr "ERROR: $message"
  exit 4
}

proc require_one {description objects} {
  if {[llength $objects] != 1} {
    export_fail "$description: expected one object, got [llength $objects]"
  }
  return [lindex $objects 0]
}

proc require_file {description path} {
  if {![file isfile $path]} {
    export_fail "$description does not exist: $path"
  }
}

foreach directory [list $report_dir $export_dir $output_dir] {
  file mkdir $directory
}
require_file "Vivado project" $project_file

open_project $project_file
set bd_file [require_one "$bd_name BD" [get_files -quiet "*/${bd_name}.bd"]]
open_bd_design $bd_file
set dma [require_one "AXI DMA" [get_bd_cells -quiet axi_dma_0]]
if {[get_property CONFIG.c_sg_length_width $dma] ne "23"} {
  export_fail "AXI DMA c_sg_length_width is not 23"
}

write_bd_tcl -force [file join $export_dir system_bd_export.tcl]
set wrappers [get_files -quiet "*/hdl/${bd_name}_wrapper.v"]
set wrapper [require_one "generated HDL wrapper" $wrappers]
file copy -force $wrapper [file join $export_dir system_wrapper.v]

file copy -force [file join $build_report_dir address_map.txt] \
  [file join $report_dir address_map.txt]
file copy -force [file join $build_report_dir axi_dma_configuration.txt] \
  [file join $report_dir axi_dma_configuration.txt]

set csv [open [file join $report_dir address_map.csv] w]
puts $csv "resource,base,range,connection,clock_mhz,reset,length_width,stream_width_bits"
puts $csv "Accelerator,0x43C00000,0x00010000,PS7_M_AXI_GP0,100,peripheral_aresetn,23,32"
puts $csv "AXI_DMA_Control,0x40400000,0x00010000,PS7_M_AXI_GP0,100,peripheral_aresetn,23,32"
puts $csv "DMA_MM2S_DDR,0x00000000,0x40000000,PS7_S_AXI_HP0,100,peripheral_aresetn,23,32"
puts $csv "DMA_S2MM_DDR,0x00000000,0x40000000,PS7_S_AXI_HP0,100,peripheral_aresetn,23,32"
close $csv

foreach {source target} [list \
    [file join $ooc_dir utilization.rpt] ooc_utilization.rpt \
    [file join $ooc_dir timing_summary.rpt] ooc_timing_summary.rpt \
    [file join $ooc_dir utilization_hierarchical.rpt] ooc_hierarchy_utilization.rpt] {
  require_file "OOC report" $source
  file copy -force $source [file join $report_dir $target]
}

set run [require_one "$run_name run" [get_runs -quiet $run_name]]
if {![string match "*Complete*" [get_property STATUS $run]]} {
  export_fail "$run_name is not complete: [get_property STATUS $run]"
}
open_run $run_name
report_utilization -file [file join $report_dir top_utilization.rpt]
report_utilization -hierarchical -file [file join $report_dir top_hierarchy_utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
  -file [file join $report_dir top_timing_summary.rpt]
report_power -file [file join $report_dir top_power.rpt]
report_drc -file [file join $report_dir top_drc.rpt]
report_clock_interaction -delay_type min_max \
  -file [file join $report_dir top_clock_interaction.rpt]

set bit_source [file join $artifact_dir zybo_resnet_system.bit]
set xsa_source [file join $artifact_dir zybo_resnet_system.xsa]
require_file "timing-PASS bitstream" $bit_source
require_file "bitstream-included XSA" $xsa_source
file copy -force $bit_source [file join $output_dir zybo_z7_op_conv.bit]
file copy -force $xsa_source [file join $output_dir zybo_z7_op_conv.xsa]

puts "HANDOFF EXPORT PASS"
puts "BD EXPORT: [file join $export_dir system_bd_export.tcl]"
puts "HDL WRAPPER: [file join $export_dir system_wrapper.v]"
puts "REPORT DIRECTORY: $report_dir"
puts "OUTPUT DIRECTORY: $output_dir"
close_project
exit 0
