package oscmix_native

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:time"

App :: struct {
	ctx:        runtime.Context, // for engine callbacks
	midi:       Midi,
	st:         State,
	connected:  bool,
	error:      string, // owned; last connection error
	device:     string, // owned; e.g. "Fireface UFX III (SERIAL) Port 4"
	osc_buf:    [dynamic]u8,
	last_tick:  time.Tick,
	last_save:  time.Tick,
}

@(private = "file")
engine_midi_out :: proc "c" (user: rawptr, buf: [^]u8, len: u32) {
	app := (^App)(user)
	context = app.ctx
	midi_send(&app.midi, buf[:len])
}

@(private = "file")
engine_osc_out :: proc "c" (user: rawptr, buf: [^]u8, len: u32) {
	app := (^App)(user)
	context = app.ctx
	osc_decode(buf[:len], proc(msg: ^Osc_Msg, user: rawptr) {
		state_apply(&(^App)(user).st, msg)
	}, app)
}

@(private = "file")
on_sysex :: proc(msg: []u8) {
	engine_sysex(raw_data(msg), u32(len(msg)))
}

// Connects to the interface (port "CLIENT:PORT" or auto-detect) and starts the engine.
// The engine can only be instantiated once per process.
app_connect :: proc(app: ^App, port: string = "") -> bool {
	app.ctx = context
	if err := midi_open(&app.midi, port); err != "" {
		app.error = err
		midi_close(&app.midi)
		return false
	}
	name := strings.clone_to_cstring(app.midi.port_name, context.temp_allocator)
	if engine_open(name, engine_midi_out, engine_osc_out, app) != 0 {
		app.error = fmt.aprintf("the oscmix engine does not support \"%s\"", app.midi.port_name)
		midi_close(&app.midi)
		return false
	}
	app.device = strings.clone(app.midi.port_name)
	app.connected = true
	app.last_tick = time.tick_now()
	app.last_save = app.last_tick
	app_send(app, "/device/info")
	app_send(app, "/refresh")
	return true
}

app_shutdown :: proc(app: ^App) {
	if app.connected {
		state_save_mix(&app.st)
		engine_close()
		midi_close(&app.midi)
	}
	state_destroy(&app.st)
	delete(app.osc_buf)
	delete(app.error)
	delete(app.device)
}

// Sends one OSC message (float args) into the engine.
app_send :: proc(app: ^App, addr: string, args: ..f32) {
	if !app.connected do return
	osc_encode(&app.osc_buf, addr, ..args)
	engine_osc(raw_data(app.osc_buf), u32(len(app.osc_buf)))
	// The engine does not always echo writes; mirror them locally so the UI
	// (and the saved mix) reflect what was sent.
	msg := Osc_Msg{addr = addr}
	for a in args[:min(len(args), MAX_OSC_ARGS)] {
		msg.args[msg.argc] = a
		msg.argc += 1
	}
	if msg.argc > 0 do state_apply(&app.st, &msg)
}

// Pumps MIDI input and the engine timer. Call often (every frame).
app_poll :: proc(app: ^App, levels := true) {
	if !app.connected do return
	midi_poll(&app.midi, on_sysex)
	if time.duration_seconds(time.tick_since(app.last_tick)) >= ENGINE_TICK_SECONDS {
		app.last_tick = time.tick_now()
		engine_timer(levels ? 1 : 0)
	}
	// Saved mix is per device (serial in the uid), known once the engine reports it.
	if app.st.mix_path == "" {
		if uid := state_str(&app.st, "/device/uid"); uid != "" {
			state_set_mix_path(&app.st, uid)
			state_load_mix(&app.st)
		}
	}
	if app.st.mix_dirty && time.duration_seconds(time.tick_since(app.last_save)) >= 2 {
		app.last_save = time.tick_now()
		state_save_mix(&app.st)
	}
}
