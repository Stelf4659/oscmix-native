package oscmix_native

// TotalMix-style window: inputs and playbacks send into the selected submix
// (an output); outputs have their own volume. Immediate-mode, raylib.

import "core:fmt"
import "core:math"
import "core:strings"
import rl "../raylib"

// --- look ---------------------------------------------------------------

COL_BG :: rl.Color{24, 26, 30, 255}
COL_ROW :: rl.Color{32, 35, 41, 255}
COL_STRIP :: rl.Color{40, 44, 52, 255}
COL_STRIP_SEL :: rl.Color{48, 62, 82, 255}
COL_TEXT :: rl.Color{220, 223, 228, 255}
COL_DIM :: rl.Color{130, 136, 148, 255}
COL_ACCENT :: rl.Color{86, 156, 255, 255}
COL_TRACK :: rl.Color{18, 20, 23, 255}
COL_MUTE :: rl.Color{220, 70, 60, 255}
COL_GREEN :: rl.Color{70, 200, 100, 255}
COL_YELLOW :: rl.Color{230, 200, 60, 255}
COL_RED :: rl.Color{235, 70, 60, 255}
COL_BUTTON :: rl.Color{56, 61, 72, 255}
COL_BUTTON_HOT :: rl.Color{70, 77, 90, 255}

STRIP_W :: 64
HEADER_W :: 96
TOPBAR_H :: 44
SCROLLBAR_H :: 10

// Send/volume levels in dB. Sends below FADER_MIN_DB are "off" (-300 for the engine).
FADER_MAX_DB :: 6.0
FADER_MIN_DB :: -65.0
SEND_OFF_DB :: -300.0

// --- widget state -------------------------------------------------------

Row :: enum {
	Input,
	Playback,
	Output,
}
ROW_TITLE := [Row]cstring {
	.Input    = "HARDWARE\nINPUTS",
	.Playback = "SOFTWARE\nPLAYBACK",
	.Output   = "HARDWARE\nOUTPUTS",
}
ROW_BUS := [Row]string {
	.Input    = "input",
	.Playback = "playback",
	.Output   = "output",
}
ROW_LEVEL := [Row]string {
	.Input    = "in",
	.Playback = "pb",
	.Output   = "out",
}

Widget :: enum u8 {
	None,
	Fader,
	Pan,
	Scroll,
}

Confirm_Action :: enum {
	None,
	Jack_Restart,
	Interface_Mode,
}

UI :: struct {
	app:          ^App,
	port:         string,
	font:         rl.Font,
	// interaction: only widgets on the topmost open layer react to input
	layer:        Layer, // layer currently being drawn
	active:       u64,
	drag_origin:  rl.Vector2,
	drag_value:   f32,
	last_click:   u64,
	last_click_t: f64,
	scroll:       [Row]f32,
	submix:       int,
	// settings
	show_settings: bool,
	jack_cfg:      Jack_Settings, // pending edit
	jack_saved:    Jack_Settings, // as in jackd.env
	jack_now:      Jack_Live,
	audio_mode:    string, // owned
	iface_pending: int,
	confirm:       Confirm_Action,
	status:        string, // owned
	status_until:  f64,
}

widget_id :: proc(w: Widget, row: Row, idx: int) -> u64 {
	return u64(w) << 40 | u64(row) << 32 | u64(idx)
}

// --- helpers -------------------------------------------------------------

set_status :: proc(ui: ^UI, msg: string, secs := 6.0) {
	delete(ui.status)
	ui.status = strings.clone(msg)
	ui.status_until = rl.GetTime() + secs
}

text :: proc(ui: ^UI, s: string, x, y: f32, size: f32 = 14, color := COL_TEXT) {
	rl.DrawTextEx(ui.font, strings.clone_to_cstring(s, context.temp_allocator), {x, y}, size, 0, color)
}

text_width :: proc(ui: ^UI, s: string, size: f32 = 14) -> f32 {
	return rl.MeasureTextEx(ui.font, strings.clone_to_cstring(s, context.temp_allocator), size, 0).x
}

