set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
set project_dir [file join $repo_root build vivado_zybo resnet_accel_zybo]
set project_file [file join $project_dir resnet_accel_zybo.xpr]
set report_dir [file join $repo_root build vivado_zybo reports]
set bd_name zybo_resnet_system

proc build_fail {message} {
  puts stderr "ERROR: $message"
  exit 4
}

proc require_one {description objects} {
  if {[llength $objects] != 1} {
    build_fail "$description: expected one object, got [llength $objects]"
  }
  return [lindex $objects 0]
}

proc require_complete {run_name} {
  set run [require_one "$run_name run" [get_runs -quiet $run_name]]
  set status [get_property STATUS $run]
  if {![string match "*Complete*" $status]} {
    build_fail "$run_name did not complete: $status"
  }
  puts "CHECK PASS: $run_name status=$status"
  return $run
}

proc count_cells {hierarchy_pattern ref_pattern} {
  return [llength [get_cells -quiet -hierarchical -filter \
    "NAME =~ $hierarchy_pattern && REF_NAME =~ $ref_pattern"]]
}

proc count_lutram_cells {hierarchy_pattern} {
  set cells {}
  foreach cell [get_cells -quiet -hierarchical -filter \
      "NAME =~ $hierarchy_pattern && REF_NAME =~ RAM*"] {
    if {![string match "RAMB*" [get_property REF_NAME $cell]]} {
      lappend cells $cell
    }
  }
  foreach cell [get_cells -quiet -hierarchical -filter \
      "NAME =~ $hierarchy_pattern && REF_NAME =~ SRL*"] {
    lappend cells $cell
  }
  return [llength [lsort -unique $cells]]
}

proc worst_slack {delay_type} {
  set paths [get_timing_paths -quiet -delay_type $delay_type -max_paths 1 \
    -nworst 1]
  if {[llength $paths] != 1} {
    build_fail "no $delay_type timing path was found"
  }
  return [get_property SLACK [lindex $paths 0]]
}

proc failing_paths {delay_type} {
  return [get_timing_paths -quiet -delay_type $delay_type \
    -slack_lesser_than 0.0 -max_paths 100000 -nworst 1]
}

proc total_negative_slack {paths} {
  set total 0.0
  foreach path $paths {
    set total [expr {$total + [get_property SLACK $path]}]
  }
  return $total
}

proc format_endpoint {path property_name} {
  set object [get_property $property_name $path]
  if {$object eq ""} {
    return "<none>"
  }
  return [get_property NAME $object]
}

proc count_log_messages {path prefix} {
  if {![file isfile $path]} {
    return 0
  }
  set channel [open $path r]
  set count 0
  while {[gets $channel line] >= 0} {
    if {[string match "${prefix}:*" $line]} {
      incr count
    }
  }
  close $channel
  return $count
}

proc check_timing_count {path category} {
  if {![file isfile $path]} {
    build_fail "check_timing report does not exist: $path"
  }
  set channel [open $path r]
  set contents [read $channel]
  close $channel
  if {![regexp "checking ${category} \\(([0-9]+)\\)" $contents -> count]} {
    build_fail "could not parse check_timing category '$category'"
  }
  return $count
}

proc pulse_width_failing_count {path} {
  if {![file isfile $path]} {
    build_fail "timing summary report does not exist: $path"
  }
  set channel [open $path r]
  while {[gets $channel line] >= 0} {
    if {[regexp {^\s*-?\d+\.\d+\s+-?\d+\.\d+\s+\d+\s+\d+\s+-?\d+\.\d+\s+-?\d+\.\d+\s+\d+\s+\d+\s+-?\d+\.\d+\s+-?\d+\.\d+\s+(\d+)\s+\d+\s*$} $line -> count]} {
      close $channel
      return $count
    }
  }
  close $channel
  build_fail "could not parse pulse-width result from $path"
}

