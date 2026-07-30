set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
cd $repo_root

puts "INFO: repository root is $repo_root"
puts "INFO: compiling SystemVerilog sources"
if {[catch {exec xvlog --sv -f scripts/sim/files.f} compile_result]} {
  puts stderr $compile_result
  exit 1
}
puts $compile_result

puts "INFO: elaborating tb_resnet_accel_top"
if {[catch {exec xelab tb_resnet_accel_top -s smoke_sim -debug typical -timescale 1ns/1ps} elaborate_result]} {
  puts stderr $elaborate_result
  exit 2
}
puts $elaborate_result

puts "INFO: running smoke simulation"
if {[catch {exec xsim smoke_sim -runall} simulation_result]} {
  puts stderr $simulation_result
  exit 3
}
puts $simulation_result
if {![string match "*SMOKE PASS:*" $simulation_result]} {
  puts stderr "ERROR: smoke simulation did not report SMOKE PASS"
  exit 4
}
exit 0

