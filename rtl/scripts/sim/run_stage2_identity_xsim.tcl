set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
cd $repo_root

if {[catch {exec xvlog --sv -f scripts/sim/full_conv_files.f} result]} {
  puts stderr $result
  exit 1
}
puts $result
if {[catch {exec xelab tb_stage2_identity_block -s stage2_identity_sim -timescale 1ns/1ps} result]} {
  puts stderr $result
  exit 2
}
puts $result
if {[catch {exec xsim stage2_identity_sim -runall} result]} {
  puts stderr $result
  exit 3
}
puts $result
if {![string match "*STAGE2 IDENTITY BLOCK PASS:*" $result]} {
  puts stderr "ERROR: stage-2 identity block simulation did not report PASS"
  exit 4
}
exit 0
