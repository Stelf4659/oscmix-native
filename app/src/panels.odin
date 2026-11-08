package oscmix_native

// TotalMix-style channel panels that open beside their strip: settings (cog),
// EQ (+ low cut), dynamics (+ auto level), room EQ (outputs); and the FX dock
// (control room, reverb, echo). Stereo pairs are edited through the left
// channel; the interface applies settings to both sides itself.
// Value ranges follow OscMix Web's parameter table for the same engine.

import "core:fmt"
import "core:math"
import "core:strings"
import rl "../raylib"

// --- value slider ------------------------------------------------------------

Slider :: struct {
	min, max, step, def: f32,
	unit:                string,
	decimals:            int,
	log:                 bool, // logarithmic travel (frequencies)
	bipolar:             bool, // fill from 0, show "+"
	off_label:           string, // shown at the minimum (e.g. "off")
}

SL_FREQ := Slider{min = 20, max = 20000, step = 1, def = 1000, unit = "Hz", log = true}
SL_LC_FREQ := Slider{min = 20, max = 500, step = 1, def = 100, unit = "Hz", log = true}
SL_EQ_GAIN := Slider{min = -20, max = 20, step = 0.5, def = 0, unit = "dB", decimals = 1, bipolar = true}
SL_Q := Slider{min = 0.4, max = 9.9, step = 0.1, def = 1, unit = "Q", decimals = 1}
SL_FX := Slider{min = -65, max = 0, step = 0.5, def = -65, unit = "dB", decimals = 1, off_label = "off"}
SL_WIDTH := Slider{min = -1, max = 1, step = 0.01, def = 1, decimals = 2, bipolar = true}
SL_DYN_GAIN := Slider{min = -30, max = 30, step = 0.5, def = 0, unit = "dB", decimals = 1, bipolar = true}
SL_ATTACK := Slider{min = 0, max = 200, step = 1, def = 10, unit = "ms"}
SL_RELEASE := Slider{min = 100, max = 999, step = 1, def = 300, unit = "ms"}
SL_COMP_THRES := Slider{min = -60, max = 0, step = 0.5, def = -30, unit = "dB", decimals = 1}
SL_EXP_THRES := Slider{min = -99, max = 20, step = 0.5, def = -60, unit = "dB", decimals = 1}
SL_RATIO := Slider{min = 1, max = 10, step = 0.1, def = 1, unit = ":1", decimals = 1}
SL_AL_MAXGAIN := Slider{min = 0, max = 18, step = 0.5, def = 6, unit = "dB", decimals = 1}
SL_AL_HEADROOM := Slider{min = 3, max = 12, step = 0.5, def = 6, unit = "dB", decimals = 1}
SL_AL_RISE := Slider{min = 0.1, max = 9.9, step = 0.1, def = 0.5, unit = "s", decimals = 1}
SL_DELAY := Slider{min = 0, max = 42.5, step = 0.01, def = 0, unit = "ms", decimals = 2}
SL_CAL_GAIN := Slider{min = -24, max = 3, step = 0.1, def = 0, unit = "dB", decimals = 1, bipolar = true}
// FX and control room
SL_RV_PREDELAY := Slider{min = 0, max = 999, step = 1, def = 35, unit = "ms"}
SL_RV_LOWCUT := Slider{min = 20, max = 500, step = 1, def = 80, unit = "Hz", log = true}
SL_RV_SCALE := Slider{min = 0.5, max = 3, step = 0.01, def = 1, decimals = 2}
SL_RV_ATTACK := Slider{min = 5, max = 400, step = 1, def = 100, unit = "ms"}
SL_RV_HOLD := Slider{min = 5, max = 400, step = 1, def = 80, unit = "ms"}
SL_RV_RELEASE := Slider{min = 5, max = 500, step = 1, def = 200, unit = "ms"}
SL_RV_HIGHCUT := Slider{min = 2000, max = 20000, step = 100, def = 18000, unit = "Hz", log = true}
SL_RV_TIME := Slider{min = 0.1, max = 4.9, step = 0.1, def = 1.5, unit = "s", decimals = 1}
SL_RV_SMOOTH := Slider{min = 0, max = 100, step = 1, def = 100, unit = "%"}
SL_FX_WIDTH := Slider{min = -1, max = 1, step = 0.01, def = 0.8, decimals = 2, bipolar = true}
SL_FX_VOLUME := Slider{min = -65, max = 6, step = 0.1, def = -3, unit = "dB", decimals = 1}
SL_ECHO_DELAY := Slider{min = 0, max = 2, step = 0.01, def = 0.5, unit = "s", decimals = 2}
SL_ECHO_FEEDBACK := Slider{min = 0, max = 100, step = 1, def = 20, unit = "%"}
SL_DIM := Slider{min = -65, max = 0, step = 0.5, def = -20, unit = "dB", decimals = 1}
SL_RECALL := Slider{min = -65, max = 0, step = 0.5, def = -10, unit = "dB", decimals = 1}

CROSSFEED_OPTIONS := []string{"Off", "1", "2", "3", "4", "5"}
SLOPE_OPTIONS := []string{"6 dB/oct", "12 dB/oct", "18 dB/oct", "24 dB/oct"}
REVERB_TYPES := []string {
	"Small Room", "Medium Room", "Large Room", "Walls", "Shorty", "Attack", "Swagger", "Old School",
	"Echoistic", "8plus9", "Grand Wide", "Thicker", "Envelope", "Gated", "Space",
}
REVERB_ENVELOPE :: 12
REVERB_GATED :: 13
REVERB_SPACE :: 14
ECHO_TYPES := []string{"Stereo Echo", "Stereo Cross", "Pong Echo"}
ECHO_HIGHCUT := []string{"Off", "16 kHz", "12 kHz", "8 kHz", "4 kHz", "2 kHz"}

// Preamp gain range of an input, as reported by the engine (/input/N/gainrange: min, max, step).
gain_slider :: proc(app: ^App, ch: int) -> (s: Slider, ok: bool) {
	e := app.st.vals[fmt.tprintf("/input/%d/gainrange", ch)] or_return
	if e.n < 2 || e.f[1] <= e.f[0] do return
	step: f32 = e.n >= 3 && e.f[2] > 0 ? e.f[2] : 1
	return Slider{min = e.f[0], max = e.f[1], step = step, def = e.f[0], unit = "dB", decimals = step < 1 ? 1 : 0}, true
}

slider_pos :: proc(s: Slider, v: f32) -> f32 {
	if s.log do return clamp(math.ln(max(v, s.min) / s.min) / math.ln(s.max / s.min), 0, 1)
	return clamp((v - s.min) / (s.max - s.min), 0, 1)
}

slider_quantize :: proc(s: Slider, v: f32) -> f32 {
	v := clamp(v, s.min, s.max)
	if s.step > 0 do v = s.min + math.round((v - s.min) / s.step) * s.step
	p := math.pow(f32(10), f32(s.decimals))
	if s.step >= 1 do p = 1
	return clamp(math.round(v * p) / p, s.min, s.max)
}

slider_value :: proc(s: Slider, p: f32) -> f32 {
	p := clamp(p, 0, 1)
	return slider_quantize(s, s.log ? s.min * math.pow(s.max / s.min, p) : s.min + p * (s.max - s.min))
}

