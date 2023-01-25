# Adapted from https://gitlab.com/incoresemi/docker-images/-/blob/master/compliance/Dockerfile
FROM debian:bookworm

ENV RISCV=/opt/riscv
ENV PATH=$PATH:$RISCV/bin

RUN apt-get update && apt-get install -y --no-install-recommends	\
	autoconf							\
	automake							\
	autotools-dev							\
	bc								\
	bison								\
	build-essential							\
	curl 								\
	device-tree-compiler						\
	flex								\
	g++								\
	gawk								\
	git								\
	gperf								\
	iverilog							\
	libexpat-dev							\
	libgmp-dev							\
	libgmp3-dev							\
	libmpc-dev							\
	libmpfr-dev							\
	libtool								\
	libusb-1.0 							\
	make								\
	opam								\
	patchutils							\
	pkg-config							\
	python3								\
	python3-numpy							\
	python3-pip							\
	rename								\
	texinfo								\
	wget								\
	z3								\
	zlib1g-dev							\
	&& rm -rf /var/lib/apt/lists/*

RUN update-alternatives --install /usr/bin/python python /usr/bin/python3.10 2
RUN mkdir -p $RISCV

# SAIL
RUN opam init -y --disable-sandboxing && \
  opam switch create ocaml-base-compiler.4.06.1 && \
  opam install sail -y && \
  eval $(opam env) && \
  git clone https://github.com/rems-project/sail-riscv.git && \
  cd sail-riscv && \
  make && \
  ARCH=RV32 make

RUN cp /sail-riscv/c_emulator/riscv_sim_* /usr/bin/
RUN cp /sail-riscv/ocaml_emulator/riscv_ocaml_sim_* /usr/bin/
RUN rm -rf /sail-riscv

# SPIKE
RUN git clone https://github.com/riscv/riscv-isa-sim.git -b master && \
  cd riscv-isa-sim && \
  mkdir build && \
  cd build && \
  ../configure --prefix=$RISCV && \
  make -j $(nproc) 1>/dev/null && \
  make install && \
  cd ../../ && \
  rm -rf riscv-isa-sim

# Toolchain - unfortunately RISCOF insists on riscv32-corev, and this generates riscv32-unknown.
RUN git clone -b conditional-build-variables \
	https://github.com/gsmecher/riscv-code-size-reduction.git riscv-code-size-reduction && \
  cd riscv-code-size-reduction && git submodule update --init -j $(nproc) --recursive && \
  cd toolchain && INSTALLPREFIX=/usr/local ./gcc.sh && \
  cd ../.. && rm -rf riscv-gnu-toolchain && \
  rename s/unknown/corev/ /usr/local/bin/*

# RISCOF
RUN pip install git+https://github.com/riscv/riscof.git
