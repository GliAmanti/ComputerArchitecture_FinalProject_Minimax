//
// Minimax: microcoded RISC-V
//
// (c) 2022 Three-Speed Logic, Inc., all rights reserved.
//
// This testbench contains:
//
// * A minimax core,
// * A 4kB dual-port RAM connected to both instruction and data buses, and
// * Enough "peripheral" to halt the simulation on completion.
//

`timescale 1 ns / 1 ps

// Use defines here rather than parameters, because iverilog's `-P` argument
// doesn't seem to work properly.
`ifndef ROM_FILENAME
`define ROM_FILENAME "../asm/blink.mem"
`endif

`ifndef MICROCODE_FILENAME
`define MICROCODE_FILENAME "../asm/microcode.mem"
`endif

`ifndef VCD_FILENAME
`define VCD_FILENAME "minimax_tb.vcd"
`endif

`ifndef MAXTICKS
`define MAXTICKS 100000
`endif

`ifdef ENABLE_TRACE
`define TRACE 1'b1
`else
`define TRACE 1'b0
`endif

module minimax_tb;
    parameter MAXTICKS = `MAXTICKS;
    parameter PC_BITS = 13;
    parameter UC_BASE = 32'h0000800;
    parameter ROM_FILENAME = `ROM_FILENAME;
    parameter MICROCODE_FILENAME = `MICROCODE_FILENAME;
    parameter TRACE = `TRACE;

    reg clk;
    reg reset;

    reg [31:0] ticks;
    reg [15:0] rom_array [0:8191];

    // Run clock at 10 ns
    always #10 clk <= (clk === 1'b0);

    initial begin
        clk = 0;
    end

    integer i;
    initial begin
        $dumpfile(`VCD_FILENAME);
        $dumpvars(0, minimax_tb);

        for (i = 0; i < 8192; i = i + 1) rom_array[i] = 16'b0;

        $readmemh(ROM_FILENAME, rom_array);
        `ifndef SKIP_MICROCODE
        $readmemh(MICROCODE_FILENAME, rom_array, UC_BASE);
        `endif

        forever begin
            @(posedge clk);
        end
    end

    wire [31:0] rom_window;
    reg [15:0] inst_lat;
    reg [15:0] inst_reg;
    wire inst_regce;

    wire [PC_BITS-1:0] inst_addr;
    wire [31:0] addr, wdata;
    reg [31:0] rdata;
    wire [3:0] wmask;
    wire rreq;
    // reg [31:0] i32;
    wire [31:0] i32;

    assign rom_window = rom_array[ticks];
    assign i32 = {rom_array[{inst_addr[PC_BITS-1:2], 1'b1}], rom_array[{inst_addr[PC_BITS-1:2], 1'b0}]};

    always @(posedge clk) begin

        rdata <= {rom_array[{addr[PC_BITS-1:2], 1'b1}], rom_array[{addr[PC_BITS-1:2], 1'b0}]};

        if (inst_addr[1])
            inst_lat <= i32[31:16];
        else
            inst_lat <= i32[15:0];

        if (inst_regce) begin
            inst_reg <= inst_lat;
        end

        if (wmask == 4'hf) begin
            rom_array[addr[PC_BITS-1:1]+1] <= wdata[31:16];
            rom_array[addr[PC_BITS-1:1]] <= wdata[15:0];
        end

    end

    minimax #(
        .TRACE(TRACE),
        .PC_BITS(PC_BITS),
        .UC_BASE(UC_BASE)
    ) dut (
        .clk(clk),
        .reset(reset),
        .inst_addr(inst_addr),
        .inst(inst_reg),
        .inst_regce(inst_regce),
        .addr(addr),
        .wdata(wdata),
        .rdata(rdata),
        .wmask(wmask),
        .rreq(rreq)
    );

    initial begin
        reset <= 1'b1;
        #96;
        reset <= 1'b0;
    end

    initial begin
        ticks <= 0;
    end

    // Capture test exit conditions - timeout or quit
    always @(posedge clk)
    begin
        // Track ticks counter and bail if we took too long
        ticks <= ticks + 1;
        if (MAXTICKS != -1 && ticks >= MAXTICKS) begin
            $display("FAIL: Exceeded MAXTICKS of %0d", MAXTICKS);
            $finish_and_return(1);
        end

        // Capture writes to address 0xfffffffc and use these as "quit" values
        if (wmask == 4'b1111 && addr == 32'hfffffffc) begin
            if (~|wdata) begin
                $display("SUCCESS: returned 0.");
                $finish_and_return(0);
            end else begin
                $display("FAIL: returned %0d", wdata);
                $finish_and_return(1);
            end
        end
    end

endmodule