fmt_value :: proc(s: Slider, v: f32) -> string {
	if s.off_label != "" && v <= s.min do return s.off_label
	if s.unit == "Hz" {
		if v >= 10000 do return fmt.tprintf("%.1f kHz", v / 1000)
		if v >= 1000 do return fmt.tprintf("%.2f kHz", v / 1000)
		return fmt.tprintf("%d Hz", int(v + 0.5))
	}
	num: string
	switch s.decimals {
	case 0:
		num = fmt.tprintf("%.0f", v)
	case 1:
		num = fmt.tprintf("%.1f", v)
	case:
		num = fmt.tprintf("%.2f", v)
	}
	if s.bipolar && v > 0 do num = fmt.tprintf("+%s", num)
	if s.unit == "" do return num
	if s.unit == ":1" do return fmt.tprintf("%s:1", num)
	if s.unit == "Q" do return fmt.tprintf("Q %s", num)
	return fmt.tprintf("%s %s", num, s.unit)
}

// Horizontal value slider. Drag (Shift = fine), wheel = one step (Shift: finer
// for frequencies), double-click = default.
slider :: proc(ui: ^UI, id: u64, r: rl.Rectangle, s: Slider, v: f32, size: f32 = FONT_SMALL) -> (out: f32, changed: bool) {
	out = v
	mouse := rl.GetMousePosition()
	shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
	if interactive(ui, r) {
		if rl.IsMouseButtonPressed(.LEFT) {
			if double_click(ui, id) {
				out = s.def
			} else {
				ui.active, ui.drag_origin, ui.drag_value = id, mouse, slider_pos(s, v)
			}
		} else if wheel := rl.GetMouseWheelMove(); wheel != 0 && !rl.IsKeyDown(.LEFT_CONTROL) {
			ui.wheel_used = true
			if s.log {
				out = slider_quantize(s, v * math.pow(shift ? f32(1.005) : f32(1.04), wheel))
				if out == v do out = slider_quantize(s, v + math.sign(wheel) * s.step)
			} else {
				step := s.step
				if !shift && (s.max - s.min) / step > 150 do step *= 5
				out = slider_quantize(s, v + wheel * step)
			}
		}
	}
	if ui.active == id {
		if rl.IsMouseButtonDown(.LEFT) {
			scale: f32 = shift ? 0.1 : 1
			out = slider_value(s, ui.drag_value + (mouse.x - ui.drag_origin.x) / r.width * scale)
		} else {
			ui.active = 0
		}
	}
	changed = out != v

	rl.DrawRectangleRounded(r, 0.3, 4, COL_TRACK)
	p := slider_pos(s, out)
	p0: f32 = s.bipolar ? slider_pos(s, 0) : 0
	fill := rl.Rectangle{r.x + r.width * min(p, p0), r.y + 1, r.width * abs(p - p0), r.height - 2}
	rl.DrawRectangleRec(fill, ui.active == id ? COL_ACCENT : rl.Color{52, 92, 150, 255})
	text_centered(ui, fmt_value(s, out), r, size)
	return
}

// --- form layout ------------------------------------------------------------------

ED_ROW_H :: 24
ED_ROW_GAP :: 5

// Layout cursor over one parameter group (a channel, or /reverb etc.).
Ed :: struct {
	ui:      ^UI,
	x, y, w: f32,
	label_w: f32,
	base:    string, // "/input/8", "/reverb", ...
	row:     Row,
	ch:      int,
	stereo:  bool,
}

// side 1 = right channel of a stereo pair (channel bases only).
ed_addr :: proc(e: ^Ed, sub: string, side := 0) -> string {
	if side == 0 do return fmt.tprintf("%s/%s", e.base, sub)
	return fmt.tprintf("/%s/%d/%s", ROW_BUS[e.row], e.ch + side, sub)
}
ed_has :: proc(e: ^Ed, sub: string) -> bool {return state_has(&e.ui.app.st, ed_addr(e, sub))}
ed_get :: proc(e: ^Ed, sub: string, def: f32 = 0) -> f32 {return state_get(&e.ui.app.st, ed_addr(e, sub), def)}
ed_set :: proc(e: ^Ed, sub: string, v: f32) {app_send(e.ui.app, ed_addr(e, sub), v)}

ed_next :: proc(e: ^Ed) {e.y += ED_ROW_H + ED_ROW_GAP}

ed_label :: proc(e: ^Ed, label: string) {
	text(e.ui, label, e.x, e.y + (ED_ROW_H - FONT) / 2, FONT, COL_DIM)
}

// Field to the right of the label.
ed_field :: proc(e: ^Ed) -> rl.Rectangle {return {e.x + e.label_w, e.y, e.w - e.label_w, ED_ROW_H}}

ed_slider :: proc(e: ^Ed, label, sub: string, s: Slider) {
	if !ed_has(e, sub) do return
	ed_label(e, label)
	addr := ed_addr(e, sub)
	if v, changed := slider(e.ui, addr_id(addr), ed_field(e), s, state_get(&e.ui.app.st, addr, s.def)); changed {
		app_send(e.ui.app, addr, v)
	}
	ed_next(e)
}

// Segmented choice (few options).
ed_choice :: proc(e: ^Ed, label, sub: string, options: []string) {
	if !ed_has(e, sub) || len(options) == 0 do return
	ed_label(e, label)
	f := ed_field(e)
	cur := int(ed_get(e, sub))
	n := f32(len(options))
	bw := (f.width - (n - 1) * 3) / n
	for o, i in options {
		if button(e.ui, {f.x + f32(i) * (bw + 3), f.y, bw, f.height}, o, cur == i, COL_ACCENT, FONT_SMALL) && cur != i {
			ed_set(e, sub, f32(i))
		}
	}
	ed_next(e)
}

// Cycle button choice (many options).
ed_cycle :: proc(e: ^Ed, label, sub: string, options: []string) {
	if !ed_has(e, sub) do return
	ed_label(e, label)
	cycle_param(e.ui, ed_field(e), ed_addr(e, sub), options, FONT)
	ed_next(e)
}

Ed_Toggle :: struct {
	label, sub: string,
	color:      rl.Color,
	side:       int, // 1 = right channel of a stereo pair
}

// Grid of on/off buttons; entries the channel lacks are skipped.
ed_toggles :: proc(e: ^Ed, items: []Ed_Toggle, per_row := 2) {
	bw := (e.w - f32(per_row - 1) * 5) / f32(per_row)
	k := 0
	for it in items {
		addr := ed_addr(e, it.sub, it.side)
		if !state_has(&e.ui.app.st, addr) do continue
		if k > 0 && k % per_row == 0 do ed_next(e)
		toggle_param(e.ui, {e.x + f32(k % per_row) * (bw + 5), e.y, bw, ED_ROW_H}, it.label, addr, it.color, FONT)
		k += 1
	}
	if k > 0 do ed_next(e)
}

// Dock section: rule, title and optional on/off switch. False if absent.
ed_section :: proc(e: ^Ed, title: string, enable_sub := "") -> bool {
	if enable_sub != "" && !ed_has(e, enable_sub) do return false
	e.y += 6
	rl.DrawLineEx({e.x, e.y}, {e.x + e.w, e.y}, 1, COL_BUTTON)
	e.y += 8
	text(e.ui, title, e.x, e.y + 3, FONT_HEAD)
	if enable_sub != "" {
		on := ed_get(e, enable_sub) != 0
		if button(e.ui, {e.x + e.w - 60, e.y, 60, ED_ROW_H}, on ? "ON" : "OFF", on, COL_ON, FONT_SMALL) {
			ed_set(e, enable_sub, on ? 0 : 1)
		}
	}
	e.y += ED_ROW_H + 8
	return true
}

