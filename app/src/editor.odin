package oscmix_native

// Channel settings dock (right side): preamp / output settings, low cut, EQ,
// dynamics (compressor + expander/gate), auto level and room EQ. Stereo pairs
// are edited through the left channel; the interface applies it to both sides.
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

CROSSFEED_OPTIONS := []string{"Off", "1", "2", "3", "4", "5"}
SLOPE_OPTIONS := []string{"6 dB", "12 dB", "18 dB", "24 dB"}

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

// --- editor layout --------------------------------------------------------------

ED_PAD :: 16
ED_LABEL_W :: 112
ED_ROW_H :: 24
ED_HEADER_H :: 66

Ed :: struct {
	ui:      ^UI,
	x, y, w: f32,
	row:     Row,
	ch:      int,
	stereo:  bool,
}

ed_addr :: proc(e: ^Ed, sub: string, side := 0) -> string {
	return fmt.tprintf("/%s/%d/%s", ROW_BUS[e.row], e.ch + side, sub)
}
ed_has :: proc(e: ^Ed, sub: string) -> bool {return state_has(&e.ui.app.st, ed_addr(e, sub))}
ed_get :: proc(e: ^Ed, sub: string, def: f32 = 0) -> f32 {return state_get(&e.ui.app.st, ed_addr(e, sub), def)}
ed_set :: proc(e: ^Ed, sub: string, v: f32) {app_send(e.ui.app, ed_addr(e, sub), v)}

// Section title with an optional on/off switch. False if the channel lacks it.
ed_section :: proc(e: ^Ed, title: string, enable_sub := "") -> bool {
	if enable_sub != "" && !ed_has(e, enable_sub) do return false
	e.y += 8
	rl.DrawLineEx({e.x, e.y}, {e.x + e.w, e.y}, 1, COL_BUTTON)
	e.y += 10
	text(e.ui, title, e.x, e.y + 3, FONT_HEAD)
	if enable_sub != "" {
		on := ed_get(e, enable_sub) != 0
		if button(e.ui, {e.x + e.w - 70, e.y, 70, ED_ROW_H}, on ? "ON" : "OFF", on, COL_EQ, FONT_SMALL) {
			ed_set(e, enable_sub, on ? 0 : 1)
		}
	}
	e.y += ED_ROW_H + 10
	return true
}

ed_label :: proc(e: ^Ed, label: string) {
	text(e.ui, label, e.x, e.y + (ED_ROW_H - FONT) / 2, FONT, COL_DIM)
}

ed_slider :: proc(e: ^Ed, label, sub: string, s: Slider) {
	if !ed_has(e, sub) do return
	ed_label(e, label)
	addr := ed_addr(e, sub)
	r := rl.Rectangle{e.x + ED_LABEL_W, e.y, e.w - ED_LABEL_W, ED_ROW_H}
	if v, changed := slider(e.ui, addr_id(addr), r, s, state_get(&e.ui.app.st, addr, s.def), FONT); changed {
		app_send(e.ui.app, addr, v)
	}
	e.y += ED_ROW_H + 6
}

ed_choice :: proc(e: ^Ed, label, sub: string, options: []string) {
	if !ed_has(e, sub) || len(options) == 0 do return
	ed_label(e, label)
	cur := int(ed_get(e, sub))
	n := f32(len(options))
	bw := (e.w - ED_LABEL_W - (n - 1) * 4) / n
	for o, i in options {
		r := rl.Rectangle{e.x + ED_LABEL_W + f32(i) * (bw + 4), e.y, bw, ED_ROW_H}
		if button(e.ui, r, o, cur == i, COL_ACCENT, FONT_SMALL) && cur != i do ed_set(e, sub, f32(i))
	}
	e.y += ED_ROW_H + 6
}

Ed_Toggle :: struct {
	label, sub: string,
	color:      rl.Color,
	side:       int, // 1 = right channel of a stereo pair
}

// Row(s) of on/off buttons; entries the channel lacks are skipped.
ed_toggles :: proc(e: ^Ed, items: []Ed_Toggle) {
	PER_ROW :: 4
	bw := (e.w - (PER_ROW - 1) * 6) / PER_ROW
	per_row := PER_ROW
	k := 0
	for it in items {
		addr := ed_addr(e, it.sub, it.side)
		if !state_has(&e.ui.app.st, addr) do continue
		if k > 0 && k % per_row == 0 do e.y += ED_ROW_H + 6
		toggle_param(e.ui, {e.x + f32(k % per_row) * (bw + 6), e.y, bw, ED_ROW_H}, it.label, addr, it.color, FONT)
		k += 1
	}
	if k > 0 do e.y += ED_ROW_H + 8
}

