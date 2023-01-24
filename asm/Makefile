PYTHON ?= python3
CROSS_COMPILE ?= riscv32-corev-elf-
CROSS_CC ?= $(CROSS_COMPILE)gcc
CROSS_OBJCOPY ?= $(CROSS_COMPILE)objcopy

CFLAGS := -march=rv32ic_zcb -mabi=ilp32	\
	  -fno-pic -nostartfiles -nostdlib

LDFLAGS := -march=rv32ic -mabi=ilp32	\
	   -fno-pic -Wl,--no-relax	\
	   -nostartfiles -nostdlib

default: blink.hex microcode.hex

.PRECIOUS: microcode.o

clean:
	rm -rf *.o *.hex*

# Linker
%.elf: %.o
	$(CROSS_CC) $(LDFLAGS) -T bare.ld -o $@ $<

%.bin: %.elf
	$(CROSS_OBJCOPY) -O binary $< $@

# Special case: microcode doesn't embed itself
microcode.hex: microcode.bin
	$(PYTHON) ./bin2hex $< $@

%.hex: %.bin microcode.hex
	$(PYTHON) ./bin2hex --microcode=microcode.hex $< $@

# Assembler
%.o: %.S
	$(CROSS_CC) $(CFLAGS) -c -o $@ $<

# Compiler
%.o: %.c
	$(CROSS_CC) $(CFLAGS) -Os -c -o $@ $<
