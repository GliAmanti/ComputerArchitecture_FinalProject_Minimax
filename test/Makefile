ifeq ($(wildcard /.dockerenv),)
    # This Makefile section is evaluated when we aren't inside a Docker
    # environment.  It re-executes make from within Docker and we end up below.
    MAKECMDGOALS ?= default
    .PHONY: default dockerimage shell quick

    DOCKERNAME=gsmecher/minimax-verification:1

    # Invoke Docker
    default quick: $(DOCKERSTAMP)
	@echo Moving inside Docker...
	docker run --user "$(shell id -u):$(shell id -g)"		\
		-v $(shell git rev-parse --show-toplevel):/minimax	\
		$(DOCKERNAME) $(MAKE) -C /minimax/test $(MAKECMDGOALS) $(MAKEFLAGS)

    # Launch a shell within Docker environment
    shell: $(DOCKERSTAMP)
	@echo Moving inside Docker...
	docker run -it --user "$(shell id -u):$(shell id -g)"		\
		-v $(shell git rev-parse --show-toplevel):/minimax	\
		$(DOCKERNAME) /bin/bash -i $(if $(CMD), -c "$(CMD)")

    # Initialize or update the Docker environment
    dockerimage: Dockerfile
	docker build -t $(DOCKERNAME) .
else
    # This section of the Makefile executes inside Docker, and runs tests.
    .PHONY: asm default quick
    asm:
	$(MAKE) -C ../asm

    default: asm
	if [ ! -d riscv-arch-test ]; then				\
		riscof --verbose info arch-test --clone;		\
	fi
	riscof run --config=config.ini					\
		--suite=riscv-arch-test/riscv-test-suite		\
		--env=riscv-arch-test/riscv-test-suite/env

    quick:
	./quick $(TESTNAME)
endif