text_centered :: proc(ui: ^UI, s: string, r: rl.Rectangle, size: f32 = 13, color := COL_TEXT) {
	s := s
	for len(s) > 1 && text_width(ui, s, size) > r.width - 4 do s = s[:len(s) - 1]
	w := text_width(ui, s, size)
	text(ui, s, r.x + (r.width - w) / 2, r.y + (r.height - size) / 2, size, color)
}

hovered :: proc(r: rl.Rectangle) -> bool {return rl.CheckCollisionPointRec(rl.GetMousePosition(), r)}

// True on the second press within 350 ms on the same widget.
double_click :: proc(ui: ^UI, id: u64) -> bool {
	now := rl.GetTime()
	dbl := ui.last_click == id && now - ui.last_click_t < 0.35
	ui.last_click, ui.last_click_t = id, now
	if dbl do ui.last_click = 0
	return dbl
}

Layer :: enum {
	Mixer,
	Settings,
	Confirm,
}

top_layer :: proc(ui: ^UI) -> Layer {
	if ui.confirm != .None do return .Confirm
	if ui.show_settings do return .Settings
	return .Mixer
}

// Mouse is over r and r belongs to the topmost layer.
interactive :: proc(ui: ^UI, r: rl.Rectangle) -> bool {
	return ui.layer == top_layer(ui) && hovered(r)
}

button :: proc(ui: ^UI, r: rl.Rectangle, label: string, on := false, on_color := COL_ACCENT, size: f32 = 13) -> bool {
	hot := interactive(ui, r)
	col := on ? on_color : (hot ? COL_BUTTON_HOT : COL_BUTTON)
	rl.DrawRectangleRounded(r, 0.25, 4, col)
	text_centered(ui, label, r, size, on ? rl.WHITE : COL_TEXT)
	return hot && rl.IsMouseButtonPressed(.LEFT)
}

// Fader curve: gain = 2·p³ (top = +6 dB, 0 dB at p≈0.794), like a console fader.
db_to_pos :: proc(db: f32) -> f32 {
	if db <= FADER_MIN_DB do return 0
	return math.cbrt(math.pow(10, min(db, FADER_MAX_DB) / 20) / 2)
}
pos_to_db :: proc(p: f32, off: f32) -> f32 {
	if p <= db_to_pos(FADER_MIN_DB + 0.01) do return off
	return clamp(20 * math.log10(2 * p * p * p), FADER_MIN_DB, FADER_MAX_DB)
}

fmt_db :: proc(db: f32) -> string {
	if db <= FADER_MIN_DB do return "-inf"
	return fmt.tprintf("%+.1f", db)
}

