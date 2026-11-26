# Host build of the Linux userland runner (tests/linux/*.sh use it).
CC     ?= cc
CFLAGS ?= -O2 -g -Wall -Wextra -std=c11
CORE   := core/elf.c core/scan.c core/vm.c core/cpu.c core/simd.c core/linux.c core/load.c core/dl.c core/bionic.c core/proc.c core/binder.c core/sf.c core/af.c core/gralloc.c core/snap.c core/hle.c core/lxfast.c core/tty.c

build/lxrun: tools/lxrun.c $(CORE) core/*.h | build
	$(CC) $(CFLAGS) -o $@ tools/lxrun.c $(CORE) -lm -lpthread

build:
	mkdir -p build

clean:
	rm -rf build

.PHONY: clean