// --- EQ graph ---------------------------------------------------------------------------

Eq_Kind :: enum {
	Bell,
	Low_Shelf,
	High_Shelf,
	High_Pass,
	Low_Pass,
}

Eq_Band :: struct {
	n:             int, // band number (1-based)
	kind:          Eq_Kind,
	freq, gain, q: f32,
}

GRAPH_RATE :: 48000.0
GRAPH_DB :: 24.0

// Band type from the engine's option names ("Bell,Shelving,High Pass,Low Pass").
eq_kind :: proc(types: []string, idx: int, high: bool) -> Eq_Kind {
	if idx < 0 || idx >= len(types) do return .Bell
	switch types[idx] {
	case "Shelving":
		return high ? .High_Shelf : .Low_Shelf
	case "High Pass":
		return .High_Pass
	case "Low Pass":
		return .Low_Pass
	}
	return .Bell
}

// Magnitude in dB of an RBJ biquad for the band at frequency f.
band_db :: proc(b: Eq_Band, f: f32) -> f64 {
	w0 := 2 * math.PI * f64(b.freq) / GRAPH_RATE
	cw, sw := math.cos(w0), math.sin(w0)
	alpha := sw / (2 * max(f64(b.q), 0.1))
	A := math.pow(10, f64(b.gain) / 40)
	sa := 2 * math.sqrt(A) * alpha
	b0, b1, b2, a0, a1, a2: f64
	switch b.kind {
	case .Bell:
		b0, b1, b2 = 1 + alpha * A, -2 * cw, 1 - alpha * A
		a0, a1, a2 = 1 + alpha / A, -2 * cw, 1 - alpha / A
	case .Low_Shelf:
		b0 = A * ((A + 1) - (A - 1) * cw + sa)
		b1 = 2 * A * ((A - 1) - (A + 1) * cw)
		b2 = A * ((A + 1) - (A - 1) * cw - sa)
		a0 = (A + 1) + (A - 1) * cw + sa
		a1 = -2 * ((A - 1) + (A + 1) * cw)
		a2 = (A + 1) + (A - 1) * cw - sa
	case .High_Shelf:
		b0 = A * ((A + 1) + (A - 1) * cw + sa)
		b1 = -2 * A * ((A - 1) + (A + 1) * cw)
		b2 = A * ((A + 1) + (A - 1) * cw - sa)
		a0 = (A + 1) - (A - 1) * cw + sa
		a1 = 2 * ((A - 1) - (A + 1) * cw)
		a2 = (A + 1) - (A - 1) * cw - sa
	case .High_Pass:
		b0, b1, b2 = (1 + cw) / 2, -(1 + cw), (1 + cw) / 2
		a0, a1, a2 = 1 + alpha, -2 * cw, 1 - alpha
	case .Low_Pass:
		b0, b1, b2 = (1 - cw) / 2, 1 - cw, (1 - cw) / 2
		a0, a1, a2 = 1 + alpha, -2 * cw, 1 - alpha
	}
	w := 2 * math.PI * f64(f) / GRAPH_RATE
	c1, s1, c2, s2 := math.cos(w), math.sin(w), math.cos(2 * w), math.sin(2 * w)
	nr, ni := b0 + b1 * c1 + b2 * c2, b1 * s1 + b2 * s2
	dr, di := a0 + a1 * c1 + a2 * c2, a1 * s1 + a2 * s2
	return 10 * math.log10(max(nr * nr + ni * ni, 1e-20) / max(dr * dr + di * di, 1e-20))
}

// Low cut as drawn by OscMix Web: (slope+1) cascaded first-order sections.
lowcut_db :: proc(freq: f32, slope: int, f: f32) -> f64 {
	K := [4]f64{1, 0.655, 0.528, 0.457}
	order := clamp(slope, 0, 3)
	fc := f64(freq) * K[order]
	f2 := f64(f) * f64(f)
	y: f64 = 1
	for _ in 0 ..= order do y *= f2 / (f2 + fc * fc)
	return 10 * math.log10(max(y, 1e-10))
}

Graph_Lowcut :: struct {
	present, on: bool,
	freq:        f32,
	slope:       int,
}

// Option names for band n of an EQ family, e.g. /eq/band1types; nil = fixed Bell.
band_types :: proc(app: ^App, family: string, n: int) -> []string {
	return option_list(app, fmt.tprintf("/%s/band%dtypes", family, n))
}

eq_bands :: proc(e: ^Ed, family: string, nbands: int) -> []Eq_Band {
	out := make([dynamic]Eq_Band, context.temp_allocator)
	for n in 1 ..= nbands {
		pre := fmt.tprintf("%s/band%d", family, n)
		if !ed_has(e, fmt.tprintf("%sfreq", pre)) do continue
		append(&out, Eq_Band {
			n    = n,
			kind = eq_kind(band_types(e.ui.app, family, n), int(ed_get(e, fmt.tprintf("%stype", pre))), n > 1),
			freq = ed_get(e, fmt.tprintf("%sfreq", pre), 1000),
			gain = ed_get(e, fmt.tprintf("%sgain", pre)),
			q    = ed_get(e, fmt.tprintf("%sq", pre), 1),
		})
	}
	return out[:]
}

eq_response :: proc(bands: []Eq_Band, lc: Graph_Lowcut, f: f32) -> f64 {
	db: f64 = 0
	for b in bands do db += band_db(b, f)
	if lc.on do db += lowcut_db(lc.freq, lc.slope, f)
	return db
}

@(private = "file")
graph_x :: proc(r: rl.Rectangle, f: f32) -> f32 {return r.x + r.width * math.ln(f / 20) / math.ln(f32(1000))}
@(private = "file")
graph_y :: proc(r: rl.Rectangle, db: f64) -> f32 {
	return r.y + r.height / 2 - f32(clamp(db, -GRAPH_DB, GRAPH_DB) / GRAPH_DB) * (r.height / 2 - 4)
}

// Draggable graph node: drag moves it, wheel / double-click are reported.
Node_Input :: struct {
	dragging: bool,
	delta:    rl.Vector2, // mouse movement since the press
	start:    [2]f32, // values captured at the press
	wheel:    f32,
	double:   bool,
}

graph_node :: proc(ui: ^UI, id: u64, c: rl.Vector2, start: [2]f32, label: string, col: rl.Color) -> (in_: Node_Input) {
	hit := rl.Rectangle{c.x - 10, c.y - 10, 20, 20}
	mouse := rl.GetMousePosition()
	hot := interactive(ui, hit)
	if hot {
		if rl.IsMouseButtonPressed(.LEFT) {
			if double_click(ui, id) {
				in_.double = true
			} else {
				ui.active, ui.drag_origin, ui.drag_value, ui.drag_value2 = id, mouse, start[0], start[1]
			}
		} else if w := rl.GetMouseWheelMove(); w != 0 && !rl.IsKeyDown(.LEFT_CONTROL) {
			ui.wheel_used = true
			in_.wheel = w
		}
	}
	if ui.active == id {
		if rl.IsMouseButtonDown(.LEFT) {
			in_.dragging = true
			in_.delta = mouse - ui.drag_origin
			in_.start = {ui.drag_value, ui.drag_value2}
		} else {
			ui.active = 0
		}
	}
	big := hot || ui.active == id
	rl.DrawCircleV(c, big ? 9 : 7.5, col)
	text_centered(ui, label, {c.x - 8, c.y - 8, 16, 16}, FONT_TINY, COL_TRACK)
	return
}