// Vertical fader. Drag (Shift = fine), wheel ±0.5 dB (Shift ±0.1),
// double-click = 0 dB, right-click = off/minimum.
fader :: proc(ui: ^UI, id: u64, r: rl.Rectangle, db: f32, off: f32, known := true) -> (out: f32, changed: bool) {
	out = db
	mouse := rl.GetMousePosition()
	travel := r.height - 16
	if interactive(ui, r) {
		if rl.IsMouseButtonPressed(.LEFT) {
			if double_click(ui, id) {
				out = 0
			} else {
				ui.active, ui.drag_origin, ui.drag_value = id, mouse, db_to_pos(db)
			}
		} else if rl.IsMouseButtonPressed(.RIGHT) {
			out = off
		} else if wheel := rl.GetMouseWheelMove(); wheel != 0 && !rl.IsKeyDown(.LEFT_CONTROL) {
			step: f32 = rl.IsKeyDown(.LEFT_SHIFT) ? 0.1 : 0.5
			base := db <= FADER_MIN_DB ? FADER_MIN_DB : db
			out = clamp(base + wheel * step, FADER_MIN_DB, FADER_MAX_DB)
			if out <= FADER_MIN_DB do out = off
		}
	}
	if ui.active == id {
		if rl.IsMouseButtonDown(.LEFT) {
			scale: f32 = rl.IsKeyDown(.LEFT_SHIFT) ? 0.15 : 1
			p := clamp(ui.drag_value - (mouse.y - ui.drag_origin.y) / travel * scale, 0, 1)
			out = pos_to_db(p, off)
		} else {
			ui.active = 0
		}
	}
	changed = out != db

	// draw: track, 0 dB mark, thumb
	cx := r.x + r.width / 2
	rl.DrawRectangleRec({cx - 2, r.y + 8, 4, travel}, COL_TRACK)
	zero_y := r.y + 8 + travel * (1 - db_to_pos(0))
	rl.DrawLineEx({cx - 9, zero_y}, {cx + 9, zero_y}, 1, COL_DIM)
	ty := r.y + 8 + travel * (1 - db_to_pos(out))
	thumb := rl.Rectangle{cx - 11, ty - 8, 22, 16}
	thumb_col := known ? (ui.active == id ? COL_ACCENT : rl.Color{180, 186, 196, 255}) : rl.Color{90, 95, 105, 255}
	rl.DrawRectangleRounded(thumb, 0.3, 4, thumb_col)
	rl.DrawLineEx({thumb.x + 3, ty}, {thumb.x + thumb.width - 3, ty}, 2, COL_TRACK)
	return
}

// Horizontal pan/balance -1..1; drag; double-click = centre.
pan_slider :: proc(ui: ^UI, id: u64, r: rl.Rectangle, v: f32) -> (out: f32, changed: bool) {
	out = v
	mouse := rl.GetMousePosition()
	if interactive(ui, r) && rl.IsMouseButtonPressed(.LEFT) {
		if double_click(ui, id) {
			out = 0
		} else {
			ui.active, ui.drag_origin, ui.drag_value = id, mouse, v
		}
	}
	if ui.active == id {
		if rl.IsMouseButtonDown(.LEFT) {
			scale: f32 = rl.IsKeyDown(.LEFT_SHIFT) ? 0.2 : 1
			out = clamp(ui.drag_value + (mouse.x - ui.drag_origin.x) / (r.width / 2) * scale, -1, 1)
			out = math.round(out * 100) / 100
		} else {
			ui.active = 0
		}
	}
	changed = out != v
	rl.DrawRectangleRounded(r, 0.4, 4, COL_TRACK)
	cx := r.x + r.width / 2
	px := cx + out * (r.width / 2 - 2)
	if out != 0 do rl.DrawRectangleRec({min(cx, px), r.y + 2, abs(px - cx), r.height - 4}, COL_ACCENT)
	label := out == 0 ? "C" : fmt.tprintf("%s%d", out < 0 ? "L" : "R", int(abs(out) * 100 + 0.5))
	text_centered(ui, label, r, 10, COL_TEXT)
	return
}

// Peak (line) and RMS (bar) meter, -60..0 dBFS.
meter :: proc(r: rl.Rectangle, peak, rms: f32) {
	rl.DrawRectangleRec(r, COL_TRACK)
	h :: proc(db: f32, r: rl.Rectangle) -> f32 {return clamp((db + 60) / 60, 0, 1) * r.height}
	col := rms > -3 ? COL_RED : (rms > -18 ? COL_YELLOW : COL_GREEN)
	rh := h(rms, r)
	rl.DrawRectangleRec({r.x, r.y + r.height - rh, r.width, rh}, col)
	py := r.y + r.height - h(peak, r)
	if peak > -60 do rl.DrawRectangleRec({r.x, py, r.width, 2}, peak > -0.5 ? COL_RED : COL_TEXT)
}

// --- mixer rows ------------------------------------------------------------

channel_count :: proc(app: ^App, row: Row) -> int {
	key := row == .Output ? "/device/outputs" : "/device/inputs"
	return int(state_get(&app.st, key, 0))
}

