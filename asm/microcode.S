/*
 * Minimax: microcoded RISC-V
 *
 * (c) 2022-2023 Three-Speed Logic, Inc. <gsmecher@threespeedlogic.com>
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

/* "x.poke" write the value of an emulation-mode register into an user-mode
 * register. */
.macro x.poke rd, rs
	.half 0x1006 + (\rd << 7)
	c.mv x8, \rs
.endm

/* "x.peek" reads from an user-mode register and deposits the result into an
 * emulation register. */
.macro x.peek rd, rs
	.half 0x100a + (\rs << 7)
	c.mv \rd, x8
.endm

/* "x.thunk" jumps from emulation mode back into user mode at the PC specified
 * in register "rd". */
.macro x.thunk rd
	.half 0x1012 + (\rd << 7)
.endm

/* Trapping looks like a JAL with a microcode-specific register bank.
 * At the point of entry,
 *
 * - Register 0x21 (that's "microcode" x1) contains the return address we should jump to
 *   (that's the trap PC, plus 2).
 *
 * It is not safe to use emulated instructions in microcode, since the CPU
 * doesn't gracefully double-fault.
 *
 * We decode the emulated instruction into the following registers:
 *
 * x1 / ra: reserved for 1-deep function calls/returns
 * x2 / sp: RESERVED - could be pointer to microcode constants/variables
 * x3: offending PC
 * x4: offending instruction
 * x5: opcode
 * x6: rd field
 * x7: opcode bits 31..12, right shifted
 *
 * x8..15: working registers
 *
 * x16: funct3, left shifted by 1
 * x17: rs1 field
 * x18: rs1 value
 * x19: rs2/shamt field
 * x20: rs2 value
 * x21: funct7 field
 *
 * All other (microcode) registers are currently unused.
 */

.section .text

microcode_entry:
	/* Trapping stores PC+2 in RA. Correct it. */
	c.mv x3, ra
	c.addi x3, -2

	/* Hot path - we want to detect and emulate 16-bit SRLI/SRAI/SLLI
	 * opcodes as quickly as possible, since they are the only RVC
	 * instructions that aren't directly implemented. */

	/* Fetch instruction, which may be half-word aligned. */
	c.mv x15, x3
	c.andi x15, 3
	c.mv x9, x3
	c.andi x9, -4	/* strip LSBs and fetch */
	c.lw x8, 0(x9)
	c.beqz x15, 1f

	/* Split instruction - fetch the other half and assemble */
	c.srli x8, 16

	c.mv x10, x8
	c.lw x8, 4(x9)
	c.slli x8, 16
	c.or x8, x10
1:	c.mv x4, x8
	c.j op32_entry

.macro dyn_shift op
	/* shift 8 bits at a time until we can't */
	c.mv x15, x9
	c.srli x15, 3
	c.beqz x15, 2f

1:	\op x8, 8
	c.addi x9, -8
	c.addi x15, -1
	c.bnez x15, 1b

2:	c.beqz x9, 4f /* maybe done? */

3:	/* now just loop bit-by-bit - slow, but compact and max 8 iters */
	\op x8, 1
	c.addi x9, -1
	c.bnez x9, 3b

4:	c.jr ra
.endm

srai_dyn: dyn_shift c.srai
srli_dyn: dyn_shift c.srli
slli_dyn: dyn_shift c.slli

op32_entry:
	c.mv x8, x4

