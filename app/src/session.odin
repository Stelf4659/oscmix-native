package oscmix_native

// Last session and mixer reset.
//
// The interface reports its settings on /refresh but never its send matrix.
// So the app keeps the mixer as it last saw it (the "last session", saved in
// the device file while the window runs) and writes it back after every
// connect: reported settings only where they differ, every send regardless
// (the device cannot confirm them). Sends the app never saw are written off,
// so after the first restore every fader is known. Covers what a snapshot
// covers; preamp gain, 48V, Hi-Z and reference level stay as the unit has them.

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"

Session_Phase :: enum {
	Off, // not tracking (probe)
	Waiting, // connected, refresh dump still arriving
	Done, // restored (or restore off); tracking changes
}

Session :: struct {
	track:    bool, // keep the last session (set by the UI)
	restore:  bool, // write it back after each connect
	phase:    Session_Phase,
	since:    time.Tick, // connect time
	checked:  time.Tick, // last capture
	restored: int, // writes queued by the last restore; -1 = nothing to report
}

// The refresh dump is complete once no new address appeared for this long.
SESSION_SETTLE_SECONDS :: 1.0
SESSION_SAVE_SECONDS :: 2.0
SESSION_NAME :: "last session"

// Reset: outputs go to 0 dB, these (Main Out, phones) to a safe level.
RESET_QUIET_DB :: -45.0

session_connected :: proc(app: ^App) {
	s := &app.session
	if !s.track do return
	s.phase = .Waiting
	s.since = time.tick_now()
}

session_poll :: proc(app: ^App, now: time.Tick) {
	s := &app.session
	switch s.phase {
	case .Off:
	case .Waiting:
		// device data (where the session lives) loads once the uid is known
		if app.st.mix_path == "" || !state_has(&app.st, "/device/outputs") do return
		if time.duration_seconds(time.tick_diff(s.since, now)) < SESSION_SETTLE_SECONDS do return
		if time.duration_seconds(time.tick_diff(app.st.last_insert, now)) < SESSION_SETTLE_SECONDS do return
		s.phase, s.checked = .Done, now
		if s.restore do s.restored = session_restore(app)
	case .Done:
		if len(app.queue) > 0 || time.duration_seconds(time.tick_diff(s.checked, now)) < SESSION_SAVE_SECONDS do return
		s.checked = now
		session_save(app)
	}
}

// Stores the current mixer as the last session if it changed. Not while a
// restore or recall is still being sent: closing then must not save a half-written mix.
session_save :: proc(app: ^App) {
	if app.session.phase != .Done || len(app.queue) > 0 do return
	values, _, _ := snapshot_capture(app, true)
	cur := &app.dev.session
	if cur.name != "" && cur.all_sends && len(cur.values) == len(values) {
		same := true
		for k, v in values {
			if cv, ok := cur.values[k]; !ok || cv != v {
				same = false
				break
			}
		}
		if same do return
	}
	snapshot_set(cur, SESSION_NAME, values, true)
	devdata_save(app)
}

// Queues the last session (or, with none saved, the current state, which
// turns unknown sends off). Returns the number of writes queued.
session_restore :: proc(app: ^App) -> int {
	app_queue_clear(app)
	values := app.dev.session.values
	if app.dev.session.name == "" do values, _, _ = snapshot_capture(app, true)
	for addr, v in values {
		if !strings.has_prefix(addr, "/mix/") do queue_if_needed(app, addr, v)
	}
	for_each_send(app, proc(app: ^App, fader, pan: string, user: rawptr) {
		values := (^map[string]f32)(user)
		if v, listed := values[fader]; listed {
			app_queue(app, fader, v)
			if pv, ok := values[pan]; ok do app_queue(app, pan, pv)
		} else {
			app_queue(app, fader, SEND_OFF_DB)
		}
	}, &values)
	return len(app.queue)
}