is_stereo :: proc(app: ^App, row: Row, i: int) -> bool {
	return state_get(&app.st, fmt.tprintf("/%s/%d/stereo", ROW_BUS[row], i)) != 0
}

channel_name :: proc(app: ^App, row: Row, i: int) -> string {
	n := state_str(&app.st, fmt.tprintf("/%s/%d/name", ROW_BUS[row], i))
	if n == "" && row == .Playback {
		// playbacks are named after the output they belong to
		n = state_str(&app.st, fmt.tprintf("/output/%d/name", i))
	}
	return n != "" ? n : fmt.tprintf("%d", i + 1)
}

// Visible strips: mono channels, and the left channel of stereo pairs.
strip_channels :: proc(app: ^App, row: Row) -> [dynamic]int {
	out := make([dynamic]int, context.temp_allocator)
	n := channel_count(app, row)
	for i := 0; i < n; i += 1 {
		append(&out, i)
		if i % 2 == 0 && is_stereo(app, row, i) do i += 1
	}
	return out
}

level_of :: proc(app: ^App, row: Row, i: int) -> (peak, rms: f32) {
	if e, ok := app.st.vals[fmt.tprintf("/level/%s/%d", ROW_LEVEL[row], i)]; ok && e.n >= 2 {
		return e.f[0], e.f[1]
	}
	return -150, -150
}

draw_row :: proc(ui: ^UI, row: Row, area: rl.Rectangle) {
	app := ui.app
	rl.DrawRectangleRec(area, COL_ROW)
	head := rl.Rectangle{area.x, area.y, HEADER_W, area.height}
	rl.DrawRectangleRec(head, COL_STRIP)
	rl.DrawTextEx(ui.font, ROW_TITLE[row], {head.x + 10, head.y + 10}, 13, 0, COL_DIM)
	if row != .Output {
		text(ui, "send to", head.x + 10, head.y + 52, 12, COL_DIM)
		text(ui, strip_name(app, .Output, ui.submix), head.x + 10, head.y + 68, 15, COL_ACCENT)
	} else {
		text(ui, "click a name to\nselect submix", head.x + 10, head.y + 52, 11, COL_DIM)
	}

	chans := strip_channels(app, row)
	view := rl.Rectangle{area.x + HEADER_W, area.y, area.width - HEADER_W, area.height - SCROLLBAR_H}
	content_w := f32(len(chans)) * STRIP_W
	max_scroll := max(0, content_w - view.width)

	// horizontal scrolling: horizontal wheel, Ctrl+wheel, or the scrollbar
	if interactive(ui, area) {
		wv := rl.GetMouseWheelMoveV()
		dx := rl.IsKeyDown(.LEFT_CONTROL) ? wv.y : wv.x
		ui.scroll[row] -= dx * STRIP_W * 2
	}
	bar := rl.Rectangle{view.x, view.y + view.height, view.width, SCROLLBAR_H}
	if max_scroll > 0 {
		thumb_w := max(40, view.width * view.width / content_w)
		sid := widget_id(.Scroll, row, 0)
		if interactive(ui, bar) && rl.IsMouseButtonPressed(.LEFT) {
			ui.active, ui.drag_origin, ui.drag_value = sid, rl.GetMousePosition(), ui.scroll[row]
		}
		if ui.active == sid {
			if rl.IsMouseButtonDown(.LEFT) {
				ui.scroll[row] = ui.drag_value + (rl.GetMousePosition().x - ui.drag_origin.x) * max_scroll / (view.width - thumb_w)
			} else {
				ui.active = 0
			}
		}
		ui.scroll[row] = clamp(ui.scroll[row], 0, max_scroll)
		tx := bar.x + (view.width - thumb_w) * ui.scroll[row] / max_scroll
		rl.DrawRectangleRec(bar, COL_TRACK)
		rl.DrawRectangleRounded({tx, bar.y + 2, thumb_w, bar.height - 4}, 0.5, 4, COL_BUTTON_HOT)
	} else {
		ui.scroll[row] = 0
	}

	rl.BeginScissorMode(i32(view.x), i32(view.y), i32(view.width), i32(view.height))
	defer rl.EndScissorMode()
	for ch, k in chans {
		x := view.x + f32(k) * STRIP_W - ui.scroll[row]
		if x + STRIP_W < view.x || x > view.x + view.width do continue
		draw_strip(ui, row, ch, {x + 1, view.y + 2, STRIP_W - 2, view.height - 4})
	}
}

