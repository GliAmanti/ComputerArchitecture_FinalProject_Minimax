/*
 * Minimax: microcoded RISC-V
 *
 * (c) 2022-2023 Three-Speed Logic, Inc. <gsmecher@threespeedlogic.com>
 * (c) 2022-2023 Sean Cross <sean@xobs.io>
 *
 * RISC-V's compressed instruction (RVC) extension is intended as an add-on to
 * the regular, 32-bit instruction set, not a replacement or competitor. Its
 * designers designed RVC instructions to be expanded into regular 32-bit RV32I
 * equivalents via a pre-decoder.
 *
 * What happens if we *explicitly* architect a RISC-V CPU to execute RVC
 * instructions, and "mop up" any RV32I instructions that aren't convenient via
 * a microcode layer? What architectural optimizations are unlocked as a result?
 *
 * "Minimax" is an experimental RISC-V implementation intended to establish if
 * an RVC-optimized CPU is, in practice, any simpler than an ordinary RV32I
 * core with pre-decoder. While it passes a modest test suite, you should not
 * use it without caution. (There are a large number of excellent, open source,
 * "little" RISC-V implementations you should probably use reach for first.)
 */

`default_nettype none

module minimax (
   input wire clk,
   input wire reset,
   input wire [15:0] inst,
   input wire [31:0] rdata,
   output wire[PC_BITS-1:0] inst_addr,
   output wire inst_regce,
   output reg [31:0] addr,
   output reg [31:0] wdata,
   output reg [3:0] wmask,
   output reg rreq,
   input wire rack);

  parameter PC_BITS = 12;
  parameter [31:0] UC_BASE = 32'h00000000;

  wire [31:0] uc_base;
  assign uc_base = UC_BASE;

  // Register file
  reg [31:0] register_file[63:0];

  // Register file address ports
  wire [5:0] addrS, addrD;
  wire [4:0] addrD_port, addrS_port;
  wire bD_banksel, bS_banksel;
  wire [31:0] regS, regD, aluA, aluB, aluS, aluX;

  // regP does into a byte permutation, producing regP
  wire [1:0] selP0, selP1, selP2, selP3;
  wire [31:0] regP;

  // Program counter
  reg [PC_BITS-1:1] pc_fetch = {(PC_BITS-1){1'b0}};
  reg [PC_BITS-1:1] pc_fetch_dly = {(PC_BITS-1){1'b0}};
  reg [PC_BITS-1:1] pc_execute = {(PC_BITS-1){1'b0}};

  // PC ALU output
  wire [PC_BITS-1:1] aguX, aguA, aguB;

  // Track bubbles and execution inhibits through the pipeline.
  reg bubble1 = 1'b1, bubble2 = 1'b1;
  reg microcode = 1'b0;
  wire bubble = bubble1 | bubble2 | data_stall;

  // Deferred writeback address
  reg [4:0] dra = 5'b0;

  // Registers for multi-cycle 16-bit instructions
  reg dly16_slli_setrd = 1'b0;
  reg dly16_slli_setrs = 1'b0;
  reg data_stall = 1'b0;

  // Opcode masks for 16-bit instructions
  wire [15:0] inst_type_masked     = inst & 16'b111_0_00000_00000_11;
  wire [15:0] inst_type_masked_zcb = inst & 16'b111_1_11000_00000_11;
  wire [15:0] inst_type_masked_i16 = inst & 16'b111_0_11111_00000_11;
  wire [15:0] inst_type_masked_and = inst & 16'b111_0_11000_00000_11;
  wire [15:0] inst_type_masked_op  = inst & 16'b111_0_11000_11000_11;
  wire [15:0] inst_type_masked_j   = inst & 16'b111_1_00000_11111_11;
  wire [15:0] inst_type_masked_mj  = inst & 16'b111_1_00000_00000_11;

  // From 16.8 (RVC Instruction Set Listings)
  wire op16_addi4spn   = (inst_type_masked     == 16'b000_0_00000_00000_00) & ~bubble;
  wire op16_lw         = (inst_type_masked     == 16'b010_0_00000_00000_00) & ~bubble;
  wire op16_sw         = (inst_type_masked     == 16'b110_0_00000_00000_00) & ~bubble;
  wire op16_sb         = (inst_type_masked_zcb == 16'b100_0_10000_00000_00) & ~bubble;
  wire op16_sh         = (inst_type_masked_zcb == 16'b100_0_11000_00000_00) & ~bubble;

  wire op16_addi       = (inst_type_masked     == 16'b000_0_00000_00000_01) & ~bubble;
  wire op16_jal        = (inst_type_masked     == 16'b001_0_00000_00000_01) & ~bubble;
  wire op16_li         = (inst_type_masked     == 16'b010_0_00000_00000_01) & ~bubble;
  wire op16_addi16sp   = (inst_type_masked_i16 == 16'b011_0_00010_00000_01) & ~bubble;
  wire op16_lui        = (inst_type_masked     == 16'b011_0_00000_00000_01) & ~bubble & ~op16_addi16sp;

  wire op16_srli       = (inst_type_masked_zcb == 16'b100_0_00000_00000_01) & ~bubble;
  wire op16_srai       = (inst_type_masked_zcb == 16'b100_0_01000_00000_01) & ~bubble;
  wire op16_andi       = (inst_type_masked_and == 16'b100_0_10000_00000_01) & ~bubble;
  wire op16_sub        = (inst_type_masked_op  == 16'b100_0_11000_00000_01) & ~bubble;
  wire op16_xor        = (inst_type_masked_op  == 16'b100_0_11000_01000_01) & ~bubble;
  wire op16_or         = (inst_type_masked_op  == 16'b100_0_11000_10000_01) & ~bubble;
  wire op16_and        = (inst_type_masked_op  == 16'b100_0_11000_11000_01) & ~bubble;
  wire op16_j          = (inst_type_masked     == 16'b101_0_00000_00000_01) & ~bubble;
  wire op16_beqz       = (inst_type_masked     == 16'b110_0_00000_00000_01) & ~bubble;
  wire op16_bnez       = (inst_type_masked     == 16'b111_0_00000_00000_01) & ~bubble;

  wire op16_slli       = (inst_type_masked_mj  == 16'b000_0_00000_00000_10) & ~bubble;
  wire op16_lwsp       = (inst_type_masked     == 16'b010_0_00000_00000_10) & ~bubble;
  wire op16_jr         = (inst_type_masked_j   == 16'b100_0_00000_00000_10) & ~bubble;
  wire op16_mv         = (inst_type_masked_mj  == 16'b100_0_00000_00000_10) & ~bubble & ~op16_jr;
  wire op16_ebreak     = (inst                 == 16'b100_1_00000_00000_10) & ~bubble;
  wire op16_jalr       = (inst_type_masked_j   == 16'b100_1_00000_00000_10) & ~bubble & ~op16_ebreak;
  wire op16_add        = (inst_type_masked_mj  == 16'b100_1_00000_00000_10) & ~bubble & ~op16_jalr & ~ op16_ebreak;
  wire op16_swsp       = (inst_type_masked     == 16'b110_0_00000_00000_10) & ~bubble;

  // Non-standard extensions to support microcode are permitted in these opcode gaps
  wire op16_slli_setrd = (inst_type_masked_j   == 16'b000_1_00000_00001_10) & ~bubble;
  wire op16_slli_setrs = (inst_type_masked_j   == 16'b000_1_00000_00010_10) & ~bubble;
  wire op16_slli_thunk = (inst_type_masked_j   == 16'b000_1_00000_00100_10) & ~bubble;

  // Blanket matches for RVC and RV32I instructions
  wire op32 =  &(inst[1:0]) & ~bubble;
  wire op16 = ~&(inst[1:0]) & ~bubble;

  wire [4:0] shamt = inst[6:2];

  // Trap on unimplemented instructions
  wire op32_trap = op32;

  wire op16_trap = op16 & ~(
      op16_addi4spn | op16_lw | op16_sw | op16_sh | op16_sb |
      op16_addi | op16_jal | op16_li | op16_addi16sp | op16_lui |
      op16_srli | op16_srai | op16_andi | op16_sub | op16_xor | op16_or | op16_and | op16_j | op16_beqz | op16_bnez |
      op16_slli | op16_lwsp | op16_jr | op16_mv | op16_ebreak | op16_jalr | op16_add | op16_swsp |
      op16_slli_setrd | op16_slli_setrs | op16_slli_thunk);

  wire trap = op16_trap | op32_trap;

  // Data bus reads and writes are registered
  always @(posedge clk) begin
    rreq <= 1'b0;
    addr <= 32'b0;
    wmask <= 4'h0;
    wdata <= 32'b0;

    if(reset | rack) begin
      data_stall <= 'b0;
    end else if(op16_lw | op16_lwsp) begin
      addr <= aluS;
      data_stall <= 1'b1;
      rreq <= 1'b1;
    end else if(op16_swsp | op16_sw | op16_sh | op16_sb) begin
      addr <= aluS;
      wmask <= {4{op16_swsp}} | {4{op16_sw}} |
        {4{op16_sh}} & {{2{inst[5]}}, {2{~inst[5]}}} |
        {4{op16_sb}} & {inst[6:5]==2'b11, inst[6:5]==2'b01, inst[6:5]==2'b10, inst[6:5]==2'b00};
      wdata <= regP;
    end
  end

  // Instruction bus outputs
  assign inst_addr = {pc_fetch, 1'b0};
  assign inst_regce = ~data_stall;

  // PC logic
  wire branch_taken = (op16_beqz & (~|regS)
                | (op16_bnez & (|regS)))
                | op16_j | op16_jal | op16_jr | op16_jalr
                | op16_slli_thunk;

  // Fetch Process
  always @(posedge clk) begin

    // Instruction mis-fetches create a 2-cycle penalty
    bubble2 <= reset | branch_taken | trap;
    bubble1 <= bubble2;

    // Update fetch instruction unless bubbling
    if (reset) begin
      pc_fetch <= 0;
      pc_fetch_dly <= 0;
      pc_execute <= 0;
    end else if (~op16_lw & ~op16_lwsp & (rack | ~data_stall)) begin
      pc_fetch <= aguX;
      pc_fetch_dly <= pc_fetch;
      pc_execute <= pc_fetch_dly;
    end

    microcode <= (microcode | trap) & ~(reset | op16_slli_thunk);

`ifdef ENABLE_ASSERTS
    if (microcode & trap) begin
      $display("Double trap!");
      $stop;
    end

    // Check to make sure the microcode doesn't exceed the program counter size
    if (UC_BASE[31:PC_BITS] != 0) begin
      $display("Microcode at 0x%0h cannot be reached with a %d-bit program counter!", UC_BASE, PC_BITS);
      $stop;
    end
