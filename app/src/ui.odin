package oscmix_native

// TotalMix-style window: inputs and playbacks send into the selected submix
// (an output); outputs have their own volume. Immediate-mode, raylib.
// Everything is laid out in logical units; ui.scale zooms the whole window
// (camera zoom for drawing, mouse scale for input).

import "core:fmt"
import "core:math"
import "core:sync"
import "core:slice"
import "core:strings"
import "core:time"
import rl "../raylib"

// --- look ---------------------------------------------------------------

COL_BG :: rl.Color{24, 26, 30, 255}
COL_ROW :: rl.Color{32, 35, 41, 255}
COL_STRIP :: rl.Color{40, 44, 52, 255}
COL_STRIP_SEL :: rl.Color{48, 62, 82, 255}
COL_TEXT :: rl.Color{225, 228, 233, 255}
COL_DIM :: rl.Color{150, 156, 168, 255}
COL_ACCENT :: rl.Color{86, 156, 255, 255}
COL_TRACK :: rl.Color{18, 20, 23, 255}
COL_MUTE :: rl.Color{220, 70, 60, 255}
COL_GREEN :: rl.Color{70, 200, 100, 255}
COL_YELLOW :: rl.Color{230, 200, 60, 255}
COL_RED :: rl.Color{235, 70, 60, 255}
COL_DYN :: rl.Color{180, 120, 30, 255}
COL_PHANTOM :: rl.Color{200, 60, 60, 255}
COL_BUTTON :: rl.Color{56, 61, 72, 255}
COL_BUTTON_HOT :: rl.Color{70, 77, 90, 255}

STRIP_W :: 72
HEADER_W :: 112
TOPBAR_H :: 46
SCROLLBAR_H :: 12
COL_ON :: rl.Color{226, 184, 48, 255} // "processing on" (EQ, dynamics, …), as in TotalMix
GROUP_COL := [GROUPS]rl.Color{{232, 120, 60, 255}, {90, 200, 210, 255}, {200, 110, 220, 255}, {150, 210, 90, 255}}
CTL_H :: 18 // strip control height
CTL_GAP :: 3

// Font sizes in logical units (pixels at 100 %).
FONT_TINY :: 11
FONT_SMALL :: 12
FONT :: 13
FONT_NAME :: 14
FONT_HEAD :: 16
FONT_TITLE :: 20

SCALE_MIN :: 0.75
SCALE_MAX :: 3.0
SCALE_STEP :: 0.125
SCALE_PRESETS :: [?]f32{1, 1.25, 1.5, 1.75, 2, 2.5}

// Relative heights of the three mixer rows (inputs carry the most controls).
ROW_WEIGHT := [Row]f32 {
	.Input    = 1.25,
	.Playback = 0.8,
	.Output   = 0.95,
}

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
ROW_TITLE := [Row]string {
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
	Name,
}

Confirm_Action :: enum {
	None,
	Jack_Restart,
	Interface_Mode,
	Main_Out,
	Save_Preset,
	Delete_Preset,
	Save_Snapshot,
	Rename,
	Reset_Mixer,
}

Reveal :: struct {
	row:     Row,
	ch:      int,
	kind:    Panel_Kind,
	pending: bool,
}

UI :: struct {
	app:          ^App,
	font:         rl.Font,
	font_owned:   bool, // font is loaded by us (not raylib's default)
	font_path:    string, // owned; "" = raylib default font
	scale:        f32,
	// interaction: only widgets on the topmost open layer react to input
	layer:        Layer, // layer currently being drawn
	clip:         rl.Rectangle, // widgets react only inside this while clipped
	clipped:      bool,
	wheel_used:   bool, // a widget consumed the mouse wheel this frame
	active:       u64,
	drag_origin:  rl.Vector2,
	drag_value:   f32,
	last_click:   u64,
	last_click_t: f64,
	drag_value2:  f32, // second value for 2-D drags (graph nodes)
	scroll:       [Row]f32,
	submix:       int,
	// channel panels beside their strips (key: strip_key)
	panels:       map[u32]Panel_Set,
	panel_scroll: map[u64]f32,
	reveal:       Reveal, // panel to scroll into view
	// control room column: outputs pinned there besides Main Out
	pins:         [dynamic]int,
	pins_uid:     string, // owned; device the pins belong to
	// FX dock (control room settings, reverb, echo)
	fx_dock:      bool,
	fx_scroll:    f32,
	// presets
	presets:      Preset_File,
	popup:        Popup, // preset list of one panel
	in_popup:     bool, // drawing the popup (it is exempt from its own input block)
	preset_target: Preset_Target, // dialog subject (preset save/delete, snapshot slot, rename)
	text:         strings.Builder, // dialog name field
	snap_store:   bool, // Store armed: the next slot click stores
	snap_active:  int, // last stored/recalled snapshot slot, -1 none
	snap_unknown: int, // unknown sends when the store dialog opened
	snap_unknown_off: bool, // store dialog choice: unknown sends stored as off
	reset_channels: bool, // reset dialog: also reset channel settings
	// settings
	show_settings: bool,
	jack_cfg:      Jack_Settings, // pending edit
	jack_saved:    Jack_Settings, // as in jackd.env
	jack_now:      Jack_Live,
	audio_mode:    string, // owned
	iface_pending: int,
	main_pending:  int, // output to become Main Out (confirm dialog)
	confirm:       Confirm_Action,
	status:        string, // owned
	status_until:  f64,
	// tooltip: offered by a hovered widget each frame, drawn last
	tip:           string,
	tip_id:        u64,
	tip_since:     f64,
	tip_seen:      bool,
}

Popup :: struct {
	open:   bool,
	row:    Row,
	ch:     int,
	kind:   Panel_Kind,
	anchor: rl.Rectangle, // its "Presets" button, refreshed while the panel is drawn
	rect:   rl.Rectangle, // last drawn area; blocks input underneath
	seen:   bool, // anchor refreshed this frame
}

Preset_Target :: struct {
	row:   Row,
	ch:    int,
	kind:  Panel_Kind,
	index: int, // delete: preset index
}

widget_id :: proc(w: Widget, row: Row, idx: int) -> u64 {
	return u64(w) << 40 | u64(row) << 32 | u64(idx)
}

// Widget id for a parameter address (top bit set: never collides with widget_id).
addr_id :: proc(addr: string) -> u64 {
	h: u64 = 14695981039346656037
	for c in transmute([]u8)addr {
		h ~= u64(c)
		h *= 1099511628211
	}
	return h | 1 << 63
}

// --- helpers -------------------------------------------------------------

set_status :: proc(ui: ^UI, msg: string, secs := 6.0) {
	delete(ui.status)
	ui.status = strings.clone(msg)
	ui.status_until = rl.GetTime() + secs
}

text :: proc(ui: ^UI, s: string, x, y: f32, size: f32 = FONT, color := COL_TEXT) {
	rl.DrawTextEx(ui.font, strings.clone_to_cstring(s, context.temp_allocator), {x, y}, size, 0, color)
}

text_width :: proc(ui: ^UI, s: string, size: f32 = FONT) -> f32 {
	return rl.MeasureTextEx(ui.font, strings.clone_to_cstring(s, context.temp_allocator), size, 0).x
}

