set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
set project_file [file join $repo_root build vivado_zybo resnet_accel_zybo resnet_accel_zybo.xpr]
set report_dir [file join $repo_root build vivado_zybo reports]
set artifact_dir [file join $repo_root build vivado_zybo artifacts]
set run_name impl_performance_postroute_physopt
set expected_strategy Performance_ExplorePostRoutePhysOpt
set expected_run_status {phys_opt_design (Post-Route) Complete!}
set checkpoint_file [file join $repo_root build vivado_zybo resnet_accel_zybo \
  resnet_accel_zybo.runs $run_name zybo_resnet_system_wrapper_postroute_physopt.dcp]
set timing_report [file join $report_dir pre_bitstream_timing_summary.rpt]
set drc_report [file join $report_dir pre_bitstream_drc.rpt]
set route_report [file join $report_dir pre_bitstream_route_status.rpt]
set check_report [file join $report_dir pre_bitstream_check_timing.rpt]
set manifest_file [file join $report_dir bitstream_xsa_manifest.txt]
set session_log [file join $report_dir generate_bitstream_xsa.log]
set bit_file [file join $artifact_dir zybo_resnet_system.bit]
set xsa_file [file join $artifact_dir zybo_resnet_system.xsa]
set checkpoint_backup_dir [file join $repo_root build vivado_zybo checkpoint_backups]

proc phase3d2_fail {message} {
  puts stderr "ERROR: PHASE3D2: $message"
  exit 5
}

proc require_one {description objects} {
  if {[llength $objects] != 1} {
    phase3d2_fail "$description: expected one object, got [llength $objects]"
  }
  return [lindex $objects 0]
}

proc require_equal {description actual expected} {
  if {$actual ne $expected} {
    phase3d2_fail "$description mismatch: expected '$expected', got '$actual'"
  }
}