proc report_hierarchy_resources {channel label pattern} {
  puts $channel "$label.LUT=[count_cells $pattern LUT*]"
  puts $channel "$label.FF=[count_cells $pattern FD*]"
  puts $channel "$label.RAMB36E1=[count_cells $pattern RAMB36E1]"
  puts $channel "$label.RAMB18E1=[count_cells $pattern RAMB18E1]"
  puts $channel "$label.DSP48E1=[count_cells $pattern DSP48E1]"
  puts $channel "$label.LUTRAM_OR_SRL=[count_lutram_cells $pattern]"
}

if {![file isfile $project_file]} {
  build_fail "project does not exist: run create_zybo_system.tcl first"
}
file mkdir $report_dir
open_project $project_file

set bd_file [require_one "$bd_name BD file" [get_files -quiet "*/${bd_name}.bd"]]
set synth_run [require_one "synth_1 run" [get_runs -quiet synth_1]]
set impl_run [require_one "impl_1 run" [get_runs -quiet impl_1]]
set synth_status [get_property STATUS $synth_run]
set impl_status [get_property STATUS $impl_run]
set clean_build [expr {$synth_status eq "Not started" &&
  $impl_status eq "Not started"}]
set report_resume [expr {[string match "*Complete*" $synth_status] &&
  [string match "*Complete*" $impl_status]}]
if {!$clean_build && !$report_resume} {
  build_fail "runs must both be Not started or both Complete: synth='$synth_status' impl='$impl_status'"
}

if {$clean_build} {
  launch_runs synth_1 -jobs 8
  wait_on_run synth_1
} else {
  puts "REPORT RESUME: reusing completed synth_1 and impl_1 checkpoints"
}
require_complete synth_1
open_run synth_1

report_timing_summary -delay_type min_max -report_unconstrained \
  -file [file join $report_dir post_synth_timing_summary.rpt]
report_utilization -file [file join $report_dir post_synth_utilization.rpt]
report_utilization -hierarchical \
  -file [file join $report_dir post_synth_utilization_hierarchical.rpt]
check_timing -verbose \
  -file [file join $report_dir post_synth_check_timing.rpt]

set black_boxes [get_cells -quiet -hierarchical -filter {IS_BLACKBOX == 1}]
if {[llength $black_boxes] != 0} {
  build_fail "post-synthesis black boxes found: $black_boxes"
}

set accel_pattern *resnet_accel_0*
set synth_ramb36 [count_cells $accel_pattern RAMB36E1]
set synth_ramb18 [count_cells $accel_pattern RAMB18E1]
set synth_dsp [count_cells $accel_pattern DSP48E1]
set synth_lutram [count_lutram_cells $accel_pattern]
puts "POST_SYNTH_ACCEL RAMB36E1=$synth_ramb36 RAMB18E1=$synth_ramb18 DSP48E1=$synth_dsp LUTRAM_OR_SRL=$synth_lutram"

if {$synth_ramb36 != 32 || $synth_ramb18 != 1 || $synth_dsp != 3 ||
    $synth_lutram != 0} {
  build_fail "accelerator post-synthesis memory/DSP inference changed"
}

close_design
if {$clean_build} {
  launch_runs impl_1 -to_step route_design -jobs 8
  wait_on_run impl_1
}
require_complete impl_1
open_run impl_1

report_timing_summary -delay_type min_max -report_unconstrained \
  -file [file join $report_dir post_route_timing_summary.rpt]
report_utilization -file [file join $report_dir post_route_utilization.rpt]
report_utilization -hierarchical \
  -file [file join $report_dir post_route_utilization_hierarchical.rpt]
report_drc -file [file join $report_dir post_route_drc.rpt]
report_methodology -file [file join $report_dir post_route_methodology.rpt]
report_route_status -file [file join $report_dir post_route_status.rpt]
report_clock_utilization -file [file join $report_dir clock_utilization.rpt]
report_clock_interaction -delay_type min_max \
  -file [file join $report_dir clock_interaction.rpt]