// Centred in r; shrinks the font a little, then truncates, if s does not fit.
text_centered :: proc(ui: ^UI, s: string, r: rl.Rectangle, size: f32 = FONT, color := COL_TEXT) {
	s, size := s, size
	min_size := size * 0.8
	for size > min_size && text_width(ui, s, size) > r.width - 4 do size -= 0.5
	for len(s) > 1 && text_width(ui, s, size) > r.width - 4 do s = s[:len(s) - 1]
	w := text_width(ui, s, size)
	text(ui, s, r.x + (r.width - w) / 2, r.y + (r.height - size) / 2, size, color)
}

// Left-aligned, truncated to max_w.
text_fit :: proc(ui: ^UI, s: string, x, y, max_w: f32, size: f32 = FONT, color := COL_TEXT) {
	if max_w <= 8 do return
	s := s
	for len(s) > 1 && text_width(ui, s, size) > max_w do s = s[:len(s) - 1]
	text(ui, s, x, y, size, color)
}

hovered :: proc(r: rl.Rectangle) -> bool {return rl.CheckCollisionPointRec(rl.GetMousePosition(), r)}

shift_down :: proc() -> bool {return rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)}
ctrl_down :: proc() -> bool {return rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)}

// Wheel for value widgets: only with Shift held, so scrolling never changes a
// level. Some systems turn Shift+wheel into a horizontal wheel; either counts.
value_wheel :: proc() -> f32 {
	if !shift_down() do return 0
	w := rl.GetMouseWheelMoveV()
	return w.y != 0 ? w.y : w.x
}

TIP_DELAY :: 0.6 // seconds of hovering before a tooltip shows

// Offers a tooltip for widget id this frame (shown by draw_tip after TIP_DELAY).
set_tip :: proc(ui: ^UI, id: u64, msg: string) {
	if ui.tip_id != id do ui.tip_id, ui.tip_since = id, rl.GetTime()
	ui.tip, ui.tip_seen = msg, true
}

draw_tip :: proc(ui: ^UI, sw, sh: f32) {
	defer ui.tip_seen = false
	if !ui.tip_seen {
		ui.tip_id = 0
		return
	}
	if ui.active != 0 || rl.GetTime() - ui.tip_since < TIP_DELAY do return
	lines := strings.split_lines(ui.tip, context.temp_allocator)
	w: f32 = 0
	for l in lines do w = max(w, text_width(ui, l, FONT_SMALL))
	h := f32(len(lines)) * (FONT_SMALL + 3) + 8
	m := rl.GetMousePosition()
	r := rl.Rectangle{min(m.x + 14, sw - w - 18), min(m.y + 18, sh - h - 4), w + 14, h}
	rl.DrawRectangleRounded(r, 0.2, 4, COL_TRACK)
	rl.DrawRectangleRoundedLinesEx(r, 0.2, 4, 1, COL_DIM)
	for l, i in lines do text(ui, l, r.x + 7, r.y + 4 + f32(i) * (FONT_SMALL + 3), FONT_SMALL, COL_TEXT)
}

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

// Mouse is over r, r belongs to the topmost layer, and r is not clipped away.
interactive :: proc(ui: ^UI, r: rl.Rectangle) -> bool {
	if ui.layer != top_layer(ui) || !hovered(r) do return false
	if ui.popup.open && !ui.in_popup && hovered(ui.popup.rect) do return false
	return !ui.clipped || hovered(ui.clip)
}

Clip :: struct {
	r:  rl.Rectangle,
	on: bool,
}

@(private = "file")
scissor :: proc(ui: ^UI, r: rl.Rectangle) {
	s := ui.scale
	rl.BeginScissorMode(i32(r.x * s), i32(r.y * s), i32(math.ceil(r.width * s)), i32(math.ceil(r.height * s)))
}

// Clips drawing and interaction to r (logical units), within any enclosing
// clip. Restore with clip_pop(ui, returned value).
clip_push :: proc(ui: ^UI, r: rl.Rectangle) -> (prev: Clip) {
	prev = {ui.clip, ui.clipped}
	r := r
	if ui.clipped {
		x0, y0 := max(r.x, ui.clip.x), max(r.y, ui.clip.y)
		x1 := min(r.x + r.width, ui.clip.x + ui.clip.width)
		y1 := min(r.y + r.height, ui.clip.y + ui.clip.height)
		r = {x0, y0, max(0, x1 - x0), max(0, y1 - y0)}
	}
	scissor(ui, r)
	ui.clip, ui.clipped = r, true
	return
}

clip_pop :: proc(ui: ^UI, prev: Clip) {
	if prev.on {
		scissor(ui, prev.r)
	} else {
		rl.EndScissorMode()
	}
	ui.clip, ui.clipped = prev.r, prev.on
}

// Dark text on light button colours (yellow "on" state), white otherwise.
on_text_color :: proc(c: rl.Color) -> rl.Color {
	lum := 0.299 * f32(c.r) + 0.587 * f32(c.g) + 0.114 * f32(c.b)
	return lum > 150 ? COL_TRACK : rl.WHITE
}

button :: proc(ui: ^UI, r: rl.Rectangle, label: string, on := false, on_color := COL_ACCENT, size: f32 = FONT) -> bool {
	hot := interactive(ui, r)
	col := on ? on_color : (hot ? COL_BUTTON_HOT : COL_BUTTON)
	rl.DrawRectangleRounded(r, 0.25, 4, col)
	text_centered(ui, label, r, size, on ? on_text_color(on_color) : COL_TEXT)
	return hot && rl.IsMouseButtonPressed(.LEFT)
}

// Button with a gear icon (channel settings).
cog_button :: proc(ui: ^UI, r: rl.Rectangle, on: bool) -> bool {
	hot := interactive(ui, r)
	bg := on ? COL_ACCENT : (hot ? COL_BUTTON_HOT : COL_BUTTON)
	rl.DrawRectangleRounded(r, 0.25, 4, bg)
	fg := on ? rl.WHITE : COL_TEXT
	c := rl.Vector2{r.x + r.width / 2, r.y + r.height / 2}
	R := min(r.width, r.height) * 0.36
	for i in 0 ..< 4 {
		rl.DrawRectanglePro({c.x, c.y, R * 0.5, 2 * R}, {R * 0.25, R}, f32(i) * 45, fg)
	}
	rl.DrawCircleV(c, R * 0.74, fg)
	rl.DrawCircleV(c, R * 0.32, bg)
	return hot && rl.IsMouseButtonPressed(.LEFT)
}

// Outline marking a strip button whose panel is open.
open_marker :: proc(r: rl.Rectangle) {
	rl.DrawRectangleRoundedLinesEx({r.x - 1, r.y - 1, r.width + 2, r.height + 2}, 0.3, 4, 1.5, COL_ACCENT)
}

