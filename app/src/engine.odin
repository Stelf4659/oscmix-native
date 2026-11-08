package oscmix_native

// Bindings to engine/engine.h: huddx01's oscmix.wasm converted to C by wasm2c.

foreign import engine_lib "../engine/libengine.a"
foreign import libm "system:m"

Engine_Out_Fn :: #type proc "c" (user: rawptr, buf: [^]u8, len: u32)

@(default_calling_convention = "c")
foreign engine_lib {
	engine_open :: proc(port: cstring, midi: Engine_Out_Fn, osc: Engine_Out_Fn, user: rawptr) -> i32 ---
	engine_close :: proc() ---
	engine_sysex :: proc(buf: [^]u8, len: u32) ---
	engine_osc :: proc(buf: [^]u8, len: u32) -> i32 ---
	engine_timer :: proc(levels: i32) ---
}

// The engine's generated C needs libm; keep the import referenced.
@(default_calling_convention = "c")
foreign libm {
	@(link_name = "fabsf") _libm_fabsf :: proc(x: f32) -> f32 ---
}

// Engine timer period (OscMix Web uses the same 33 ms tick).
ENGINE_TICK_SECONDS :: 0.033