// --- EQ response graph -------------------------------------------------------------

Eq_Kind :: enum {
	Bell,
	Low_Shelf,
	High_Shelf,
	High_Pass,
	Low_Pass,
}

Eq_Band :: struct {
	kind:            Eq_Kind,
	freq, gain, q:   f32,
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
	num := (b0 + b1 * c1 + b2 * c2) * (b0 + b1 * c1 + b2 * c2) + (b1 * s1 + b2 * s2) * (b1 * s1 + b2 * s2)
	den := (a0 + a1 * c1 + a2 * c2) * (a0 + a1 * c1 + a2 * c2) + (a1 * s1 + a2 * s2) * (a1 * s1 + a2 * s2)
	return 10 * math.log10(max(num, 1e-20) / max(den, 1e-20))
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
	on:    bool,
	freq:  f32,
	slope: int,
}

draw_eq_graph :: proc(ui: ^UI, r: rl.Rectangle, bands: []Eq_Band, lc: Graph_Lowcut, active: bool) {
	rl.DrawRectangleRounded(r, 0.04, 4, COL_TRACK)
	fx :: proc(r: rl.Rectangle, f: f32) -> f32 {return r.x + r.width * math.ln(f / 20) / math.ln(f32(1000))}
	gy :: proc(r: rl.Rectangle, db: f64) -> f32 {
		return r.y + r.height / 2 - f32(clamp(db, -GRAPH_DB, GRAPH_DB) / GRAPH_DB) * (r.height / 2 - 4)
	}
	grid := rl.Color{44, 48, 56, 255}
	for f in ([]f32{50, 100, 200, 500, 1000, 2000, 5000, 10000}) {
		x := fx(r, f)
		rl.DrawLineEx({x, r.y}, {x, r.y + r.height}, 1, grid)
	}
	for db in ([]f64{-12, 12}) do rl.DrawLineEx({r.x, gy(r, db)}, {r.x + r.width, gy(r, db)}, 1, grid)
	rl.DrawLineEx({r.x, gy(r, 0)}, {r.x + r.width, gy(r, 0)}, 1, COL_BUTTON_HOT)
	for l in ([]struct {f: f32, s: string}{{100, "100"}, {1000, "1k"}, {10000, "10k"}}) {
		text(ui, l.s, fx(r, l.f) + 3, r.y + r.height - FONT_TINY - 3, FONT_TINY, COL_DIM)
	}
	text(ui, "+12", r.x + 4, gy(r, 12) - FONT_TINY - 1, FONT_TINY, COL_DIM)
	text(ui, "-12", r.x + 4, gy(r, -12) + 1, FONT_TINY, COL_DIM)

	response :: proc(bands: []Eq_Band, lc: Graph_Lowcut, f: f32) -> f64 {
		db: f64 = 0
		for b in bands do db += band_db(b, f)
		if lc.on do db += lowcut_db(lc.freq, lc.slope, f)
		return db
	}
	N :: 160
	pts: [N]rl.Vector2
	for i in 0 ..< N {
		f := 20 * math.pow(f32(1000), f32(i) / (N - 1))
		pts[i] = {fx(r, f), gy(r, response(bands, lc, f))}
	}
	col := active ? COL_ACCENT : COL_DIM
	rl.DrawSplineLinear(&pts[0], N, 2, col)
	for b, i in bands {
		c := rl.Vector2{fx(r, b.freq), gy(r, response(bands, lc, b.freq))}
		rl.DrawCircleV(c, 7, col)
		text_centered(ui, fmt.tprintf("%d", i + 1), {c.x - 7, c.y - 7, 14, 14}, FONT_TINY, COL_TRACK)
	}
}

// --- sections ------------------------------------------------------------------------

// Option names for band n of an EQ family, e.g. /eq/band1types; nil = fixed Bell.
band_types :: proc(app: ^App, family: string, n: int) -> []string {
	return option_list(app, fmt.tprintf("/%s/band%dtypes", family, n))
}

