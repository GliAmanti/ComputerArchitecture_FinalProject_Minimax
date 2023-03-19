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
	pipx								\
	python3.10							\
	python3-numpy							\
	python3-pip							\
	rename								\
	rsync								\
	texinfo								\
	verilator							\
	wget								\
	z3								\
	zlib1g-dev							\
	&& rm -rf /var/lib/apt/lists/*

RUN update-alternatives --install /usr/bin/python python /usr/bin/python3 2
RUN mkdir -p $RISCV

# "swuser" corresponds to the tools installation, but need not be the user that
# runs any tests. (In fact, for CI, it usually isn't - Github uses a "runner"
# user with a UID that is almost certainly not 1000.)
RUN useradd -u 1000 -m swuser
USER swuser
WORKDIR /home/swuser
ENV PATH "${PATH}:/home/swuser/.local/bin"

# SAIL
RUN opam init -y --disable-sandboxing && \
  opam switch create ocaml-base-compiler.4.06.1 && \
  opam install sail -y

RUN eval $(opam env) && \
  git clone https://github.com/rems-project/sail-riscv.git && \
  cd sail-riscv && \
  make && \
  ARCH=RV32 make

RUN mkdir -p ~/.local/bin \
	&& cp -t ~/.local/bin sail-riscv/c_emulator/riscv_sim_* sail-riscv/ocaml_emulator/riscv_ocaml_sim_* \
	&& rm -rf sail-riscv

# SPIKE
RUN git clone https://github.com/riscv/riscv-isa-sim.git -b master &&	\
  cd riscv-isa-sim &&							\
  mkdir build &&							\
  cd build &&								\
  ../configure --prefix=$RISCV &&					\
  make -j $(nproc) 1>/dev/null &&					\
  make install DESTDIR=~/.local &&					\
  cd ../../ &&								\
  rm -rf riscv-isa-sim

# Toolchain - unfortunately RISCOF insists on riscv32-corev, and this generates riscv32-unknown.
RUN git clone https://github.com/riscv/riscv-code-size-reduction.git &&	\
  cd riscv-code-size-reduction && git submodule update --init -j $(nproc) --recursive &&	\
  cd toolchain && INSTALLPREFIX=~/.local ./gcc.sh &&			\
  cd ../.. && rm -rf riscv-code-size-reduction &&			\
  rename s/unknown/corev/ ~/.local/bin/*

# RISCOF
RUN pipx install git+https://github.com/riscv/riscof.git