proc require_file {description path} {
  if {![file isfile $path] || [file size $path] <= 0} {
    phase3d2_fail "$description is missing or empty: $path"
  }
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

proc check_timing_count {path category} {
  set channel [open $path r]
  set contents [read $channel]
  close $channel
  if {![regexp "checking ${category} \\(([0-9]+)\\)" $contents -> count]} {
    phase3d2_fail "could not parse check_timing category '$category' from $path"
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
  phase3d2_fail "could not parse timing summary metrics from $path"
}

proc mapped_segments {segment_name} {
  set matches {}
  foreach segment [get_bd_addr_segs -quiet] {
    if {[get_property NAME $segment] eq $segment_name &&
        [get_property OFFSET $segment] ne ""} {
      lappend matches $segment
    }
  }
  return $matches
}

proc require_address {description segment_name expected_offset expected_range expected_count} {
  set segments [mapped_segments $segment_name]
  if {[llength $segments] != $expected_count} {
    phase3d2_fail "$description mapping count mismatch: expected $expected_count, got [llength $segments]"
  }
  foreach segment $segments {
    require_equal "$description base" [string toupper [get_property OFFSET $segment]] \
      [string toupper $expected_offset]
    require_equal "$description range" [string toupper [get_property RANGE $segment]] \
      [string toupper $expected_range]
  }
}

proc sha256_file {path} {
  if {[catch {exec sha256sum $path} result]} {
    phase3d2_fail "sha256sum failed for $path: $result"
  }
  return [string tolower [lindex $result 0]]
}

proc immutable_file_state {path} {
  if {![file isfile $path]} {
    phase3d2_fail "immutable implementation result is missing: $path"
  }
  return [list [file size $path] [file mtime $path] [sha256_file $path]]
}

proc log_message_count {path prefix} {
  if {![file isfile $path]} {
    return -1
  }
  set channel [open $path r]
  set contents [read $channel]
  close $channel
  return [regexp -all -line "^${prefix}" $contents]
}

if {![file isfile $project_file]} {
  phase3d2_fail "Vivado project does not exist: $project_file"
}
require_file "timing-PASS checkpoint" $checkpoint_file
file mkdir $report_dir
file mkdir $artifact_dir

open_project $project_file
require_equal "Vivado version" [version -short] 2022.2
require_equal "FPGA part" [get_property PART [current_project]] xc7z020clg400-1
require_equal "board part" [get_property BOARD_PART [current_project]] \
  digilentinc.com:zybo-z7-20:part0:1.2
require_equal "project top" [get_property TOP [get_filesets sources_1]] \
  zybo_resnet_system_wrapper

set run [require_one "$run_name run" [get_runs -quiet $run_name]]
require_equal "implementation strategy" [get_property STRATEGY $run] $expected_strategy
set run_status_before [get_property STATUS $run]
set run_progress_before [get_property PROGRESS $run]
set run_directory [file normalize [get_property DIRECTORY $run]]
require_equal "implementation run directory" $run_directory [file dirname $checkpoint_file]
set official_run_bit [file join $run_directory zybo_resnet_system_wrapper.bit]
set write_bitstream_already_complete \
  [string match "*write_bitstream*Complete*" $run_status_before]
if {$run_status_before ne $expected_run_status && !$write_bitstream_already_complete} {
  phase3d2_fail "implementation run is neither post-route timing PASS nor write_bitstream complete: $run_status_before"
}
if {$write_bitstream_already_complete} {
  require_file "official run bitstream" $official_run_bit
}

set protected_implementation_files [glob -nocomplain -directory $run_directory *.dcp]
lappend protected_implementation_files \
  [file join $run_directory .place_design.end.rst] \
  [file join $run_directory .route_design.end.rst] \
  [file join $run_directory .post_route_phys_opt_design.end.rst]
set protected_states_before [dict create]
foreach protected_file $protected_implementation_files {
  dict set protected_states_before $protected_file [immutable_file_state $protected_file]
}
file mkdir $checkpoint_backup_dir
set checkpoint_backup [file join $checkpoint_backup_dir \
  zybo_resnet_system_wrapper_postroute_physopt_before_write_bitstream.dcp]
if {[file exists $checkpoint_backup]} {
  require_equal "checkpoint backup SHA-256" [sha256_file $checkpoint_backup] \
    [sha256_file $checkpoint_file]
} else {
  file copy $checkpoint_file $checkpoint_backup
}
require_file "timing-PASS checkpoint backup" $checkpoint_backup
set previous_artifact_sha256 NONE
if {[file isfile $bit_file] && [file size $bit_file] > 0} {
  set previous_artifact_sha256 [sha256_file $bit_file]
}
set bd_file [require_one "zybo_resnet_system BD" [get_files -quiet */zybo_resnet_system.bd]]
open_bd_design $bd_file
require_equal "BD name" [current_bd_design] zybo_resnet_system
set ps_cell [require_one "processing_system7_0 instance" \
  [get_bd_cells -quiet processing_system7_0]]
set dma_cell [require_one "axi_dma_0 instance" [get_bd_cells -quiet axi_dma_0]]
set accel_cell [require_one "resnet_accel_0 instance" \
  [get_bd_cells -quiet resnet_accel_0]]
require_equal "processing system VLNV" [get_property VLNV $ps_cell] \
  xilinx.com:ip:processing_system7:5.5
require_equal "AXI DMA VLNV" [get_property VLNV $dma_cell] \
  xilinx.com:ip:axi_dma:7.1
require_equal "accelerator VLNV" [get_property VLNV $accel_cell] \
  jmhwang.local:npu:resnet_accel:1.0
set fclk_mhz [get_property CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ $ps_cell]
if {$fclk_mhz eq "" || [expr {abs(double($fclk_mhz) - 100.0)}] > 0.000001} {
  phase3d2_fail "FCLK_CLK0 frequency mismatch: expected 100 MHz, got '$fclk_mhz'"
}
require_address "accelerator control" SEG_resnet_accel_0_Reg \
  0x43C00000 0x00010000 1
require_address "DMA control" SEG_axi_dma_0_Reg \
  0x40400000 0x00010000 1
require_address "DMA DDR/Low-OCM" SEG_processing_system7_0_HP0_DDR_LOWOCM \
  0x00000000 0x40000000 2
close_bd_design [current_bd_design]

open_run $run_name
require_equal "open implemented design" [current_design] $run_name
set clocks [get_clocks -quiet]
if {[llength $clocks] != 1} {
  phase3d2_fail "expected exactly one implemented clock, got [llength $clocks]"
}
set clock_object [lindex $clocks 0]
require_equal "implemented clock name" [get_property NAME $clock_object] clk_fpga_0
set clock_period [get_property PERIOD $clock_object]
if {[expr {abs(double($clock_period) - 10.0)}] > 0.000001} {
  phase3d2_fail "implemented clock period mismatch: expected 10.000 ns, got $clock_period"
}

report_timing_summary -delay_type min_max -report_unconstrained \
  -file $timing_report
report_drc -file $drc_report
report_route_status -file $route_report
check_timing -verbose -file $check_report

lassign [timing_summary_metrics $timing_report] \
  setup_wns setup_tns setup_fail hold_whs hold_ths hold_fail \
  pulse_wns pulse_tns pulse_fail
set drc_errors [get_drc_violations -quiet -filter {SEVERITY == Error}]
set drc_warnings [get_drc_violations -quiet -filter {SEVERITY == Warning}]
set drc_advisories [get_drc_violations -quiet -filter {SEVERITY == Advisory}]
set unrouted_nets [get_nets -quiet -hierarchical -filter {ROUTE_STATUS == UNROUTED}]
set no_clock [check_timing_count $check_report no_clock]
set unconstrained [check_timing_count $check_report unconstrained_internal_endpoints]

set accel_pattern *resnet_accel_0*
set accel_hierarchy [get_cells -quiet -hierarchical -filter \
  {NAME =~ *resnet_accel_0 && IS_PRIMITIVE == 0}]
if {[llength $accel_hierarchy] == 0} {
  phase3d2_fail "implemented accelerator hierarchy is missing"
}
set accel_ramb36 [count_cells $accel_pattern RAMB36E1]
set accel_ramb18 [count_cells $accel_pattern RAMB18E1]
set accel_dsp [count_cells $accel_pattern DSP48E1]
set accel_lutram [count_lutram_cells $accel_pattern]

if {$setup_wns < 0.0 || $setup_tns != 0.0 || $setup_fail != 0} {
  phase3d2_fail "setup timing failed: WNS=$setup_wns TNS=$setup_tns endpoints=$setup_fail"
}
if {$hold_whs < 0.0 || $hold_ths != 0.0 || $hold_fail != 0} {
  phase3d2_fail "hold timing failed: WHS=$hold_whs THS=$hold_ths endpoints=$hold_fail"
}
if {$pulse_fail != 0} {
  phase3d2_fail "pulse-width timing failed: endpoints=$pulse_fail"
}
if {[llength $drc_errors] != 0} {
  phase3d2_fail "pre-bitstream DRC has [llength $drc_errors] errors"
}
if {[llength $unrouted_nets] != 0} {
  phase3d2_fail "implemented design has [llength $unrouted_nets] unrouted nets"
}
if {$no_clock != 0 || $unconstrained != 0} {
  phase3d2_fail "timing coverage failed: no_clock=$no_clock unconstrained=$unconstrained"
}
if {$accel_ramb36 != 24 || $accel_ramb18 != 1 || $accel_dsp != 3 ||
    $accel_lutram != 0} {
  phase3d2_fail "accelerator structure mismatch: RAMB36=$accel_ramb36 RAMB18=$accel_ramb18 DSP=$accel_dsp LUTRAM/SRL=$accel_lutram"
}

puts "PHASE3D2: all pre-bitstream acceptance checks passed"
set pre_setup_wns $setup_wns
set pre_setup_tns $setup_tns
set pre_setup_fail $setup_fail
set pre_hold_whs $hold_whs
set pre_hold_ths $hold_ths
set pre_hold_fail $hold_fail
close_design

set official_write_bitstream_launched 0
if {!$write_bitstream_already_complete} {
  puts "PHASE3D2: launching only the official write_bitstream run step"
  if {[catch {
    launch_runs $run_name -to_step write_bitstream -jobs 8
    wait_on_run $run_name
  } launch_error]} {
    phase3d2_fail "official write_bitstream run step failed: $launch_error"
  }
  set official_write_bitstream_launched 1
}

set run [require_one "$run_name run after write_bitstream" [get_runs -quiet $run_name]]
set run_status_after [get_property STATUS $run]
set run_progress_after [get_property PROGRESS $run]
if {![string match "*write_bitstream*Complete*" $run_status_after]} {
  phase3d2_fail "Vivado did not register the official run bitstream: status=$run_status_after"
}
require_file "official run bitstream" $official_run_bit

foreach protected_file $protected_implementation_files {
  set state_after [immutable_file_state $protected_file]
  require_equal "protected implementation result $protected_file" $state_after \
    [dict get $protected_states_before $protected_file]
}
set implementation_steps_reexecuted NO
set official_run_bit_sha256 [sha256_file $official_run_bit]
set official_run_bit_mtime [file mtime $official_run_bit]

open_run $run_name
require_equal "post-bitstream implemented design" [current_design] $run_name
set clocks [get_clocks -quiet]
if {[llength $clocks] != 1} {
  phase3d2_fail "post-bitstream clock count mismatch: [llength $clocks]"
}
set clock_object [lindex $clocks 0]
require_equal "post-bitstream clock name" [get_property NAME $clock_object] clk_fpga_0
set clock_period [get_property PERIOD $clock_object]
if {[expr {abs(double($clock_period) - 10.0)}] > 0.000001} {
  phase3d2_fail "post-bitstream clock period mismatch: $clock_period"
}

report_timing_summary -delay_type min_max -report_unconstrained \
  -file $timing_report
report_drc -file $drc_report
report_route_status -file $route_report
check_timing -verbose -file $check_report
lassign [timing_summary_metrics $timing_report] \
  setup_wns setup_tns setup_fail hold_whs hold_ths hold_fail \
  pulse_wns pulse_tns pulse_fail
set drc_errors [get_drc_violations -quiet -filter {SEVERITY == Error}]
set drc_warnings [get_drc_violations -quiet -filter {SEVERITY == Warning}]
set drc_advisories [get_drc_violations -quiet -filter {SEVERITY == Advisory}]
set unrouted_nets [get_nets -quiet -hierarchical -filter {ROUTE_STATUS == UNROUTED}]
set no_clock [check_timing_count $check_report no_clock]
set unconstrained [check_timing_count $check_report unconstrained_internal_endpoints]
if {$setup_wns < 0.0 || $setup_tns != 0.0 || $setup_fail != 0} {
  phase3d2_fail "post-bitstream setup timing failed: WNS=$setup_wns TNS=$setup_tns endpoints=$setup_fail"
}
if {$hold_whs < 0.0 || $hold_ths != 0.0 || $hold_fail != 0} {
  phase3d2_fail "post-bitstream hold timing failed: WHS=$hold_whs THS=$hold_ths endpoints=$hold_fail"
}
if {$pulse_fail != 0 || [llength $drc_errors] != 0 ||
    [llength $unrouted_nets] != 0 || $no_clock != 0 || $unconstrained != 0} {
  phase3d2_fail "post-bitstream acceptance failed: pulse=$pulse_fail DRC=[llength $drc_errors] unrouted=[llength $unrouted_nets] no_clock=$no_clock unconstrained=$unconstrained"
}
set post_bitstream_drc_errors $drc_errors

file copy -force $official_run_bit $bit_file
require_file "official bitstream artifact copy" $bit_file
set bit_sha256 [sha256_file $bit_file]
require_equal "artifact copy SHA-256" $bit_sha256 $official_run_bit_sha256
set previous_artifact_matches_official [expr {$previous_artifact_sha256 ne "NONE" &&
  $previous_artifact_sha256 eq $official_run_bit_sha256}]

if {[catch {
  write_hw_platform -fixed -force -include_bit $xsa_file
} xsa_error]} {
  phase3d2_fail "write_hw_platform failed: $xsa_error"
}
require_file "generated XSA" $xsa_file

if {[catch {exec unzip -t $xsa_file} archive_test]} {
  phase3d2_fail "XSA archive integrity test failed: $archive_test"
}
if {[catch {exec unzip -Z1 $xsa_file} archive_listing]} {
  phase3d2_fail "could not list XSA archive: $archive_listing"
}
set archive_members [split [string trim $archive_listing] "\n"]
set bit_members {}
set hwh_members {}
foreach member $archive_members {
  if {[string match -nocase *.bit $member]} {
    lappend bit_members $member
  }
  if {[string match -nocase *.hwh $member]} {
    lappend hwh_members $member
  }
}
if {[llength $bit_members] != 1} {
  phase3d2_fail "XSA must contain exactly one bitstream, found [llength $bit_members]"
}
if {[llength $hwh_members] < 1} {
  phase3d2_fail "XSA contains no hardware handoff metadata (.hwh)"
}

set embedded_bit_temp [file join $artifact_dir .xsa_embedded_bit.tmp]
if {[catch {
  exec unzip -p $xsa_file [lindex $bit_members 0] > $embedded_bit_temp
} extract_error]} {
  phase3d2_fail "could not extract XSA bitstream for validation: $extract_error"
}
require_file "XSA embedded bitstream" $embedded_bit_temp
set bit_sha256 [sha256_file $bit_file]
set embedded_bit_sha256 [sha256_file $embedded_bit_temp]
file delete -force $embedded_bit_temp
require_equal "XSA embedded bitstream SHA-256" $embedded_bit_sha256 $bit_sha256

set hwh_text ""
foreach member $hwh_members {
  if {[catch {exec unzip -p $xsa_file $member} member_text]} {
    phase3d2_fail "could not read XSA metadata member $member: $member_text"
  }
  append hwh_text "\n" $member_text
}
set hwh_lower [string tolower $hwh_text]
foreach required_token {
  processing_system7_0
  zybo_resnet_system
  resnet_accel_0
  jmhwang.local:npu:resnet_accel:1.0
  axi_dma_0
  43c00000
  43c0ffff
  40400000
  4040ffff
  3fffffff
} {
  if {[string first [string tolower $required_token] $hwh_lower] < 0} {
    phase3d2_fail "XSA hardware metadata is missing '$required_token'"
  }
}

set xsa_sha256 [sha256_file $xsa_file]
set git_branch [string trim [exec git -C $repo_root branch --show-current]]
set git_head [string trim [exec git -C $repo_root rev-parse HEAD]]
set git_status [string trim [exec git -C $repo_root status --short]]
flush stdout
set log_warning_count [log_message_count $session_log WARNING:]
set log_critical_warning_count [log_message_count $session_log {CRITICAL WARNING:}]
set log_error_count [log_message_count $session_log ERROR:]

set manifest [open $manifest_file w]
puts $manifest "GENERATED_AT=[clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%S%z}]"
puts $manifest "VIVADO_VERSION=[version -short]"
puts $manifest "GIT_BRANCH=$git_branch"
puts $manifest "GIT_HEAD=$git_head"
puts $manifest "WORKTREE_STATUS_BEGIN"
if {$git_status eq ""} {
  puts $manifest "CLEAN"
} else {
  puts $manifest $git_status
}
puts $manifest "WORKTREE_STATUS_END"
puts $manifest "BOARD=Zybo Z7-20"
puts $manifest "BOARD_PART=[get_property BOARD_PART [current_project]]"
puts $manifest "FPGA_PART=[get_property PART [current_project]]"
puts $manifest "BD=zybo_resnet_system"
puts $manifest "TOP=[get_property TOP [get_filesets sources_1]]"
puts $manifest "IMPLEMENTATION_STRATEGY=$expected_strategy"
puts $manifest "IMPLEMENTATION_RUN=$run_name"
puts $manifest "IMPLEMENTATION_RUN_STATUS_BEFORE=$run_status_before"
puts $manifest "IMPLEMENTATION_RUN_PROGRESS_BEFORE=$run_progress_before"
puts $manifest "IMPLEMENTATION_RUN_STATUS_AFTER=$run_status_after"
puts $manifest "IMPLEMENTATION_RUN_PROGRESS_AFTER=$run_progress_after"
puts $manifest "WRITE_BITSTREAM_RUN_STEP_LAUNCHED=$official_write_bitstream_launched"
puts $manifest "WRITE_BITSTREAM_RUN_STEP_STATUS=$run_status_after"
puts $manifest "IMPLEMENTATION_STEPS_REEXECUTED=$implementation_steps_reexecuted"
puts $manifest "IMPLEMENTATION_RESULTS_IMMUTABLE_CHECK=PASS"
puts $manifest "IMPLEMENTATION_CHECKPOINT=$checkpoint_file"
puts $manifest "IMPLEMENTATION_CHECKPOINT_BACKUP=$checkpoint_backup"
puts $manifest "IMPLEMENTATION_CHECKPOINT_SHA256=[sha256_file $checkpoint_file]"
foreach protected_file $protected_implementation_files {
  set protected_label [string map {. _ - _} [file tail $protected_file]]
  set protected_before [dict get $protected_states_before $protected_file]
  set protected_after [immutable_file_state $protected_file]
  puts $manifest "IMPLEMENTATION_FILE_${protected_label}_SIZE_BEFORE=[lindex $protected_before 0]"
  puts $manifest "IMPLEMENTATION_FILE_${protected_label}_MTIME_BEFORE=[lindex $protected_before 1]"
  puts $manifest "IMPLEMENTATION_FILE_${protected_label}_SHA256_BEFORE=[lindex $protected_before 2]"
  puts $manifest "IMPLEMENTATION_FILE_${protected_label}_SIZE_AFTER=[lindex $protected_after 0]"
  puts $manifest "IMPLEMENTATION_FILE_${protected_label}_MTIME_AFTER=[lindex $protected_after 1]"
  puts $manifest "IMPLEMENTATION_FILE_${protected_label}_SHA256_AFTER=[lindex $protected_after 2]"
}
puts $manifest "CLOCK=clk_fpga_0"
puts $manifest "CLOCK_PERIOD_NS=$clock_period"
puts $manifest "FCLK_CLK0_MHZ=$fclk_mhz"
puts $manifest "PRE_WRITE_BITSTREAM_SETUP_WNS_NS=$pre_setup_wns"
puts $manifest "PRE_WRITE_BITSTREAM_SETUP_TNS_NS=$pre_setup_tns"
puts $manifest "PRE_WRITE_BITSTREAM_SETUP_FAILING_ENDPOINTS=$pre_setup_fail"
puts $manifest "PRE_WRITE_BITSTREAM_HOLD_WHS_NS=$pre_hold_whs"
puts $manifest "PRE_WRITE_BITSTREAM_HOLD_THS_NS=$pre_hold_ths"
puts $manifest "PRE_WRITE_BITSTREAM_HOLD_FAILING_ENDPOINTS=$pre_hold_fail"
puts $manifest "SETUP_WNS_NS=$setup_wns"
puts $manifest "SETUP_TNS_NS=$setup_tns"
puts $manifest "SETUP_FAILING_ENDPOINTS=$setup_fail"
puts $manifest "HOLD_WHS_NS=$hold_whs"
puts $manifest "HOLD_THS_NS=$hold_ths"
puts $manifest "HOLD_FAILING_ENDPOINTS=$hold_fail"
puts $manifest "PULSE_WIDTH_WORST_SLACK_NS=$pulse_wns"
puts $manifest "PULSE_WIDTH_TOTAL_NEGATIVE_SLACK_NS=$pulse_tns"
puts $manifest "PULSE_WIDTH_FAILING_ENDPOINTS=$pulse_fail"
puts $manifest "DRC_ERROR_COUNT=[llength $drc_errors]"
puts $manifest "DRC_WARNING_COUNT=[llength $drc_warnings]"
puts $manifest "DRC_ADVISORY_COUNT=[llength $drc_advisories]"
puts $manifest "POST_BITSTREAM_DRC_ERROR_COUNT=[llength $post_bitstream_drc_errors]"
puts $manifest "UNROUTED_NET_COUNT=[llength $unrouted_nets]"
puts $manifest "NO_CLOCK_REGISTERS=$no_clock"
puts $manifest "UNCONSTRAINED_INTERNAL_ENDPOINTS=$unconstrained"
puts $manifest "ACCELERATOR_RAMB36E1=$accel_ramb36"
puts $manifest "ACCELERATOR_RAMB18E1=$accel_ramb18"
puts $manifest "ACCELERATOR_DSP48E1=$accel_dsp"
puts $manifest "ACCELERATOR_LUTRAM_OR_SRL=$accel_lutram"
puts $manifest "ACCELERATOR_INSTANCE=resnet_accel_0"
puts $manifest "ACCELERATOR_VLNV=jmhwang.local:npu:resnet_accel:1.0"
puts $manifest "ACCELERATOR_BASE=0x43C00000"
puts $manifest "ACCELERATOR_HIGH=0x43C0FFFF"
puts $manifest "DMA_INSTANCE=axi_dma_0"
puts $manifest "DMA_BASE=0x40400000"
puts $manifest "DMA_HIGH=0x4040FFFF"
puts $manifest "DMA_DDR_BASE=0x00000000"
puts $manifest "DMA_DDR_HIGH=0x3FFFFFFF"
puts $manifest "BITSTREAM_STATUS=PASS"
puts $manifest "OFFICIAL_RUN_BITSTREAM_PATH=$official_run_bit"
puts $manifest "OFFICIAL_RUN_BITSTREAM_SIZE_BYTES=[file size $official_run_bit]"
puts $manifest "OFFICIAL_RUN_BITSTREAM_MTIME=[clock format $official_run_bit_mtime -format {%Y-%m-%dT%H:%M:%S%z}]"
puts $manifest "OFFICIAL_RUN_BITSTREAM_SHA256=$official_run_bit_sha256"
puts $manifest "PREVIOUS_EXTERNAL_ARTIFACT_SHA256=$previous_artifact_sha256"
puts $manifest "PREVIOUS_EXTERNAL_ARTIFACT_MATCHES_OFFICIAL=$previous_artifact_matches_official"
puts $manifest "BITSTREAM_ARTIFACT_SOURCE=OFFICIAL_RUN_BITSTREAM_COPY"
puts $manifest "BITSTREAM_PATH=$bit_file"
puts $manifest "BITSTREAM_SIZE_BYTES=[file size $bit_file]"
puts $manifest "BITSTREAM_MTIME=[clock format [file mtime $bit_file] -format {%Y-%m-%dT%H:%M:%S%z}]"
puts $manifest "BITSTREAM_SHA256=$bit_sha256"
puts $manifest "XSA_STATUS=PASS"
puts $manifest "XSA_PATH=$xsa_file"
puts $manifest "XSA_SIZE_BYTES=[file size $xsa_file]"
puts $manifest "XSA_MTIME=[clock format [file mtime $xsa_file] -format {%Y-%m-%dT%H:%M:%S%z}]"
puts $manifest "XSA_SHA256=$xsa_sha256"
puts $manifest "XSA_ARCHIVE_TEST=PASS"
puts $manifest "XSA_BITSTREAM_INCLUDED=1"
puts $manifest "XSA_BITSTREAM_MEMBER=[lindex $bit_members 0]"
puts $manifest "XSA_BITSTREAM_SHA256=$embedded_bit_sha256"
puts $manifest "XSA_HWH_MEMBERS=[join $hwh_members ,]"
puts $manifest "XSA_METADATA_PS_ADDRESS_IP_VALIDATION=PASS"
puts $manifest "SESSION_WARNING_COUNT=$log_warning_count"
puts $manifest "SESSION_CRITICAL_WARNING_COUNT=$log_critical_warning_count"
puts $manifest "SESSION_ERROR_COUNT=$log_error_count"
puts $manifest "PRE_BITSTREAM_TIMING_REPORT=$timing_report"
puts $manifest "PRE_BITSTREAM_DRC_REPORT=$drc_report"
puts $manifest "PRE_BITSTREAM_ROUTE_REPORT=$route_report"
puts $manifest "PRE_BITSTREAM_CHECK_TIMING_REPORT=$check_report"
puts $manifest "VITIS_PLATFORM=NOT_STARTED"
puts $manifest "FIRMWARE_ELF=NOT_STARTED"
puts $manifest "FSBL=NOT_STARTED"
puts $manifest "BOOT_BIN=NOT_STARTED"
puts $manifest "PHYSICAL_BOARD_TEST=NOT_STARTED"
puts $manifest "PHASE3D2_ACCEPTANCE=PASS"
close $manifest

require_file "bitstream/XSA manifest" $manifest_file
puts "PHASE3D2: bitstream and bitstream-included XSA generation passed"
puts "PHASE3D2: bitstream=$bit_file"
puts "PHASE3D2: xsa=$xsa_file"
puts "PHASE3D2: manifest=$manifest_file"
close_project
exit 0
