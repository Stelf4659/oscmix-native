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
	port:       string, // owned; requested "CLIENT:PORT", "" = auto-detect
	error:      string, // owned; last connection error
	device:     string, // owned; e.g. "Fireface UFX III (SERIAL) Port 4"
	osc_buf:    [dynamic]u8,
	last_tick:  time.Tick,
	last_save:  time.Tick,
	last_rx:    time.Tick, // last SysEx from the interface
	last_check: time.Tick, // last port check / reconnect attempt
}

// The interface streams meter replies continuously while connected; this
// long without any input means it is gone (unplugged, powered off, mode change).
RX_TIMEOUT_SECONDS :: 5.0
WATCH_SECONDS :: 2.0

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
app_connect :: proc(app: ^App, port: string = "") -> bool {
	app.ctx = context
	if port != app.port {
		delete(app.port)
		app.port = strings.clone(port)
	}
	delete(app.error)
	app.error = ""
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
	delete(app.device)
	app.device = strings.clone(app.midi.port_name)
	app.connected = true
	app.last_tick = time.tick_now()
	app.last_save, app.last_rx, app.last_check = app.last_tick, app.last_tick, app.last_tick
	app_send(app, "/device/info")
	app_send(app, "/refresh")
	return true
}

// Drops the connection (engine + MIDI) but keeps the parameter mirror, so the
// window keeps showing the last known state until the interface is back.
app_disconnect :: proc(app: ^App, reason: string) {
	if !app.connected do return
	state_save_mix(&app.st)
	engine_close()
	midi_close(&app.midi)
	app.connected = false
	delete(app.error)
	app.error = strings.clone(reason)
	app.last_check = time.tick_now()
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
	delete(app.port)
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

// Pumps MIDI input and the engine timer, and watches the connection: drops it
// when the port vanishes or goes silent, and reconnects (with `reconnect`)
// every WATCH_SECONDS while disconnected. Call often (every frame).
app_poll :: proc(app: ^App, levels := true, reconnect := true) {
	now := time.tick_now()
	if !app.connected {
		if reconnect && time.duration_seconds(time.tick_diff(app.last_check, now)) >= WATCH_SECONDS {
			app.last_check = now
			app_connect(app, app.port)
		}
		return
	}
	if midi_poll(&app.midi, on_sysex) > 0 do app.last_rx = now
	if time.duration_seconds(time.tick_diff(app.last_check, now)) >= WATCH_SECONDS {
		app.last_check = now
		if !midi_port_present(&app.midi) {
			app_disconnect(app, "interface disconnected, reconnecting…")
			return
		}
	}
	if time.duration_seconds(time.tick_diff(app.last_rx, now)) >= RX_TIMEOUT_SECONDS {
		app_disconnect(app, "interface not responding, reconnecting…")
		return
	}
	if time.duration_seconds(time.tick_diff(app.last_tick, now)) >= ENGINE_TICK_SECONDS {
		app.last_tick = now
		engine_timer(levels ? 1 : 0)
	}
	// Saved mix is per device (serial in the uid), known once the engine reports it.
	if app.st.mix_path == "" {
		if uid := state_str(&app.st, "/device/uid"); uid != "" {
			state_set_mix_path(&app.st, uid)
			state_load_mix(&app.st)
		}
	}
	if app.st.mix_dirty && time.duration_seconds(time.tick_diff(app.last_save, now)) >= 2 {
		app.last_save = now
		state_save_mix(&app.st)
	}
}
