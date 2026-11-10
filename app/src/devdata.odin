package oscmix_native

// Local per-interface data, ~/.config/oscmix-native/device-<uid>.json:
// channel names, fader/mute groups, mixer snapshots and the last session
// (see session.odin). The UFX III keeps none of these over this engine
// (written names are not stored; tested), so like TotalMix's workspace they
// live on the computer.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

SNAPSHOT_SLOTS :: 8
GROUPS :: 4

Snapshot :: struct {
	name:      string, // "" = empty slot
	values:    map[string]f32, // absolute address → value
	all_sends: bool, // sends not in values are off (else: left as they are)
}

Device_Data :: struct {
	path:      string, // not serialized
	names:     map[string]string, // "/input/6" → name
	groups:    map[string]u8, // "/input/6" → bits 0-3: fader groups 1-4, bits 4-7: mute groups 1-4
	snapshots: [dynamic]Snapshot, // SNAPSHOT_SLOTS entries
	session:   Snapshot, // mixer as last seen; name "" = none saved yet
}

@(private = "file")
Device_File :: struct {
	names:     map[string]string,
	groups:    map[string]u8,
	snapshots: [dynamic]Snapshot,
	session:   Snapshot,
}

chan_key :: proc(row: Row, ch: int) -> string {return fmt.tprintf("/%s/%d", ROW_BUS[row], ch)}

// "/input/6" → (.Input, 6)
chan_key_parse :: proc(key: string) -> (row: Row, ch: int, ok: bool) {
	parts := strings.split(key, "/", context.temp_allocator)
	if len(parts) != 3 do return
	found := false
	for bus, r in ROW_BUS do if bus == parts[1] {row, found = r, true}
	if !found do return
	ch = strconv.parse_int(parts[2]) or_return
	return row, ch, true
}

devdata_load :: proc(app: ^App, uid: string) {
	devdata_destroy(&app.dev)
	app.dev = {}
	if dir, err := os.user_config_dir(context.temp_allocator); err == nil {
		safe, _ := strings.replace_all(uid, "/", "_", context.temp_allocator)
		app.dev.path = fmt.aprintf("%s/oscmix-native/device-%s.json", dir, safe)
		if data, rerr := os.read_entire_file(app.dev.path, context.temp_allocator); rerr == nil {
			f: Device_File
			if json.unmarshal(data, &f) == nil {
				app.dev.names, app.dev.groups, app.dev.snapshots, app.dev.session = f.names, f.groups, f.snapshots, f.session
			} else {
				fmt.eprintfln("ignoring unreadable %s", app.dev.path)
				delete(app.dev.path)
				app.dev.path = "" // never overwrite a file we could not read
			}
		}
	}
	for len(app.dev.snapshots) < SNAPSHOT_SLOTS do append(&app.dev.snapshots, Snapshot{})
}

snapshot_free :: proc(s: ^Snapshot) {
	delete(s.name)
	for k in s.values do delete(k)
	delete(s.values)
	s^ = {}
}

devdata_destroy :: proc(d: ^Device_Data) {
	delete(d.path)
	for k, v in d.names {
		delete(k)
		delete(v)
	}
	delete(d.names)
	for k in d.groups do delete(k)
	delete(d.groups)
	for &s in d.snapshots do snapshot_free(&s)
	delete(d.snapshots)
	snapshot_free(&d.session)
}

devdata_save :: proc(app: ^App) -> bool {
	d := &app.dev
	if d.path == "" do return false
	data, merr := json.marshal(Device_File{d.names, d.groups, d.snapshots, d.session}, {pretty = true}, context.temp_allocator)
	if merr != nil do return false
	os.make_directory_all(filepath.dir(d.path))
	tmp := strings.concatenate({d.path, ".tmp"}, context.temp_allocator)
	return os.write_entire_file(tmp, data) == nil && os.rename(tmp, d.path) == nil
}

// --- names ----------------------------------------------------------------------------

local_name :: proc(app: ^App, row: Row, ch: int) -> string {
	return app.dev.names[chan_key(row, ch)]
}

// Sets a local channel name; "" returns to the interface's name.
set_local_name :: proc(app: ^App, row: Row, ch: int, name: string) {
	key := chan_key(row, ch)
	if key in app.dev.names {
		k, v := delete_key(&app.dev.names, key)
		delete(k)
		delete(v)
	}
	if name != "" do app.dev.names[strings.clone(key)] = strings.clone(name)
	devdata_save(app)
}