// Resets the mix: every send off except playback 1/2 → Main Out at 0 dB, all
// send pans centred; output volumes 0 dB, `quiet` outputs RESET_QUIET_DB.
// With `channels` also processing (EQ, low cut, dynamics, auto level off and
// at default values) and routing settings (mute, pan/balance, width, M/S,
// phase, FX send/return). Preamp, 48V, Hi-Z, reference level and the reverb
// and echo are left alone. Returns the number of writes queued.
mixer_reset :: proc(app: ^App, quiet: []int, channels: bool) -> int {
	app_queue_clear(app)
	Main :: struct {
		left, right: string, // send addresses that stay on; right only for mono playbacks
	}
	m: Main
	if main := main_out(app); main >= 0 {
		m.left = fmt.tprintf("/mix/pb/0/%d/fader", main)
		if !is_stereo(app, .Playback, 0) do m.right = fmt.tprintf("/mix/pb/1/%d/fader", main)
	}
	for_each_send(app, proc(app: ^App, fader, pan: string, user: rawptr) {
		m := (^Main)(user)
		if m.left != "" && fader == m.left {
			app_queue(app, fader, 0)
			app_queue(app, pan, m.right != "" ? -1 : 0)
		} else if m.right != "" && fader == m.right {
			app_queue(app, fader, 0)
			app_queue(app, pan, 1)
		} else {
			app_queue(app, fader, SEND_OFF_DB)
			app_queue(app, pan, 0)
		}
	}, &m)
	for ch in strip_channels(app, .Output) {
		queue_if_needed(app, fmt.tprintf("/output/%d/volume", ch), slice.contains(quiet, ch) ? RESET_QUIET_DB : 0)
	}
	if channels {
		for row in Row {
			for ch in strip_channels(app, row) do reset_channel(app, row, ch)
		}
	}
	return len(app.queue)
}

@(private = "file")
reset_channel :: proc(app: ^App, row: Row, ch: int) {
	set :: proc(app: ^App, row: Row, ch: int, p: string, v: f32) {
		if addr := fmt.tprintf("/%s/%d/%s", ROW_BUS[row], ch, p); state_has(&app.st, addr) do queue_if_needed(app, addr, v)
	}
	set(app, row, ch, "width", SL_WIDTH.def)
	if row == .Playback do return

	// routing
	set(app, row, ch, "mute", 0)
	sides := ch % 2 == 0 && is_stereo(app, row, ch) ? 2 : 1
	for side in 0 ..< sides do set(app, row, ch + side, "phase", 0)
	if row == .Input {
		set(app, row, ch, "msproc", 0)
		set(app, row, ch, "fxsend", SL_FX.def)
	} else {
		set(app, row, ch, "balpan", 0)
		set(app, row, ch, "fxreturn", SL_FX.def)
	}

	// processing: off, at the values untouched channels report (the unit's
	// factory defaults: low cut 20 Hz, shelving 80 Hz / bell 1 kHz / shelving 5 kHz, flat)
	for p in ([]string{"lowcut/enable", "eq/enable", "dynamics/enable", "autolevel/enable"}) do set(app, row, ch, p, 0)
	set(app, row, ch, "lowcut/freq", 20)
	band_freq := [3]f32{80, 1000, 5000}
	for n in 1 ..= 3 {
		set(app, row, ch, fmt.tprintf("eq/band%dfreq", n), band_freq[n - 1])
		set(app, row, ch, fmt.tprintf("eq/band%dgain", n), SL_EQ_GAIN.def)
		set(app, row, ch, fmt.tprintf("eq/band%dq", n), SL_Q.def)
	}
	for n in ([]int{1, 3}) {
		for t, i in band_types(app, "eq", n) {
			if strings.equal_fold(t, "Shelving") do set(app, row, ch, fmt.tprintf("eq/band%dtype", n), f32(i))
		}
	}
	set(app, row, ch, "dynamics/gain", SL_DYN_GAIN.def)
	set(app, row, ch, "dynamics/attack", SL_ATTACK.def)
	set(app, row, ch, "dynamics/release", SL_RELEASE.def)
	set(app, row, ch, "dynamics/compthres", SL_COMP_THRES.def)
	set(app, row, ch, "dynamics/compratio", SL_RATIO.def)
	set(app, row, ch, "dynamics/expthres", SL_EXP_THRES.def)
	set(app, row, ch, "dynamics/expratio", SL_RATIO.def)
	set(app, row, ch, "autolevel/maxgain", SL_AL_MAXGAIN.def)
	set(app, row, ch, "autolevel/headroom", SL_AL_HEADROOM.def)
	set(app, row, ch, "autolevel/risetime", 5)
}