1:	/* Isolate opcode into x5 - note we strip the lower bits, which are always 11 */
	c.srli x8, 2
	c.mv x9, x8
	c.andi x9, 0x1f
	c.mv x5, x9

	/* Isolate rd */
	c.srli x8, 5
	c.mv x9, x8
	c.andi x9, 0x1f
	c.mv x6, x9

	/* isolate funct3, left shifted by 1 for jump tables */
	c.srli x8, 5
	c.mv x9, x8
	c.andi x9, 0x7
	c.slli x9, 1
	c.mv x16, x9

	/* isolate rs1 */
	c.srli x8, 3
	c.mv x9, x8
	c.andi x9, 0x1f
	c.mv x17, x9

	/* look up rs1 value from register file (we mostly need it) */
	x.peek x18, 17

	/* isolate rs2/shamt */
	c.srli x8, 5
	c.mv x9, x8
	c.andi x9, 0x1f
	c.mv x19, x9

	/* look up rs2 value from register file (we sometimes need it) */
	x.peek x20, 19

	/* isolate funct7 */
	c.srli x8, 5
	c.mv x21, x8

	/* create jump based on opcode */
	c.mv x8, x5
	c.slli x8, 1 /* 1 compressed instruction per opcode */

	/* Table jump */
	c.jal .+2
	c.addi ra, 6 /* offset to table base */
	c.add ra, x8
	c.jr ra

	/* Names per Table 24.1 */
	c.j table0	/* 0: LOAD */
	c.j .		/* 1: LOAD-FP */
	c.j .		/* 2: custom-0 */
	c.j table3	/* 3: MISC-MEM */
	c.j table4	/* 4: OP-IMM */
	c.j auipc	/* 5: AUIPC */
	c.j .		/* 6: OP-IMM-32 */
	c.j .		/* 7: 48b */
	c.j table8	/* 8: STORE */
	c.j .		/* 9: STORE-FP */
	c.j .		/* a: custom-1 */
	c.j .		/* b: AMO */
	c.j tablec	/* c: OP */
	c.j lui		/* d: LUI */
	c.j .		/* e: OP-32 */
	c.j .		/* f: 64b */
	c.j .		/* 10: MADD */
	c.j .		/* 11: MSUB */
	c.j .		/* 12: NMSUB */
	c.j .		/* 13: NMADD */
	c.j .		/* 14: OP-FP */
	c.j .		/* 15: reserved */
	c.j .		/* 16: custom-2/rv128 */
	c.j .		/* 17: 48b */
	c.j table18	/* 18: BRANCH */
	c.j jalr	/* 19: JALR */
	c.j .		/* 1a: reserved */
	c.j jal		/* 1b: JAL */
	c.j table1c	/* 1c: SYSTEM */
	c.j .		/* 1d: reserved */
	c.j .		/* 1e: custom-3/rv128 */
	c.j .		/* 1f: >=80b */

table0:
	c.jal .+2
	c.addi ra, 6 /* offset to table base */
	c.add ra, x16
	c.jr ra

	c.j lb	/* 0.0: LB */
	c.j lh	/* 0.1: LH */
	c.j lw	/* 0.2: LW */
	c.j .	/* 0.3: */
	c.j lbu	/* 0.4: LBU */
	c.j lhu	/* 0.5: LHU*/
	c.j .	/* 0.6: */
	c.j .	/* 0.7: */

table3:
	c.jal .+2
	c.addi ra, 6 /* offset to table base */
	c.add ra, x16
	c.jr ra

	c.j ret_rv32	/* 3.0: FENCE is a noop */
	c.j .	/* 3.1: */
	c.j .	/* 3.2: */
	c.j .	/* 3.3: */
	c.j .	/* 3.4: */
	c.j .	/* 3.5: */
	c.j .	/* 3.6: */
	c.j .	/* 3.7: */

table4:
	c.jal .+2
	c.addi ra, 6 /* offset to table base */
	c.add ra, x16
	c.jr ra

	c.j addi	/* 4.0: ADDI */
	c.j slli_zip	/* 4.1: SLLI or bitmanip */
	c.j slti	/* 4.2: SLTI */
	c.j sltiu	/* 4.3: SLTIU */
	c.j xori	/* 4.4: XORI */
	c.j srli_srai_unzip	/* 4.5: SRLI/SRAI or bitmanip */
	c.j ori		/* 4.6: ORI */
	c.j andi	/* 4.7: ANDI */