// "AN 1/AN 2" for stereo pairs
strip_name :: proc(app: ^App, row: Row, ch: int) -> string {
	name := channel_name(app, row, ch)
	if ch % 2 == 0 && is_stereo(app, row, ch) do name = fmt.tprintf("%s/%s", name, channel_name(app, row, ch + 1))
	return name
}

draw_strip :: proc(ui: ^UI, row: Row, ch: int, r: rl.Rectangle) {
	app := ui.app
	stereo := ch % 2 == 0 && is_stereo(app, row, ch)
	selected := row == .Output && (ch == ui.submix)
	rl.DrawRectangleRounded(r, 0.08, 4, selected ? COL_STRIP_SEL : COL_STRIP)

	// name (outputs: click selects the submix)
	name_r := rl.Rectangle{r.x, r.y + 2, r.width, 18}
	name := strip_name(app, row, ch)
	text_centered(ui, name, name_r, 12, selected ? rl.WHITE : COL_TEXT)
	if row == .Output && interactive(ui, name_r) && rl.IsMouseButtonPressed(.LEFT) {
		ui.submix = ch
	}
	if stereo do text_centered(ui, "ST", {r.x, r.y + 18, r.width, 12}, 10, COL_DIM)

	// pan (sends) / no pan for outputs
	y := r.y + 32
	bus := ROW_LEVEL[row]
	if row != .Output {
		addr := fmt.tprintf("/mix/%s/%d/%d/balpan", bus, ch, ui.submix)
		v, changed := pan_slider(ui, widget_id(.Pan, row, ch), {r.x + 5, y, r.width - 10, 14}, state_get(&app.st, addr))
		if changed do app_send(app, addr, v)
	}
	y += 20

	// mute (inputs and outputs; global, not per submix)
	if row != .Playback {
		maddr := fmt.tprintf("/%s/%d/mute", ROW_BUS[row], ch)
		muted := state_get(&app.st, maddr) != 0
		if button(ui, {r.x + 5, y, r.width - 10, 16}, "M", muted, COL_MUTE, 11) {
			app_send(app, maddr, muted ? 0 : 1)
		}
	}
	y += 22

	// value label
	faddr: string
	off: f32
	if row == .Output {
		faddr = fmt.tprintf("/output/%d/volume", ch)
		off = FADER_MIN_DB
	} else {
		faddr = fmt.tprintf("/mix/%s/%d/%d/fader", bus, ch, ui.submix)
		off = SEND_OFF_DB
	}
	known := state_has(&app.st, faddr)
	db := state_get(&app.st, faddr, off)
	label := known ? fmt_db(db) : "?"
	text_centered(ui, label, {r.x, y, r.width, 14}, 12, known ? COL_TEXT : COL_DIM)
	y += 18

	// fader + meter(s)
	fr := rl.Rectangle{r.x + 2, y, r.width - 22, r.y + r.height - y - 4}
	if fr.height > 40 {
		new_db, changed := fader(ui, widget_id(.Fader, row, ch), fr, db, off, known)
		if changed do app_send(app, faddr, new_db)
		pk, rms := level_of(app, row, ch)
		mw: f32 = stereo ? 5 : 10
		meter({r.x + r.width - 18, fr.y + 8, mw, fr.height - 16}, pk, rms)
		if stereo {
			pk, rms = level_of(app, row, ch + 1)
			meter({r.x + r.width - 12, fr.y + 8, mw, fr.height - 16}, pk, rms)
		}
	}
}

