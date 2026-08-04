set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
cd $repo_root

set common_sources [list \
  rtl/common/sat_add_int32.sv \
  rtl/common/requantizer.sv \
  rtl/common/relu_clamp.sv]

set tests [list \
  [list tb_sat_add_int32 tb/tb_sat_add_int32.sv unit_sat_add] \
  [list tb_requantizer tb/tb_requantizer.sv unit_requantizer] \
  [list tb_relu_clamp tb/tb_relu_clamp.sv unit_relu_clamp]]

if {[catch {exec xvlog --sv {*}$common_sources} result]} {
  puts stderr $result
  exit 1
}
puts $result

set pass_count 0
foreach test $tests {
  lassign $test top tb snapshot
  puts "INFO: compiling $tb"
  if {[catch {exec xvlog --sv $tb} result]} {
    puts stderr $result
    exit 2
  }
  puts $result

  puts "INFO: elaborating $top"
  if {[catch {exec xelab $top -s $snapshot -timescale 1ns/1ps} result]} {
    puts stderr $result
    exit 3
  }
  puts $result

  puts "INFO: simulating $top"
  if {[catch {exec xsim $snapshot -runall} result]} {
    puts stderr $result
    exit 4
  }
  puts $result
  if {![string match "*UNIT PASS:*" $result]} {
    puts stderr "ERROR: $top did not report UNIT PASS"
    exit 5
  }
  incr pass_count
}

puts "UNIT REGRESSION PASS: $pass_count tests"
exit 0
