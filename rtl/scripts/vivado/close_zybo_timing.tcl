set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
set project_dir [file join $repo_root build vivado_zybo resnet_accel_zybo]
set project_file [file join $project_dir resnet_accel_zybo.xpr]
set report_dir [file join $repo_root build vivado_zybo reports]
set comparison_file [file join $report_dir timing_strategy_comparison.txt]

proc timing_fail {message} {
  puts stderr "ERROR: $message"
  exit 4
}

proc require_one {description objects} {
  if {[llength $objects] != 1} {
    timing_fail "$description: expected one object, got [llength $objects]"
  }
  return [lindex $objects 0]
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

proc check_timing_count {path category} {
  set channel [open $path r]
  set contents [read $channel]
  close $channel
  if {![regexp "checking ${category} \\(([0-9]+)\\)" $contents -> count]} {
    timing_fail "could not parse check_timing category '$category' in $path"
  }
  return $count
}

proc timing_summary_metrics {path} {
  set channel [open $path r]
  while {[gets $channel line] >= 0} {
    if {[regexp {^\s*(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+\d+\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+\d+\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+\d+\s*$} \
        $line -> wns tns setup_fail whs ths hold_fail wpws tpws pulse_fail]} {
      close $channel
      return [list $wns $tns $setup_fail $whs $ths $hold_fail \
        $wpws $tpws $pulse_fail]
    }
  }
  close $channel
  timing_fail "could not parse timing summary metrics from $path"
}

proc timing_path_delay_metrics {path} {
  set channel [open $path r]
  set contents [read $channel]
  close $channel
  if {![regexp {Data Path Delay:\s+(-?\d+\.\d+)ns\s+\(logic\s+(-?\d+\.\d+)ns[^\n]*route\s+(-?\d+\.\d+)ns} \
      $contents -> data_delay logic_delay route_delay]} {
    timing_fail "could not parse worst-path delay metrics from $path"
  }
  return [list $data_delay $logic_delay $route_delay]
}

proc utilization_count {path resource_pattern} {
  set channel [open $path r]
  while {[gets $channel line] >= 0} {
    if {[regexp "^\\|\\s*${resource_pattern}\\s*\\|\\s*([0-9]+(?:\\.[0-9]+)?)\\s*\\|" \
        $line -> used]} {
      close $channel
      return $used
    }
  }
  close $channel
  timing_fail "could not parse utilization resource '$resource_pattern' from $path"
}

proc report_candidate {label run_name runtime_seconds report_dir} {
  set run [require_one "$run_name run" [get_runs -quiet $run_name]]
  open_run $run_name

  set prefix [file join $report_dir $label]
  set timing_report ${prefix}_timing_summary.rpt
  set route_report ${prefix}_route_status.rpt
  set drc_report ${prefix}_drc.rpt
  set utilization_report ${prefix}_utilization.rpt
  set hierarchy_report ${prefix}_utilization_hierarchical.rpt
  set check_report ${prefix}_check_timing.rpt
  set worst_setup_report ${prefix}_worst_setup.rpt
  set worst_hold_report ${prefix}_worst_hold.rpt
  set congestion_report ${prefix}_congestion.rpt

  report_timing_summary -delay_type min_max -report_unconstrained \
    -file $timing_report
  report_route_status -file $route_report
  report_drc -file $drc_report
  report_utilization -file $utilization_report
  report_utilization -hierarchical -file $hierarchy_report
  check_timing -verbose -file $check_report
  report_timing -delay_type max -max_paths 10 -nworst 1 -input_pins \
    -file $worst_setup_report
  report_timing -delay_type min -max_paths 10 -nworst 1 -input_pins \
    -file $worst_hold_report
  report_design_analysis -congestion -file $congestion_report

  lassign [timing_summary_metrics $timing_report] \
    wns tns setup_fail whs ths hold_fail wpws tpws pulse_fail
  lassign [timing_path_delay_metrics $worst_setup_report] \
    data_delay logic_delay route_delay

  set worst_setup [require_one "$label worst setup path" \
    [get_timing_paths -quiet -delay_type max -max_paths 1 -nworst 1]]
  set worst_hold [require_one "$label worst hold path" \
    [get_timing_paths -quiet -delay_type min -max_paths 1 -nworst 1]]
  set setup_start [get_property NAME [get_property STARTPOINT_PIN $worst_setup]]
  set setup_end [get_property NAME [get_property ENDPOINT_PIN $worst_setup]]
  set hold_start [get_property NAME [get_property STARTPOINT_PIN $worst_hold]]
  set hold_end [get_property NAME [get_property ENDPOINT_PIN $worst_hold]]

  set drc_errors [get_drc_violations -quiet -filter {SEVERITY == Error}]
  set unrouted [get_nets -quiet -hierarchical \
    -filter {ROUTE_STATUS == UNROUTED}]
  set no_clock [check_timing_count $check_report no_clock]
  set unconstrained \
    [check_timing_count $check_report unconstrained_internal_endpoints]

  set accel_pattern *resnet_accel_0*
  set ramb36 [count_cells $accel_pattern RAMB36E1]
  set ramb18 [count_cells $accel_pattern RAMB18E1]
  set dsp [count_cells $accel_pattern DSP48E1]
  set lutram [count_lutram_cells $accel_pattern]
  set lut [utilization_count $utilization_report {Slice LUTs}]
  set ff [utilization_count $utilization_report {Slice Registers}]
  set total_ramb36 [utilization_count $utilization_report {RAMB36/FIFO\*}]
  set total_ramb18 [utilization_count $utilization_report RAMB18]
  set total_dsp [utilization_count $utilization_report DSPs]
  set total_bufg [utilization_count $utilization_report BUFGCTRL]

  set summary ${prefix}_summary.txt
  set ch [open $summary w]
  puts $ch "LABEL=$label"
  puts $ch "RUN=$run_name"
  puts $ch "STRATEGY=[get_property STRATEGY $run]"
  foreach prop {STEPS.OPT_DESIGN.ARGS.DIRECTIVE STEPS.PLACE_DESIGN.ARGS.DIRECTIVE STEPS.PHYS_OPT_DESIGN.IS_ENABLED STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE} {
    puts $ch "$prop=[get_property $prop $run]"
  }
  puts $ch "RUN_STATUS=[get_property STATUS $run]"
  puts $ch "RUNTIME_SECONDS=$runtime_seconds"
  puts $ch "SETUP_WNS_NS=$wns"
  puts $ch "SETUP_TNS_NS=$tns"
  puts $ch "SETUP_FAILING_ENDPOINTS=$setup_fail"
  puts $ch "HOLD_WHS_NS=$whs"
  puts $ch "HOLD_THS_NS=$ths"
  puts $ch "HOLD_FAILING_ENDPOINTS=$hold_fail"
  puts $ch "PULSE_WIDTH_WORST_SLACK_NS=$wpws"
  puts $ch "PULSE_WIDTH_TOTAL_NEGATIVE_SLACK_NS=$tpws"
  puts $ch "PULSE_WIDTH_FAILING_ENDPOINTS=$pulse_fail"
  puts $ch "WORST_SETUP_START=$setup_start"
  puts $ch "WORST_SETUP_END=$setup_end"
  puts $ch "WORST_SETUP_DATA_DELAY_NS=$data_delay"
  puts $ch "WORST_SETUP_LOGIC_DELAY_NS=$logic_delay"
  puts $ch "WORST_SETUP_ROUTE_DELAY_NS=$route_delay"
  puts $ch "WORST_HOLD_START=$hold_start"
  puts $ch "WORST_HOLD_END=$hold_end"
  puts $ch "DRC_ERROR_COUNT=[llength $drc_errors]"
  puts $ch "UNROUTED_NET_COUNT=[llength $unrouted]"
  puts $ch "NO_CLOCK_REGISTERS=$no_clock"
  puts $ch "UNCONSTRAINED_INTERNAL_ENDPOINTS=$unconstrained"
  puts $ch "TOTAL_SLICE_LUTS=$lut"
  puts $ch "TOTAL_FF=$ff"
  puts $ch "TOTAL_RAMB36_OR_FIFO=$total_ramb36"
  puts $ch "TOTAL_RAMB18=$total_ramb18"
  puts $ch "TOTAL_DSP=$total_dsp"
  puts $ch "TOTAL_BUFGCTRL=$total_bufg"
  puts $ch "ACCELERATOR_RAMB36E1=$ramb36"
  puts $ch "ACCELERATOR_RAMB18E1=$ramb18"
  puts $ch "ACCELERATOR_DSP48E1=$dsp"
  puts $ch "ACCELERATOR_LUTRAM_OR_SRL=$lutram"
  set pass [expr {$wns >= 0.0 && $tns == 0.0 && $setup_fail == 0 &&
    $whs >= 0.0 && $ths == 0.0 && $hold_fail == 0 &&
    $pulse_fail == 0 && [llength $drc_errors] == 0 &&
    [llength $unrouted] == 0 && $no_clock == 0 && $unconstrained == 0 &&
    $ramb36 == 24 && $ramb18 == 1 && $dsp == 3 && $lutram == 0}]
  puts $ch "TIMING_AND_IMPLEMENTATION_PASS=$pass"
  close $ch
  close_design

  return [dict create label $label run $run_name strategy \
    [get_property STRATEGY $run] runtime $runtime_seconds wns $wns tns $tns \
    setup_fail $setup_fail whs $whs ths $ths hold_fail $hold_fail \
    pulse_fail $pulse_fail start $setup_start end $setup_end \
    data_delay $data_delay logic_delay $logic_delay route_delay $route_delay \
    drc_errors [llength $drc_errors] unrouted [llength $unrouted] \
    no_clock $no_clock unconstrained $unconstrained lut $lut ff $ff \
    total_ramb36 $total_ramb36 total_ramb18 $total_ramb18 \
    total_dsp $total_dsp total_bufg $total_bufg ramb36 $ramb36 ramb18 $ramb18 dsp $dsp \
    lutram $lutram pass $pass]
}

if {![file isfile $project_file]} {
  timing_fail "project does not exist: $project_file"
}
file mkdir $report_dir
open_project $project_file

set synth_run [require_one "synth_1 run" [get_runs -quiet synth_1]]
set baseline_run [require_one "impl_1 run" [get_runs -quiet impl_1]]
if {![string match "*Complete*" [get_property STATUS $synth_run]]} {
  timing_fail "synth_1 is not complete"
}
if {![string match "*Complete*" [get_property STATUS $baseline_run]]} {
  timing_fail "baseline impl_1 is not complete"
}

set candidate_specs {
  {performance_explore impl_performance_explore Performance_Explore route_design}
  {performance_postroute_physopt impl_performance_postroute_physopt Performance_ExplorePostRoutePhysOpt {phys_opt_design (Post-Route)}}
}

foreach spec $candidate_specs {
  lassign $spec label run_name strategy final_step
  set existing [get_runs -quiet $run_name]
  if {[llength $existing] == 0} {
    if {[catch {
      create_run $run_name -part [get_property PART [current_project]] \
        -flow {Vivado Implementation 2022} -strategy $strategy \
        -constrset constrs_1 -parent_run synth_1
    } error]} {
      timing_fail "Vivado 2022.2 does not support strategy '$strategy': $error"
    }
  } elseif {[llength $existing] != 1} {
    timing_fail "unexpected duplicate run name: $run_name"
  }
  set run [get_runs $run_name]
  if {[get_property STRATEGY $run] ne $strategy} {
    timing_fail "strategy mismatch for $run_name"
  }
}

set baseline_runtime [get_property STATS.ELAPSED $baseline_run]
if {$baseline_runtime eq ""} {
  set baseline_runtime existing_run
}
set baseline [report_candidate baseline impl_1 $baseline_runtime $report_dir]
set results [list $baseline]

foreach spec $candidate_specs {
  lassign $spec label run_name strategy final_step
  set run [get_runs $run_name]
  if {[string match "*Complete*" [get_property STATUS $run]]} {
    set runtime [get_property STATS.ELAPSED $run]
    if {$runtime eq ""} {
      set runtime existing_run
    }
  } else {
    if {[get_property STATUS $run] ne "Not started"} {
      reset_run $run_name
    }
    set started [clock seconds]
    launch_runs $run_name -to_step $final_step -jobs 8
    wait_on_run $run_name
    set runtime [expr {[clock seconds] - $started}]
    if {![string match "*Complete*" [get_property STATUS $run]]} {
      timing_fail "$run_name failed: [get_property STATUS $run]"
    }
  }
  lappend results [report_candidate $label $run_name $runtime $report_dir]
}

set best [lindex $results 0]
foreach result [lrange $results 1 end] {
  if {[dict get $result wns] > [dict get $best wns]} {
    set best $result
  }
}

set ch [open $comparison_file w]
puts $ch "VIVADO_VERSION=[version -short]"
puts $ch "GIT_HEAD=[string trim [exec git -C $repo_root rev-parse HEAD]]"
puts $ch "GIT_BRANCH=[string trim [exec git -C $repo_root branch --show-current]]"
puts $ch "SYNTH_CHECKPOINT_RUN=synth_1"
puts $ch "CLOCK=clk_fpga_0"
puts $ch "PERIOD_NS=10.000"
puts $ch "BASELINE_WNS_NS=-0.258"
puts $ch ""
puts $ch "LABEL|STRATEGY|WNS_NS|IMPROVEMENT_NS|TNS_NS|SETUP_FAIL|WHS_NS|THS_NS|HOLD_FAIL|PULSE_FAIL|DRC_ERROR|UNROUTED|RUNTIME|DATA_DELAY_NS|LOGIC_DELAY_NS|ROUTE_DELAY_NS|SLICE_LUTS|FF|TOTAL_RAMB36_FIFO|TOTAL_RAMB18|TOTAL_DSP|BUFGCTRL|ACCEL_RAMB36|ACCEL_RAMB18|ACCEL_DSP|ACCEL_LUTRAM_SRL|PASS"
foreach result $results {
  set improvement [expr {[dict get $result wns] - (-0.258)}]
  puts $ch "[dict get $result label]|[dict get $result strategy]|[dict get $result wns]|$improvement|[dict get $result tns]|[dict get $result setup_fail]|[dict get $result whs]|[dict get $result ths]|[dict get $result hold_fail]|[dict get $result pulse_fail]|[dict get $result drc_errors]|[dict get $result unrouted]|[dict get $result runtime]|[dict get $result data_delay]|[dict get $result logic_delay]|[dict get $result route_delay]|[dict get $result lut]|[dict get $result ff]|[dict get $result total_ramb36]|[dict get $result total_ramb18]|[dict get $result total_dsp]|[dict get $result total_bufg]|[dict get $result ramb36]|[dict get $result ramb18]|[dict get $result dsp]|[dict get $result lutram]|[dict get $result pass]"
  puts $ch "  WORST_PATH=[dict get $result start] -> [dict get $result end]"
}
puts $ch ""
puts $ch "BEST_LABEL=[dict get $best label]"
puts $ch "BEST_STRATEGY=[dict get $best strategy]"
puts $ch "BEST_WNS_NS=[dict get $best wns]"
puts $ch "BEST_PASS=[dict get $best pass]"
puts $ch "BITSTREAM_GENERATED=0"
close $ch

puts "TIMING STRATEGY COMPARISON COMPLETE"
puts "BEST: [dict get $best label] WNS=[dict get $best wns] PASS=[dict get $best pass]"
puts "BITSTREAM GENERATED: 0"
close_project
exit 0