// --- top bar & settings ------------------------------------------------------

draw_topbar :: proc(ui: ^UI, w: f32) {
	app := ui.app
	rl.DrawRectangleRec({0, 0, w, TOPBAR_H}, COL_STRIP)
	text(ui, "oscmix", 14, 12, 18, COL_ACCENT)
	if app.connected {
		dev := state_str(&app.st, "/device/name")
		if dev == "" do dev = app.device
		text(ui, fmt.tprintf("%s   ·   MIDI %d:%d", dev, app.midi.client, app.midi.port), 90, 15, 14, COL_TEXT)
	} else {
		text(ui, app.error != "" ? app.error : "not connected", 90, 15, 14, COL_RED)
		if button(ui, {w - 330, 9, 80, 26}, "Retry") {
			delete(app.error)
			app.error = ""
			app_connect(app, ui.port)
		}
	}
	jack := ui.jack_saved
	jtxt := jack.rate > 0 ? fmt.tprintf("JACK %d Hz · %d×%d", jack.rate, jack.period, jack.nperiods) : "JACK: no jackd.env"
	mode := ui.audio_mode != "" ? ui.audio_mode : "?"
	info := fmt.tprintf("%s   ·   mode %s", jtxt, mode)
	text(ui, info, w - 240 - text_width(ui, info, 13), 15, 13, COL_DIM)
	if button(ui, {w - 120, 9, 106, 26}, "Settings", ui.show_settings) {
		ui.show_settings = !ui.show_settings
		if ui.show_settings do settings_refresh(ui)
	}
	if rl.GetTime() < ui.status_until {
		sw := text_width(ui, ui.status, 13) + 20
		r := rl.Rectangle{(w - sw) / 2, TOPBAR_H + 6, sw, 24}
		rl.DrawRectangleRounded(r, 0.3, 4, {20, 22, 26, 235})
		text_centered(ui, ui.status, r, 13)
	}
}

settings_refresh :: proc(ui: ^UI) {
	if s, ok := jack_env_read(); ok {
		ui.jack_saved, ui.jack_cfg = s, s
	}
	ui.jack_now = jack_live()
	delete(ui.audio_mode)
	ui.audio_mode = strings.clone(audio_mode_get())
	ui.iface_pending = -1
}

INTERFACE_MODES := [?]string{"Auto", "USB2", "USB3", "CC"}