table8:
	c.jal .+2
	c.addi ra, 6 /* offset to table base */
	c.add ra, x16
	c.jr ra

	c.j sb	/* 8.0: SB */
	c.j sh	/* 8.1: SH */
	c.j sw	/* 8.2: SW */
	c.j .	/* 8.3: */
	c.j .	/* 8.4: */
	c.j .	/* 8.5: */
	c.j .	/* 8.6: */
	c.j .	/* 8.7: */

tablec:
	c.jal .+2
	c.addi ra, 6 /* offset to table base */
	c.add ra, x16
	c.jr ra

	c.j add_sub	/* c.0: ADD/SUB */
	c.j sll		/* c.1: SLL */
	c.j slt		/* c.2: SLT */
	c.j sltu	/* c.3: SLTU */
	c.j xor		/* c.4: XOR */
	c.j srl_sra	/* c.5: SRL/SRA */
	c.j or		/* c.6: OR */
	c.j and		/* c.7: AND */

table18:
	c.jal .+2
	c.addi ra, 6 /* offset to table base */
	c.add ra, x16
	c.jr ra

	c.j beq		/* 18.0: BEQ */
	c.j bne		/* 18.1: BNE */
	c.j .		/* 18.2: */
	c.j .		/* 18.3: */
	c.j blt		/* 18.4: BLT */
	c.j bge		/* 18.5: BGE */
	c.j bltu	/* 18.6: BLTU */
	c.j bgeu	/* 18.7: BGEU */

table1c:
	c.jal .+2
	c.addi ra, 6 /* offset to table base */
	c.add ra, x16
	c.jr ra

	c.j .		/* 1c.0: */
	c.j csrrw	/* 1c.1: CSRRW */
	c.j csrrs	/* 1c.2: CSRRS */
	c.j csrrc	/* 1c.3: CSRRC */
	c.j .		/* 1c.4:  */
	c.j csrrwi	/* 1c.5: CSRRWI */
	c.j csrrsi	/* 1c.6: CSRRSI */
	c.j csrrci	/* 1c.7: CSRRCI */

lui:	c.mv x8, x4
	c.srli x8, 12
	c.slli x8, 12
	x.poke 6, x8
	c.j ret_rv32

auipc:	c.mv x8, x4
	c.srli x8, 12
	c.slli x8, 12
	c.add x8, x3
	x.poke 6, x8
	c.j ret_rv32

/*
 * FIXME: loads do not gracefully handle misaligned addresses.
 */

lb:	c.jal load_form_address
	c.lw x8, 0(x8)

	c.addi x9, -3
1:	c.beqz x9, 3f
2:	c.slli x8, 8
	c.addi x9, 1
	c.bnez x9, 2b

3:	c.srai x8, 24
	x.poke 6, x8
	c.j ret_rv32

lh:	c.jal load_form_address
	c.lw x8, 0(x8)
	c.bnez x9, 1f
	c.slli x8, 16
1:	c.srai x8, 16
	x.poke 6, x8
	c.j ret_rv32

lw:	c.jal load_form_address
	c.lw x8, 0(x8)
	x.poke 6, x8
	c.j ret_rv32

lbu:	c.jal load_form_address
	c.lw x8, 0(x8)

	c.addi x9, -3
1:	c.beqz x9, 3f
2:	c.slli x8, 8
	c.addi x9, 1
	c.bnez x9, 2b

3:	c.srli x8, 24
	x.poke 6, x8
	c.j ret_rv32


lhu:	c.jal load_form_address
	c.lw x8, 0(x8)
	c.bnez x9, 1f
	c.slli x8, 16
1:	c.srli x8, 16
	x.poke 6, x8
	c.j ret_rv32