// Frequency response with draggable band nodes: drag = frequency (+ gain for
// bell/shelf), wheel = Q, double-click = 0 dB. The low cut node ("L") moves
// its frequency.
eq_graph :: proc(e: ^Ed, r: rl.Rectangle, family: string, nbands: int, with_lowcut: bool) {
	ui := e.ui
	bands := eq_bands(e, family, nbands)
	on := ed_get(e, fmt.tprintf("%s/enable", family)) != 0
	lc: Graph_Lowcut
	if with_lowcut && ed_has(e, "lowcut/freq") {
		lc = {present = true, on = ed_get(e, "lowcut/enable") != 0, freq = ed_get(e, "lowcut/freq", 20), slope = int(ed_get(e, "lowcut/slope"))}
	}
	shown := bands if on else nil

	rl.DrawRectangleRounded(r, 0.04, 4, COL_TRACK)
	grid := rl.Color{44, 48, 56, 255}
	for f in ([]f32{50, 100, 200, 500, 1000, 2000, 5000, 10000}) {
		x := graph_x(r, f)
		rl.DrawLineEx({x, r.y}, {x, r.y + r.height}, 1, grid)
	}
	for db in ([]f64{-12, 12}) do rl.DrawLineEx({r.x, graph_y(r, db)}, {r.x + r.width, graph_y(r, db)}, 1, grid)
	rl.DrawLineEx({r.x, graph_y(r, 0)}, {r.x + r.width, graph_y(r, 0)}, 1, COL_BUTTON_HOT)
	for l in ([]struct {f: f32, s: string}{{100, "100"}, {1000, "1k"}, {10000, "10k"}}) {
		text(ui, l.s, graph_x(r, l.f) + 3, r.y + r.height - FONT_TINY - 3, FONT_TINY, COL_DIM)
	}
	text(ui, "+12", r.x + 4, graph_y(r, 12) - FONT_TINY - 1, FONT_TINY, COL_DIM)
	text(ui, "-12", r.x + 4, graph_y(r, -12) + 1, FONT_TINY, COL_DIM)

	N :: 160
	pts: [N]rl.Vector2
	for i in 0 ..< N {
		f := 20 * math.pow(f32(1000), f32(i) / (N - 1))
		pts[i] = {graph_x(r, f), graph_y(r, eq_response(shown, lc, f))}
	}
	rl.DrawSplineLinear(&pts[0], N, 2, on || lc.on ? COL_ON : COL_DIM)

	gain_per_px := GRAPH_DB / (r.height / 2 - 4)
	freq_at :: proc(start: f32, dx, width: f32, s: Slider) -> f32 {
		return slider_quantize(s, start * math.pow(f32(1000), dx / width))
	}
	if lc.present {
		c := rl.Vector2{graph_x(r, lc.freq), graph_y(r, eq_response(shown, lc, lc.freq))}
		addr := ed_addr(e, "lowcut/freq")
		n := graph_node(ui, addr_id(addr), c, {lc.freq, 0}, "L", lc.on ? COL_ON : COL_DIM)
		if n.dragging {
			if f := freq_at(n.start[0], n.delta.x, r.width, SL_LC_FREQ); f != lc.freq do app_send(ui.app, addr, f)
		}
	}
	for b in bands {
		pre := fmt.tprintf("%s/band%d", family, b.n)
		c := rl.Vector2{graph_x(r, b.freq), graph_y(r, eq_response(shown, lc, b.freq))}
		n := graph_node(ui, addr_id(ed_addr(e, fmt.tprintf("%s#node", pre))), c, {b.freq, b.gain}, fmt.tprintf("%d", b.n), on ? COL_ON : COL_DIM)
		has_gain := b.kind != .High_Pass && b.kind != .Low_Pass
		if n.dragging {
			if f := freq_at(n.start[0], n.delta.x, r.width, SL_FREQ); f != b.freq do ed_set(e, fmt.tprintf("%sfreq", pre), f)
			if has_gain {
				if g := slider_quantize(SL_EQ_GAIN, n.start[1] - n.delta.y * gain_per_px); g != b.gain do ed_set(e, fmt.tprintf("%sgain", pre), g)
			}
		}
		if n.wheel != 0 {
			if q := slider_quantize(SL_Q, b.q + n.wheel * 0.1); q != b.q do ed_set(e, fmt.tprintf("%sq", pre), q)
		}
		if n.double && has_gain do ed_set(e, fmt.tprintf("%sgain", pre), 0)
	}
}

// One band row: number, type, frequency, gain, Q.
ed_band :: proc(e: ^Ed, family: string, n: int) {
	pre := fmt.tprintf("%s/band%d", family, n)
	fsub := fmt.tprintf("%sfreq", pre)
	if !ed_has(e, fsub) do return
	ed_label(e, fmt.tprintf("%d", n))
	x := e.x + 20
	TW :: 82
	tsub := fmt.tprintf("%stype", pre)
	if types := band_types(e.ui.app, family, n); len(types) > 0 && ed_has(e, tsub) {
		cycle_param(e.ui, {x, e.y, TW, ED_ROW_H}, ed_addr(e, tsub), types, FONT_SMALL)
	} else {
		text_centered(e.ui, "Bell", {x, e.y, TW, ED_ROW_H}, FONT_SMALL, COL_DIM)
	}
	x += TW + 5
	sw := (e.x + e.w - x - 10) / 3
	subs := [3]string{fsub, fmt.tprintf("%sgain", pre), fmt.tprintf("%sq", pre)}
	sliders := [3]Slider{SL_FREQ, SL_EQ_GAIN, SL_Q}
	for i in 0 ..< 3 {
		addr := ed_addr(e, subs[i])
		r := rl.Rectangle{x + f32(i) * (sw + 5), e.y, sw, ED_ROW_H}
		if v, changed := slider(e.ui, addr_id(addr), r, sliders[i], state_get(&e.ui.app.st, addr, sliders[i].def)); changed {
			app_send(e.ui.app, addr, v)
		}
	}
	ed_next(e)
}

// --- dynamics graph -----------------------------------------------------------------

DYN_MIN :: -65.0
DYN_MAX :: 5.0
GR_RANGE :: 24.0

Dyn :: struct {
	gain, comp_thres, comp_ratio, exp_thres, exp_ratio: f32,
}

// Static transfer curve (as OscMix Web draws it): expander below its
// threshold, compressor above its threshold, then make-up gain.
dyn_transfer :: proc(d: Dyn, x: f32) -> f32 {
	y := x
	if x < d.exp_thres do y = d.exp_thres - (d.exp_thres - x) * d.exp_ratio
	if x > d.comp_thres do y = d.comp_thres + (x - d.comp_thres) / max(d.comp_ratio, 1)
	return y + d.gain
}

