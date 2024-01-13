#!/usr/bin/Vivado/2019.1/bin -S vivado -mode batch -source

create_project arty_a7 arty_a7 -part "xc7a35t-csg324-1"

# RTL Sources
read_vhdl -vhdl2008 [file normalize "../rtl/blinker.vhd"]
read_verilog -sv [file normalize "../rtl/minimax.v"]
set_property top blinker [current_fileset]

# Blinker assembly
add_files ../asm/blink.mem

# Constraints
add_files -fileset constrs_1 arty_a7.xdc

# Ensure we're aggressively optimizing
set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE AreaOptimized_high [get_runs synth_1]

start_gui
