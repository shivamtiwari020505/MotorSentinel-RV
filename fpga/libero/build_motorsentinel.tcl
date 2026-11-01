# MotorSentinel-RV standalone fabric build for Libero SoC.
#
# Builds motorsentinel_top on the Icicle Kit device (MPFS250T, FCVG484,
# STD speed, 1.05 V core, extended range) through synthesis, place and route
# and static timing analysis, so the data plane's utilization and 50 MHz
# timing can be measured before it is merged into the Icicle reference design.
#
# Usage (from the repository root):
#   libero SCRIPT:fpga/libero/build_motorsentinel.tcl LOGFILE:build/libero/libero.log
# or run scripts/run_libero.ps1, which locates Libero and summarizes reports.
#
# The repository is found from this script's own location and the project is
# written to <repo_root>/build/libero. Optional SCRIPT_ARGS "<repo_root>
# <build_dir>" override both, but Libero splits SCRIPT_ARGS on spaces, so use
# them only with paths that contain none. The project directory is recreated
# on every run so the result depends only on the checked-in sources.
#
# In this standalone build the APB bus and sensor pins become device I/Os with
# automatic placement. Board pin assignment and the MSS/CoreAPB3 connection
# belong to the Icicle reference-design overlay (see docs/libero-build.md).

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file dirname [file dirname $script_dir]]
set build_dir  [file join $repo_root build libero]
if {[info exists argv] && [llength $argv] >= 1} {
    set repo_root [file normalize [lindex $argv 0]]
}
if {[info exists argv] && [llength $argv] >= 2} {
    set build_dir [file normalize [lindex $argv 1]]
}

set project_name {motorsentinel}
set project_dir  [file join $build_dir $project_name]
set top_module   {motorsentinel_top}

# Dependency order: leaf modules first, top level last.
set rtl_files {
    rtl/edgematrix_pe.sv
    rtl/edgematrix_array.sv
    rtl/edgematrix_autoencoder.sv
    rtl/motorsentinel_model_store.sv
    rtl/motorsentinel_inference.sv
    rtl/motorsentinel_integrity_monitor.sv
    rtl/motorsentinel_feature_extractor.sv
    rtl/motorsentinel_protocol_guard.sv
    rtl/motorsentinel_safety_policy.sv
    rtl/motorsentinel_guard_apb.sv
    rtl/motorsentinel_core_apb.sv
    rtl/motorsentinel_adxl345_reader.sv
    rtl/motorsentinel_top.sv
}
set sdc_file [file join $repo_root fpga constraints motorsentinel_top.sdc]

proc msrv_step {name body} {
    puts "MSRV: ---- $name ----"
    if {[catch {uplevel 1 $body} message]} {
        puts "MSRV: FAILED during $name: $message"
        error "MotorSentinel-RV build failed during $name"
    }
    puts "MSRV: $name completed"
}

puts "MSRV: repository  $repo_root"
puts "MSRV: project     $project_dir"

if {[file exists $project_dir]} {
    file delete -force $project_dir
}
file mkdir $build_dir

msrv_step {create project} {
    new_project \
        -location $project_dir \
        -name $project_name \
        -project_description {MotorSentinel-RV fabric data plane} \
        -block_mode 0 \
        -standalone_peripheral_initialization 0 \
        -instantiate_in_smartdesign 1 \
        -ondemand_build_dh 1 \
        -use_relative_path 0 \
        -linked_files_root_dir_env {} \
        -hdl {VERILOG} \
        -family {PolarFireSoC} \
        -die {MPFS250T} \
        -package {FCVG484} \
        -speed {STD} \
        -die_voltage {1.05} \
        -part_range {EXT} \
        -adv_options {IO_DEFT_STD:LVCMOS 1.8V} \
        -adv_options {TEMPR:EXT} \
        -adv_options {VOLTR:EXT}
    project_settings -verilog_mode {SYSTEM_VERILOG}
}

msrv_step {link sources} {
    foreach relative $rtl_files {
        set path [file join $repo_root $relative]
        if {![file exists $path]} {
            error "missing source $path"
        }
        create_links -convert_EDN_to_HDL 0 -library {work} -hdl_source $path
    }
    create_links -convert_EDN_to_HDL 0 -sdc $sdc_file
    build_design_hierarchy
    set_root -module "${top_module}::work"
}

msrv_step {assign constraints} {
    foreach tool {SYNTHESIZE PLACEROUTE VERIFYTIMING} {
        organize_tool_files \
            -tool $tool \
            -file $sdc_file \
            -module "${top_module}::work" \
            -input_type {constraint}
    }
    save_project
}

msrv_step {synthesis}         { run_tool -name {SYNTHESIZE} }
msrv_step {place and route}   { run_tool -name {PLACEROUTE} }
msrv_step {timing analysis}   { run_tool -name {VERIFYTIMING} }

save_project
puts "MSRV: build complete; reports are under [file join $project_dir designer $top_module]"
