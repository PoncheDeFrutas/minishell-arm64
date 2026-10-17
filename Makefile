MODE ?= qemu
SOURCES := main.s src/io.s src/parser.s src/builtins.s src/external.s
OBJECTS := $(patsubst %.s,build/%.o,$(SOURCES))
BIN := build/minishell

ifeq ($(MODE),native)
AS = as
LD = ld
RUN = ./$(BIN)
else ifeq ($(MODE),qemu)
AS = aarch64-linux-gnu-as
LD = aarch64-linux-gnu-ld
RUN = qemu-aarch64 $(BIN)
else
$(error MODE debe ser qemu o native)
endif

.PHONY: all run test debug-server clean
all: $(BIN)

$(BIN): $(OBJECTS)
	$(LD) -o $@ $(OBJECTS)

build/%.o: %.s
	@mkdir -p $(dir $@)
	$(AS) -g -o $@ $<

run: all
	$(RUN)

test: all
	./tests/smoke.sh $(MODE)

debug-server: all
ifeq ($(MODE),qemu)
	qemu-aarch64 -g 1234 $(BIN)
else
	@echo 'debug-server requiere MODE=qemu; en ARM64 use gdb ./build/minishell' >&2
	@exit 2
endif

clean:
	rm -rf build