draw_settings :: proc(ui: ^UI, sw, sh: f32) {
	app := ui.app
	r := rl.Rectangle{(sw - 600) / 2, TOPBAR_H + 30, 600, 420}
	rl.DrawRectangleRec({0, 0, sw, sh}, {0, 0, 0, 120})
	rl.DrawRectangleRounded(r, 0.03, 6, COL_STRIP)
	x, y := r.x + 20, r.y + 18

	text(ui, "JACK server (jackd)", x, y, 16)
	live := ui.jack_now.running ? fmt.tprintf("running: %d Hz, %d frames", ui.jack_now.rate, ui.jack_now.period) : "not running"
	text(ui, live, x + 200, y + 2, 13, ui.jack_now.running ? COL_DIM : COL_RED)
	y += 30
	text(ui, "Sample rate", x, y + 5, 13, COL_DIM)
	for rate, i in JACK_RATES {
		label := rate % 1000 == 0 ? fmt.tprintf("%dk", rate / 1000) : fmt.tprintf("%.1fk", f32(rate) / 1000)
		if button(ui, {x + 110 + f32(i) * 72, y, 66, 24}, label, ui.jack_cfg.rate == rate) do ui.jack_cfg.rate = rate
	}
	y += 32
	text(ui, "Buffer", x, y + 5, 13, COL_DIM)
	for p, i in JACK_PERIODS {
		if button(ui, {x + 110 + f32(i) * 62, y, 56, 24}, fmt.tprintf("%d", p), ui.jack_cfg.period == p) do ui.jack_cfg.period = p
	}
	y += 32
	text(ui, "Periods", x, y + 5, 13, COL_DIM)
	for n, i in JACK_NPERIODS {
		if button(ui, {x + 110 + f32(i) * 62, y, 56, 24}, fmt.tprintf("%d", n), ui.jack_cfg.nperiods == n) do ui.jack_cfg.nperiods = n
	}
	cfg := ui.jack_cfg
	if cfg.rate > 0 && cfg.period > 0 {
		lat := f32(cfg.period * cfg.nperiods) / f32(cfg.rate) * 1000
		text(ui, fmt.tprintf("output latency ≈ %.2f ms", lat), x + 250, y + 5, 13, COL_DIM)
	}
	y += 36
	dirty := cfg != ui.jack_saved
	only_period := dirty && cfg.rate == ui.jack_saved.rate && cfg.nperiods == ui.jack_saved.nperiods
	if dirty {
		if only_period {
			if button(ui, {x, y, 200, 26}, "Apply buffer (live)") {
				if jack_set_period_live(cfg.period) && jack_env_write(cfg) {
					ui.jack_saved = cfg
					set_status(ui, fmt.tprintf("JACK buffer now %d frames", cfg.period))
				} else {
					set_status(ui, "could not change the JACK buffer size")
				}
				ui.jack_now = jack_live()
			}
		} else if button(ui, {x, y, 200, 26}, "Apply & restart jackd") {
			ui.confirm = .Jack_Restart
		}
		if button(ui, {x + 210, y, 90, 26}, "Revert") do ui.jack_cfg = ui.jack_saved
	} else {
		text(ui, "saved in ~/.config/jackd/jackd.env", x, y + 6, 12, COL_DIM)
	}

	y += 50
	text(ui, "Audio mode", x, y, 16)
	text(ui, "restart REAPER after switching", x + 200, y + 2, 13, COL_DIM)
	y += 30
	for m, i in ([]string{"rme", "soundgrid"}) {
		label := m == "rme" ? "RME (jackd)" : "SoundGrid"
		if button(ui, {x + f32(i) * 150, y, 140, 26}, label, ui.audio_mode == m) && ui.audio_mode != m {
			ok, out := audio_mode_set(m)
			delete(ui.audio_mode)
			ui.audio_mode = strings.clone(audio_mode_get())
			set_status(ui, ok ? fmt.tprintf("audio mode: %s — restart REAPER", m) : fmt.tprintf("audio-mode failed: %s", out))
		}
	}

	y += 50
	text(ui, "Interface mode (device)", x, y, 16)
	cur := int(state_get(&app.st, "/hardware/interfacemode", -1))
	text(ui, "USB modes have no Linux driver", x + 250, y + 2, 13, COL_DIM)
	y += 30
	for m, i in INTERFACE_MODES {
		if button(ui, {x + f32(i) * 100, y, 92, 26}, m, cur == i) && cur != i && app.connected {
			ui.iface_pending = i
			ui.confirm = .Interface_Mode
		}
	}

	if button(ui, {r.x + r.width - 110, r.y + r.height - 42, 90, 28}, "Close") do ui.show_settings = false
}