check_timing -verbose \
  -file [file join $report_dir post_route_check_timing.rpt]
report_timing -delay_type max -max_paths 10 -nworst 1 -input_pins \
  -file [file join $report_dir worst_setup_paths.rpt]
report_timing -delay_type min -max_paths 10 -nworst 1 -input_pins \
  -file [file join $report_dir worst_hold_paths.rpt]
report_high_fanout_nets -timing -load_types -max_nets 50 \
  -file [file join $report_dir post_route_high_fanout_nets.rpt]
report_cdc -details -file [file join $report_dir post_route_cdc.rpt]

set setup_wns [worst_slack max]
set hold_whs [worst_slack min]
set setup_failing [failing_paths max]
set hold_failing [failing_paths min]
set setup_tns [total_negative_slack $setup_failing]
set hold_ths [total_negative_slack $hold_failing]

set worst_setup [lindex [get_timing_paths -quiet -delay_type max \
  -max_paths 1 -nworst 1] 0]
set worst_hold [lindex [get_timing_paths -quiet -delay_type min \
  -max_paths 1 -nworst 1] 0]

set drc_errors [get_drc_violations -quiet -filter {SEVERITY == Error}]
set unrouted_nets [get_nets -quiet -hierarchical \
  -filter {ROUTE_STATUS == UNROUTED}]
set check_timing_report [file join $report_dir post_route_check_timing.rpt]
set route_timing_report [file join $report_dir post_route_timing_summary.rpt]
set pulse_width_failing [pulse_width_failing_count $route_timing_report]
set no_clock_register_count [check_timing_count $check_timing_report no_clock]
set unconstrained_endpoint_count \
  [check_timing_count $check_timing_report unconstrained_internal_endpoints]

set route_ramb36 [count_cells $accel_pattern RAMB36E1]
set route_ramb18 [count_cells $accel_pattern RAMB18E1]
set route_dsp [count_cells $accel_pattern DSP48E1]
set route_lutram [count_lutram_cells $accel_pattern]

set clocks [get_clocks -quiet]
set fclk [require_one "implemented 100 MHz clock" \
  [get_clocks -quiet -filter {PERIOD == 10.000}]]

set synth_log [file join $project_dir resnet_accel_zybo.runs synth_1 runme.log]
set impl_log [file join $project_dir resnet_accel_zybo.runs impl_1 runme.log]

