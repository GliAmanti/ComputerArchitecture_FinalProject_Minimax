#ifndef _COMPLIANCE_MODEL_H
#define _COMPLIANCE_MODEL_H
#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                            \
        .align 8; .global tohost; tohost: .dword 0;                     \
        .align 8; .global fromhost; fromhost: .dword 0;                 \
        .popsection;                                                    \
        .align 8; .global begin_regstate; begin_regstate:               \
        .word 128;                                                      \
        .align 8; .global end_regstate; end_regstate:                   \
        .word 4;

#define RVMODEL_HALT			\
	la a0, begin_signature;		\
	la a1, end_signature;		\
	sub a1, a1, a0;			\
	li a2, -8;			\
	beqz a1, compliance_quit;	\
compliance_loop:			\
	lw a3, 0(a0);			\
	sw a3, 0(a2);			\
	addi a0, a0, 4;			\
	addi a1, a1, -4;		\
	bnez a1, compliance_loop;	\
compliance_quit:			\
	li a0, 0;			\
	sw a0, 4(a2);			\
	j .

#define RVMODEL_BOOT

#define RVMODEL_DATA_BEGIN	\
  RVMODEL_DATA_SECTION		\
  .align 4;			\
  .global begin_signature;	\
  begin_signature:

#define RVMODEL_DATA_END	\
  .align 4;			\
  .global end_signature;	\
  end_signature:

#define RVMODEL_IO_INIT
#define RVMODEL_IO_WRITE_STR(_R, _STR)
#define RVMODEL_IO_CHECK()
#define RVMODEL_IO_ASSERT_GPR_EQ(_S, _R, _I)
#define RVMODEL_IO_ASSERT_SFPR_EQ(_F, _R, _I)
#define RVMODEL_IO_ASSERT_DFPR_EQ(_D, _R, _I)

#define RVMODEL_SET_MSW_INT
#define RVMODEL_CLEAR_MSW_INT
#define RVMODEL_CLEAR_MTIMER_INT
#define RVMODEL_CLEAR_MEXT_INT

#endif