// Pre-FX level of the channel (both sides of a pair), dBFS.
channel_level :: proc(e: ^Ed) -> f32 {
	pk, rms := level_of(e.ui.app, e.row, e.ch)
	lvl := max(pk, rms)
	if e.stereo {
		pk2, rms2 := level_of(e.ui.app, e.row, e.ch + 1)
		lvl = max(lvl, pk2, rms2)
	}
	return lvl
}

// Transfer curve with draggable C (compressor) and E (expander/gate) nodes:
// drag sideways = threshold, up/down = ratio, wheel = ratio. When dynamics
// are on, the live input level rides the curve and the estimated gain change
// is returned (static curve; attack/release are not modelled).
dyn_graph :: proc(e: ^Ed, r: rl.Rectangle) -> (gr: f32, live: bool) {
	ui := e.ui
	d := Dyn {
		gain       = ed_get(e, "dynamics/gain"),
		comp_thres = ed_get(e, "dynamics/compthres", -30),
		comp_ratio = ed_get(e, "dynamics/compratio", 1),
		exp_thres  = ed_get(e, "dynamics/expthres", -60),
		exp_ratio  = ed_get(e, "dynamics/expratio", 1),
	}
	on := ed_get(e, "dynamics/enable") != 0
	px :: proc(r: rl.Rectangle, db: f32) -> f32 {return r.x + (clamp(db, DYN_MIN, DYN_MAX) - DYN_MIN) / (DYN_MAX - DYN_MIN) * r.width}
	py :: proc(r: rl.Rectangle, db: f32) -> f32 {return r.y + r.height - (clamp(db, DYN_MIN, DYN_MAX) - DYN_MIN) / (DYN_MAX - DYN_MIN) * r.height}

	rl.DrawRectangleRounded(r, 0.04, 4, COL_TRACK)
	grid := rl.Color{44, 48, 56, 255}
	for db: f32 = -60; db <= 0; db += 10 {
		rl.DrawLineEx({px(r, db), r.y}, {px(r, db), r.y + r.height}, 1, db == 0 ? COL_BUTTON_HOT : grid)
		rl.DrawLineEx({r.x, py(r, db)}, {r.x + r.width, py(r, db)}, 1, db == 0 ? COL_BUTTON_HOT : grid)
	}
	rl.DrawLineEx({px(r, DYN_MIN), py(r, DYN_MIN)}, {px(r, DYN_MAX), py(r, DYN_MAX)}, 1, COL_BUTTON)
	for db in ([]f32{-60, -40, -20}) do text(ui, fmt.tprintf("%d", int(db)), px(r, db) + 2, r.y + r.height - FONT_TINY - 2, FONT_TINY, COL_DIM)
	text(ui, "in", r.x + r.width - 16, r.y + r.height - FONT_TINY - 2, FONT_TINY, COL_DIM)
	text(ui, "out", r.x + 3, r.y + 3, FONT_TINY, COL_DIM)

	N :: 120
	pts: [N]rl.Vector2
	for i in 0 ..< N {
		x := DYN_MIN + (DYN_MAX - DYN_MIN) * f32(i) / (N - 1)
		pts[i] = {px(r, x), py(r, dyn_transfer(d, x))}
	}
	col := on ? COL_ON : COL_DIM
	rl.DrawSplineLinear(&pts[0], N, 2, col)

	// live input level on the curve
	lvl := channel_level(e)
	if on && lvl > DYN_MIN {
		live = true
		gr = dyn_transfer(d, lvl) - d.gain - lvl
		y := py(r, dyn_transfer(d, lvl))
		rl.DrawLineEx({px(r, lvl), y}, {px(r, lvl), r.y + r.height}, 1, {230, 200, 60, 90})
		rl.DrawCircleV({px(r, lvl), y}, 5, rl.WHITE)
	}

	// threshold/ratio nodes
	ratio_per_px: f32 = (SL_RATIO.max - SL_RATIO.min) / 150
	db_per_px := (DYN_MAX - DYN_MIN) / r.width
	Node :: struct {thres, ratio: f32, tsub, rsub, label: string, ts: Slider}
	nodes := [2]Node {
		{d.comp_thres, d.comp_ratio, "dynamics/compthres", "dynamics/compratio", "C", SL_COMP_THRES},
		{d.exp_thres, d.exp_ratio, "dynamics/expthres", "dynamics/expratio", "E", SL_EXP_THRES},
	}
	for nd in nodes {
		c := rl.Vector2{px(r, nd.thres), py(r, dyn_transfer(d, nd.thres))}
		n := graph_node(ui, addr_id(ed_addr(e, fmt.tprintf("%s#node", nd.tsub))), c, {nd.thres, nd.ratio}, nd.label, col)
		if n.dragging {
			if t := slider_quantize(nd.ts, n.start[0] + n.delta.x * db_per_px); t != nd.thres do ed_set(e, nd.tsub, t)
			if q := slider_quantize(SL_RATIO, n.start[1] - n.delta.y * ratio_per_px); q != nd.ratio do ed_set(e, nd.rsub, q)
		}
		if n.wheel != 0 {
			if q := slider_quantize(SL_RATIO, nd.ratio + n.wheel * 0.2); q != nd.ratio do ed_set(e, nd.rsub, q)
		}
	}
	return
}

// Gain change meter: down from the top for reduction, up from the bottom
// for gain; dimmed when there is no live signal.
gr_meter :: proc(ui: ^UI, r: rl.Rectangle, gr: f32, live: bool) {
	text_centered(ui, "GR", {r.x - 6, r.y - 16, r.width + 12, 14}, FONT_TINY, COL_DIM)
	rl.DrawRectangleRec(r, COL_TRACK)
	g := clamp(gr, -GR_RANGE, GR_RANGE)
	h := abs(g) / GR_RANGE * r.height
	if live && g < -0.05 do rl.DrawRectangleRec({r.x, r.y, r.width, h}, COL_DYN)
	if live && g > 0.05 do rl.DrawRectangleRec({r.x, r.y + r.height - h, r.width, h}, COL_GREEN)
	for db in ([]f32{6, 12, 18}) {
		y := r.y + db / GR_RANGE * r.height
		rl.DrawLineEx({r.x, y}, {r.x + r.width, y}, 1, COL_BUTTON)
	}
	label := live ? fmt.tprintf("%.1f", g) : "-"
	text_centered(ui, label, {r.x - 14, r.y + r.height + 2, r.width + 28, 14}, FONT_TINY, COL_DIM)
}

// --- panels ------------------------------------------------------------------------------

Panel_Kind :: enum u8 {
	Settings,
	EQ,
	Dynamics,
	Room_EQ,
}
Panel_Set :: bit_set[Panel_Kind;u8]

PANEL_TITLE := [Panel_Kind]string {
	.Settings = "Settings",
	.EQ       = "EQ",
	.Dynamics = "Dynamics",
	.Room_EQ  = "Room EQ",
}
PANEL_W := [Panel_Kind]f32 {
	.Settings = 290,
	.EQ       = 450,
	.Dynamics = 490,
	.Room_EQ  = 450,
}
PANEL_HEADER_H :: 36
PANEL_GAP :: 4
COL_PANEL :: rl.Color{36, 40, 48, 255}

strip_key :: proc(row: Row, ch: int) -> u32 {return u32(row) << 16 | u32(ch)}