set summary [open [file join $report_dir implementation_summary.txt] w]
puts $summary "VIVADO_VERSION=[version -short]"
puts $summary "BOARD_PART=[get_property BOARD_PART [current_project]]"
puts $summary "FPGA_PART=[get_property PART [current_project]]"
puts $summary "GIT_HEAD=[string trim [exec git -C $repo_root rev-parse HEAD]]"
puts $summary "GIT_BRANCH=[string trim [exec git -C $repo_root branch --show-current]]"
puts $summary "BD_NAME=$bd_name"
puts $summary "SYNTH_STATUS=[get_property STATUS $synth_run]"
puts $summary "IMPLEMENTATION_STATUS=[get_property STATUS $impl_run]"
puts $summary "PHYS_OPT_ENABLED=[get_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED $impl_run]"
puts $summary "SETUP_WNS_NS=$setup_wns"
puts $summary "SETUP_TNS_NS=$setup_tns"
puts $summary "SETUP_FAILING_ENDPOINTS=[llength $setup_failing]"
puts $summary "HOLD_WHS_NS=$hold_whs"
puts $summary "HOLD_THS_NS=$hold_ths"
puts $summary "HOLD_FAILING_ENDPOINTS=[llength $hold_failing]"
puts $summary "PULSE_WIDTH_FAILING_ENDPOINTS=$pulse_width_failing"
puts $summary "WORST_SETUP_START=[format_endpoint $worst_setup STARTPOINT_PIN]"
puts $summary "WORST_SETUP_END=[format_endpoint $worst_setup ENDPOINT_PIN]"
puts $summary "WORST_HOLD_START=[format_endpoint $worst_hold STARTPOINT_PIN]"
puts $summary "WORST_HOLD_END=[format_endpoint $worst_hold ENDPOINT_PIN]"
puts $summary "CLOCK_COUNT=[llength $clocks]"
puts $summary "FCLK_NAME=[get_property NAME $fclk]"
puts $summary "FCLK_PERIOD_NS=[get_property PERIOD $fclk]"
puts $summary "NO_CLOCK_REGISTERS=$no_clock_register_count"
puts $summary "UNCONSTRAINED_INTERNAL_ENDPOINTS=$unconstrained_endpoint_count"
puts $summary "DRC_ERROR_COUNT=[llength $drc_errors]"
puts $summary "DRC_ERRORS=$drc_errors"
puts $summary "UNROUTED_NET_COUNT=[llength $unrouted_nets]"
puts $summary "BLACK_BOX_COUNT=[llength $black_boxes]"
puts $summary "SYNTH_ERROR_COUNT=[count_log_messages $synth_log ERROR]"
puts $summary "SYNTH_CRITICAL_WARNING_COUNT=[count_log_messages $synth_log {CRITICAL WARNING}]"
puts $summary "SYNTH_WARNING_COUNT=[count_log_messages $synth_log WARNING]"
puts $summary "IMPL_ERROR_COUNT=[count_log_messages $impl_log ERROR]"
puts $summary "IMPL_CRITICAL_WARNING_COUNT=[count_log_messages $impl_log {CRITICAL WARNING}]"
puts $summary "IMPL_WARNING_COUNT=[count_log_messages $impl_log WARNING]"
report_hierarchy_resources $summary TOTAL *
report_hierarchy_resources $summary ACCELERATOR *resnet_accel_0*
report_hierarchy_resources $summary AXI_DMA *axi_dma_0*
report_hierarchy_resources $summary CONTROL_SMARTCONNECT *control_smartconnect*
report_hierarchy_resources $summary MEMORY_SMARTCONNECT *memory_smartconnect*
report_hierarchy_resources $summary PROCESSING_SYSTEM7 *processing_system7_0*
report_hierarchy_resources $summary PROC_SYS_RESET *proc_sys_reset_0*
puts $summary "WARNING.BOARD_PRESET_DDR=PSU-1 through PSU-4 originate from the Digilent preset"
puts $summary "WARNING.DMA_INTERRUPTS=Polling mode leaves mm2s_introut and s2mm_introut unconnected"
puts $summary "WARNING.SMARTCONNECT_METADATA=BD 41-2384 concerns generated internal AXI metadata payload adaptation"
puts $summary "BITSTREAM_GENERATED=0"
close $summary

if {$setup_wns < 0.0 || [llength $setup_failing] != 0} {
  build_fail "setup timing failed"
}
if {$hold_whs < 0.0 || [llength $hold_failing] != 0} {
  build_fail "hold timing failed"
}
if {$pulse_width_failing != 0} {
  build_fail "pulse-width timing failed"
}
if {[llength $drc_errors] != 0} {
  build_fail "post-route DRC errors found: $drc_errors"
}
if {[llength $unrouted_nets] != 0} {
  build_fail "unrouted nets found"
}
if {$no_clock_register_count != 0} {
  build_fail "registers without clocks found"
}
if {$unconstrained_endpoint_count != 0} {
  build_fail "unconstrained internal endpoints found"
}
if {$route_ramb36 != 32 || $route_ramb18 != 1 || $route_dsp != 3 ||
    $route_lutram != 0} {
  build_fail "accelerator post-route memory/DSP structure changed"
}

puts "IMPLEMENTATION PASS: setup WNS=$setup_wns hold WHS=$hold_whs"
puts "REPORT DIRECTORY: $report_dir"
puts "BITSTREAM GENERATED: 0"
close_project
exit 0