// --- groups ------------------------------------------------------------------------------

group_bits :: proc(app: ^App, row: Row, ch: int) -> u8 {return app.dev.groups[chan_key(row, ch)]}

group_toggle :: proc(app: ^App, row: Row, ch: int, bit: uint) {
	key := chan_key(row, ch)
	bits := app.dev.groups[key] ~ (1 << bit)
	if key in app.dev.groups {
		k, _ := delete_key(&app.dev.groups, key)
		delete(k)
	}
	if bits != 0 do app.dev.groups[strings.clone(key)] = bits
	devdata_save(app)
}

// Fader of a strip in the current view: the send into `submix`, or an output's volume.
strip_fader_addr :: proc(row: Row, ch, submix: int) -> (addr: string, off: f32) {
	if row == .Output do return fmt.tprintf("/output/%d/volume", ch), FADER_MIN_DB
	return fmt.tprintf("/mix/%s/%d/%d/fader", ROW_LEVEL[row], ch, submix), SEND_OFF_DB
}

// A fader of a fader-group member moved from `old` to `new` dB: move the other
// members' faders by the same amount (relative, like TotalMix). Members whose
// level is unknown or off stay as they are.
group_fader_moved :: proc(app: ^App, row: Row, ch, submix: int, old, new: f32) {
	mine := group_bits(app, row, ch) & 0x0F
	if mine == 0 do return
	delta := max(new, FADER_MIN_DB) - max(old, FADER_MIN_DB)
	if delta == 0 do return
	for key, bits in app.dev.groups {
		if bits & mine == 0 do continue
		mrow, mch := chan_key_parse(key) or_continue
		if mrow == row && mch == ch do continue
		addr, off := strip_fader_addr(mrow, mch, submix)
		if !state_has(&app.st, addr) do continue
		v := state_get(&app.st, addr)
		if v <= FADER_MIN_DB do continue
		nv := clamp(v + delta, FADER_MIN_DB, FADER_MAX_DB)
		app_send(app, addr, nv <= FADER_MIN_DB ? off : nv)
	}
}

// A mute-group member's mute was set to `v`: set every member the same.
group_mute_set :: proc(app: ^App, row: Row, ch: int, v: f32) {
	mine := group_bits(app, row, ch) & 0xF0
	if mine == 0 do return
	for key, bits in app.dev.groups {
		if bits & mine == 0 do continue
		mrow, mch := chan_key_parse(key) or_continue
		if mrow == row && mch == ch do continue
		if addr := fmt.tprintf("%s/mute", key); state_has(&app.st, addr) do app_send(app, addr, v)
	}
}

// --- snapshots ---------------------------------------------------------------------------

// Mixer settings a snapshot covers, per channel (hardware settings such as
// preamp gain, 48V, reference level, stereo pairing, room EQ and names are
// left alone, as in TotalMix).
snapshot_channel_params :: proc(row: Row) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	switch row {
	case .Playback:
		append(&out, "width")
		return out[:]
	case .Input:
		append(&out, "mute", "fxsend", "width", "msproc")
	case .Output:
		append(&out, "mute", "volume", "balpan", "fxreturn")
	}
	append(&out, "lowcut/enable", "eq/enable", "dynamics/enable", "autolevel/enable")
	append(&out, ..preset_params(.EQ))
	append(&out, ..preset_params(.Dynamics))
	return out[:]
}

// All send addresses of the current strip layout (left channels of pairs).
for_each_send :: proc(app: ^App, fn: proc(app: ^App, fader, pan: string, user: rawptr), user: rawptr) {
	outs := strip_channels(app, .Output)
	for row in ([]Row{.Input, .Playback}) {
		for ch in strip_channels(app, row) {
			for o in outs {
				fn(app, fmt.tprintf("/mix/%s/%d/%d/fader", ROW_LEVEL[row], ch, o), fmt.tprintf("/mix/%s/%d/%d/balpan", ROW_LEVEL[row], ch, o), user)
			}
		}
	}
}