panel_open :: proc(ui: ^UI, row: Row, ch: int, kind: Panel_Kind) -> bool {
	return kind in ui.panels[strip_key(row, ch)]
}

// Opens or closes a panel beside the strip; opening scrolls it into view.
toggle_panel :: proc(ui: ^UI, row: Row, ch: int, kind: Panel_Kind) {
	key := strip_key(row, ch)
	set := ui.panels[key] ~ {kind}
	if set == {} {
		delete_key(&ui.panels, key)
	} else {
		ui.panels[key] = set
	}
	if kind in set && !(row == .Output && is_cr_output(ui, ch)) {
		ui.reveal = Reveal{row = row, ch = ch, kind = kind, pending = true}
	}
}

Header_Toggle :: struct {
	label, sub: string,
}

// Enable switches in each panel's header, right to left.
PANEL_TOGGLES := [Panel_Kind][]Header_Toggle {
	.Settings = {},
	.EQ       = {{"EQ", "eq/enable"}, {"Low Cut", "lowcut/enable"}},
	.Dynamics = {{"Dyn", "dynamics/enable"}, {"Auto Level", "autolevel/enable"}},
	.Room_EQ  = {{"Room EQ", "roomeq/enable"}},
}

draw_panel :: proc(ui: ^UI, row: Row, ch: int, kind: Panel_Kind, r: rl.Rectangle) {
	app := ui.app
	e := channel_ed(ui, row, ch)
	rl.DrawRectangleRounded(r, 0.025, 4, COL_PANEL)
	rl.DrawRectangleRoundedLinesEx(r, 0.025, 4, 1, COL_BUTTON_HOT)

	// header: title, channel name, enable switches, close
	hx := r.x + 10
	text(ui, PANEL_TITLE[kind], hx, r.y + 10, FONT_HEAD)
	name_x := hx + text_width(ui, PANEL_TITLE[kind], FONT_HEAD) + 10
	bx := r.x + r.width - 8 - 28
	if button(ui, {bx, r.y + 6, 28, 24}, "×") {
		toggle_panel(ui, row, ch, kind)
		return
	}
	for t in PANEL_TOGGLES[kind] {
		if !ed_has(&e, t.sub) do continue
		bw := text_width(ui, t.label, FONT) + 22
		bx -= bw + 5
		on := ed_get(&e, t.sub) != 0
		if button(ui, {bx, r.y + 6, bw, 24}, t.label, on, COL_ON, FONT) do ed_set(&e, t.sub, on ? 0 : 1)
	}
	if kind != .Settings {
		bw := text_width(ui, "Presets", FONT) + 22
		bx -= bw + 5
		anchor := rl.Rectangle{bx, r.y + 6, bw, 24}
		mine := ui.popup.open && ui.popup.row == row && ui.popup.ch == ch && ui.popup.kind == kind
		if button(ui, anchor, "Presets", mine, COL_ACCENT, FONT) {
			ui.popup = mine ? {} : Popup{open = true, row = row, ch = ch, kind = kind}
			mine = !mine
		}
		if mine do ui.popup.anchor, ui.popup.seen = anchor, true
	}
	text_fit(ui, strip_name(app, row, ch), name_x, r.y + 12, bx - name_x - 6, FONT_SMALL, COL_DIM)

	// content, scrolled vertically if it does not fit the row
	content := rl.Rectangle{r.x + 1, r.y + PANEL_HEADER_H, r.width - 2, r.height - PANEL_HEADER_H - 2}
	skey := u64(strip_key(row, ch)) << 8 | u64(kind)
	scroll := ui.panel_scroll[skey]
	prev := clip_push(ui, content)
	e.x, e.y, e.w = content.x + 10, content.y + 2 - scroll, content.width - 26
	avail := content.height - 6
	switch kind {
	case .Settings:
		switch row {
		case .Input:
			panel_input_settings(&e)
		case .Output:
			panel_output_settings(&e)
		case .Playback:
			panel_playback_settings(&e)
		}
	case .EQ:
		panel_eq(&e, avail)
	case .Dynamics:
		panel_dynamics(&e, avail)
	case .Room_EQ:
		panel_room_eq(&e, avail)
	}
	content_h := e.y + scroll - content.y + 4
	clip_pop(ui, prev)

	max_scroll := max(0, content_h - content.height)
	if interactive(ui, content) && !ui.wheel_used && !rl.IsKeyDown(.LEFT_CONTROL) {
		scroll -= rl.GetMouseWheelMove() * 50
	}
	scroll = clamp(scroll, 0, max_scroll)
	if scroll == 0 {
		delete_key(&ui.panel_scroll, skey)
	} else {
		ui.panel_scroll[skey] = scroll
	}
	if max_scroll > 0 {
		th := max(24, content.height * content.height / content_h)
		ty := content.y + (content.height - th) * scroll / max_scroll
		rl.DrawRectangleRounded({content.x + content.width - 8, ty, 4, th}, 1, 4, COL_BUTTON_HOT)
	}
}

// Name (local rename) and fader / mute group membership rows.
ed_name_groups :: proc(e: ^Ed) {
	ui := e.ui
	ed_label(e, "Name")
	if button(ui, ed_field(e), fmt.tprintf("%s  (rename)", strip_name(ui.app, e.row, e.ch)), false, COL_ACCENT, FONT_SMALL) {
		open_rename(ui, e.row, e.ch)
	}
	ed_next(e)
	bits := group_bits(ui.app, e.row, e.ch)
	kinds := e.row == .Playback ? 1 : 2 // playbacks have no mute
	for kind in 0 ..< kinds {
		ed_label(e, kind == 0 ? "Fader group" : "Mute group")
		f := ed_field(e)
		bw := (f.width - 3 * 4) / GROUPS
		for g in 0 ..< GROUPS {
			bit := uint(g + kind * 4)
			on := bits & (1 << bit) != 0
			if button(ui, {f.x + f32(g) * (bw + 4), f.y, bw, f.height}, fmt.tprintf("%d", g + 1), on, GROUP_COL[g], FONT_SMALL) {
				group_toggle(ui.app, e.row, e.ch, bit)
			}
		}
		ed_next(e)
	}
	e.y += 4
}

panel_playback_settings :: proc(e: ^Ed) {
	e.label_w = 76
	ed_name_groups(e)
	if e.stereo do ed_slider(e, "Width", "width", SL_WIDTH)
}

panel_input_settings :: proc(e: ^Ed) {
	e.label_w = 76
	ed_name_groups(e)
	toggles := make([dynamic]Ed_Toggle, context.temp_allocator)
	append(&toggles, Ed_Toggle{"48V", "48v", COL_PHANTOM, 0}, Ed_Toggle{"Hi-Z", "instrument", COL_ACCENT, 0}, Ed_Toggle{"AutoSet", "autoset", COL_ACCENT, 0})
	if e.stereo {
		append(&toggles, Ed_Toggle{"Phase L", "phase", COL_ACCENT, 0}, Ed_Toggle{"Phase R", "phase", COL_ACCENT, 1})
	} else {
		append(&toggles, Ed_Toggle{"Phase", "phase", COL_ACCENT, 0})
	}
	append(&toggles, Ed_Toggle{"M/S", "msproc", COL_ACCENT, 0}, Ed_Toggle{"Stereo", "stereo", COL_ACCENT, 0})
	ed_toggles(e, toggles[:])
	if s, ok := gain_slider(e.ui.app, e.ch); ok do ed_slider(e, "Gain", "gain", s)
	ed_choice(e, "Ref. level", "reflevel", option_list(e.ui.app, ed_addr(e, "reflevels")))
	if e.stereo do ed_slider(e, "Width", "width", SL_WIDTH)
	ed_slider(e, "FX send", "fxsend", SL_FX)
}

