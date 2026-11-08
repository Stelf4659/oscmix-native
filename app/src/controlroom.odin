package oscmix_native

// Control room column (right side, as in TotalMix): Main Out (the interface's
// /controlroom/mainout assignment) plus outputs pinned there locally (e.g.
// phones). These outputs leave the output row; their panels open to the
// left of their strip inside the column.

import "core:fmt"
import "core:slice"
import "core:strings"
import rl "../raylib"

CR_STRIP_W :: 80
CR_MIN_W :: 200
CR_PAD :: 8
CR_HEAD_H :: 78 // title, DIM / MONO / RECALL, strip tags
CR_PANEL_ORDER := [?]Panel_Kind{.Room_EQ, .Dynamics, .EQ, .Settings}

// Left channel of the pair `ch` belongs to.
pair_left :: proc(app: ^App, ch: int) -> int {
	if ch % 2 == 1 && is_stereo(app, .Output, ch - 1) do return ch - 1
	return ch
}

// Main Out as an output strip index; -1 if unassigned/unknown.
main_out :: proc(app: ^App) -> int {
	if !state_has(&app.st, "/controlroom/mainout") do return -1
	m := int(state_get(&app.st, "/controlroom/mainout", -1))
	if m < 0 || m >= channel_count(app, .Output) do return -1
	return pair_left(app, m)
}

// Control room outputs: Main Out first, then pinned outputs in pin order.
cr_outputs :: proc(ui: ^UI) -> []int {
	app := ui.app
	out := make([dynamic]int, context.temp_allocator)
	if m := main_out(app); m >= 0 do append(&out, m)
	n := channel_count(app, .Output)
	for p in ui.pins {
		if p < 0 || p >= n do continue
		ch := pair_left(app, p)
		if !slice.contains(out[:], ch) do append(&out, ch)
	}
	return out[:]
}

is_cr_output :: proc(ui: ^UI, ch: int) -> bool {
	return slice.contains(cr_outputs(ui), ch)
}

cr_pinned :: proc(ui: ^UI, ch: int) -> bool {
	for p in ui.pins do if pair_left(ui.app, p) == ch do return true
	return false
}

cr_pin_toggle :: proc(ui: ^UI, ch: int) {
	if cr_pinned(ui, ch) {
		for i := len(ui.pins) - 1; i >= 0; i -= 1 {
			if pair_left(ui.app, ui.pins[i]) == ch do ordered_remove(&ui.pins, i)
		}
	} else {
		append(&ui.pins, ch)
	}
	prefs_save(ui)
}

// Loads the pinned outputs saved for the connected interface (once its uid is known).
cr_sync_pins :: proc(ui: ^UI) {
	uid := state_str(&ui.app.st, "/device/uid")
	if uid == "" || uid == ui.pins_uid do return
	delete(ui.pins_uid)
	ui.pins_uid = strings.clone(uid)
	clear(&ui.pins)
	if p, _ := prefs_load(); p.control_room != nil {
		if list, ok := p.control_room[uid]; ok do append(&ui.pins, ..list)
	}
}

cr_width :: proc(ui: ^UI) -> f32 {
	w: f32 = 2 * CR_PAD
	for ch in cr_outputs(ui) {
		w += CR_STRIP_W
		set := ui.panels[strip_key(.Output, ch)]
		for k in CR_PANEL_ORDER do if k in set do w += PANEL_W[k] + PANEL_GAP
	}
	return max(w, CR_MIN_W)
}

draw_control_room :: proc(ui: ^UI, area: rl.Rectangle) {
	app := ui.app
	rl.DrawRectangleRec(area, COL_ROW)
	right := area.x + area.width - CR_PAD
	text(ui, "CONTROL ROOM", right - 184, area.y + 8, FONT_SMALL, COL_DIM)

	// DIM / MONO act on Main Out; RECALL sets it to the recall volume
	main := main_out(app)
	bw: f32 = 58
	bx := right - 3 * bw - 10
	toggle_param(ui, {bx, area.y + 26, bw, 26}, "DIM", "/controlroom/dim", COL_ON, FONT)
	toggle_param(ui, {bx + bw + 5, area.y + 26, bw, 26}, "MONO", "/controlroom/mainmono", COL_ON, FONT)
	if button(ui, {bx + 2 * (bw + 5), area.y + 26, bw, 26}, "RECALL") && main >= 0 {
		app_send(app, fmt.tprintf("/output/%d/volume", main), state_get(&app.st, "/controlroom/recallvolume", -10))
	}

	outs := cr_outputs(ui)
	y0 := area.y + CR_HEAD_H
	h := area.y + area.height - y0 - 2
	if len(outs) == 0 {
		text(ui, "No Main Out assigned.\nUse an output's settings\n(cog) to assign one.", right - 184, y0 + 6, FONT_SMALL, COL_DIM)
		return
	}
	x := area.x + area.width - cr_width(ui) + CR_PAD
	for ch in outs {
		set := ui.panels[strip_key(.Output, ch)]
		for k in CR_PANEL_ORDER {
			if k not_in set do continue
			draw_panel(ui, .Output, ch, k, {x, y0, PANEL_W[k], h})
			x += PANEL_W[k] + PANEL_GAP
		}
		tag := ch == main ? "MAIN" : "CONTROL ROOM"
		text_centered(ui, tag, {x, y0 - 18, CR_STRIP_W - 2, 16}, FONT_TINY, ch == main ? COL_ACCENT : COL_DIM)
		draw_strip(ui, .Output, ch, {x, y0, CR_STRIP_W - 2, h})
		x += CR_STRIP_W
	}
}