// One band: type, frequency, gain, Q.
ed_band :: proc(e: ^Ed, family: string, n: int) {
	pre := fmt.tprintf("%s/band%d", family, n)
	fsub := fmt.tprintf("%sfreq", pre)
	if !ed_has(e, fsub) do return
	ed_label(e, fmt.tprintf("%d", n))
	x := e.x + 22
	TW :: 84
	tsub := fmt.tprintf("%stype", pre)
	if types := band_types(e.ui.app, family, n); len(types) > 0 && ed_has(e, tsub) {
		cycle_param(e.ui, {x, e.y, TW, ED_ROW_H}, ed_addr(e, tsub), types, FONT_SMALL)
	} else {
		text_centered(e.ui, "Bell", {x, e.y, TW, ED_ROW_H}, FONT_SMALL, COL_DIM)
	}
	x += TW + 6
	sw := (e.x + e.w - x - 12) / 3
	subs := [3]string{fsub, fmt.tprintf("%sgain", pre), fmt.tprintf("%sq", pre)}
	sliders := [3]Slider{SL_FREQ, SL_EQ_GAIN, SL_Q}
	for i in 0 ..< 3 {
		addr := ed_addr(e, subs[i])
		r := rl.Rectangle{x + f32(i) * (sw + 6), e.y, sw, ED_ROW_H}
		if v, changed := slider(e.ui, addr_id(addr), r, sliders[i], state_get(&e.ui.app.st, addr, sliders[i].def)); changed {
			app_send(e.ui.app, addr, v)
		}
	}
	e.y += ED_ROW_H + 6
}

ed_eq_bands :: proc(e: ^Ed, family: string, nbands: int, lc: Graph_Lowcut, active: bool) {
	bands := make([dynamic]Eq_Band, context.temp_allocator)
	for n in 1 ..= nbands {
		pre := fmt.tprintf("%s/band%d", family, n)
		if !ed_has(e, fmt.tprintf("%sfreq", pre)) do continue
		types := band_types(e.ui.app, family, n)
		append(&bands, Eq_Band {
			kind = eq_kind(types, int(ed_get(e, fmt.tprintf("%stype", pre))), n > 1),
			freq = ed_get(e, fmt.tprintf("%sfreq", pre), 1000),
			gain = ed_get(e, fmt.tprintf("%sgain", pre)),
			q    = ed_get(e, fmt.tprintf("%sq", pre), 1),
		})
	}
	draw_eq_graph(e.ui, {e.x, e.y, e.w, 150}, bands[:], lc, active)
	e.y += 158
	for n in 1 ..= nbands do ed_band(e, family, n)
}

ed_input :: proc(e: ^Ed) {
	ed_section(e, "Input")
	phase := e.stereo ? []Ed_Toggle{{"Phase L", "phase", COL_ACCENT, 0}, {"Phase R", "phase", COL_ACCENT, 1}} : []Ed_Toggle{{"Phase", "phase", COL_ACCENT, 0}}
	toggles := make([dynamic]Ed_Toggle, context.temp_allocator)
	append(&toggles, Ed_Toggle{"48V", "48v", COL_PHANTOM, 0}, Ed_Toggle{"Hi-Z", "instrument", COL_ACCENT, 0}, Ed_Toggle{"AutoSet", "autoset", COL_ACCENT, 0})
	append(&toggles, ..phase)
	append(&toggles, Ed_Toggle{"M/S", "msproc", COL_ACCENT, 0}, Ed_Toggle{"Stereo", "stereo", COL_ACCENT, 0})
	ed_toggles(e, toggles[:])
	if s, ok := gain_slider(e.ui.app, e.ch); ok do ed_slider(e, "Gain", "gain", s)
	ed_choice(e, "Ref. level", "reflevel", option_list(e.ui.app, ed_addr(e, "reflevels")))
	if e.stereo do ed_slider(e, "Width", "width", SL_WIDTH)
	ed_slider(e, "FX send", "fxsend", SL_FX)
}

ed_output :: proc(e: ^Ed) {
	ed_section(e, "Output")
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
		r := rl.Rectangle{e.x + ED_LABEL_W, e.y + 2, e.w - ED_LABEL_W, ED_ROW_H - 4}
		if v, changed := pan_slider(e.ui, addr_id(addr), r, state_get(&e.ui.app.st, addr)); changed do app_send(e.ui.app, addr, v)
		e.y += ED_ROW_H + 6
	}
	ed_slider(e, "FX return", "fxreturn", SL_FX)
}

ed_lowcut_eq :: proc(e: ^Ed) {
	lc := Graph_Lowcut{on = ed_get(e, "lowcut/enable") != 0, freq = ed_get(e, "lowcut/freq", 20), slope = int(ed_get(e, "lowcut/slope"))}
	if ed_section(e, "Low Cut", "lowcut/enable") {
		ed_slider(e, "Frequency", "lowcut/freq", SL_LC_FREQ)
		ed_choice(e, "Slope / oct", "lowcut/slope", SLOPE_OPTIONS)
	}
	if ed_section(e, "EQ", "eq/enable") {
		ed_eq_bands(e, "eq", 3, lc, ed_get(e, "eq/enable") != 0)
	}
}