load_form_address:
	c.mv x31, ra

	# x8 -> 32-bit address, possibly unaligned
	c.mv x8, x4
	c.srai x8, 20
	c.add x8, x18

	# x8 -> 32-bit address; x9 -> address LSBs
	c.mv x9, x8
	c.andi x9, 3
	c.andi x8, -4

	c.jr x31

sb:
	c.mv x8, x4
	c.srai x8, 20
	c.andi x8, -32 # drop bits 24..20 - these encode rs2
	c.add x8, x6 # low offset bits
	c.add x8, x18 # base address
	c.mv x10, x8
	c.andi x8, -4 # mask 2 LSBs
	c.mv x9, x20 # value

	c.andi x10, 3 # extract byte offset
	c.bnez x10, 1f

	# address ...00
	c.sb x9, 0(x8)
	c.j ret_rv32

1:	c.addi x10, -1
	c.bnez x10, 2f

	# address ...01
	c.sb x9, 1(x8)
	c.j ret_rv32

2:	c.addi x10, -1
	c.bnez x10, 3f

	# address ...10
	c.sb x9, 2(x8)
	c.j ret_rv32

3:	# address ...11
	c.sb x9, 3(x8)
	c.j ret_rv32

sh:
	c.mv x8, x4
	c.srai x8, 20
	c.andi x8, -32 # drop bits 24..20 - these encode rs2
	c.add x8, x6 # low offset bits
	c.add x8, x18 # base address
	c.mv x10, x8
	c.andi x8, -4 # mask 2 LSBs
	c.mv x9, x20 # value

	c.andi x10, 2 # extract halfword offset
	c.bnez x10, 1f

	c.sh x9, 0(x8)
	c.j ret_rv32

1:	c.sh x9, 2(x8)
	c.j ret_rv32

sw:	c.mv x8, x4
	c.srai x8, 20
	c.andi x8, -32 # drop bits 24..20 - these encode rs2
	c.add x8, x6 # low offset bits
	c.add x8, x18 # base address
	c.mv x9, x20
	c.sw x9, 0(x8)
	c.j ret_rv32

/* Placed here because c.bnez/c.beqz have limited range and are used in
 * relative branches */
ret_rv32:
	c.addi x3, 4
	x.thunk 3

beq:
	c.mv x8, x18
	c.mv x9, x20
	c.sub x8, x9
	c.bnez x8, ret_rv32 /* branch not taken */

	c.jal resolve_imm1
	c.add x8, x3
	x.thunk 8
	c.j ret_rv32

bne:
	c.mv x8, x18
	c.mv x9, x20
	c.sub x8, x9
	c.beqz x8, ret_rv32 /* branch not taken */

	c.jal resolve_imm1
	c.add x8, x3
	x.thunk 8
	c.j ret_rv32

blt:
	c.mv x8, x18
	c.mv x9, x20
	c.jal slt_func
	c.beqz x8, ret_rv32 /* branch not taken */

	c.jal resolve_imm1
	c.add x8, x3
	x.thunk 8
	c.j ret_rv32

slt:
	c.mv x8, x18
	c.mv x9, x20
	c.jal slt_func
	x.poke 6, x8
	c.j ret_rv32

sltu:
	c.mv x8, x18
	c.mv x9, x20
	c.jal sltu_func
	x.poke 6, x8
	c.j ret_rv32

addi:	c.mv x8, x4
	c.srai x8, 20
	c.add x8, x18
	x.poke 6, x8
	c.j ret_rv32

andi:	c.mv x8, x4
	c.srai x8, 20
	c.mv x9, x18
	c.and x8, x9
	x.poke 6, x8
	c.j ret_rv32

ori:	c.mv x8, x4
	c.srai x8, 20
	c.mv x9, x18
	c.or x8, x9
	x.poke 6, x8
	c.j ret_rv32

xori:	c.mv x8, x4
	c.srai x8, 20
	c.mv x9, x18
	c.xor x8, x9
	x.poke 6, x8
	c.j ret_rv32

