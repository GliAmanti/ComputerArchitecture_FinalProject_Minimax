OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS {
	. = 0x0;

	.text : {
		_start = .;
		*(.text)
	}
	.data : { *(.data) }
	.bss : { *(.bss) }
}
