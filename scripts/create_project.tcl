# Usage: vivado -mode batch -source scripts/create_project.tcl -tclargs baseline
# This creates a project only; run synthesis/implementation from Vivado afterward.
if {$argc != 1 || [lindex $argv 0] ni {baseline extra_credit}} {
    error "Usage: -tclargs baseline|extra_credit"
}

set variant [lindex $argv 0]
set repo_dir [file normalize [file join [file dirname [info script]] ..]]
set variant_dir [file join $repo_dir $variant]
set project_dir [file join $repo_dir build $variant]

create_project -force video_$variant $project_dir -part xc7a35tcpg236-1
set_property target_language Verilog [current_project]
set_property simulator_language Verilog [current_project]
add_files -norecurse [lsort [glob [file join $variant_dir source *.v]]]
add_files -fileset constrs_1 -norecurse [lsort [glob [file join $variant_dir constraint *.xdc]]]
add_files -fileset sim_1 -norecurse [lsort [glob [file join $variant_dir simulation *.v]]]
set_property top top_ov7670_fifo_vga [get_filesets sources_1]
set_property top tb_vga_640x480 [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts "Created $variant project: [file join $project_dir video_$variant.xpr]"
close_project
