# Phase 3E-2A: create the Vitis 2022.2 platform and standalone BSP only.
# Run with:
#   /home/jmhwang/tools/Xilinxe/Vitis/2022.2/bin/xsct -nodisp \
#     scripts/vitis/create_platform_bsp.tcl

set repo_root     "/home/jmhwang/resnet-fpga-accelerator"
set workspace     [file join $repo_root "build/vitis/workspace"]
set xsa_path      [file join $repo_root "build/vivado_zybo/artifacts/zybo_resnet_system.xsa"]
set platform_name "zybo_resnet_platform"
set processor     "ps7_cortexa9_0"
set domain_name   "standalone_ps7_cortexa9_0"

if {![file isfile $xsa_path]} {
    error "XSA not found: $xsa_path"
}

file mkdir $workspace
set platform_dir [file join $workspace $platform_name]
if {[file exists $platform_dir]} {
    error "Refusing to overwrite existing platform: $platform_dir"
}

puts "PHASE3E2A: workspace=$workspace"
puts "PHASE3E2A: xsa=$xsa_path"
puts "PHASE3E2A: platform=$platform_name"
puts "PHASE3E2A: processor=$processor"
puts "PHASE3E2A: domain=$domain_name"

setws $workspace

# Do not generate a boot BSP or FSBL in Phase 3E-2A.
platform create \
    -name $platform_name \
    -hw $xsa_path \
    -no-boot-bsp
platform active $platform_name

domain create \
    -name $domain_name \
    -os standalone \
    -proc $processor

platform write
platform generate
platform report

puts "PHASE3E2A: platform and standalone BSP generation complete"
exit