panel_output_settings :: proc(e: ^Ed) {
	e.label_w = 76
	ed_name_groups(e)
	toggles := make([dynamic]Ed_Toggle, context.temp_allocator)
	if e.stereo {
		append(&toggles, Ed_Toggle{"Phase L", "phase", COL_ACCENT, 0}, Ed_Toggle{"Phase R", "phase", COL_ACCENT, 1})
		append(&toggles, Ed_Toggle{"Loopback L", "loopback", COL_ACCENT, 0}, Ed_Toggle{"Loopback R", "loopback", COL_ACCENT, 1})
	} else {
		append(&toggles, Ed_Toggle{"Phase", "phase", COL_ACCENT, 0}, Ed_Toggle{"Loopback", "loopback", COL_ACCENT, 0})
	}
	append(&toggles, Ed_Toggle{"Stereo", "stereo", COL_ACCENT, 0})
	ed_toggles(e, toggles[:])
	ed_choice(e, "Ref. level", "reflevel", option_list(e.ui.app, ed_addr(e, "reflevels")))
	ed_choice(e, "Crossfeed", "crossfeed", CROSSFEED_OPTIONS)
	if ed_has(e, "balpan") {
		ed_label(e, "Balance")
		addr := ed_addr(e, "balpan")
		f := ed_field(e)
		if v, changed := pan_slider(e.ui, addr_id(addr), {f.x, f.y + 2, f.width, f.height - 4}, state_get(&e.ui.app.st, addr)); changed {
			app_send(e.ui.app, addr, v)
		}
		ed_next(e)
	}
	ed_slider(e, "FX return", "fxreturn", SL_FX)
	if ed_has(e, "roomeq/enable") {
		open := panel_open(e.ui, e.row, e.ch, .Room_EQ)
		r := rl.Rectangle{e.x, e.y + 4, e.w, ED_ROW_H + 2}
		if button(e.ui, r, open ? "Room EQ  (open)" : "Room EQ…", ed_get(e, "roomeq/enable") != 0, COL_ON, FONT) {
			toggle_panel(e.ui, e.row, e.ch, .Room_EQ)
		}
		if open do rl.DrawRectangleRoundedLinesEx(r, 0.25, 4, 2, COL_ACCENT)
		e.y += ED_ROW_H + 10
	}

	// control room: Main Out (stored in the interface) or pinned locally
	ui := e.ui
	text(ui, "Control room", e.x, e.y + 4, FONT, COL_DIM)
	e.y += 22
	half := (e.w - 5) / 2
	is_main := main_out(ui.app) == e.ch
	if button(ui, {e.x, e.y, half, ED_ROW_H}, is_main ? "Main Out" : "Make Main Out", is_main, COL_ACCENT, FONT_SMALL) && !is_main {
		ui.main_pending, ui.confirm = e.ch, .Main_Out
	}
	if !is_main {
		pinned := cr_pinned(ui, e.ch)
		if button(ui, {e.x + half + 5, e.y, half, ED_ROW_H}, pinned ? "In control room" : "Pin to control room", pinned, COL_ACCENT, FONT_SMALL) {
			cr_pin_toggle(ui, e.ch)
		}
	}
	ed_next(e)
}

panel_eq :: proc(e: ^Ed, avail: f32) {
	e.label_w = 20
	rows: f32 = ed_has(e, "lowcut/freq") ? 4 : 3
	gh := clamp(avail - rows * (ED_ROW_H + ED_ROW_GAP) - 8, 90, 260)
	eq_graph(e, {e.x, e.y, e.w, gh}, "eq", 3, true)
	e.y += gh + 8
	if ed_has(e, "lowcut/freq") {
		text(e.ui, "LC", e.x, e.y + (ED_ROW_H - FONT) / 2, FONT, COL_DIM)
		x := e.x + 20
		SW :: 92
		cycle_param(e.ui, {x, e.y, SW, ED_ROW_H}, ed_addr(e, "lowcut/slope"), SLOPE_OPTIONS, FONT_SMALL)
		addr := ed_addr(e, "lowcut/freq")
		r := rl.Rectangle{x + SW + 5, e.y, e.x + e.w - x - SW - 5, ED_ROW_H}
		if v, changed := slider(e.ui, addr_id(addr), r, SL_LC_FREQ, state_get(&e.ui.app.st, addr, 20)); changed {
			app_send(e.ui.app, addr, v)
		}
		ed_next(e)
	}
	for n in 1 ..= 3 do ed_band(e, "eq", n)
}

panel_room_eq :: proc(e: ^Ed, avail: f32) {
	e.label_w = 90
	ed_slider(e, "Delay", "delay", SL_DELAY)
	ed_slider(e, "Volume cal.", "gain", SL_CAL_GAIN)
	gh := clamp(avail - 11 * (ED_ROW_H + ED_ROW_GAP) - 8, 110, 220)
	eq_graph(e, {e.x, e.y, e.w, gh}, "roomeq", 9, false)
	e.y += gh + 8
	for n in 1 ..= 9 do ed_band(e, "roomeq", n)
}

panel_dynamics :: proc(e: ^Ed, avail: f32) {
	al_rows: f32 = ed_has(e, "autolevel/maxgain") ? 3 : 0
	s := clamp(avail - al_rows * (ED_ROW_H + ED_ROW_GAP) - 26, 120, 220)
	x0, y0 := e.x, e.y

	// left: transfer curve + gain change meter, auto level below
	gr, live := dyn_graph(e, {x0, y0, s, s})
	gr_meter(e.ui, {x0 + s + 10, y0 + 16, 12, s - 34}, gr, live)
	left_w := s + 32
	al := e^
	al.x, al.y, al.w, al.label_w = x0, y0 + s + 8, left_w, 76
	if al_rows > 0 {
		ed_slider(&al, "Max gain", "autolevel/maxgain", SL_AL_MAXGAIN)
		ed_slider(&al, "Headroom", "autolevel/headroom", SL_AL_HEADROOM)
		ed_slider(&al, "Rise time", "autolevel/risetime", SL_AL_RISE)
	}

	// right: compressor / expander parameters
	col := e^
	col.x = x0 + left_w + 14
	col.w = e.x + e.w - col.x
	col.y, col.label_w = y0, 84
	ed_slider(&col, "Gain", "dynamics/gain", SL_DYN_GAIN)
	ed_slider(&col, "Attack", "dynamics/attack", SL_ATTACK)
	ed_slider(&col, "Release", "dynamics/release", SL_RELEASE)
	ed_slider(&col, "Comp thr.", "dynamics/compthres", SL_COMP_THRES)
	ed_slider(&col, "Comp ratio", "dynamics/compratio", SL_RATIO)
	ed_slider(&col, "Gate thr.", "dynamics/expthres", SL_EXP_THRES)
	ed_slider(&col, "Gate ratio", "dynamics/expratio", SL_RATIO)
	text(e.ui, "graph: drag C/E = threshold, ratio", col.x, col.y + 2, FONT_TINY, COL_DIM)
	col.y += 18
	e.y = max(al.y, col.y)
}

