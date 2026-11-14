package oscmix_native

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
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
	queue:      [dynamic]Queued_Write, // paced bulk writes
	queue_pos:  int, // next to send
	dev:        Device_Data, // local per-device data (names, groups, snapshots)
	session:    Session, // last-session tracking and restore (session.odin)
	// The window runs app_poll on a worker thread (app_worker_start): a hidden
	// window blocks in EndDrawing for up to ~1 s per frame, which slowed the
	// refresh dump and the restore to ~45 s. `lock` guards everything above.
	lock:       sync.Mutex,
	worker:     ^thread.Thread,
	stop:       bool, // atomic
}

Queued_Write :: struct {
	addr: string, // owned
	v:    f32,
}

// The interface silently drops writes sent in a burst (3760 at once: only
// ~5% applied); 50 per 2 ms with MIDI serviced in between all landed
// (tested). 12 per poll at one poll per 2 ms (~6000/s) stays well below that.
QUEUE_PER_POLL :: 12
POLL_INTERVAL :: 2 * time.Millisecond

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
on_sysex :: proc(msg: []u8, user: rawptr) {
	session_sysex((^App)(user), msg)
	engine_sysex(raw_data(msg), u32(len(msg)))
}

// Connects to the interface (port "CLIENT:PORT", or the first auto-detected
// RME control port the engine supports) and starts the engine.
app_connect :: proc(app: ^App, port: string = "") -> bool {
	app.ctx = context
	if port != app.port {
		delete(app.port)
		app.port = strings.clone(port)
	}
	delete(app.error)
	app.error = ""
	targets := port != "" ? []string{port} : midi_rme_candidates()[:]
	if len(targets) == 0 {
		app.error = strings.clone("no RME interface found on the ALSA sequencer (is it connected and in CC mode?)")
		return false
	}
	opened := false
	for target in targets {
		delete(app.error)
		app.error = ""
		if err := midi_open(&app.midi, target); err != "" {
			app.error = err
			midi_close(&app.midi)
			continue
		}
		name := strings.clone_to_cstring(app.midi.port_name, context.temp_allocator)
		if engine_open(name, engine_midi_out, engine_osc_out, app) != 0 {
			app.error = fmt.aprintf("the oscmix engine does not support \"%s\"", app.midi.port_name)
			midi_close(&app.midi)
			continue
		}
		opened = true
		break
	}
	if !opened do return false
	if app.device != "" && app.device != app.midi.port_name {
		// Another interface (the port name carries the serial): drop the old
		// one's mirror and local data, so neither its files nor its session
		// get applied to this one; both reload once the new uid is reported.
		state_destroy(&app.st)
		app.st = {}
		devdata_destroy(&app.dev)
		app.dev = {}
	}
	delete(app.device)
	app.device = strings.clone(app.midi.port_name)
	app.connected = true
	app.last_tick = time.tick_now()
	app.last_save, app.last_rx, app.last_check = app.last_tick, app.last_tick, app.last_tick
	// input sends are re-read from the refresh dump (it lists those that are on)
	state_forget_prefix(&app.st, "/mix/in/")
	session_connected(app)
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
	app_queue_clear(app) // unsent writes are void; the state is re-read on reconnect
	delete(app.error)
	app.error = strings.clone(reason)
	app.last_check = time.tick_now()
}

app_shutdown :: proc(app: ^App) {
	if app.connected {
		session_save(app)
		state_save_mix(&app.st)
		engine_close()
		midi_close(&app.midi)
	}
	state_destroy(&app.st)
	app_queue_clear(app)
	delete(app.queue)
	devdata_destroy(&app.dev)
	delete(app.osc_buf)
	delete(app.error)
	delete(app.device)
	delete(app.port)
}

// Sends one OSC message (float args) into the engine.
app_send :: proc(app: ^App, addr: string, args: ..f32) {
	app.ctx = context // engine callbacks run on the calling thread
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

// Queues a write for paced sending by app_poll (bulk changes).
app_queue :: proc(app: ^App, addr: string, v: f32) {
	append(&app.queue, Queued_Write{strings.clone(addr), v})
}

app_queue_clear :: proc(app: ^App) {
	for w in app.queue do delete(w.addr)
	clear(&app.queue)
	app.queue_pos = 0
}

// (sent, total) of the pending bulk writes; total 0 when idle.
app_queue_progress :: proc(app: ^App) -> (sent, total: int) {
	return app.queue_pos, len(app.queue)
}

// Pumps MIDI input and the engine timer, and watches the connection: drops it
// when the port vanishes or goes silent, and reconnects (with `reconnect`)
// every WATCH_SECONDS while disconnected. Call every POLL_INTERVAL.
app_poll :: proc(app: ^App, levels := true, reconnect := true) {
	app.ctx = context // engine callbacks run on the calling thread
	now := time.tick_now()
	if !app.connected {
		if reconnect && time.duration_seconds(time.tick_diff(app.last_check, now)) >= WATCH_SECONDS {
			app.last_check = now
			app_connect(app, app.port)
		}
		return
	}
	if midi_poll(&app.midi, on_sysex, app) > 0 do app.last_rx = now
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
	// Saved mix and local device data are per device (serial in the uid),
	// known once the engine reports it.
	if app.st.mix_path == "" {
		if uid := state_str(&app.st, "/device/uid"); uid != "" {
			state_set_mix_path(&app.st, uid)
			state_load_mix(&app.st)
			devdata_load(app, uid)
		}
	}
	// paced bulk writes (snapshot recall): bursts are dropped by the interface
	n := 0
	for app.queue_pos < len(app.queue) && n < QUEUE_PER_POLL {
		w := app.queue[app.queue_pos]
		app_send(app, w.addr, w.v)
		app.queue_pos += 1
		n += 1
	}
	if app.queue_pos > 0 && app.queue_pos == len(app.queue) do app_queue_clear(app)
	session_poll(app, now)
	if app.st.mix_dirty && time.duration_seconds(time.tick_diff(app.last_save, now)) >= 2 {
		app.last_save = now
		state_save_mix(&app.st)
	}
}

@(private = "file")
app_worker :: proc(t: ^thread.Thread) {
	app := (^App)(t.data)
	for !sync.atomic_load(&app.stop) {
		sync.mutex_lock(&app.lock)
		app_poll(app)
		sync.mutex_unlock(&app.lock)
		free_all(context.temp_allocator)
		time.sleep(POLL_INTERVAL)
	}
}

// Polls the interface every POLL_INTERVAL on a worker thread until
// app_worker_stop. Everything else must hold app.lock while it uses the App.
app_worker_start :: proc(app: ^App) {
	sync.atomic_store(&app.stop, false)
	app.worker = thread.create(app_worker)
	app.worker.data = app
	thread.start(app.worker)
}

app_worker_stop :: proc(app: ^App) {
	if app.worker == nil do return
	sync.atomic_store(&app.stop, true)
	thread.join(app.worker)
	thread.destroy(app.worker)
	app.worker = nil
}
