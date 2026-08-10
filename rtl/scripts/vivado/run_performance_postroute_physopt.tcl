set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
set project_file [file join $repo_root build vivado_zybo resnet_accel_zybo resnet_accel_zybo.xpr]
set run_name impl_performance_postroute_physopt
set strategy Performance_ExplorePostRoutePhysOpt
set expected_run_status {phys_opt_design (Post-Route) Complete!}

if {![file isfile $project_file]} {
  puts stderr "ERROR: project not found: $project_file"
  exit 1
}

open_project $project_file

if {[llength [get_runs -quiet $run_name]] == 0} {
  create_run $run_name -parent_run synth_1 -flow {Vivado Implementation 2022} \
    -strategy $strategy
} else {
  set existing_strategy [get_property STRATEGY [get_runs $run_name]]
  if {$existing_strategy ne $strategy} {
    puts stderr "ERROR: existing run $run_name has strategy $existing_strategy, expected $strategy"
    exit 2
  }
  reset_run $run_name
}

set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED 1 [get_runs $run_name]

launch_runs $run_name -to_step {phys_opt_design (Post-Route)} -jobs 8
wait_on_run $run_name

set run [get_runs $run_name]
set status [get_property STATUS $run]
puts "RUN_STATUS: $status"
if {$status ne $expected_run_status} {
  puts stderr "ERROR: run did not reach expected status. Got: $status"
  exit 3
}

open_run $run_name
report_timing_summary -delay_type min_max -report_unconstrained \
  -file [file join $repo_root build vivado_zybo reports postroute_physopt_timing_summary.rpt]

puts "PHYSOPT RUN PASS: $run_name status=$status"
close_project
exit 0
