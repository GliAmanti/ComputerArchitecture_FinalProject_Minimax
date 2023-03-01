ifeq ($(wildcard /.dockerenv),)
    # This Makefile section is evaluated when we aren't inside a Docker
    # environment.  It re-executes make from within Docker and we end up below.
    MAKECMDGOALS ?= default
    .PHONY: default dockerimage

    DOCKERNAME=gsmecher/minimax-verification:1

    # Invoke Docker
    default: $(DOCKERSTAMP)
	@echo Moving inside Docker...
	docker run --user "$(shell id -u):$(shell id -g)"		\
		-v $(shell git rev-parse --show-toplevel):/minimax	\
		$(DOCKERNAME) make -C /minimax/test $(MAKECMDGOALS)

    # Initialize or update the Docker environment
    dockerimage: Dockerfile
	docker build -t $(DOCKERNAME) .
else
    # This section of the Makefile executes inside Docker, and runs tests.
    .PHONY: asm default
    asm:
	$(MAKE) -C ../asm

    default: asm
	[ ! -d riscv-arch-test ] && riscof --verbose info arch-test --clone
	riscof run --config=config.ini					\
		--suite=riscv-arch-test/riscv-test-suite		\
		--env=riscv-arch-test/riscv-test-suite/env
endif
