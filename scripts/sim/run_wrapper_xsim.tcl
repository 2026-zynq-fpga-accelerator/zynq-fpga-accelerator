set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
cd $repo_root

if {[catch {exec xvlog --sv -i . -f scripts/sim/files_wrapper.f} result]} {
  puts stderr $result
  exit 1
}
puts $result

foreach test {
  {tb_resnet_accel_ip_wrapper wrapper_smoke_sim {SMOKE PASS: 64 output bytes matched}}
  {tb_resnet_accel_ip_wrapper_full_conv wrapper_full_conv_sim {FULL CONV PASS: 16384 output bytes, mismatch=0}}
} {
  lassign $test top snapshot marker
  if {[catch {exec xelab $top -s $snapshot -timescale 1ns/1ps} result]} {
    puts stderr $result
    exit 2
  }
  puts $result
  if {[catch {exec xsim $snapshot -runall} result]} {
    puts stderr $result
    exit 3
  }
  puts $result
  if {![string match "*${marker}*" $result]} {
    puts stderr "ERROR: $top did not report $marker"
    exit 4
  }
}

puts "WRAPPER REGRESSION PASS: smoke and full convolution"
exit 0