// --- FX dock: control room, reverb, echo -------------------------------------------

FX_DOCK_W :: 300

draw_fx_dock :: proc(ui: ^UI, area: rl.Rectangle) {
	rl.DrawRectangleRec(area, COL_ROW)
	prev := clip_push(ui, area)
	e := Ed{ui = ui, x = area.x + 14, y = area.y + 4 - ui.fx_scroll, w = area.width - 34, label_w = 90}

	e.base = "/controlroom"
	ed_section(&e, "Control Room")
	if state_has(&ui.app.st, "/globalmute") {
		toggle_param(ui, {e.x, e.y, e.w, ED_ROW_H}, "Mute enable (all mutes)", "/globalmute", COL_MUTE, FONT)
		ed_next(&e)
	}
	ed_slider(&e, "Dim level", "dimreduction", SL_DIM)
	ed_slider(&e, "Recall vol.", "recallvolume", SL_RECALL)

	e.base = "/reverb"
	if ed_section(&e, "Reverb", "enable") {
		ed_cycle(&e, "Type", "type", REVERB_TYPES)
		t := int(ed_get(&e, "type"))
		ed_slider(&e, "Pre-delay", "predelay", SL_RV_PREDELAY)
		ed_slider(&e, "Low cut", "lowcut", SL_RV_LOWCUT)
		if t < REVERB_ENVELOPE do ed_slider(&e, "Room scale", "roomscale", SL_RV_SCALE)
		if t == REVERB_ENVELOPE do ed_slider(&e, "Attack", "attack", SL_RV_ATTACK)
		if t == REVERB_ENVELOPE || t == REVERB_GATED {
			ed_slider(&e, "Hold", "hold", SL_RV_HOLD)
			ed_slider(&e, "Release", "release", SL_RV_RELEASE)
		}
		if t == REVERB_SPACE {
			ed_slider(&e, "Time", "time", SL_RV_TIME)
			ed_slider(&e, "High damp", "highdamp", SL_RV_HIGHCUT)
		}
		ed_slider(&e, "High cut", "highcut", SL_RV_HIGHCUT)
		ed_slider(&e, "Smooth", "smooth", SL_RV_SMOOTH)
		ed_slider(&e, "Width", "width", SL_FX_WIDTH)
		ed_slider(&e, "Volume", "volume", SL_FX_VOLUME)
	}

	e.base = "/echo"
	if ed_section(&e, "Echo", "enable") {
		ed_cycle(&e, "Type", "type", ECHO_TYPES)
		ed_slider(&e, "Delay", "delay", SL_ECHO_DELAY)
		ed_slider(&e, "Feedback", "feedback", SL_ECHO_FEEDBACK)
		ed_cycle(&e, "High cut", "highcut", ECHO_HIGHCUT)
		ed_slider(&e, "Width", "width", SL_FX_WIDTH)
		ed_slider(&e, "Volume", "volume", SL_FX_VOLUME)
	}
	text(ui, "FX send: input settings (cog).\nFX return: output settings (cog).", e.x, e.y + 6, FONT_TINY, COL_DIM)
	content_h := e.y + 40 + ui.fx_scroll - area.y
	clip_pop(ui, prev)

	max_scroll := max(0, content_h - area.height)
	if interactive(ui, area) && !ui.wheel_used do ui.fx_scroll -= rl.GetMouseWheelMove() * 50
	ui.fx_scroll = clamp(ui.fx_scroll, 0, max_scroll)
	if max_scroll > 0 {
		th := max(30, area.height * area.height / content_h)
		ty := area.y + (area.height - th) * ui.fx_scroll / max_scroll
		rl.DrawRectangleRounded({area.x + area.width - 7, ty, 4, th}, 1, 4, COL_BUTTON_HOT)
	}
}

channel_ed :: proc(ui: ^UI, row: Row, ch: int) -> Ed {
	return Ed {
		ui     = ui,
		row    = row,
		ch     = ch,
		stereo = ch % 2 == 0 && is_stereo(ui.app, row, ch),
		base   = fmt.tprintf("/%s/%d", ROW_BUS[row], ch),
	}
}

// --- preset list ------------------------------------------------------------------------

POPUP_W :: 250

// Preset list under a panel's "Presets" button, drawn above the mixer
// (unclipped). Click a name to recall it (the list stays open for trying
// others), × deletes, "Save current as…" names a new one. Closes on a click
// elsewhere, Esc, or when its panel is no longer drawn.
draw_preset_popup :: proc(ui: ^UI, sw, sh: f32) {
	p := &ui.popup
	if !p.open do return
	if !p.seen {
		p^ = {}
		return
	}
	p.seen = false
	list := presets_of(&ui.presets, p.kind)
	ROW :: 28
	max_rows := max(1, int((sh - TOPBAR_H - 100) / ROW))
	shown := min(len(list), max_rows)
	h := 8 + 22 + f32(max(shown, 1)) * ROW + 6 + ROW + 8
	r := rl.Rectangle{p.anchor.x + p.anchor.width - POPUP_W, p.anchor.y + p.anchor.height + 4, POPUP_W, h}
	r.x = clamp(r.x, 4, sw - POPUP_W - 4)
	if r.y + r.height > sh - 4 do r.y = max(TOPBAR_H, sh - 4 - r.height)
	p.rect = r
	ui.in_popup = true
	defer ui.in_popup = false

	rl.DrawRectangleRounded(r, 0.04, 4, COL_STRIP)
	rl.DrawRectangleRoundedLinesEx(r, 0.04, 4, 1, COL_ACCENT)
	x, y, w := r.x + 8, r.y + 8, r.width - 16
	text(ui, fmt.tprintf("%s presets (saved on this computer)", PANEL_TITLE[p.kind]), x + 2, y + 2, FONT_TINY, COL_DIM)
	y += 22
	if shown == 0 {
		text(ui, "none saved yet", x + 2, y + 6, FONT, COL_DIM)
		y += ROW
	}
	e := channel_ed(ui, p.row, p.ch)
	for &pr, i in list[:shown] {
		if button(ui, {x, y, w - 32, ROW - 4}, pr.name, false, COL_ACCENT, FONT) {
			sent := preset_recall(p.kind, &pr, &e)
			set_status(ui, fmt.tprintf("%s preset \"%s\" recalled (%d values sent)", PANEL_TITLE[p.kind], pr.name, sent))
		}
		if button(ui, {x + w - 28, y, 28, ROW - 4}, "×") {
			ui.preset_target = {row = p.row, ch = p.ch, kind = p.kind, index = i}
			ui.confirm = .Delete_Preset
		}
		y += ROW
	}
	y += 6
	if button(ui, {x, y, w, ROW - 2}, "Save current as…", false, COL_ACCENT, FONT) {
		ui.preset_target = {row = p.row, ch = p.ch, kind = p.kind}
		strings.builder_reset(&ui.text)
		ui.confirm = .Save_Preset
		p^ = {}
		return
	}
	if (rl.IsMouseButtonPressed(.LEFT) || rl.IsMouseButtonPressed(.RIGHT)) && !hovered(r) && !hovered(p.anchor) do p^ = {}
}