slli_zip:
	/* Set up operands */
	c.mv x8, x18
	c.mv x9, x19

	/* Disambiguate based on funct7 */
	c.mv x10, x21
	c.beqz x10, 1f /* 0 => SLLI */
	c.addi x10, -4
	c.beqz x10, zip /* 4 -> Zbkb zip */

1:	c.jal slli_dyn
	x.poke 6, x8
	c.j ret_rv32

zip:	c.j . /* unimplemented */

srli_srai_unzip:
	/* Set up operands */
	c.mv x8, x18
	c.mv x9, x19

	/* disambiguate based on funct7 */
	c.mv x10, x21
	c.beqz x10, 1f /* 0 -> SRLI */
	c.addi x10, -32
	c.beqz x10, 2f /* 32 -> SRAI */
	c.mv x10, x21
	c.addi x10, -4
	c.beqz x10, unzip

	c.j . /* unknown/unimplemented: bail */

1:	c.jal srli_dyn
	x.poke 6, x8
	c.j ret_rv32

2:	c.jal srai_dyn
	x.poke 6, x8
	c.j ret_rv32

unzip:
	c.li x10, 0 /* even bits go here */
	c.li x11, 0 /* odd bits go here */
	c.li x12, 16 /* loop */
	c.lui x13, 0x8 /* constant 0x8000 */

1:	c.mv x9, x8 /* even bit */
	c.andi x9, 1 /* mask LSB */
	c.srli x10, 1 /* make room */
	c.beqz x9, 2f
	c.or x10, x13
2:	c.srli x8, 1

	c.mv x9, x8 /* odd bit */
	c.andi x9, 1
	c.srli x11, 1
	c.beqz x9, 3f
	c.or x11, x13
3:	c.srli x8, 1

	c.addi x12, -1
	c.bnez x12, 1b

	/* now shift odd bits to high word */
	c.mv x8, x11
	c.slli x8, 16
	c.or x8, x10

	x.poke 6, x8
	c.j ret_rv32

slti:
	c.mv x8, x4
	c.srai x8, 20
	c.mv x9, x8

	c.mv x8, x18
	c.jal slt_func
	x.poke 6, x8
	c.j ret_rv32

sltiu:
	c.mv x8, x4
	c.srai x8, 20
	c.mv x9, x8

	c.mv x8, x18
	c.jal sltu_func
	x.poke 6, x8
	c.j ret_rv32

bge:
	c.mv x8, x18
	c.mv x9, x20

	c.jal slt_func
	c.bnez x8, 1f

	c.jal resolve_imm1
	c.add x8, x3
	x.thunk 8

1:	c.j ret_rv32

bltu:
	c.mv x8, x18
	c.mv x9, x20

	c.jal sltu_func
	c.beqz x8, 1f

	/* take the branch */
	c.jal resolve_imm1
	c.add x8, x3
	x.thunk 8

1:	c.j ret_rv32

slt_func: /* clobbers x10, x11 */
	c.mv x31, ra

	/* Compare MSBs */
	c.mv x10, x8
	c.xor x8, x9
	c.srli x8, 31
	c.beqz x8, 1f

	/* MSBs differed: right-shift to avoid overflow */
	c.srai x10, 1
	c.srai x9, 1

1:	/* MSBs were the same. Compare directly. */
	c.sub x10, x9
	c.mv x8, x10
	c.srli x8, 31

	c.jr x31

sltu_func: /* clobbers x10, x11 */
	c.mv x31, ra

	/* Compare MSBs */
	c.mv x10, x8
	c.xor x8, x9
	c.srli x8, 31
	c.beqz x8, 1f

	/* MSBs differed: right-shift to avoid overflow */
	c.srli x10, 1
	c.srli x9, 1

1:	/* MSBs were the same. Compare directly. */
	c.sub x10, x9
	c.mv x8, x10
	c.srli x8, 31

	c.jr x31

