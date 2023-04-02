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

  // Instruction register
  reg [15:0] inst_d;

  // Register file address ports
  wire [5:0] addrS, addrD;
  wire [4:0] addrD_port, addrS_port;
  wire bD_banksel, bS_banksel;
  wire [31:0] regS, regD, aluA, aluB, aluS, aluX;

  // Program counter
  reg [PC_BITS-1:1] pc_f = {(PC_BITS-1){1'b0}};
  reg [PC_BITS-1:1] pc_d = {(PC_BITS-1){1'b0}};
  reg [PC_BITS-1:1] pc_e = {(PC_BITS-1){1'b0}};

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

  // Instruction strobes at fetch and decode cycles
  wire op16_add_f, op16_add_d,
    op16_addi_f, op16_addi_d,
    op16_addi16sp_f, op16_addi16sp_d,
    op16_addi4spn_f, op16_addi4spn_d,
    op16_and_f, op16_and_d,
    op16_andi_f, op16_andi_d,
    op16_beqz_f, op16_beqz_d,
    op16_bnez_f, op16_bnez_d,
    op16_ebreak_f, op16_ebreak_d,
    op16_j_f, op16_j_d,
    op16_jal_f, op16_jal_d,
    op16_jalr_f, op16_jalr_d,
    op16_jr_f, op16_jr_d,
    op16_li_f, op16_li_d,
    op16_lui_f, op16_lui_d,
    op16_lw_f, op16_lw_d,
    op16_lwsp_f, op16_lwsp_d,
    op16_mv_f, op16_mv_d,
    op16_or_f, op16_or_d,
    op16_sb_f, op16_sb_d,
    op16_sh_f, op16_sh_d,
    op16_slli_f, op16_slli_d,
    op16_slli_setrd_f, op16_slli_setrd_d,
    op16_slli_setrs_f, op16_slli_setrs_d,
    op16_slli_thunk_f, op16_slli_thunk_d,
    op16_srai_f, op16_srai_d,
    op16_srli_f, op16_srli_d,
    op16_sub_f, op16_sub_d,
    op16_sw_f, op16_sw_d,
    op16_swsp_f, op16_swsp_d,
    op16_xor_f, op16_xor_d;

  // Opcode masks for 16-bit instructions
  wire [15:0] inst_type_masked     = inst_d & 16'b111_0_00000_00000_11;
  wire [15:0] inst_type_masked_zcb = inst_d & 16'b111_1_11000_00000_11;
  wire [15:0] inst_type_masked_i16 = inst_d & 16'b111_0_11111_00000_11;
  wire [15:0] inst_type_masked_and = inst_d & 16'b111_0_11000_00000_11;
  wire [15:0] inst_type_masked_op  = inst_d & 16'b111_0_11000_11000_11;
  wire [15:0] inst_type_masked_j   = inst_d & 16'b111_1_00000_11111_11;
  wire [15:0] inst_type_masked_mj  = inst_d & 16'b111_1_00000_00000_11;

  wire op16_addi4spn_d   = (inst_type_masked     == 16'b000_0_00000_00000_00) & ~bubble;
  wire op16_lw_d         = (inst_type_masked     == 16'b010_0_00000_00000_00) & ~bubble;
  wire op16_sw_d         = (inst_type_masked     == 16'b110_0_00000_00000_00) & ~bubble;
  wire op16_sb_d         = (inst_type_masked_zcb == 16'b100_0_10000_00000_00) & ~bubble;
  wire op16_sh_d         = (inst_type_masked_zcb == 16'b100_0_11000_00000_00) & ~bubble;

  wire op16_addi_d       = (inst_type_masked     == 16'b000_0_00000_00000_01) & ~bubble;
  wire op16_jal_d        = (inst_type_masked     == 16'b001_0_00000_00000_01) & ~bubble;
  wire op16_li_d         = (inst_type_masked     == 16'b010_0_00000_00000_01) & ~bubble;
  wire op16_addi16sp_d   = (inst_type_masked_i16 == 16'b011_0_00010_00000_01) & ~bubble;
  wire op16_lui_d        = (inst_type_masked     == 16'b011_0_00000_00000_01) & ~bubble & ~op16_addi16sp_d;

  wire op16_srli_d       = (inst_type_masked_zcb == 16'b100_0_00000_00000_01) & ~bubble;
  wire op16_srai_d       = (inst_type_masked_zcb == 16'b100_0_01000_00000_01) & ~bubble;
  wire op16_andi_d       = (inst_type_masked_and == 16'b100_0_10000_00000_01) & ~bubble;
  wire op16_sub_d        = (inst_type_masked_op  == 16'b100_0_11000_00000_01) & ~bubble;
  wire op16_xor_d        = (inst_type_masked_op  == 16'b100_0_11000_01000_01) & ~bubble;
  wire op16_or_d         = (inst_type_masked_op  == 16'b100_0_11000_10000_01) & ~bubble;
  wire op16_and_d        = (inst_type_masked_op  == 16'b100_0_11000_11000_01) & ~bubble;
  wire op16_j_d          = (inst_type_masked     == 16'b101_0_00000_00000_01) & ~bubble;
  wire op16_beqz_d       = (inst_type_masked     == 16'b110_0_00000_00000_01) & ~bubble;
  wire op16_bnez_d       = (inst_type_masked     == 16'b111_0_00000_00000_01) & ~bubble;

  wire op16_slli_d       = (inst_type_masked_mj  == 16'b000_0_00000_00000_10) & ~bubble;
  wire op16_lwsp_d       = (inst_type_masked     == 16'b010_0_00000_00000_10) & ~bubble;
  wire op16_jr_d         = (inst_type_masked_j   == 16'b100_0_00000_00000_10) & ~bubble;
  wire op16_mv_d         = (inst_type_masked_mj  == 16'b100_0_00000_00000_10) & ~bubble & ~op16_jr_d;
  wire op16_ebreak_d     = (inst_d             == 16'b100_1_00000_00000_10) & ~bubble;
  wire op16_jalr_d       = (inst_type_masked_j   == 16'b100_1_00000_00000_10) & ~bubble & ~op16_ebreak_d;
  wire op16_add_d        = (inst_type_masked_mj  == 16'b100_1_00000_00000_10) & ~bubble & ~op16_jalr_d & ~ op16_ebreak_d;
  wire op16_swsp_d       = (inst_type_masked     == 16'b110_0_00000_00000_10) & ~bubble;

  // Non-standard extensions to support microcode are permitted in these opcode gaps
  wire op16_slli_setrd_d = (inst_type_masked_j   == 16'b000_1_00000_00001_10) & ~bubble;
  wire op16_slli_setrs_d = (inst_type_masked_j   == 16'b000_1_00000_00010_10) & ~bubble;
  wire op16_slli_thunk_d = (inst_type_masked_j   == 16'b000_1_00000_00100_10) & ~bubble;

  // Blanket matches for RVC and RV32I instructions
  wire op32 =  &(inst_d[1:0]) & ~bubble;
  wire op16_d = ~&(inst_d[1:0]) & ~bubble;

  // Trap on unimplemented instructions
  wire trap = op32;

  // Data bus reads and writes are registered
  always @(posedge clk) begin
    rreq <= 1'b0;
    addr <= 32'b0;
    wmask <= 4'h0;
    wdata <= 32'b0;

    if(~data_stall)
      inst_d <= inst;

    if(reset | rack) begin
      data_stall <= 'b0;
    end else if(op16_lw_d | op16_lwsp_d) begin
      addr <= aluS;
      data_stall <= 1'b1;
      rreq <= 1'b1;
    end else if(op16_swsp_d | op16_sw_d | op16_sh_d | op16_sb_d) begin
      addr <= aluS;
      wmask <= {4{op16_swsp_d}} | {4{op16_sw_d}} |
        {4{op16_sh_d}} & {{2{inst_d[5]}}, {2{~inst_d[5]}}} |
        {4{op16_sb_d}} & {inst_d[6:5]==2'b11, inst_d[6:5]==2'b01, inst_d[6:5]==2'b10, inst_d[6:5]==2'b00};
      wdata <= oshift;
    end
  end

  // Instruction bus outputs
  assign inst_addr = {pc_f, 1'b0};

  // PC logic
  wire branch_taken = (op16_beqz_d & (~|regS)
                | (op16_bnez_d & (|regS)))
                | op16_j_d | op16_jal_d | op16_jr_d | op16_jalr_d
                | op16_slli_thunk_d;

  // Fetch Process
  always @(posedge clk) begin

    // Instruction mis-fetches create a 2-cycle penalty
    bubble2 <= reset | branch_taken | trap;
    bubble1 <= bubble2;

    // Update fetch instruction unless bubbling
    if (reset) begin
      pc_f <= 0;
      pc_d <= 0;
      pc_e <= 0;
    end else if (~op16_lw_d & ~op16_lwsp_d & (rack | ~data_stall)) begin
      pc_f <= aguX;
      pc_d <= pc_f;
      pc_e <= pc_d;
    end

    microcode <= (microcode | trap) & ~(reset | op16_slli_thunk_d);

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
    dly16_slli_setrs <= op16_slli_setrs_d;
    dly16_slli_setrd <= op16_slli_setrd_d;

    // Load and setrs/setrd instructions complete a cycle after they are
    // initiated, so we need to keep some state.
    if(reset)
      dra <= 5'h0;
    else if(~bubble)
      dra <= (regD[4:0] & ({5{op16_slli_setrd_d | op16_slli_setrs_d}}))
           | ({2'b01, inst_d[4:2]} & {5{op16_lw_d}})
           | (inst_d[11:7] & {5{op16_lwsp_d | op32}});
  end

  // READ/WRITE register file port
  assign addrD_port = (dra & {5{dly16_slli_setrd | rack}})
        | (5'b00001 & {5{op16_jal_d | op16_jalr_d | trap}}) // write return address into ra
        | ({2'b01, inst_d[4:2]} & {5{op16_addi4spn_d | op16_sw_d | op16_sh_d | op16_sb_d}}) // data
        | (inst_d[6:2] & {5{op16_swsp_d}})
        | (inst_d[11:7] & ({5{op16_addi_d | op16_add_d
            | (op16_mv_d & ~dly16_slli_setrd)
            | op16_addi16sp_d
            | op16_slli_setrd_d | op16_slli_setrs_d
            | op16_li_d | op16_lui_d
            | op16_slli_d}}))
        | ({2'b01, inst_d[9:7]} & {5{op16_sub_d
            | op16_xor_d | op16_or_d | op16_and_d | op16_andi_d
            | op16_srli_d | op16_srai_d}});

      // READ-ONLY register file port
  assign addrS_port = (dra & {5{dly16_slli_setrs}})
          | (5'b00010 & {5{op16_addi4spn_d | op16_lwsp_d | op16_swsp_d}})
          | (inst_d[11:7] & {5{op16_jr_d | op16_jalr_d | op16_slli_thunk_d}}) // jump destination
          | ({2'b01, inst_d[9:7]} & {5{op16_sw_d | op16_sh_d | op16_sb_d | op16_lw_d | op16_beqz_d | op16_bnez_d}})
          | ({2'b01, inst_d[4:2]} & {5{op16_and_d | op16_or_d | op16_xor_d | op16_sub_d}})
          | (inst_d[6:2] & {5{(op16_mv_d & ~dly16_slli_setrs) | op16_add_d}});

  // Select between "normal" and "microcode" register banks.
  assign bD_banksel = (microcode ^ dly16_slli_setrd) | trap;
  assign bS_banksel = (microcode ^ dly16_slli_setrs) | trap;

  assign addrD = {bD_banksel, addrD_port};
  assign addrS = {bS_banksel, addrS_port};

  // Look up register file contents combinatorially
  assign regD = register_file[addrD];
  assign regS = register_file[addrS];

  assign aluA = (regD & {32{op16_add_d | op16_addi_d | op16_sub_d
                    | op16_and_d | op16_andi_d
                    | op16_or_d | op16_xor_d
                    | op16_addi16sp_d}})
          | ({22'b0, inst_d[10:7], inst_d[12:11], inst_d[5], inst_d[6], 2'b0} & {32{op16_addi4spn_d}})
          | ({24'b0, inst_d[8:7], inst_d[12:9], 2'b0} & {32{op16_swsp_d}})
          | ({24'b0, inst_d[3:2], inst_d[12], inst_d[6:4], 2'b0} & {32{op16_lwsp_d}})
          | ({25'b0, inst_d[5], inst_d[12:10], inst_d[6], 2'b0} & {32{op16_lw_d | op16_sw_d}});

  assign aluB = regS
          | ({{27{inst_d[12]}}, inst_d[6:2]} & {32{op16_addi_d | op16_andi_d | op16_li_d}})
          | ({{15{inst_d[12]}}, inst_d[6:2], 12'b0} & {32{op16_lui_d}})
          | ({{23{inst_d[12]}}, inst_d[4:3], inst_d[5], inst_d[2], inst_d[6], 4'b0} & {32{op16_addi16sp_d}});

  // This synthesizes into 4 CARRY8s - no need for manual xor/cin heroics
  assign aluS = op16_sub_d ? (aluA - aluB) : (aluA + aluB);

  // Full shifter: uses a single shift operator, with bit reversal to handle
  // c.slli, c.srli, and c.srai.
  //wire shift_right = inst_d[15];
  wire shift_right = op16_srli_d | op16_srai_d;
  reg [4:0] shamt;
  always @(*)
  case(1'b1)
    op16_srli_d: shamt=inst_d[6:2];
    op16_srai_d: shamt=inst_d[6:2];
    op16_slli_d: shamt=inst_d[6:2];
    op16_sb_d: shamt={inst_d[5], inst_d[6], 3'b0};
    op16_sh_d: shamt={inst_d[5], 4'b0};
    default: shamt=0; // sw, swsp, ...
  endcase

  wire [31:0] regD_reversed = {<<{regD}};
  wire signed [32:0] ishift = shift_right ? {regD[31] & op16_srai_d, regD} : {1'b0, regD_reversed};
  wire [32:0] rshift = ishift >>> shamt;
  wire [31:0] rshift_reversed = {<<{rshift[31:0]}};
  wire [31:0] oshift = shift_right ? rshift[31:0] : rshift_reversed;

  assign aluX = (aluS & (
                    {32{op16_add_d | op16_sub_d | op16_addi_d
                      | op16_li_d | op16_lui_d
                      | op16_addi4spn_d | op16_addi16sp_d}})) |
          ((aluA & aluB) & {32{op16_andi_d | op16_and_d}}) |
	  (oshift & {32{op16_slli_d | op16_srai_d | op16_srli_d}}) |
          ((aluA ^ aluB) & {32{op16_xor_d}}) |
          ((aluA | aluB) & {32{op16_or_d | op16_mv_d}}) |
          (rdata & {32{rack}}) |
          ({{(32-PC_BITS){1'b0}}, pc_d[PC_BITS-1:1], 1'b0} & {32{op16_jal_d | op16_jalr_d | trap}}); //  instruction following the jump (hence _dly)

  // Address Generation Unit (AGU)
  assign aguA = (pc_f & ~{(PC_BITS-1){trap | branch_taken}})
        | (pc_e & {(PC_BITS-1){branch_taken}} & ~{(PC_BITS-1){op16_jr_d | op16_jalr_d | op16_slli_thunk_d}});

  assign aguB = (regS[PC_BITS-1:1] & {(PC_BITS-1){op16_jr_d | op16_jalr_d | op16_slli_thunk_d}})
        | ({{(PC_BITS-11){inst_d[12]}}, inst_d[8], inst_d[10:9], inst_d[6], inst_d[7], inst_d[2], inst_d[11], inst_d[5:3]}
              & {(PC_BITS-1){branch_taken & (op16_j_d | op16_jal_d)}})
        | ({{(PC_BITS-8){inst_d[12]}}, inst_d[6:5], inst_d[2], inst_d[11:10], inst_d[4:3]}
              & {(PC_BITS-1){branch_taken & (op16_bnez_d | op16_beqz_d)}})
        | (uc_base[PC_BITS-1:1] & {(PC_BITS-1){trap}});

  assign aguX = (aguA + aguB) + {{(PC_BITS-2){1'b0}}, ~(branch_taken | rreq | trap)};

  wire wb = trap |                  // writes microcode x1/ra
             rack | // writes data
             op16_jal_d | op16_jalr_d |   // writes x1/ra
             op16_li_d | op16_lui_d |
             op16_addi_d | op16_addi4spn_d | op16_addi16sp_d |
             op16_andi_d | op16_mv_d | op16_add_d |
             op16_and_d | op16_or_d | op16_xor_d | op16_sub_d |
             op16_slli_d | op16_srli_d | op16_srai_d;

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
      $write("%8H ", {pc_f, 1'b0});
      $write("%8H ", {pc_d, 1'b0});
      $write("%8H ", {pc_e, 1'b0});
      $write("%8H ", {aguA, 1'b0});
      $write("%8H ", {aguB, 1'b0});
      $write("%8H ", {aguX, 1'b0});
      $write("%8H ", inst_d);

      if(op16_addi4spn_d)        begin $write("ADDI4SPN"); opcode = "ADDI4SPN"; end
      else if(op16_lw_d)         begin $write("LW      "); opcode = "LW      "; end
      else if(op16_sw_d)         begin $write("SW      "); opcode = "SW      "; end
      else if(op16_sb_d)         begin $write("SB      "); opcode = "SB      "; end
      else if(op16_sh_d)         begin $write("SH      "); opcode = "SH      "; end
      else if(op16_addi_d)       begin $write("ADDI    "); opcode = "ADDI    "; end
      else if(op16_jal_d)        begin $write("JAL     "); opcode = "JAL     "; end
      else if(op16_li_d)         begin $write("LI      "); opcode = "LI      "; end
      else if(op16_addi16sp_d)   begin $write("ADDI16SP"); opcode = "ADDI16SP"; end
      else if(op16_lui_d)        begin $write("LUI     "); opcode = "LUI     "; end
      else if(op16_srli_d)       begin $write("SRLI    "); opcode = "SRLI    "; end
      else if(op16_srai_d)       begin $write("SRAI    "); opcode = "SRAI    "; end
      else if(op16_andi_d)       begin $write("ANDI    "); opcode = "ANDI    "; end
      else if(op16_sub_d)        begin $write("SUB     "); opcode = "SUB     "; end
      else if(op16_xor_d)        begin $write("XOR     "); opcode = "XOR     "; end
      else if(op16_or_d)         begin $write("OR      "); opcode = "OR      "; end
      else if(op16_and_d)        begin $write("AND     "); opcode = "AND     "; end
      else if(op16_j_d)          begin $write("J       "); opcode = "J       "; end
      else if(op16_beqz_d)       begin $write("BEQZ    "); opcode = "BEQZ    "; end
      else if(op16_bnez_d)       begin $write("BNEZ    "); opcode = "BNEZ    "; end
      else if(op16_slli_d)       begin $write("SLLI    "); opcode = "SLLI    "; end
      else if(op16_lwsp_d)       begin $write("LWSP    "); opcode = "LWSP    "; end
      else if(op16_jr_d)         begin $write("JR      "); opcode = "JR      "; end
      else if(op16_mv_d)         begin $write("MV      "); opcode = "MV      "; end
      else if(op16_ebreak_d)     begin $write("EBREAK  "); opcode = "EBREAK  "; end
      else if(op16_jalr_d)       begin $write("JALR    "); opcode = "JALR    "; end
      else if(op16_add_d)        begin $write("ADD     "); opcode = "ADD     "; end
      else if(op16_swsp_d)       begin $write("SWSP    "); opcode = "SWSP    "; end
      else if(op16_slli_thunk_d) begin $write("THUNK   "); opcode = "THUNK   "; end
      else if(op16_slli_setrd_d) begin $write("SETRD   "); opcode = "SETRD   "; end
      else if(op16_slli_setrs_d) begin $write("SETRS   "); opcode = "SETRS   "; end
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