`endif

  end

  // Datapath Process
  always @(posedge clk) begin
    dly16_slli_setrs <= op16_slli_setrs;
    dly16_slli_setrd <= op16_slli_setrd;

    // Load and setrs/setrd instructions complete a cycle after they are
    // initiated, so we need to keep some state.
    if(reset)
      dra <= 5'h0;
    else if(~bubble)
      dra <= (regD[4:0] & ({5{op16_slli_setrd | op16_slli_setrs}}))
           | ({2'b01, inst[4:2]} & {5{op16_lw}})
           | (inst[11:7] & {5{op16_lwsp | op32}});
  end

  // READ/WRITE register file port
  assign addrD_port = (dra & {5{dly16_slli_setrd | rack}})
    | (5'b00001 & {5{op16_jal | op16_jalr | trap}}) // write return address into ra
    | ({2'b01, inst[4:2]} & {5{op16_addi4spn | op16_sw | op16_sh | op16_sb}}) // data
    | (inst[6:2] & {5{op16_swsp}})
    | (inst[11:7] & ({5{op16_addi | op16_add
        | (op16_mv & ~dly16_slli_setrd)
        | op16_addi16sp
        | op16_slli_setrd | op16_slli_setrs
        | op16_li | op16_lui
        | op16_slli}}))
    | ({2'b01, inst[9:7]} & {5{op16_sub
        | op16_xor | op16_or | op16_and | op16_andi
        | op16_srli | op16_srai}});

  // READ-ONLY register file port
  assign addrS_port = (dra & {5{dly16_slli_setrs}})
      | (5'b00010 & {5{op16_addi4spn | op16_lwsp | op16_swsp}})
      | (inst[11:7] & {5{op16_jr | op16_jalr | op16_slli_thunk}}) // jump destination
      | ({2'b01, inst[9:7]} & {5{op16_sw | op16_sh | op16_sb | op16_lw | op16_beqz | op16_bnez}})
      | ({2'b01, inst[4:2]} & {5{op16_and | op16_or | op16_xor | op16_sub}})
      | (inst[6:2] & {5{(op16_mv & ~dly16_slli_setrs) | op16_add}});

  // Select between "normal" and "microcode" register banks.
  assign bD_banksel = (microcode ^ dly16_slli_setrd) | trap;
  assign bS_banksel = (microcode ^ dly16_slli_setrs) | trap;

  assign addrD = {bD_banksel, addrD_port};
  assign addrS = {bS_banksel, addrS_port};

  // Look up register file contents combinatorially
  assign regD = register_file[addrD];
  assign regS = register_file[addrS];

  // RegD goes straight into a set of byte-select multiplexers to produce
  // regP. These are currently used for Zcb's c.sb/c.sh instructions, but can
  // also be used for coarse shifts or rotates.
  assign regP[7:0]   = selP0[1] ? (selP0[0] ? regD[31:24] : regD[23:16]) : (selP0[0] ? regD[15:8] : regD[7:0]);
  assign regP[15:8]  = selP1[1] ? (selP1[0] ? regD[31:24] : regD[23:16]) : (selP1[0] ? regD[15:8] : regD[7:0]);
  assign regP[23:16] = selP2[1] ? (selP2[0] ? regD[31:24] : regD[23:16]) : (selP2[0] ? regD[15:8] : regD[7:0]);
  assign regP[31:24] = selP3[1] ? (selP3[0] ? regD[31:24] : regD[23:16]) : (selP3[0] ? regD[15:8] : regD[7:0]);

  assign selP0 = 2'b00;
  assign selP1 = (2'b01 & {2{~op16_sb}});
  assign selP2 = (2'b10 & {2{~(op16_sb | op16_sh)}});
  assign selP3 = (2'b01 & {2{op16_sh}}) | (2'b11 & ~{2{op16_sb | op16_sh}});

  // aluA skips the permutation on regP and takes the register-file output
  // directly.
  assign aluA = (regD & {32{op16_add | op16_addi | op16_sub
                    | op16_and | op16_andi
                    | op16_or | op16_xor
                    | op16_addi16sp}})
          | ({22'b0, inst[10:7], inst[12:11], inst[5], inst[6], 2'b0} & {32{op16_addi4spn}})
          | ({24'b0, inst[8:7], inst[12:9], 2'b0} & {32{op16_swsp}})
          | ({24'b0, inst[3:2], inst[12], inst[6:4], 2'b0} & {32{op16_lwsp}})
          | ({25'b0, inst[5], inst[12:10], inst[6], 2'b0} & {32{op16_lw | op16_sw}});

  assign aluB = regS
          | ({{27{inst[12]}}, inst[6:2]} & {32{op16_addi | op16_andi | op16_li}})
          | ({{15{inst[12]}}, inst[6:2], 12'b0} & {32{op16_lui}})
          | ({{23{inst[12]}}, inst[4:3], inst[5], inst[2], inst[6], 4'b0} & {32{op16_addi16sp}});

  // This synthesizes into 4 CARRY8s - no need for manual xor/cin heroics
  assign aluS = op16_sub ? (aluA - aluB) : (aluA + aluB);

  assign aluX = (aluS & (
                    {32{op16_add | op16_sub | op16_addi
                      | op16_li | op16_lui
                      | op16_addi4spn | op16_addi16sp}})) |
          ((aluA & aluB) & {32{op16_andi | op16_and}}) |
	  ((regD >> shamt) & {32{op16_srli}}) |
	  ($unsigned($signed(regD) >>> shamt) & {32{op16_srai}}) |
	  ((regD << shamt) & {32{op16_slli}}) |
          ((aluA ^ aluB) & {32{op16_xor}}) |
          ((aluA | aluB) & {32{op16_or | op16_mv}}) |
          (rdata & {32{rack}}) |
          ({{(32-PC_BITS){1'b0}}, pc_fetch_dly[PC_BITS-1:1], 1'b0} & {32{op16_jal | op16_jalr | trap}}); //  instruction following the jump (hence _dly)

  // Address Generation Unit (AGU)
  assign aguA = (pc_fetch & ~{(PC_BITS-1){trap | branch_taken}})
        | (pc_execute & {(PC_BITS-1){branch_taken}} & ~{(PC_BITS-1){op16_jr | op16_jalr | op16_slli_thunk}});

  assign aguB = (regS[PC_BITS-1:1] & {(PC_BITS-1){op16_jr | op16_jalr | op16_slli_thunk}})
        | ({{(PC_BITS-11){inst[12]}}, inst[8], inst[10:9], inst[6], inst[7], inst[2], inst[11], inst[5:3]}
              & {(PC_BITS-1){branch_taken & (op16_j | op16_jal)}})
        | ({{(PC_BITS-8){inst[12]}}, inst[6:5], inst[2], inst[11:10], inst[4:3]}
              & {(PC_BITS-1){branch_taken & (op16_bnez | op16_beqz)}})
        | (uc_base[PC_BITS-1:1] & {(PC_BITS-1){trap}});

  assign aguX = (aguA + aguB) + {{(PC_BITS-2){1'b0}}, ~(branch_taken | rreq | trap)};

  wire wb = trap |                  // writes microcode x1/ra
             rack | // writes data
             op16_jal | op16_jalr |   // writes x1/ra
             op16_li | op16_lui |
             op16_addi | op16_addi4spn | op16_addi16sp |
             op16_andi | op16_mv | op16_add |
             op16_and | op16_or | op16_xor | op16_sub |
             op16_slli | op16_srli | op16_srai;

  // Regs proc
  always @(posedge clk) begin
    // writeback
    if (|(addrD[4:0]) & wb) begin
      register_file[addrD] <= aluX;
    end
  end

  // Tracing
`ifdef ENABLE_TRACE
  initial begin
      $display(
          "  FETCH1"
        , "   FETCH2"
        , "  EXECUTE"
        , "     aguA"
        , "     aguB"
        , "     aguX"
        , "     INST"
        , " OPCODE  "
        , " addrD"
        , " addrS"
        , "     regD"
        , "     regS"
        , "     aluA"
        , "     aluB"
        , "     aluS"
        , "     aluX"
        , " FLAGS");
  end

  // This register can be viewed in the resulting VCD file by setting
  // the display type to "ASCII".
  reg [8*8-1:0] opcode;

  always @(posedge clk) begin
      $write("%8H ", {pc_fetch, 1'b0});
      $write("%8H ", {pc_fetch_dly, 1'b0});
      $write("%8H ", {pc_execute, 1'b0});
      $write("%8H ", {aguA, 1'b0});
      $write("%8H ", {aguB, 1'b0});
      $write("%8H ", {aguX, 1'b0});
      $write("%8H ", inst);

      if(op16_addi4spn)        begin $write("ADDI4SPN"); opcode = "ADDI4SPN"; end
      else if(op16_lw)         begin $write("LW      "); opcode = "LW      "; end
      else if(op16_sw)         begin $write("SW      "); opcode = "SW      "; end
      else if(op16_sb)         begin $write("SB      "); opcode = "SB      "; end
      else if(op16_sh)         begin $write("SH      "); opcode = "SH      "; end
      else if(op16_addi)       begin $write("ADDI    "); opcode = "ADDI    "; end
      else if(op16_jal)        begin $write("JAL     "); opcode = "JAL     "; end
      else if(op16_li)         begin $write("LI      "); opcode = "LI      "; end
      else if(op16_addi16sp)   begin $write("ADDI16SP"); opcode = "ADDI16SP"; end
      else if(op16_lui)        begin $write("LUI     "); opcode = "LUI     "; end
      else if(op16_srli)       begin $write("SRLI    "); opcode = "SRLI    "; end
      else if(op16_srai)       begin $write("SRAI    "); opcode = "SRAI    "; end
      else if(op16_andi)       begin $write("ANDI    "); opcode = "ANDI    "; end
      else if(op16_sub)        begin $write("SUB     "); opcode = "SUB     "; end
      else if(op16_xor)        begin $write("XOR     "); opcode = "XOR     "; end
      else if(op16_or)         begin $write("OR      "); opcode = "OR      "; end
      else if(op16_and)        begin $write("AND     "); opcode = "AND     "; end
      else if(op16_j)          begin $write("J       "); opcode = "J       "; end
      else if(op16_beqz)       begin $write("BEQZ    "); opcode = "BEQZ    "; end
      else if(op16_bnez)       begin $write("BNEZ    "); opcode = "BNEZ    "; end
      else if(op16_slli)       begin $write("SLLI    "); opcode = "SLLI    "; end
      else if(op16_lwsp)       begin $write("LWSP    "); opcode = "LWSP    "; end
      else if(op16_jr)         begin $write("JR      "); opcode = "JR      "; end
      else if(op16_mv)         begin $write("MV      "); opcode = "MV      "; end
      else if(op16_ebreak)     begin $write("EBREAK  "); opcode = "EBREAK  "; end
      else if(op16_jalr)       begin $write("JALR    "); opcode = "JALR    "; end
      else if(op16_add)        begin $write("ADD     "); opcode = "ADD     "; end
      else if(op16_swsp)       begin $write("SWSP    "); opcode = "SWSP    "; end
      else if(op16_slli_thunk) begin $write("THUNK   "); opcode = "THUNK   "; end
      else if(op16_slli_setrd) begin $write("SETRD   "); opcode = "SETRD   "; end
      else if(op16_slli_setrs) begin $write("SETRS   "); opcode = "SETRS   "; end
      else if(op32)            begin $write("RV32I   "); opcode = "RV32I   "; end
      else if(bubble)          begin $write("BUBBLE  "); opcode = "BUBBLE  "; end
      else                     begin $write("NOP?    "); opcode = "NOP?    "; end

      $write("  %1b.%2H", addrD[5], addrD[4:0]);
      $write("  %1b.%2H", addrS[5], addrS[4:0]);

      $write(" %8H", regD);
      $write(" %8H", regS);

      $write(" %8H", aluA);
      $write(" %8H", aluB);
      $write(" %8H", aluS);
      $write(" %8H", aluX);

      if(trap) begin
        $write(" TRAP");
      end
      if(branch_taken) begin
        $write(" TAKEN");
      end
      if(bubble) begin
        $write(" BUBBLE");
      end
      if(wb) begin
        $write(" WB");
      end
      if(reset) begin
        $write(" RESET");
      end
      if(microcode) begin
        $write(" MCODE");
      end
      if(| wmask) begin
        $write(" WMASK=%0h", wmask);
        $write(" ADDR=%0h", addr);
        $write(" WDATA=%0h", wdata);
      end
      if(rreq) begin
        $write(" RREQ");
        $write(" ADDR=%0h", addr);
      end
      if(| dra) begin
        $write(" @DRA=%0h", dra);
      end
      if(~inst_regce) begin
        $write(" ~REGCE");
      end
      if(rack) begin
        $write(" RACK");
      end
      $display("");
    end
`endif // `ifdef ENABLE_TRACE

  initial begin
    for(integer i=0; i<64; i++) begin
      register_file[i] = 32'h00000000;
    end
  end

`ifdef ENABLE_REGISTER_INSPECTION
  // Wires that make it easier to inspect the register file during simulation
  wire [31:0] cpu_x0 = register_file[0];
  wire [31:0] cpu_x1 = register_file[1];
  wire [31:0] cpu_x2 = register_file[2];
  wire [31:0] cpu_x3 = register_file[3];
  wire [31:0] cpu_x4 = register_file[4];
  wire [31:0] cpu_x5 = register_file[5];
  wire [31:0] cpu_x6 = register_file[6];
  wire [31:0] cpu_x7 = register_file[7];
  wire [31:0] cpu_x8 = register_file[8];
  wire [31:0] cpu_x9 = register_file[9];
  wire [31:0] cpu_x10 = register_file[10];
  wire [31:0] cpu_x11 = register_file[11];
  wire [31:0] cpu_x12 = register_file[12];
  wire [31:0] cpu_x13 = register_file[13];
  wire [31:0] cpu_x14 = register_file[14];
  wire [31:0] cpu_x15 = register_file[15];
  wire [31:0] cpu_x16 = register_file[16];
  wire [31:0] cpu_x17 = register_file[17];
  wire [31:0] cpu_x18 = register_file[18];
  wire [31:0] cpu_x19 = register_file[19];
  wire [31:0] cpu_x20 = register_file[20];
  wire [31:0] cpu_x21 = register_file[21];
  wire [31:0] cpu_x22 = register_file[22];
  wire [31:0] cpu_x23 = register_file[23];
  wire [31:0] cpu_x24 = register_file[24];
  wire [31:0] cpu_x25 = register_file[25];
  wire [31:0] cpu_x26 = register_file[26];
  wire [31:0] cpu_x27 = register_file[27];
  wire [31:0] cpu_x28 = register_file[28];
  wire [31:0] cpu_x29 = register_file[29];
  wire [31:0] cpu_x30 = register_file[30];
  wire [31:0] cpu_x31 = register_file[31];

  wire [31:0] uc_x0 = register_file[0 + 32];
  wire [31:0] uc_x1 = register_file[1 + 32];
  wire [31:0] uc_x2 = register_file[2 + 32];
  wire [31:0] uc_x3 = register_file[3 + 32];
  wire [31:0] uc_x4 = register_file[4 + 32];
  wire [31:0] uc_x5 = register_file[5 + 32];
  wire [31:0] uc_x6 = register_file[6 + 32];
  wire [31:0] uc_x7 = register_file[7 + 32];
  wire [31:0] uc_x8 = register_file[8 + 32];
  wire [31:0] uc_x9 = register_file[9 + 32];
  wire [31:0] uc_x10 = register_file[10 + 32];
  wire [31:0] uc_x11 = register_file[11 + 32];
  wire [31:0] uc_x12 = register_file[12 + 32];
  wire [31:0] uc_x13 = register_file[13 + 32];
  wire [31:0] uc_x14 = register_file[14 + 32];
  wire [31:0] uc_x15 = register_file[15 + 32];
  wire [31:0] uc_x16 = register_file[16 + 32];
  wire [31:0] uc_x17 = register_file[17 + 32];
  wire [31:0] uc_x18 = register_file[18 + 32];
  wire [31:0] uc_x19 = register_file[19 + 32];
  wire [31:0] uc_x20 = register_file[20 + 32];
  wire [31:0] uc_x21 = register_file[21 + 32];
  wire [31:0] uc_x22 = register_file[22 + 32];
  wire [31:0] uc_x23 = register_file[23 + 32];
  wire [31:0] uc_x24 = register_file[24 + 32];
  wire [31:0] uc_x25 = register_file[25 + 32];
  wire [31:0] uc_x26 = register_file[26 + 32];
  wire [31:0] uc_x27 = register_file[27 + 32];
  wire [31:0] uc_x28 = register_file[28 + 32];
  wire [31:0] uc_x29 = register_file[29 + 32];
  wire [31:0] uc_x30 = register_file[30 + 32];
  wire [31:0] uc_x31 = register_file[31 + 32];
`endif // `ifdef ENABLE_REGISTER_INSPECTION

endmodule
