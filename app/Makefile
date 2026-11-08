# oscmix-native: Odin UI + huddx01's oscmix.wasm engine (via wasm2c)
#   make            build ./oscmix-native
#   make engine     only the C engine library
#   make wasm WASM=path/to/new/oscmix.wasm   swap in a newer engine release

WABT_RT  = /usr/share/wabt/wasm2c
CC      ?= cc
CFLAGS  ?= -O2
# Explicit bounds checks: no SIGSEGV handler installed behind raylib's back.
ENGINE_CFLAGS = $(CFLAGS) -fPIC -I$(WABT_RT) -Iengine -DWASM_RT_MEMCHECK_BOUNDS_CHECK=1 \
	-Wno-unused-function -Wno-unused-parameter
ODINFLAGS ?= -o:speed

ENGINE_OBJS = engine/oscmix_w2c.o engine/engine.o engine/wasm-rt-impl.o engine/wasm-rt-mem-impl.o \
	engine/wasm-rt-exceptions-impl.o

all: oscmix-native

engine: engine/libengine.a

engine/oscmix_w2c.c engine/oscmix_w2c.h: engine/oscmix.wasm
	wasm2c $< -n oscmix -o engine/oscmix_w2c.c

engine/oscmix_w2c.o: engine/oscmix_w2c.c engine/oscmix_w2c.h
	$(CC) $(ENGINE_CFLAGS) -c -o $@ $<
engine/engine.o: engine/engine.c engine/engine.h engine/oscmix_w2c.h
	$(CC) $(ENGINE_CFLAGS) -Wall -c -o $@ $<
engine/wasm-rt-impl.o: $(WABT_RT)/wasm-rt-impl.c
	$(CC) $(ENGINE_CFLAGS) -c -o $@ $<
engine/wasm-rt-mem-impl.o: $(WABT_RT)/wasm-rt-mem-impl.c
	$(CC) $(ENGINE_CFLAGS) -c -o $@ $<
engine/wasm-rt-exceptions-impl.o: $(WABT_RT)/wasm-rt-exceptions-impl.c
	$(CC) $(ENGINE_CFLAGS) -c -o $@ $<

engine/libengine.a: $(ENGINE_OBJS)
	rm -f $@ && ar rcs $@ $^

# raylib 6.0 to match the Odin bindings in raylib/ (official release, checksum-pinned)
RAYLIB_DIR = third_party/raylib-6.0_linux_amd64
RAYLIB_URL = https://github.com/raysan5/raylib/releases/download/6.0/raylib-6.0_linux_amd64.tar.gz
RAYLIB_SHA = b64ba618a19e7da9e9c0e09bb398ecfd477a77d2d7231901bafc8739d27c08d2

$(RAYLIB_DIR)/lib/libraylib.a:
	mkdir -p third_party
	curl -sSL -o third_party/raylib.tar.gz $(RAYLIB_URL)
	echo "$(RAYLIB_SHA)  third_party/raylib.tar.gz" | sha256sum -c
	tar -C third_party -xzf third_party/raylib.tar.gz && rm third_party/raylib.tar.gz

oscmix-native: engine/libengine.a $(RAYLIB_DIR)/lib/libraylib.a $(wildcard src/*.odin) raylib/raylib.odin
	odin build src -out:$@ $(ODINFLAGS)

wasm:
	cp $(WASM) engine/oscmix.wasm && $(MAKE) all

PREFIX ?= $(HOME)/.local
install: oscmix-native
	install -Dm755 oscmix-native $(PREFIX)/bin/oscmix-native
	mkdir -p $(PREFIX)/share/applications
	printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=oscmix' \
		'Comment=RME TotalMix-style mixer (Fireface UFX III in CC mode)' \
		'Exec=$(PREFIX)/bin/oscmix-native' 'Icon=audio-card' \
		'Categories=AudioVideo;Audio;Mixer;' 'Terminal=false' \
		> $(PREFIX)/share/applications/oscmix-native.desktop

clean:
	rm -f engine/*.o engine/libengine.a oscmix-native

.PHONY: all engine wasm install clean