// Shows options[cur]; left click = next option, right click = previous.
cycle_button :: proc(ui: ^UI, r: rl.Rectangle, options: []string, cur: int, size: f32 = FONT_SMALL) -> (next: int, changed: bool) {
	hot := interactive(ui, r)
	rl.DrawRectangleRounded(r, 0.25, 4, hot ? COL_BUTTON_HOT : COL_BUTTON)
	label := cur >= 0 && cur < len(options) ? options[cur] : "?"
	text_centered(ui, label, r, size)
	if !hot || len(options) == 0 do return cur, false
	if rl.IsMouseButtonPressed(.LEFT) do return (max(cur, -1) + 1) % len(options), true
	if rl.IsMouseButtonPressed(.RIGHT) do return (max(cur, 0) + len(options) - 1) % len(options), true
	return cur, false
}

// On/off parameter button.
toggle_param :: proc(ui: ^UI, r: rl.Rectangle, label, addr: string, color := COL_ACCENT, size: f32 = FONT_SMALL) {
	on := state_get(&ui.app.st, addr) != 0
	if button(ui, r, label, on, color, size) do app_send(ui.app, addr, on ? 0 : 1)
}

// Enum parameter as a cycle button.
cycle_param :: proc(ui: ^UI, r: rl.Rectangle, addr: string, options: []string, size: f32 = FONT_SMALL) {
	if v, changed := cycle_button(ui, r, options, int(state_get(&ui.app.st, addr, -1)), size); changed {
		app_send(ui.app, addr, f32(v))
	}
}