draw_confirm :: proc(ui: ^UI, sw, sh: f32) {
	msg: string
	switch ui.confirm {
	case .None:
		return
	case .Jack_Restart:
		msg = fmt.tprintf("Restart jackd at %d Hz, %d×%d?\nAudio apps (REAPER) lose their JACK connection\nand must be restarted.", ui.jack_cfg.rate, ui.jack_cfg.period, ui.jack_cfg.nperiods)
	case .Interface_Mode:
		mode := INTERFACE_MODES[ui.iface_pending]
		msg = mode == "CC" ? "Switch the interface to CC mode?\nThe unit restarts." : fmt.tprintf("Switch the interface to %s?\nThe unit restarts in driver mode: Linux has no driver for it,\nso audio and this app stop working. Switching back to CC\nneeds the front panel (SETUP → Options → Interface Mode).", mode)
	}
	r := rl.Rectangle{(sw - 520) / 2, (sh - 190) / 2, 520, 190}
	rl.DrawRectangleRec({0, 0, sw, sh}, {0, 0, 0, 140})
	rl.DrawRectangleRounded(r, 0.05, 6, COL_ROW)
	rl.DrawTextEx(ui.font, strings.clone_to_cstring(msg, context.temp_allocator), {r.x + 20, r.y + 20}, 14, 0, COL_TEXT)
	if button(ui, {r.x + r.width - 220, r.y + r.height - 46, 95, 30}, "Cancel") do ui.confirm = .None
	if button(ui, {r.x + r.width - 115, r.y + r.height - 46, 95, 30}, "Confirm", true) {
		action := ui.confirm
		ui.confirm = .None
		switch action {
		case .None:
		case .Jack_Restart:
			if !jack_env_write(ui.jack_cfg) {
				set_status(ui, "could not write ~/.config/jackd/jackd.env")
			} else {
				ui.jack_saved = ui.jack_cfg
				ok, out := jackd_restart()
				set_status(ui, ok ? "jackd restarted" : fmt.tprintf("jackd restart failed: %s", out))
			}
			ui.jack_now = jack_live()
		case .Interface_Mode:
			app_send(ui.app, "/hardware/interfacemode", f32(ui.iface_pending))
			set_status(ui, fmt.tprintf("interface mode → %s", INTERFACE_MODES[ui.iface_pending]))
		}
	}
}

// --- main loop ---------------------------------------------------------------------

load_ui_font :: proc() -> rl.Font {
	ok, path := run_cmd("fc-match", "-f", "%{file}", "sans-serif:style=Regular")
	if ok && path != "" {
		// Latin-1 plus the few symbols the UI uses.
		cps := make([dynamic]rune, context.temp_allocator)
		for c in rune(32) ..< 256 do append(&cps, c)
		append(&cps, '·', '→', '≈', '×', '…')
		f := rl.LoadFontEx(strings.clone_to_cstring(path, context.temp_allocator), 32, raw_data(cps), i32(len(cps)))
		if f.glyphCount > 0 {
			rl.SetTextureFilter(f.texture, .BILINEAR)
			return f
		}
	}
	return rl.GetFontDefault()
}

run_ui :: proc(app: ^App, port: string) {
	ui := UI{app = app, port = port, iface_pending = -1}
	defer {
		delete(ui.audio_mode)
		delete(ui.status)
	}
	app_connect(app, port)

	rl.SetTraceLogLevel(.WARNING)
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT, .MSAA_4X_HINT})
	rl.InitWindow(1400, 860, "oscmix")
	defer rl.CloseWindow()
	rl.SetWindowMinSize(800, 560)
	rl.SetTargetFPS(60)
	ui.font = load_ui_font()
	settings_refresh(&ui)

	for !rl.WindowShouldClose() {
		app_poll(app)
		// stereo submix: always address the left output of a pair
		if ui.submix % 2 == 1 && is_stereo(app, .Output, ui.submix - 1) do ui.submix -= 1

		sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
		rl.BeginDrawing()
		rl.ClearBackground(COL_BG)
		rows_h := sh - TOPBAR_H
		row_h := rows_h / 3
		for row in Row {
			ui.layer = .Mixer
			draw_row(&ui, row, {0, TOPBAR_H + f32(row) * row_h + 2, sw, row_h - 4})
		}
		ui.layer = .Settings
		if ui.show_settings do draw_settings(&ui, sw, sh)
		// the top bar stays usable while settings are open (its button closes them)
		ui.layer = ui.confirm != .None ? .Mixer : top_layer(&ui)
		draw_topbar(&ui, sw)
		ui.layer = .Confirm
		draw_confirm(&ui, sw, sh)
		rl.EndDrawing()
		free_all(context.temp_allocator)
	}
}
