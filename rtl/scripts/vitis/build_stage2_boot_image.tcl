# Build a Vitis 2022.2 platform, Stage-2 (OP_RESIDUAL_ADD) application, Zynq FSBL, and BOOT.BIN
# from the timing-accepted Stage-2 bitstream/XSA, using firmware sources cloned from Eunsoo
# Soh's personal repository (https://github.com/EunsooSoh/Zynq_FPGA_ResNet, commit 88377ab) at
# a location OUTSIDE this team repository -- firmware-verification/** in this repo is untouched
# and this script does not read or write anything under it.
#
# firmware_root is never hardcoded: pass it via the EUNSOO_FIRMWARE_ROOT environment variable
# or as a second script argument (env var takes precedence). This keeps every session-specific
# clone path out of version control.
#
# Run with:
#   EUNSOO_FIRMWARE_ROOT=/path/to/clone xsct -nodisp scripts/vitis/build_stage2_boot_image.tcl all
# or:
#   xsct -nodisp scripts/vitis/build_stage2_boot_image.tcl all /path/to/clone
#
# The app is compiled/linked directly against the generated BSP (arm-none-eabi-gcc), not via
# Vitis's `importsources` + `app build` IDE pipeline: in this headless xsct flow, CDT's
# generated subdir.mk does not pick up files dropped into imported source folders (there is no
# IDE-side "refresh" to trigger the rescan), so `app build` silently links an empty object set.
# Direct compilation is the only path that was empirically confirmed to produce a working ELF.
set repo_root [file normalize [file join [file dirname [info script]] .. ..]]
set vitis_root "/home/jmhwang/tools/Xilinxe/Vitis/2022.2"
set cc [file join $vitis_root gnu aarch32 lin gcc-arm-none-eabi bin arm-none-eabi-gcc]
set bootgen [file join $vitis_root bin bootgen]
set workspace [file join $repo_root build vitis_stage2 workspace]
set xsa_path [file join $repo_root build vivado_zybo artifacts zybo_resnet_system.xsa]
set bit_path [file join $repo_root build vivado_zybo artifacts zybo_resnet_system.bit]
set boot_dir [file join $repo_root build vitis_stage2 boot]
set platform_name "zybo_resnet_stage2_platform"
set domain_name "standalone_ps7_cortexa9_0"
set fsbl_domain "standalone_fsbl_ps7_cortexa9_0"
set processor "ps7_cortexa9_0"
set app_name "stage2_residual_test"
set fsbl_name "zybo_resnet_fsbl"
set hello_world_platform_src [file join $vitis_root data embeddedsw lib sw_apps hello_world src]

if {[llength $argv] < 1 || [llength $argv] > 2 || [lindex $argv 0] ne "all"} {
  error "Usage: EUNSOO_FIRMWARE_ROOT=/path/to/clone xsct -nodisp build_stage2_boot_image.tcl all\n   or: xsct -nodisp build_stage2_boot_image.tcl all /path/to/clone"
}
if {[info exists ::env(EUNSOO_FIRMWARE_ROOT)] && $::env(EUNSOO_FIRMWARE_ROOT) ne ""} {
  set firmware_root $::env(EUNSOO_FIRMWARE_ROOT)
} elseif {[llength $argv] == 2} {
  set firmware_root [lindex $argv 1]
} else {
  error "firmware_root not specified: set EUNSOO_FIRMWARE_ROOT or pass it as a second argument"
}
foreach required [list $xsa_path $bit_path $cc $bootgen \
    [file join $hello_world_platform_src platform.c] \
    [file join $hello_world_platform_src platform.h] \
    [file join $firmware_root firmware inc platform_config.h] \
    [file join $firmware_root firmware test stage2_residual_test.c] \
    [file join $firmware_root firmware test generated stage2_identity_test_vector.h]] {
  if {![file isfile $required]} { error "Required input not found: $required" }
}
if {[file exists $workspace]} { error "Refusing to reuse or overwrite workspace: $workspace" }
file mkdir $workspace
puts "STAGE2: workspace=$workspace"
puts "STAGE2: xsa=$xsa_path"
puts "STAGE2: firmware(external, not team repo)=$firmware_root"
puts "STAGE2: processor=$processor"