// Current mixer state as a snapshot (temp-allocated); `unknown` counts sends
// whose level the app does not know. Sends that are on are always listed.
// all_sends (no unknown sends, or unknown_off chosen): every send not listed
// is off. Otherwise known-off sends are listed explicitly and unknown sends
// are left out, so recalling leaves them as they are.
snapshot_capture :: proc(app: ^App, unknown_off: bool) -> (values: map[string]f32, unknown: int, all_sends: bool) {
	values = make(map[string]f32, 4096, context.temp_allocator)
	for row in Row {
		params := snapshot_channel_params(row)
		for ch in strip_channels(app, row) {
			stereo := ch % 2 == 0 && is_stereo(app, row, ch)
			for p in params {
				if addr := fmt.tprintf("/%s/%d/%s", ROW_BUS[row], ch, p); state_has(&app.st, addr) {
					values[addr] = state_get(&app.st, addr)
				}
			}
			if stereo && row != .Playback { // phase is per side
				for side in 0 ..= 1 {
					if addr := fmt.tprintf("/%s/%d/phase", ROW_BUS[row], ch + side); state_has(&app.st, addr) do values[addr] = state_get(&app.st, addr)
				}
			} else if addr := fmt.tprintf("/%s/%d/phase", ROW_BUS[row], ch); state_has(&app.st, addr) {
				values[addr] = state_get(&app.st, addr)
			}
		}
	}
	for addr, e in app.st.vals {
		if (strings.has_prefix(addr, "/reverb/") || strings.has_prefix(addr, "/echo/")) && e.n > 0 do values[addr] = e.f[0]
	}
	Cap :: struct {
		values:    ^map[string]f32,
		unknown:   ^int,
		known_off: [dynamic]string,
	}
	cap := Cap{&values, &unknown, make([dynamic]string, context.temp_allocator)}
	for_each_send(app, proc(app: ^App, fader, pan: string, user: rawptr) {
		c := (^Cap)(user)
		if !state_has(&app.st, fader) {
			c.unknown^ += 1
			return
		}
		f := state_get(&app.st, fader)
		p, pan_known := app.st.vals[pan]
		if f > SEND_OFF_DB || (pan_known && p.f[0] != 0) {
			c.values[fader] = f
			if pan_known do c.values[pan] = p.f[0] // an unknown pan stays unknown
		} else {
			append(&c.known_off, fader)
		}
	}, &cap)
	all_sends = unknown == 0 || unknown_off
	if !all_sends {
		for f in cap.known_off do values[f] = SEND_OFF_DB
	}
	return
}

snapshot_store :: proc(app: ^App, slot: int, name: string, values: map[string]f32, all_sends: bool) -> bool {
	snapshot_set(&app.dev.snapshots[slot], name, values, all_sends)
	return devdata_save(app)
}

// Replaces s with copies of name and values.
snapshot_set :: proc(s: ^Snapshot, name: string, values: map[string]f32, all_sends: bool) {
	snapshot_free(s)
	s.name = strings.clone(name)
	s.all_sends = all_sends
	for k, v in values do s.values[strings.clone(k)] = v
}

snapshot_clear :: proc(app: ^App, slot: int) -> bool {
	snapshot_free(&app.dev.snapshots[slot])
	return devdata_save(app)
}

queue_if_needed :: proc(app: ^App, addr: string, v: f32) {
	if state_has(&app.st, addr) && state_get(&app.st, addr) == v do return
	app_queue(app, addr, v)
}

// Queues every value that differs from (or is unknown in) the current state;
// with all_sends also every send the snapshot does not list (→ off). Returns
// the number of writes queued (sent paced by app_poll).
snapshot_recall :: proc(app: ^App, slot: int) -> int {
	s := &app.dev.snapshots[slot]
	app_queue_clear(app)
	for addr, v in s.values {
		if !s.all_sends || !strings.has_prefix(addr, "/mix/") do queue_if_needed(app, addr, v)
	}
	if s.all_sends {
		for_each_send(app, proc(app: ^App, fader, pan: string, user: rawptr) {
			s := (^Snapshot)(user)
			if v, listed := s.values[fader]; listed {
				queue_if_needed(app, fader, v)
				if pv, ok := s.values[pan]; ok do queue_if_needed(app, pan, pv)
			} else { // not listed: off
				queue_if_needed(app, fader, SEND_OFF_DB)
				queue_if_needed(app, pan, 0)
			}
		}, s)
	}
	return len(app.queue)
}
