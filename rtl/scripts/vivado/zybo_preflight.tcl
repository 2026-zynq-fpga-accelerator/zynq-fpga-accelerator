# Read-only Zybo Z7-20 inventory preflight.
#
# This script intentionally performs only catalog/property queries. It does not
# create a project, read or modify a design, synthesize, package IP, create a
# block design, implement, or generate programming/export artifacts.

proc property_if_present {object property_name} {
  set available [list_property $object]
  if {[lsearch -exact $available $property_name] >= 0} {
    return [get_property $property_name $object]
  }
  return "<property-not-present>"
}

puts "PREFLIGHT_VIVADO_VERSION=[version -short]"

set repo_paths [get_param board.repoPaths]
puts "PREFLIGHT_BOARD_REPO_PATHS=$repo_paths"

set zybo_parts [lsort -dictionary [get_board_parts -quiet *zybo*]]
puts "PREFLIGHT_ZYBO_BOARD_PART_COUNT=[llength $zybo_parts]"
foreach board_part $zybo_parts {
  puts "BOARD_PART_BEGIN=$board_part"
  foreach property_name {NAME DISPLAY_NAME VENDOR VERSION FILE_NAME PART_NAME PART} {
    puts "BOARD_PART_${property_name}=[property_if_present $board_part $property_name]"
  }
  puts "BOARD_PART_BEGIN_END=$board_part"
}

set z020_clg400_speed1_parts [lsort -dictionary [get_parts -quiet *xc7z020*clg400*-1*]]
puts "PREFLIGHT_XC7Z020_CLG400_SPEED1_COUNT=[llength $z020_clg400_speed1_parts]"
foreach fpga_part $z020_clg400_speed1_parts {
  puts "FPGA_PART_BEGIN=$fpga_part"
  foreach property_name {NAME DEVICE PACKAGE SPEED SPEED_GRADE FAMILY ARCHITECTURE} {
    puts "FPGA_PART_${property_name}=[property_if_present $fpga_part $property_name]"
  }
  puts "FPGA_PART_END=$fpga_part"
}

set exact_candidate [get_parts -quiet xc7z020clg400-1]
puts "PREFLIGHT_EXACT_XC7Z020CLG400_1_COUNT=[llength $exact_candidate]"
if {[llength $exact_candidate] == 1} {
  puts "PREFLIGHT_EXACT_XC7Z020CLG400_1=[lindex $exact_candidate 0]"
}

puts "PREFLIGHT_READ_ONLY_COMPLETE=1"
exit 0