ed_dynamics :: proc(e: ^Ed) {
	if ed_section(e, "Dynamics", "dynamics/enable") {
		ed_slider(e, "Gain", "dynamics/gain", SL_DYN_GAIN)
		ed_slider(e, "Attack", "dynamics/attack", SL_ATTACK)
		ed_slider(e, "Release", "dynamics/release", SL_RELEASE)
		ed_slider(e, "Comp. threshold", "dynamics/compthres", SL_COMP_THRES)
		ed_slider(e, "Comp. ratio", "dynamics/compratio", SL_RATIO)
		ed_slider(e, "Gate threshold", "dynamics/expthres", SL_EXP_THRES)
		ed_slider(e, "Gate ratio", "dynamics/expratio", SL_RATIO)
	}
	if ed_section(e, "Auto Level", "autolevel/enable") {
		ed_slider(e, "Max. gain", "autolevel/maxgain", SL_AL_MAXGAIN)
		ed_slider(e, "Headroom", "autolevel/headroom", SL_AL_HEADROOM)
		ed_slider(e, "Rise time", "autolevel/risetime", SL_AL_RISE)
	}
}

ed_roomeq :: proc(e: ^Ed) {
	if !ed_section(e, "Room EQ", "roomeq/enable") do return
	ed_slider(e, "Delay", "delay", SL_DELAY)
	ed_slider(e, "Volume cal.", "gain", SL_CAL_GAIN)
	ed_eq_bands(e, "roomeq", 9, {}, ed_get(e, "roomeq/enable") != 0)
}

// --- dock ------------------------------------------------------------------------------

draw_editor :: proc(ui: ^UI, area: rl.Rectangle) {
	app := ui.app
	row, ch := ui.edit_row, ui.edit_ch
	stereo := ch % 2 == 0 && is_stereo(app, row, ch)
	rl.DrawRectangleRec(area, COL_ROW)

	// header: name, channel numbers, previous / next channel, close
	x := area.x + ED_PAD
	text_centered(ui, strip_name(app, row, ch), {x, area.y + 8, area.width - 2 * ED_PAD - 120, 26}, FONT_TITLE)
	kind := row == .Input ? "hardware input" : "hardware output"
	nums := stereo ? fmt.tprintf("%d/%d", ch + 1, ch + 2) : fmt.tprintf("%d", ch + 1)
	text(ui, fmt.tprintf("%s %s", kind, nums), x, area.y + 38, FONT_SMALL, COL_DIM)
	bx := area.x + area.width - ED_PAD - 112
	chans := strip_channels(app, row)
	k := -1
	for c, i in chans do if c == ch do k = i
	if button(ui, {bx, area.y + 10, 34, 28}, "<") && k > 0 do open_editor(ui, row, chans[k - 1])
	if button(ui, {bx + 38, area.y + 10, 34, 28}, ">") && k >= 0 && k + 1 < len(chans) do open_editor(ui, row, chans[k + 1])
	if button(ui, {bx + 78, area.y + 10, 34, 28}, "×") do ui.edit_ch = -1
	if ui.edit_ch < 0 do return
	row, ch = ui.edit_row, ui.edit_ch
	stereo = ch % 2 == 0 && is_stereo(app, row, ch)

	content := rl.Rectangle{area.x, area.y + ED_HEADER_H, area.width, area.height - ED_HEADER_H}
	clip_begin(ui, content)
	e := Ed{ui = ui, x = content.x + ED_PAD, y = content.y - ui.edit_scroll, w = content.width - 2 * ED_PAD - 8, row = row, ch = ch, stereo = stereo}
	if row == .Input {
		ed_input(&e)
	} else {
		ed_output(&e)
	}
	ed_lowcut_eq(&e)
	ed_dynamics(&e)
	if row == .Output do ed_roomeq(&e)
	content_h := e.y + ui.edit_scroll - content.y + 16
	clip_end(ui)

	max_scroll := max(0, content_h - content.height)
	if interactive(ui, content) && !ui.wheel_used do ui.edit_scroll -= rl.GetMouseWheelMove() * 60
	ui.edit_scroll = clamp(ui.edit_scroll, 0, max_scroll)
	if max_scroll > 0 {
		th := max(30, content.height * content.height / content_h)
		ty := content.y + (content.height - th) * ui.edit_scroll / max_scroll
		rl.DrawRectangleRounded({content.x + content.width - 7, ty, 4, th}, 1, 4, COL_BUTTON_HOT)
	}
}
