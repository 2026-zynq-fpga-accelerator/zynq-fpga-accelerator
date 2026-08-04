set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
cd $repo_root

if {[catch {exec xvlog --sv -f scripts/sim/full_conv_files.f} result]} {
  puts stderr $result
  exit 1
}
puts $result
if {[catch {exec xelab tb_full_conv -s full_conv_sim -timescale 1ns/1ps} result]} {
  puts stderr $result
  exit 2
}
puts $result
if {[catch {exec xsim full_conv_sim -runall} result]} {
  puts stderr $result
  exit 3
}
puts $result
if {![string match "*FULL CONV PASS:*" $result]} {
  puts stderr "ERROR: full convolution did not report FULL CONV PASS"
  exit 4
}
exit 0