bgeu:
	c.mv x8, x18
	c.mv x9, x20

	c.jal sltu_func
	c.bnez x8, 1f

	/* take the branch */
	c.jal resolve_imm1
	c.add x8, x3
	x.thunk 8

1:	c.j ret_rv32

add_sub:
	c.mv x8, x18
	c.mv x9, x20

	/* disambiguate add/sub */
	c.mv x10, x4
	c.mv x11, x4
	c.slli x11, 2
	c.srli x11, 2
	c.sub x10, x11

	c.beqz x10, 1f
	c.li x10, -1
	c.xor x9, x10
	c.addi x9, 1

1:	c.add x8, x9
	x.poke 6, x8
	c.j ret_rv32

sll:
	c.mv x8, x18
	c.mv x9, x20
	c.andi x9, 31
	c.jal slli_dyn
	x.poke 6, x8
	c.j ret_rv32

srl_sra:
	/* Cheat by leveraging srli_srai */
	c.mv x8, x20
	c.andi x8, 31
	c.mv x19, x8
	c.j srli_srai_unzip

xor:
	c.mv x8, x18
	c.mv x9, x20
	c.xor x8, x9
	x.poke 6, x8
	c.j ret_rv32

or:
	c.mv x8, x18
	c.mv x9, x20
	c.or x8, x9
	x.poke 6, x8
	c.j ret_rv32

and:
	c.mv x8, x18
	c.mv x9, x20
	c.and x8, x9
	x.poke 6, x8
	c.j ret_rv32

jalr:
	/* Save pc+4 to rd */
	c.mv x9, x3
	c.addi x9, 4
	x.poke 6, x9

	/* Resolve immediate and add to rd */
	c.mv x8, x4
	c.srai x8, 20
	c.add x8, x18
	c.andi x8, -2 /* zero LSB */

	/* Thunk there */
	x.thunk 8

jal:
	/* sign extend into imm[20] */
	c.mv x8, x4
	c.srai x8, 31
	c.slli x8, 20
	c.mv x9, x8

	/* imm[19:12] */
	c.lui x8, 0x1f /* 0x1f000 */
	c.slli x8, 3
	c.lui x10, 0x7
	c.or x10, x8 /* form 0xff000 */

	c.mv x8, x4
	c.and x8, x10
	c.or x9, x8

	/* imm[11] */
	c.mv x8, x19
	c.andi x8, 1
	c.slli x8, 11
	c.or x9, x8

	/* imm[10:1] */
	c.mv x8, x4
	c.slli x8, 1
	c.srli x8, 21
	c.andi x8, -2
	c.or x8, x9

	/* Write return address into rd */
	c.mv x9, x3
	c.addi x9, 4
	x.poke 6, x9

	/* Form pc-relative offset and thunk there */
	c.add x8, x3
	x.thunk 8

resolve_imm1:
	c.mv x31, ra

	/* Signed immediate per BEQ and friends into x8; x9, x10, x31 destroyed */
	c.mv x8, x4
	c.srai x8, 31
	c.slli x8, 12 /* sign extend into imm[12] */
	c.mv x9, x8

	/* pick imm[11] */
	c.mv x8, x6
	c.andi x8, 1
	c.slli x8, 11
	c.or x9, x8

	/* pick imm[10:5] */
	c.mv x8, x4
	c.slli x8, 1
	c.srli x8, 26
	c.slli x8, 5
	c.or x9, x8

	/* pick imm[4:1] */
	c.mv x8, x6
	c.andi x8, 0x1e /* mask LSB */
	c.or x8, x9

	c.jr x31

	/* CSRs are no-ops for now. */
csrrw:	c.j ret_rv32
csrrs:	c.j ret_rv32
csrrc:	c.j ret_rv32
csrrwi:	c.j ret_rv32
csrrsi:	c.j ret_rv32
csrrci:	c.j ret_rv32
