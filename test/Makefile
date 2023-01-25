ifeq ($(wildcard /.dockerenv),)
    MAKECMDGOALS ?= default

    # Not inside Docker - move inside and re-invoke Make.
    DOCKERNAME=minimax-riscof
    DOCKERSTAMP := .dockerenv-$(DOCKERNAME)-$(shell hostname)

    # Invoke Docker
    $(MAKECMDGOALS): $(DOCKERSTAMP)
	@echo Moving inside Docker...
	docker run -it --user "$(shell id -u):$(shell id -g)"		\
		-v $(shell git rev-parse --show-toplevel):/minimax	\
		$(DOCKERNAME) make -C /minimax/test $(MAKECMDGOALS)

    # Initialize or update the Docker environment
    $(DOCKERSTAMP): Dockerfile
	docker build -t $(DOCKERNAME) .
	@touch $@
else
    # The dockerfile in the compiler has this name
    CROSS_COMPILE ?= riscv32-unknown-elf-
    export CROSS_COMPILE

    # Inside docker - the "real" recipe is here
    .PHONY: asm default
    asm:
	$(MAKE) -C ../asm

    default: asm
	riscof run --config=config.ini				\
		--suite=riscv-arch-test/riscv-test-suite	\
		--env=riscv-arch-test/riscv-test-suite/env

endif
