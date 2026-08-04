# Build a clean Vitis 2022.2 platform, Stage-1 application, and Zynq FSBL.
# Run with: xsct -nodisp scripts/vitis/build_stage1_boot_image.tcl all
set repo_root "/home/jmhwang/resnet-fpga-accelerator"
set firmware_root "/home/jmhwang/Zynq_FPGA_ResNet"
set workspace [file join $repo_root vitis stage1_workspace]
set xsa_path [file join $repo_root vivado output zybo_z7_op_conv.xsa]
set vector_header [file join $repo_root build vitis_stage1 stage1_test_vector.h]
set platform_name "zybo_z7_stage1_platform"
set domain_name "standalone_ps7_cortexa9_0"
set fsbl_domain "standalone_fsbl_ps7_cortexa9_0"
set processor "ps7_cortexa9_0"
set app_name "stage1_conv_test"
set fsbl_name "zybo_z7_fsbl"
if {[llength $argv] != 1 || [lindex $argv 0] ne "all"} { error "Usage: xsct -nodisp build_stage1_boot_image.tcl all" }
foreach required [list $xsa_path $vector_header [file join $firmware_root firmware inc platform_config.h] [file join $firmware_root firmware test stage1_conv_test.c]] {
    if {![file isfile $required]} { error "Required input not found: $required" }
}
if {[file exists $workspace]} { error "Refusing to reuse or overwrite workspace: $workspace" }
file mkdir $workspace
puts "STAGE1: workspace=$workspace"
puts "STAGE1: xsa=$xsa_path"
puts "STAGE1: firmware=$firmware_root"
puts "STAGE1: processor=$processor"
setws $workspace
platform create -name $platform_name -hw $xsa_path -out $workspace -no-boot-bsp
platform active $platform_name
domain create -name $domain_name -os standalone -proc $processor
platform generate -domains $domain_name
# The approved vector include precedes firmware roots so a stale tracked header cannot shadow it.
set vector_include [file join $workspace vector_include]
set vector_generated [file join $vector_include generated]
file mkdir $vector_generated
file copy $vector_header [file join $vector_generated stage1_test_vector.h]
domain active $domain_name
app create -name $app_name -platform $platform_name -domain $domain_name -template {Hello World}
set app_src [file join $workspace $app_name src]
set sample_main [file join $app_src helloworld.c]
if {![file isfile $sample_main]} { error "Hello World template main not found: $sample_main" }
file delete $sample_main
foreach source [list [file join $firmware_root firmware src accel_driver.c] [file join $firmware_root firmware src dma_transfer.c] [file join $firmware_root firmware src resnet_scheduler.c]] {
    importsources -name $app_name -path $source -soft-link -target-path firmware_src
}
importsources -name $app_name -path [file join $firmware_root firmware test stage1_conv_test.c] -soft-link -target-path firmware_test
app config -name $app_name build-config release
app config -name $app_name -add include-path $vector_include
app config -name $app_name -add include-path [file join $firmware_root firmware inc]
app config -name $app_name -add include-path [file join $firmware_root firmware test]
app config -name $app_name -add include-path $app_src
app build -name $app_name
platform active $platform_name
domain create -name $fsbl_domain -os standalone -proc $processor -support-app {Zynq FSBL}
platform generate -domains $fsbl_domain
domain active $fsbl_domain
app create -name $fsbl_name -platform $platform_name -domain $fsbl_domain -template {Zynq FSBL}
app config -name $fsbl_name build-config release
app build -name $fsbl_name
puts "STAGE1_PLATFORM_APPLICATION_FSBL_BUILD_PASS"
exit