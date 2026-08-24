# Generates utilization reports from the *actual* run used to produce the shipped bitstream
# (impl_performance_postroute_physopt), not the default impl_1 run. build_zybo_implementation.tcl
# always operates on impl_1, whose timing/resources can differ from whichever strategy actually
# won and shipped -- report_shipped_bitstream_utilization.rpt/_hierarchical.rpt are the
# release-accurate counterparts to build_zybo_implementation.tcl's post_route_utilization*.rpt.
set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
set project_file [file join $repo_root build vivado_zybo resnet_accel_zybo resnet_accel_zybo.xpr]
set report_dir [file join $repo_root build vivado_zybo reports]
set run_name impl_performance_postroute_physopt

open_project $project_file
open_run $run_name

report_utilization -file [file join $report_dir pre_bitstream_utilization.rpt]
report_utilization -hierarchical \
  -file [file join $report_dir pre_bitstream_utilization_hierarchical.rpt]

puts "SHIPPED BITSTREAM UTILIZATION REPORT PASS"
close_project
exit 0