// Comma-separated option list reported by the engine (e.g. /input/0/reflevels).
option_list :: proc(app: ^App, addr: string) -> []string {
	s := state_str(&app.st, addr)
	if s == "" do return nil
	return strings.split(s, ",", context.temp_allocator)
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

// Vertical fader. Drag (Shift = fine), Shift+wheel ±0.5 dB (Ctrl+Shift ±0.1),
// double-click = 0 dB, right-click = off/minimum. The plain wheel scrolls.
fader :: proc(ui: ^UI, id: u64, r: rl.Rectangle, db: f32, off: f32, known := true) -> (out: f32, changed: bool) {
	out = db
	mouse := rl.GetMousePosition()
	travel := r.height - 16
	if interactive(ui, r) {
		set_tip(ui, id, "Drag (Shift: fine) · Shift+wheel ±0.5 dB, Ctrl+Shift+wheel ±0.1\nDouble-click 0 dB · right-click off")
		if rl.IsMouseButtonPressed(.LEFT) {
			if double_click(ui, id) {
				out = 0
			} else {
				ui.active, ui.drag_origin, ui.drag_value = id, mouse, db_to_pos(db)
			}
		} else if rl.IsMouseButtonPressed(.RIGHT) {
			out = off
		} else if wheel := value_wheel(); wheel != 0 {
			step: f32 = ctrl_down() ? 0.1 : 0.5
			base := db <= FADER_MIN_DB ? FADER_MIN_DB : db
			out = clamp(base + wheel * step, FADER_MIN_DB, FADER_MAX_DB)
			if out <= FADER_MIN_DB do out = off
		}
	}
	if ui.active == id {
		if rl.IsMouseButtonDown(.LEFT) {
			scale: f32 = shift_down() ? 0.15 : 1
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
	rl.DrawLineEx({cx - 10, zero_y}, {cx + 10, zero_y}, 1, COL_DIM)
	ty := r.y + 8 + travel * (1 - db_to_pos(out))
	thumb := rl.Rectangle{cx - 12, ty - 8, 24, 16}
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
	text_centered(ui, label, r, FONT_TINY, COL_TEXT)
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

// Local name if set (see devdata.odin), else the interface's.
channel_name :: proc(app: ^App, row: Row, i: int) -> string {
	if n := local_name(app, row, i); n != "" do return n
	return interface_name(app, row, i)
}

interface_name :: proc(app: ^App, row: Row, i: int) -> string {
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

// Strips of a row; outputs shown in the control room column are left out.
row_channels :: proc(ui: ^UI, row: Row) -> []int {
	chans := strip_channels(ui.app, row)
	if row != .Output do return chans[:]
	cr := cr_outputs(ui)
	out := make([dynamic]int, 0, len(chans), context.temp_allocator)
	for ch in chans do if !slice.contains(cr, ch) do append(&out, ch)
	return out[:]
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
	text(ui, ROW_TITLE[row], head.x + 10, head.y + 10, FONT_SMALL, COL_DIM)
	if row != .Output {
		text(ui, "send to", head.x + 10, head.y + 54, FONT_SMALL, COL_DIM)
		text_centered(ui, strip_name(app, .Output, ui.submix), {head.x + 4, head.y + 70, head.width - 8, 22}, FONT_HEAD, COL_ACCENT)
	} else {
		text(ui, "click a channel\nto select its\nsubmix", head.x + 10, head.y + 54, FONT_SMALL, COL_DIM)
	}
	if row != .Playback {
		text(ui, "cog / EQ / DY:\nopen or close the\npanel beside the\nchannel", head.x + 10, head.y + 118, FONT_TINY, COL_DIM)
	}

	// layout: each strip, followed by its open panels
	Item :: struct {
		x, w:  f32,
		ch:    int,
		panel: Maybe(Panel_Kind),
	}
	items := make([dynamic]Item, context.temp_allocator)
	content_w: f32 = 0
	for ch in row_channels(ui, row) {
		append(&items, Item{x = content_w, w = STRIP_W, ch = ch})
		content_w += STRIP_W
		set := ui.panels[strip_key(row, ch)]
		for kind in Panel_Kind {
			if kind not_in set do continue
			append(&items, Item{x = content_w, w = PANEL_W[kind] + PANEL_GAP, ch = ch, panel = kind})
			content_w += PANEL_W[kind] + PANEL_GAP
		}
	}
	view := rl.Rectangle{area.x + HEADER_W, area.y, area.width - HEADER_W, area.height - SCROLLBAR_H}
	max_scroll := max(0, content_w - view.width)

	// horizontal scrolling: the wheel (vertical or horizontal) or the scrollbar.
	// Value widgets take the wheel only with Shift, and an open panel that can
	// scroll takes it first (it sets wheel_used), so this runs after drawing.
	defer if interactive(ui, area) && !ui.wheel_used && !shift_down() {
		wv := rl.GetMouseWheelMoveV()
		ui.scroll[row] -= (wv.x != 0 ? wv.x : wv.y) * STRIP_W * 2
	}
	// a panel that was just opened scrolls fully into view (once it is laid out)
	if ui.reveal.pending && ui.reveal.row == row {
		for it in items {
			if k, ok := it.panel.?; ok && k == ui.reveal.kind && it.ch == ui.reveal.ch {
				if it.x + it.w - ui.scroll[row] > view.width do ui.scroll[row] = it.x + it.w - view.width
				if it.x - STRIP_W - ui.scroll[row] < 0 do ui.scroll[row] = max(0, it.x - STRIP_W)
				ui.reveal.pending = false
			}
		}
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

	prev := clip_push(ui, view)
	defer clip_pop(ui, prev)
	for it in items {
		x := view.x + it.x - ui.scroll[row]
		if x + it.w < view.x || x > view.x + view.width do continue
		if kind, ok := it.panel.?; ok {
			draw_panel(ui, row, it.ch, kind, {x + 1, view.y + 2, it.w - PANEL_GAP - 2, view.height - 4})
		} else {
			draw_strip(ui, row, it.ch, {x + 1, view.y + 2, STRIP_W - 2, view.height - 4})
		}
	}
}

// "AN 1/AN 2" for stereo pairs; a local name on the left channel names the pair.
strip_name :: proc(app: ^App, row: Row, ch: int) -> string {
	name := channel_name(app, row, ch)
	if ch % 2 == 0 && is_stereo(app, row, ch) && local_name(app, row, ch) == "" {
		name = fmt.tprintf("%s/%s", name, channel_name(app, row, ch + 1))
	}
	return name
}

draw_strip :: proc(ui: ^UI, row: Row, ch: int, r: rl.Rectangle) {
	app := ui.app
	st := &app.st
	stereo := ch % 2 == 0 && is_stereo(app, row, ch)
	selected := row == .Output && ch == ui.submix
	rl.DrawRectangleRounded(r, 0.06, 4, selected ? COL_STRIP_SEL : COL_STRIP)

	base := fmt.tprintf("/%s/%d", ROW_BUS[row], ch)
	x, w := r.x + 4, r.width - 8
	y := r.y + 3
	name_r := rl.Rectangle{r.x, y, r.width, 20}
	text_centered(ui, strip_name(app, row, ch), name_r, FONT_NAME, selected ? rl.WHITE : COL_TEXT)
	if interactive(ui, name_r) && rl.IsMouseButtonPressed(.LEFT) && double_click(ui, widget_id(.Name, row, ch)) {
		open_rename(ui, row, ch)
	}
	y += 22

	if row == .Input {
		// preamp gain (mic/instrument inputs)
		gaddr := fmt.tprintf("%s/gain", base)
		if s, ok := gain_slider(app, ch); ok && state_has(st, gaddr) {
			v, changed := slider(ui, addr_id(gaddr), {x, y, w, CTL_H}, s, state_get(st, gaddr), FONT_SMALL)
			if changed do app_send(app, gaddr, v)
		}
		y += CTL_H + CTL_GAP
		// 48 V + Hi-Z on the mic inputs, reference level on line inputs
		if state_has(st, fmt.tprintf("%s/48v", base)) {
			half := (w - CTL_GAP) / 2
			toggle_param(ui, {x, y, half, CTL_H}, "48V", fmt.tprintf("%s/48v", base), COL_PHANTOM, FONT_TINY)
			if iaddr := fmt.tprintf("%s/instrument", base); state_has(st, iaddr) {
				toggle_param(ui, {x + half + CTL_GAP, y, half, CTL_H}, "Hi-Z", iaddr, COL_ACCENT, FONT_TINY)
			}
		} else if levels := option_list(app, fmt.tprintf("%s/reflevels", base)); len(levels) > 0 {
			cycle_param(ui, {x, y, w, CTL_H}, fmt.tprintf("%s/reflevel", base), levels, FONT_TINY)
		}
		y += CTL_H + CTL_GAP
	}

	if row == .Playback {
		// channel settings (name, width, groups)
		cog := rl.Rectangle{x, y, w, CTL_H}
		if cog_button(ui, cog, panel_open(ui, row, ch, .Settings)) do toggle_panel(ui, row, ch, .Settings)
		y += CTL_H + CTL_GAP
	} else {
		// mute + channel settings; EQ + dynamics (yellow = processing on).
		// Each opens/closes its panel beside the strip.
		half := (w - CTL_GAP) / 2
		maddr := fmt.tprintf("%s/mute", base)
		muted := state_get(st, maddr) != 0
		if button(ui, {x, y, half, CTL_H}, "M", muted, COL_MUTE, FONT_TINY) {
			app_send(app, maddr, muted ? 0 : 1)
			group_mute_set(app, row, ch, muted ? 0 : 1)
		}
		cog := rl.Rectangle{x + half + CTL_GAP, y, half, CTL_H}
		if cog_button(ui, cog, panel_open(ui, row, ch, .Settings)) do toggle_panel(ui, row, ch, .Settings)
		y += CTL_H + CTL_GAP

		eq_on := state_get(st, fmt.tprintf("%s/eq/enable", base)) != 0 || state_get(st, fmt.tprintf("%s/lowcut/enable", base)) != 0
		eq_r := rl.Rectangle{x, y, half, CTL_H}
		if button(ui, eq_r, "EQ", eq_on, COL_ON, FONT_TINY) do toggle_panel(ui, row, ch, .EQ)
		if panel_open(ui, row, ch, .EQ) do open_marker(eq_r)
		dy_on := state_get(st, fmt.tprintf("%s/dynamics/enable", base)) != 0 || state_get(st, fmt.tprintf("%s/autolevel/enable", base)) != 0
		dy_r := rl.Rectangle{x + half + CTL_GAP, y, half, CTL_H}
		if button(ui, dy_r, "DY", dy_on, COL_ON, FONT_TINY) do toggle_panel(ui, row, ch, .Dynamics)
		if panel_open(ui, row, ch, .Dynamics) do open_marker(dy_r)
		y += CTL_H + CTL_GAP
	}

	// pan of the send into the submix; balance for outputs
	bus := ROW_LEVEL[row]
	paddr := row == .Output ? fmt.tprintf("%s/balpan", base) : fmt.tprintf("/mix/%s/%d/%d/balpan", bus, ch, ui.submix)
	if v, changed := pan_slider(ui, widget_id(.Pan, row, ch), {x, y, w, 16}, state_get(st, paddr)); changed {
		app_send(app, paddr, v)
	}
	y += 20

	// value label
	faddr: string
	off: f32
	if row == .Output {
		faddr = fmt.tprintf("%s/volume", base)
		off = FADER_MIN_DB
	} else {
		faddr = fmt.tprintf("/mix/%s/%d/%d/fader", bus, ch, ui.submix)
		off = SEND_OFF_DB
	}
	known := state_has(st, faddr)
	db := state_get(st, faddr, off)
	text_centered(ui, known ? fmt_db(db) : "?", {r.x, y, r.width, 16}, FONT_SMALL, known ? COL_TEXT : COL_DIM)
	// group membership: fader group left (F1-F4), mute group right (M1-M4)
	bits := group_bits(app, row, ch)
	for g in 0 ..< GROUPS {
		if bits & (1 << uint(g)) != 0 {
			text(ui, fmt.tprintf("F%d", g + 1), r.x + 3, y + 2, FONT_TINY, GROUP_COL[g])
			break
		}
	}
	for g in 0 ..< GROUPS {
		if bits & (1 << uint(g + 4)) != 0 {
			text(ui, fmt.tprintf("M%d", g + 1), r.x + r.width - 18, y + 2, FONT_TINY, GROUP_COL[g])
			break
		}
	}
	y += 18

	// fader + meter(s)
	fr := rl.Rectangle{r.x + 2, y, r.width - 24, r.y + r.height - y - 4}
	if fr.height > 40 {
		new_db, changed := fader(ui, widget_id(.Fader, row, ch), fr, db, off, known)
		if changed {
			app_send(app, faddr, new_db)
			if known do group_fader_moved(app, row, ch, ui.submix, db, new_db)
		}
		pk, rms := level_of(app, row, ch)
		mw: f32 = stereo ? 5 : 10
		meter({r.x + r.width - 19, fr.y + 8, mw, fr.height - 16}, pk, rms)
		if stereo {
			pk, rms = level_of(app, row, ch + 1)
			meter({r.x + r.width - 13, fr.y + 8, mw, fr.height - 16}, pk, rms)
		}
	}

	// anywhere on an output strip: select its submix
	if row == .Output && interactive(ui, r) && rl.IsMouseButtonPressed(.LEFT) do ui.submix = ch
}

// --- top bar & settings ------------------------------------------------------

draw_topbar :: proc(ui: ^UI, w: f32) {
	app := ui.app
	rl.DrawRectangleRec({0, 0, w, TOPBAR_H}, COL_STRIP)
	text(ui, "oscmix", 14, 12, FONT_TITLE, COL_ACCENT)

	// right: control room quick buttons, FX dock, settings
	bx := w - 14 - 100
	if button(ui, {bx, 9, 100, 28}, "Settings", ui.show_settings) {
		ui.show_settings = !ui.show_settings
		if ui.show_settings do settings_refresh(ui)
	}
	bx -= 6 + 56
	if button(ui, {bx, 9, 56, 28}, "FX", ui.fx_dock) {
		ui.fx_dock = !ui.fx_dock
		prefs_save(ui)
	}

	jack := ui.jack_saved
	jtxt := jack.rate > 0 ? fmt.tprintf("JACK %d · %d×%d", jack.rate, jack.period, jack.nperiods) : "JACK: no jackd.env"
	mode := ui.audio_mode != "" ? ui.audio_mode : "?"
	info := fmt.tprintf("%s · %s · %d%%", jtxt, mode, int(ui.scale * 100 + 0.5))
	iw := text_width(ui, info, FONT)
	ix := bx - 16 - iw
	text(ui, info, ix, 15, FONT, COL_DIM)

	// DSP load reported by the interface (live; e.g. 9 idle, 23 with EQ +
	// dynamics on 8 channels)
	if app.connected && state_has(&app.st, "/hardware/dspload") {
		load := state_get(&app.st, "/hardware/dspload")
		dx := ix - 22 - 132
		text(ui, "DSP", dx, 15, FONT, COL_DIM)
		bar := rl.Rectangle{dx + 36, 18, 56, 10}
		rl.DrawRectangleRounded(bar, 0.5, 4, COL_TRACK)
		col := load >= 85 ? COL_RED : (load >= 60 ? COL_YELLOW : COL_GREEN)
		rl.DrawRectangleRounded({bar.x, bar.y, bar.width * clamp(load / 100, 0, 1), bar.height}, 0.5, 4, col)
		text(ui, fmt.tprintf("%d %%", int(load)), bar.x + bar.width + 8, 15, FONT, COL_TEXT)
		ix = dx
	}

	if app.connected {
		dev := state_str(&app.st, "/device/name")
		if dev == "" do dev = app.device
		text_fit(ui, fmt.tprintf("%s · MIDI %d:%d", dev, app.midi.client, app.midi.port), 100, 15, ix - 116, FONT_NAME, COL_TEXT)
	} else {
		if button(ui, {100, 9, 90, 28}, "Retry now") do app_connect(app, app.port)
		text_fit(ui, app.error != "" ? app.error : "not connected", 200, 15, ix - 216, FONT_NAME, COL_RED)
	}
	if sent, total := app_queue_progress(app); total > 0 {
		msg := fmt.tprintf("sending to the interface: %d / %d", sent, total)
		sw := text_width(ui, msg, FONT) + 24
		r := rl.Rectangle{(w - sw) / 2, TOPBAR_H + 6, sw, 28}
		rl.DrawRectangleRounded(r, 0.3, 4, {20, 22, 26, 235})
		rl.DrawRectangleRounded({r.x, r.y + r.height - 3, r.width * f32(sent) / f32(total), 3}, 1, 4, COL_ACCENT)
		text_centered(ui, msg, r, FONT)
	} else if rl.GetTime() < ui.status_until {
		sw := text_width(ui, ui.status, FONT) + 24
		r := rl.Rectangle{(w - sw) / 2, TOPBAR_H + 6, sw, 28}
		rl.DrawRectangleRounded(r, 0.3, 4, {20, 22, 26, 235})
		text_centered(ui, ui.status, r, FONT)
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
	r := rl.Rectangle{(sw - 640) / 2, TOPBAR_H + 20, 640, 610}
	rl.DrawRectangleRec({0, 0, sw, sh}, {0, 0, 0, 120})
	rl.DrawRectangleRounded(r, 0.03, 6, COL_STRIP)
	x, y := r.x + 20, r.y + 18

	text(ui, "Window scale", x, y, FONT_HEAD)
	text(ui, "Ctrl + / Ctrl − / Ctrl 0", x + 250, y + 2, FONT, COL_DIM)
	y += 30
	if button(ui, {x, y, 34, 26}, "−") do ui_set_scale(ui, ui.scale - SCALE_STEP)
	for p, i in SCALE_PRESETS {
		if button(ui, {x + 42 + f32(i) * 74, y, 68, 26}, fmt.tprintf("%d%%", int(p * 100)), abs(ui.scale - p) < 0.01) {
			ui_set_scale(ui, p)
		}
	}
	if button(ui, {x + 42 + f32(len(SCALE_PRESETS)) * 74, y, 34, 26}, "+") do ui_set_scale(ui, ui.scale + SCALE_STEP)

	y += 50
	text(ui, "JACK server (jackd)", x, y, FONT_HEAD)
	live := ui.jack_now.running ? fmt.tprintf("running: %d Hz, %d frames", ui.jack_now.rate, ui.jack_now.period) : "not running"
	text(ui, live, x + 220, y + 2, FONT, ui.jack_now.running ? COL_DIM : COL_RED)
	y += 30
	text(ui, "Sample rate", x, y + 5, FONT, COL_DIM)
	for rate, i in JACK_RATES {
		label := rate % 1000 == 0 ? fmt.tprintf("%dk", rate / 1000) : fmt.tprintf("%.1fk", f32(rate) / 1000)
		if button(ui, {x + 110 + f32(i) * 76, y, 70, 26}, label, ui.jack_cfg.rate == rate) do ui.jack_cfg.rate = rate
	}
	y += 34
	text(ui, "Buffer", x, y + 5, FONT, COL_DIM)
	for p, i in JACK_PERIODS {
		if button(ui, {x + 110 + f32(i) * 66, y, 60, 26}, fmt.tprintf("%d", p), ui.jack_cfg.period == p) do ui.jack_cfg.period = p
	}
	y += 34
	text(ui, "Periods", x, y + 5, FONT, COL_DIM)
	for n, i in JACK_NPERIODS {
		if button(ui, {x + 110 + f32(i) * 66, y, 60, 26}, fmt.tprintf("%d", n), ui.jack_cfg.nperiods == n) do ui.jack_cfg.nperiods = n
	}
	cfg := ui.jack_cfg
	if cfg.rate > 0 && cfg.period > 0 {
		lat := f32(cfg.period * cfg.nperiods) / f32(cfg.rate) * 1000
		text(ui, fmt.tprintf("output latency ~ %.2f ms", lat), x + 260, y + 5, FONT, COL_DIM)
	}
	y += 38
	dirty := cfg != ui.jack_saved
	only_period := dirty && cfg.rate == ui.jack_saved.rate && cfg.nperiods == ui.jack_saved.nperiods
	if dirty {
		if only_period {
			if button(ui, {x, y, 210, 28}, "Apply buffer (live)") {
				if jack_set_period_live(cfg.period) && jack_env_write(cfg) {
					ui.jack_saved = cfg
					set_status(ui, fmt.tprintf("JACK buffer now %d frames", cfg.period))
				} else {
					set_status(ui, "could not change the JACK buffer size")
				}
				ui.jack_now = jack_live()
			}
		} else if button(ui, {x, y, 210, 28}, "Apply & restart jackd") {
			ui.confirm = .Jack_Restart
		}
		if button(ui, {x + 220, y, 90, 28}, "Revert") do ui.jack_cfg = ui.jack_saved
	} else {
		text(ui, "saved in ~/.config/jackd/jackd.env", x, y + 6, FONT_SMALL, COL_DIM)
	}

	y += 50
	text(ui, "Audio mode", x, y, FONT_HEAD)
	text(ui, "restart REAPER after switching", x + 220, y + 2, FONT, COL_DIM)
	y += 30
	for m, i in ([]string{"rme", "soundgrid"}) {
		label := m == "rme" ? "RME (jackd)" : "SoundGrid"
		if button(ui, {x + f32(i) * 160, y, 150, 28}, label, ui.audio_mode == m) && ui.audio_mode != m {
			ok, out := audio_mode_set(m)
			delete(ui.audio_mode)
			ui.audio_mode = strings.clone(audio_mode_get())
			set_status(ui, ok ? fmt.tprintf("audio mode: %s — restart REAPER", m) : fmt.tprintf("audio-mode failed: %s", out))
		}
	}

	y += 50
	text(ui, "Interface mode (device)", x, y, FONT_HEAD)
	cur := int(state_get(&app.st, "/hardware/interfacemode", -1))
	text(ui, "USB modes have no Linux driver", x + 260, y + 2, FONT, COL_DIM)
	y += 30
	for m, i in INTERFACE_MODES {
		if button(ui, {x + f32(i) * 104, y, 96, 28}, m, cur == i) && cur != i && app.connected {
			ui.iface_pending = i
			ui.confirm = .Interface_Mode
		}
	}

	y += 50
	text(ui, "Mixer", x, y, FONT_HEAD)
	text(ui, "the interface does not report its sends", x + 220, y + 2, FONT, COL_DIM)
	y += 30
	restore := app.session.restore
	if button(ui, {x, y, 300, 28}, restore ? "Restore last session on connect: on" : "Restore last session on connect: off", restore) {
		app.session.restore = !restore
		prefs_save(ui)
	}
	if button(ui, {x + 310, y, 150, 28}, "Reset mixer…") && app.connected {
		ui.reset_channels = false
		ui.confirm = .Reset_Mixer
	}

	if button(ui, {r.x + r.width - 110, r.y + r.height - 44, 90, 30}, "Close") do ui.show_settings = false
}

draw_confirm :: proc(ui: ^UI, sw, sh: f32) {
	msg: string
	switch ui.confirm {
	case .None:
		return
	case .Save_Preset, .Save_Snapshot, .Rename:
		draw_text_dialog(ui, sw, sh)
		return
	case .Jack_Restart:
		msg = fmt.tprintf("Restart jackd at %d Hz, %d×%d?\nAudio apps (REAPER) lose their JACK connection\nand must be restarted.", ui.jack_cfg.rate, ui.jack_cfg.period, ui.jack_cfg.nperiods)
	case .Interface_Mode:
		mode := INTERFACE_MODES[ui.iface_pending]
		msg = mode == "CC" ? "Switch the interface to CC mode?\nThe unit restarts." : fmt.tprintf("Switch the interface to %s?\nThe unit restarts in driver mode: Linux has no driver for it,\nso audio and this app stop working. Switching back to CC\nneeds the front panel (SETUP > Options > Interface Mode).", mode)
	case .Main_Out:
		msg = fmt.tprintf("Make %s the Main Out?\nThe interface stores this; Dim, Mono and Recall then act\non it. The current Main Out goes back to the output row\nunless it is pinned to the control room.", strip_name(ui.app, .Output, ui.main_pending))
	case .Delete_Preset:
		t := ui.preset_target
		msg = fmt.tprintf("Delete the %s preset \"%s\"?", PANEL_TITLE[t.kind], presets_of(&ui.presets, t.kind)[t.index].name)
	case .Reset_Mixer:
		msg = fmt.tprintf("Reset the mix? Every send goes off except playback 1/2 to\nMain Out (0 dB). Outputs go to 0 dB, Main Out and phones to\n%.0f dB. Snapshots and the last session are kept until you change\nsomething; the reset becomes the new last session.", RESET_QUIET_DB)
	}
	dh: f32 = ui.confirm == .Reset_Mixer ? 290 : 210
	r := rl.Rectangle{(sw - 580) / 2, (sh - dh) / 2, 580, dh}
	rl.DrawRectangleRec({0, 0, sw, sh}, {0, 0, 0, 140})
	rl.DrawRectangleRounded(r, 0.05, 6, COL_ROW)
	text(ui, msg, r.x + 20, r.y + 20, FONT_NAME)
	if ui.confirm == .Reset_Mixer {
		cy := r.y + r.height - 100
		if button(ui, {r.x + 20, cy, 28, 28}, ui.reset_channels ? "×" : "", ui.reset_channels) do ui.reset_channels = !ui.reset_channels
		text(ui, "Also reset channel settings: EQ, low cut, dynamics, auto level\n(off, default values), mute, pan, width, M/S, phase, FX send/return", r.x + 58, cy, FONT_SMALL, COL_DIM)
	}
	if button(ui, {r.x + r.width - 230, r.y + r.height - 48, 100, 32}, "Cancel") do ui.confirm = .None
	if button(ui, {r.x + r.width - 120, r.y + r.height - 48, 100, 32}, "Confirm", true) {
		action := ui.confirm
		ui.confirm = .None
		switch action {
		case .None, .Save_Preset, .Save_Snapshot, .Rename:
		case .Reset_Mixer:
			quiet := make([dynamic]int, context.temp_allocator)
			append(&quiet, ..cr_outputs(ui))
			for ch in strip_channels(ui.app, .Output) {
				if strings.has_prefix(interface_name(ui.app, .Output, ch), "PH") && !slice.contains(quiet[:], ch) do append(&quiet, ch)
			}
			n := mixer_reset(ui.app, quiet[:], ui.reset_channels)
			ui.snap_active = -1
			set_status(ui, fmt.tprintf("mixer reset: %d writes", n))
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
			set_status(ui, fmt.tprintf("interface mode: %s", INTERFACE_MODES[ui.iface_pending]))
		case .Main_Out:
			app_send(ui.app, "/controlroom/mainout", f32(ui.main_pending))
			set_status(ui, fmt.tprintf("Main Out: %s", strip_name(ui.app, .Output, ui.main_pending)))
		case .Delete_Preset:
			t := ui.preset_target
			if !preset_delete(&ui.presets, t.kind, t.index) do set_status(ui, "could not save presets.json")
		}
	}
}

// Opens the rename dialog for a channel (prefilled with its current name).
open_rename :: proc(ui: ^UI, row: Row, ch: int) {
	ui.preset_target = {row = row, ch = ch}
	strings.builder_reset(&ui.text)
	strings.write_string(&ui.text, channel_name(ui.app, row, ch))
	ui.confirm = .Rename
}

// Opens the store dialog for a snapshot slot.
open_snapshot_store :: proc(ui: ^UI, slot: int) {
	ui.preset_target = {index = slot}
	strings.builder_reset(&ui.text)
	name := ui.app.dev.snapshots[slot].name
	strings.write_string(&ui.text, name != "" ? name : fmt.tprintf("Snapshot %d", slot + 1))
	_, ui.snap_unknown, _ = snapshot_capture(ui.app, false)
	ui.snap_unknown_off = false
	ui.confirm = .Save_Snapshot
}

// Name entry dialog: preset save, snapshot store, channel rename.
draw_text_dialog :: proc(ui: ^UI, sw, sh: f32) {
	t := ui.preset_target
	app := ui.app
	for c := rl.GetCharPressed(); c != 0; c = rl.GetCharPressed() {
		if c >= 32 && c < 256 && c != 127 && strings.builder_len(ui.text) < 40 do strings.write_rune(&ui.text, c)
	}
	if rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressedRepeat(.BACKSPACE) do strings.pop_rune(&ui.text)
	name := strings.trim_space(strings.to_string(ui.text))

	title, hint, ok_label: string
	allow_empty := true
	#partial switch ui.confirm {
	case .Save_Preset:
		title = fmt.tprintf("Save %s preset from %s", PANEL_TITLE[t.kind], strip_name(app, t.row, t.ch))
		hint = "Type a name; Enter saves, Esc cancels."
		for p in presets_of(&ui.presets, t.kind) do if p.name == name do hint = "Replaces the existing preset with this name."
		ok_label, allow_empty = "Save", false
	case .Save_Snapshot:
		title = fmt.tprintf("Store snapshot %d (the whole mix)", t.index + 1)
		hint = name == "" ? "An empty name clears this slot." : "Enter stores, Esc cancels."
		if ui.snap_unknown > 0 && name != "" {
			hint = fmt.tprintf("%d send levels are unknown to this app (the interface does\nnot report them). Leave them as they are on recall, or store\nthem as off so the snapshot sets every send.", ui.snap_unknown)
		}
		ok_label = name == "" ? "Clear" : "Store"
	case .Rename:
		title = fmt.tprintf("Rename %s", strip_name(app, t.row, t.ch))
		hint = "Stored on this computer (the interface does not keep names).\nAn empty name returns to the interface's name."
		ok_label = "Rename"
	case:
		return
	}

	dh: f32 = ui.confirm == .Save_Snapshot && ui.snap_unknown > 0 ? 300 : 240
	r := rl.Rectangle{(sw - 560) / 2, (sh - dh) / 2, 560, dh}
	rl.DrawRectangleRec({0, 0, sw, sh}, {0, 0, 0, 140})
	rl.DrawRectangleRounded(r, 0.05, 6, COL_ROW)
	text(ui, title, r.x + 20, r.y + 18, FONT_HEAD)
	field := rl.Rectangle{r.x + 20, r.y + 54, r.width - 40, 34}
	rl.DrawRectangleRounded(field, 0.2, 4, COL_TRACK)
	rl.DrawRectangleRoundedLinesEx(field, 0.2, 4, 1, COL_ACCENT)
	typed := strings.to_string(ui.text)
	text(ui, typed, field.x + 10, field.y + 9, FONT_NAME)
	if int(rl.GetTime() * 2) % 2 == 0 {
		cx := field.x + 11 + text_width(ui, typed, FONT_NAME)
		rl.DrawLineEx({cx, field.y + 7}, {cx, field.y + field.height - 7}, 1.5, COL_TEXT)
	}
	text(ui, hint, field.x, field.y + field.height + 8, FONT_SMALL, COL_DIM)
	if ui.confirm == .Save_Snapshot && ui.snap_unknown > 0 && name != "" {
		cy := r.y + r.height - 90
		text(ui, "Unknown sends:", field.x, cy + 6, FONT, COL_TEXT)
		bw: f32 = 150
		if button(ui, {field.x + 120, cy, bw, 28}, "Leave as they are", !ui.snap_unknown_off, COL_ACCENT, FONT_SMALL) do ui.snap_unknown_off = false
		if button(ui, {field.x + 126 + bw, cy, bw, 28}, "Set off", ui.snap_unknown_off, COL_MUTE, FONT_SMALL) do ui.snap_unknown_off = true
	}

	if button(ui, {r.x + r.width - 230, r.y + r.height - 48, 100, 32}, "Cancel") do ui.confirm = .None
	can := allow_empty || name != ""
	ok := button(ui, {r.x + r.width - 120, r.y + r.height - 48, 100, 32}, ok_label, can) || rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER)
	if !ok || !can do return
	#partial switch ui.confirm {
	case .Save_Preset:
		e := channel_ed(ui, t.row, t.ch)
		saved := preset_store(&ui.presets, t.kind, &e, name)
		set_status(ui, saved ? fmt.tprintf("%s preset \"%s\" saved", PANEL_TITLE[t.kind], name) : "could not save presets.json")
	case .Save_Snapshot:
		saved: bool
		if name == "" {
			saved = snapshot_clear(app, t.index)
			if ui.snap_active == t.index do ui.snap_active = -1
		} else {
			values, _, all_sends := snapshot_capture(app, ui.snap_unknown_off)
			saved = snapshot_store(app, t.index, name, values, all_sends)
			ui.snap_active = t.index
		}
		set_status(ui, saved ? fmt.tprintf("snapshot %d %s", t.index + 1, name == "" ? "cleared" : "stored") : "could not save the device file")
	case .Rename:
		// the interface's own name needs no local override
		set_local_name(app, t.row, t.ch, name == interface_name(app, t.row, t.ch) ? "" : name)
	}
	ui.confirm = .None
}

// --- scale & fonts -------------------------------------------------------------------

// Rasterizes the UI font for the current scale, with mipmaps so small text stays clean.
load_ui_font :: proc(ui: ^UI) {
	if ui.font_owned do rl.UnloadFont(ui.font)
	ui.font, ui.font_owned = rl.GetFontDefault(), false
	if ui.font_path == "" do return
	cps := make([dynamic]rune, context.temp_allocator)
	for c in rune(32) ..< 256 do append(&cps, c)
	append(&cps, '·', '×', '…', '−') // Noto Sans has no arrows or ≈
	px := i32(clamp(math.round(FONT_TITLE * 1.6 * ui.scale), 24, 96))
	f := rl.LoadFontEx(strings.clone_to_cstring(ui.font_path, context.temp_allocator), px, raw_data(cps), i32(len(cps)))
	if f.glyphCount == 0 do return
	rl.GenTextureMipmaps(&f.texture)
	rl.SetTextureFilter(f.texture, .TRILINEAR)
	ui.font, ui.font_owned = f, true
}

ui_set_scale :: proc(ui: ^UI, scale: f32) {
	s := clamp(math.round(scale / SCALE_STEP) * SCALE_STEP, SCALE_MIN, SCALE_MAX)
	if s == ui.scale && ui.font_owned do return
	ui.scale = s
	rl.SetMouseScale(1 / s, 1 / s)
	load_ui_font(ui)
	prefs_save(ui)
}

// Initial scale when nothing is saved: by monitor height.
default_scale :: proc() -> f32 {
	h := rl.GetMonitorHeight(rl.GetCurrentMonitor())
	if h >= 2000 do return 1.75
	if h >= 1400 do return 1.5
	return 1.25
}

handle_keys :: proc(ui: ^UI) {
	ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
	if ctrl && (rl.IsKeyPressed(.EQUAL) || rl.IsKeyPressed(.KP_ADD)) do ui_set_scale(ui, ui.scale + SCALE_STEP)
	if ctrl && (rl.IsKeyPressed(.MINUS) || rl.IsKeyPressed(.KP_SUBTRACT)) do ui_set_scale(ui, ui.scale - SCALE_STEP)
	if ctrl && rl.IsKeyPressed(.ZERO) do ui_set_scale(ui, 1)
	if rl.IsKeyPressed(.ESCAPE) {
		if ui.confirm != .None {
			ui.confirm = .None
		} else if ui.show_settings {
			ui.show_settings = false
		} else if ui.popup.open {
			ui.popup.open = false
		} else {
			clear(&ui.panels) // close every channel panel
		}
	}
}

// --- main loop ---------------------------------------------------------------------

// Frame rate: full while the user interacts or bulk writes are sent, half
// otherwise (meters stay smooth at 30 fps).
FPS_ACTIVE :: 60.0
FPS_IDLE :: 30.0
ACTIVE_SECONDS :: 0.5

user_active :: proc(ui: ^UI) -> bool {
	if d := rl.GetMouseDelta(); d.x != 0 || d.y != 0 do return true
	if rl.GetMouseWheelMove() != 0 || rl.IsMouseButtonDown(.LEFT) || rl.IsMouseButtonDown(.RIGHT) do return true
	if ui.active != 0 || ui.confirm != .None do return true
	_, pending := app_queue_progress(ui.app)
	return pending > 0
}

run_ui :: proc(app: ^App, port: string) {
	ui := UI{app = app, iface_pending = -1, snap_active = -1}
	defer {
		if ui.font_owned do rl.UnloadFont(ui.font)
		delete(ui.font_path)
		delete(ui.audio_mode)
		delete(ui.status)
		delete(ui.panels)
		delete(ui.panel_scroll)
		delete(ui.pins)
		delete(ui.pins_uid)
		presets_destroy(&ui.presets)
		strings.builder_destroy(&ui.text)
	}
	prefs, has_prefs := prefs_load()
	app.session.track, app.session.restore, app.session.restored = true, !prefs.no_restore, -1
	app_connect(app, port)

	rl.SetTraceLogLevel(.WARNING)
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT, .MSAA_4X_HINT})
	rl.InitWindow(1500, 940, "oscmix")
	defer rl.CloseWindow()
	rl.SetWindowMinSize(800, 560)
	rl.SetTargetFPS(0) // paced in the loop below
	rl.SetExitKey(.KEY_NULL) // Esc closes panels instead
	if ok, path := run_cmd("fc-match", "-f", "%{file}", "sans-serif:style=Regular"); ok && path != "" {
		ui.font_path = strings.clone(path)
	}
	ui.fx_dock = prefs.fx_dock
	ui_set_scale(&ui, has_prefs ? prefs.scale : default_scale())
	presets_load(&ui.presets)
	settings_refresh(&ui)

	// the interface is polled on its own thread from here on; the window holds
	// app.lock while it reads or changes the App (everything up to EndDrawing)
	app_worker_start(app)
	defer app_worker_stop(app)
	last_input: f64
	for !rl.WindowShouldClose() {
		frame_start := time.tick_now()
		sync.mutex_lock(&app.lock)
		if user_active(&ui) do last_input = rl.GetTime()
		if n := app.session.restored; n >= 0 {
			app.session.restored = -1
			set_status(ui = &ui, msg = fmt.tprintf("last session restored: %d writes", n))
		}
		cr_sync_pins(&ui)
		handle_keys(&ui)
		ui.wheel_used = false
		// stereo pairs: always address the left channel
		if ui.submix % 2 == 1 && is_stereo(app, .Output, ui.submix - 1) do ui.submix -= 1

		lw := f32(rl.GetScreenWidth()) / ui.scale
		lh := f32(rl.GetScreenHeight()) / ui.scale
		fx_w: f32 = ui.fx_dock ? FX_DOCK_W : 0
		cr_w := cr_width(&ui)
		mix_w := max(lw - fx_w - cr_w, 320)
		rl.BeginDrawing()
		rl.ClearBackground(COL_BG)
		rl.BeginMode2D({zoom = ui.scale})
		rows_h := lh - TOPBAR_H
		total: f32 = 0
		for w in ROW_WEIGHT do total += w
		y: f32 = TOPBAR_H
		ui.layer = .Mixer
		for row in Row {
			h := rows_h * ROW_WEIGHT[row] / total
			draw_row(&ui, row, {0, y + 2, mix_w, h - 4})
			y += h
		}
		draw_control_room(&ui, {mix_w + 2, TOPBAR_H + 2, cr_w - 2, rows_h - 4})
		if ui.fx_dock do draw_fx_dock(&ui, {mix_w + cr_w + 2, TOPBAR_H + 2, fx_w - 2, rows_h - 4})
		draw_preset_popup(&ui, lw, lh)
		ui.layer = .Settings
		if ui.show_settings do draw_settings(&ui, lw, lh)
		// the top bar stays usable while settings are open (its button closes them)
		ui.layer = ui.confirm != .None ? .Mixer : top_layer(&ui)
		draw_topbar(&ui, lw)
		ui.layer = .Confirm
		draw_confirm(&ui, lw, lh)
		draw_tip(&ui, lw, lh)
		rl.EndMode2D()
		sync.mutex_unlock(&app.lock) // EndDrawing can block for long while the window is hidden
		rl.EndDrawing()
		free_all(context.temp_allocator)
		// pace by sleeping (raylib's limiter busy-waits part of every frame)
		budget := 1.0 / (rl.GetTime() - last_input < ACTIVE_SECONDS ? FPS_ACTIVE : FPS_IDLE)
		if el := time.duration_seconds(time.tick_since(frame_start)); el < budget {
			time.sleep(time.Duration((budget - el) * f64(time.Second)))
		}
	}
}
