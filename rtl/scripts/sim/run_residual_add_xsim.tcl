set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
cd $repo_root

if {[catch {exec xvlog --sv -f scripts/sim/directed_files.f} result]} {
  puts stderr $result
  exit 1
}
puts $result
if {[catch {exec xelab tb_op_residual_add_directed -s residual_add_directed_sim -timescale 1ns/1ps} result]} {
  puts stderr $result
  exit 2
}
puts $result
if {[catch {exec xsim residual_add_directed_sim -runall} result]} {
  puts stderr $result
  exit 3
}
puts $result
if {![string match "*DIRECTED PASS:*" $result]} {
  puts stderr "ERROR: directed simulation did not report DIRECTED PASS"
  exit 4
}
exit 0