setws $workspace
platform create -name $platform_name -hw $xsa_path -out $workspace -no-boot-bsp
platform active $platform_name
domain create -name $domain_name -os standalone -proc $processor
platform generate -domains $domain_name

domain active $domain_name
app create -name $app_name -platform $platform_name -domain $domain_name -template {Empty Application(C)}
set app_src [file join $workspace $app_name src]
set app_build_dir [file join $workspace $app_name build]
file mkdir $app_build_dir

set test_dir [file join $app_src firmware_test]
file mkdir [file join $test_dir generated]
file copy [file join $hello_world_platform_src platform.c] $test_dir
file copy [file join $hello_world_platform_src platform.h] $test_dir
file copy [file join $firmware_root firmware test stage2_residual_test.c] $test_dir
file copy [file join $firmware_root firmware test generated stage2_identity_test_vector.h] \
  [file join $test_dir generated]

set src_dir [file join $app_src firmware_src]
file mkdir $src_dir
foreach source_name [list accel_driver.c dma_transfer.c resnet_scheduler.c] {
  file copy [file join $firmware_root firmware src $source_name] $src_dir
}

set bsp_export [file join $workspace $platform_name export $platform_name sw $platform_name $domain_name]
set bsp_include [file join $bsp_export bspinclude include]
set bsp_lib [file join $bsp_export bsplib lib]

set cflags [list -Wall -O2 -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard \
  -I$bsp_include -I[file join $firmware_root firmware inc] -I$test_dir]
set app_sources [list \
  [file join $test_dir platform.c] \
  [file join $test_dir stage2_residual_test.c] \
  [file join $src_dir accel_driver.c] \
  [file join $src_dir dma_transfer.c] \
  [file join $src_dir resnet_scheduler.c]]
set objects {}
foreach source $app_sources {
  set obj [file join $app_build_dir "[file rootname [file tail $source]].o"]
  puts "STAGE2: compiling $source"
  exec {*}$cc {*}$cflags -c $source -o $obj
  lappend objects $obj
}
set app_elf [file join $app_build_dir "$app_name.elf"]
exec {*}$cc -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard -Wl,-build-id=none \
  -specs=[file join $app_src Xilinx.spec] -Wl,-T -Wl,[file join $app_src lscript.ld] \
  -L$bsp_lib -o $app_elf {*}$objects \
  -Wl,--start-group,-lxil,-lgcc,-lc,--end-group
puts "STAGE2: app ELF built at $app_elf"

platform active $platform_name
domain create -name $fsbl_domain -os standalone -proc $processor -support-app {Zynq FSBL}
platform generate -domains $fsbl_domain
domain active $fsbl_domain
app create -name $fsbl_name -platform $platform_name -domain $fsbl_domain -template {Zynq FSBL}
app config -name $fsbl_name build-config release
app build -name $fsbl_name
set fsbl_elf [file join $workspace $fsbl_name Release "$fsbl_name.elf"]
if {![file isfile $fsbl_elf]} { error "FSBL build did not produce $fsbl_elf" }

file mkdir $boot_dir
set bif_path [file join $boot_dir stage2.bif]
set bif [open $bif_path w]
puts $bif "the_ROM_image:"
puts $bif "\{"
puts $bif "\t\[bootloader\]$fsbl_elf"
puts $bif "\t$bit_path"
puts $bif "\t$app_elf"
puts $bif "\}"
close $bif

set boot_bin [file join $boot_dir BOOT.BIN]
exec $bootgen -image $bif_path -arch zynq -o $boot_bin -w on

puts "STAGE2_PLATFORM_APPLICATION_FSBL_BUILD_PASS"
puts "STAGE2_APP_ELF=$app_elf"
puts "STAGE2_FSBL_ELF=$fsbl_elf"
puts "STAGE2_BOOT_BIN=$boot_bin"
exit
