Minimax: a Compressed-First, Microcoded RISC-V CPU
==================================================

[![CI status](https://github.com/gsmecher/minimax/workflows/CI/badge.svg)](https://github.com/gsmecher/minimax/actions?query=workflow%3ACI)

What?
-----

RISC-V's compressed instruction (RVC) extension is intended as an add-on to the
regular, 32-bit instruction set, not a replacement or competitor. Its designers
designed RVC instructions to be expanded into regular 32-bit RV32I equivalents
via a pre-decoder.

What happens if we *explicitly* architect a RISC-V CPU to execute RVC
instructions, and "mop up" any RV32I instructions that aren't convenient via a
microcode layer? What architectural optimizations are unlocked as a result?

"Minimax" is an experimental RISC-V implementation intended to establish if an
RVC-optimized CPU is, in practice, any simpler than an ordinary RV32I core with
pre-decoder. While it passes a modest test suite, you should not use it without
caution. (There are a large number of excellent, open source, "little" RISC-V
implementations you should probably use reach for first.)

Originally, we included both Verilog and VHDL implementations. Sadly, the VHDL
implementation has been retired.

In short:

* RV32C (compressed) instructions are first-class and execute at 1 clock per
  instruction. (Exceptions: branches have a 2-cycle "taken" penalty.)

* All RV32I instructions are emulated in microcode, using the instructions
  above.

This is distinct from (all?) other RV32C-capable RISC-V cores, because it
really is architected for compressed first. This is not how the compressed
ISA was intended to be implemented.

Why?
----

A compressed-first RISC-V architecture unlocks the following:

* 1 clock per instruction (CPI) using a 2-port register file. RVC
  instructions have only 1 rd and 1 rs field. A 2-port register file
  maps cleanly into a single RAM64X1D per bit.

* A simplified 16-bit instruction path without alignment considerations. The
  processor is a modified Harvard architecture, with a separate 16-bit
  instruction bus intended to connect to a second port of the instruction
  memory.  On Xilinx, the asymmetric ports (16-bit instruction, 32-bit data)
  are reconciled using an asymmetric block RAM primitive. As a result, we don't
  have to worry about a 32-bit instruction split across two 32-bit words.

Why is this desirable?

* Compilers (GCC, LLVM) are learning to prefer RVC instructions when
  optimizing for size. This means compiled code (with appropriate
  optimization settings) plays to Minimax's performance sweet-spot,
  preferring direct instructions to microcoded instructions.
  (see e.g. https://muxup.com/2022q3/whats-new-for-risc-v-in-llvm-15)

* RVC instructions nearly double code density, which pay for the cost of
  microcode ROM when compared against a minimalist RV32I implementation.

* It's not quite the smallest RVC implementation (SERV is smaller), but
  it is likely much faster with the appropriate compiler settings, and
  slightly less unorthodox in implementation.

What's awkward?

* RVC decoding is definitely uglier than regular RV32I. I expect this
  ugliness is better masked when RVC instructions are decoded to RV32I and
  executed as "regular" 32-bit instructions.

How?
----

What's the design like?

* Three-stage pipeline (fetch, decode, and everything-else).
  There is a corresponding 2-cycle penalty on taken branches.

* Several "extension instructions" that use the non-standard extension space
  reserved in C.SLLI. This space allows us to add "fused" instructions
  accessible only in microcode, that perform the following:

  - "Thunk" from microcode back to standard code,
  - Move data from "user" registers into "microcode" registers and back again.

  These instructions are only part of the microcode - you are not required to
  build an unusual toolchain to use Minimax.

Performance
===========

Resource Usage
--------------

The following statistics were collected using an Arty A7 (35T) as an execution
target. This FPGA uses LUT6s.

Resource usage (excluding ROM and peripherals; KU060; 12-bit PC):

* Minimax: 191 FFs, 507 CLB LUTs

Compare to:

* PicoRV32: 483 FFs, 782 LUTs ("small", RV32I only)
* FemtoRV32 186 FFs, 411 LUTs ("quark", RV32I only)
* SERV: 312 FFs, 182 LUTs (no CSR or timer; RV32I only)
* PicoBlaze: 82 FFs, 103 LUTs

Minimax is competitive, even against RV32I-only cores. When comparing
against RV32IC implementations, it does better:

* SERV: 303 FFs, 336 LUTs (no CSR or timer; RV32IC)
* PicoRV32: 518 FFs, 1085 LUTs (RV32IC)

It is difficult to gather defensible benchmarks: please treat these as
approximate, and let me know if they are inaccurate.

Fmax
----

Minimax meets timing closure at 100 MHz on an Artix A7 FPGA (-1 speed grade; xc7a35tcsg324-1).

How To
======

Regression Tests
----------------

The following command line snippet:

    $ cd minimax/tests
    $ run

...will run regression tests using the cSail framework. (The regression tests
take several minutes to complete; the initial run is even slower since it
involves a git checkout of the regression tests themselves.)

After completion, you should see something like the following:

    INFO | TEST NAME                                          : COMMIT ID                                : STATUS
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/C/src/cadd-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/C/src/caddi-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/C/src/caddi16sp-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/C/src/caddi4spn-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/C/src/cand-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/C/src/candi-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/C/src/cbeqz-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/C/src/cbnez-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/C/src/cj-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/C/src/cjal-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/C/src/cjalr-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/C/src/cjr-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/C/src/cli-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/C/src/clui-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/C/src/clw-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/C/src/clwsp-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/C/src/cmv-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/C/src/cnop-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/C/src/cor-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/C/src/cslli-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/C/src/csrai-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/C/src/csrli-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/C/src/csub-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/C/src/csw-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/C/src/cswsp-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/C/src/cxor-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/add-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/addi-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/and-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/andi-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/auipc-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/beq-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/bge-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/bgeu-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/blt-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/bltu-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/bne-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/fence-01.S : 81c7a2b769baa2f33f40bc5455299b1362b5d125 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/jal-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/jalr-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/lb-align-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/lbu-align-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/lh-align-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/lhu-align-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/lui-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/lw-align-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/misalign1-jalr-01.S : 0c4cdffe19b1a48d9fec8590c8817af2ff924a37 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/or-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/ori-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/sb-align-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/sh-align-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/sll-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/slli-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/slt-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/slti-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/sltiu-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/sltu-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/sra-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/srai-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/srl-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/srli-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/sub-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/sw-align-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/xor-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | /minimax/test/riscv-arch-test/riscv-test-suite/rv32i_m/I/src/xori-01.S : b91f98f3a0e908bad4680c2e3901fbc24b63a563 : Passed
    INFO | Test report generated at /minimax/test/riscof_work/report.html.


Example Bitstream
-----------------

The following command line snippet:

    $ source /path/to/Vivado/settings.sh
    $ cd minimax/tcl
    $ ./arty_a7.tcl

...will create a "blinker" project using a Minimax core in Vivado. You should
be able to click "generate bitstream" and produce a blinking light using an
Arty A35T board.

Contributing
============

Minimax needs the following:

* Zicsr and interrupt support

I am happy to collaborate and/or provide mentorship on this or any other
Minimax-related project.  Comments and PRs always welcome.

Graeme Smecher
gsmecher@threespeedlogic.com
