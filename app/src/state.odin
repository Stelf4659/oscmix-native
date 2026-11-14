package oscmix_native

// Mirror of the engine's OSC parameter tree, plus persistence of the
// submix matrix (/mix/...), which the UFX III never reports back.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

Entry :: struct {
	f: [MAX_OSC_ARGS]f32, // numeric args (ints and bools converted)
	n: u8, // number of args
	s: string, // first string arg, owned
}

State :: struct {
	vals:        map[string]Entry, // keys owned
	mix_dirty:   bool,
	mix_path:    string, // where /mix values are saved; "" = no persistence
	last_insert: time.Tick, // last time a new address appeared (refresh still arriving)
}

state_destroy :: proc(st: ^State) {
	for k, e in st.vals {
		delete(k)
		delete(e.s)
	}
	delete(st.vals)
	delete(st.mix_path)
}

state_apply :: proc(st: ^State, msg: ^Osc_Msg) {
	e: Entry
	for i in 0 ..< msg.argc {
		switch v in msg.args[i] {
		case f32:
			e.f[e.n] = v
		case i32:
			e.f[e.n] = f32(v)
		case bool:
			e.f[e.n] = v ? 1 : 0
		case string:
			if e.s == "" do e.s = v
			continue
		}
		e.n += 1
	}
	key, slot, just_inserted, _ := map_entry(&st.vals, msg.addr)
	owned := ""
	if just_inserted {
		key^ = strings.clone(msg.addr)
		st.last_insert = time.tick_now()
	} else if e.s != "" && e.s == slot.s {
		owned = slot.s // unchanged string: keep the existing copy
	} else {
		delete(slot.s)
	}
	if e.s != "" && owned == "" do owned = strings.clone(e.s)
	e.s = owned
	slot^ = e
	if strings.has_prefix(msg.addr, "/mix/") do st.mix_dirty = true
}

state_get :: proc(st: ^State, addr: string, def: f32 = 0) -> f32 {
	if e, ok := st.vals[addr]; ok && e.n > 0 do return e.f[0]
	return def
}

state_has :: proc(st: ^State, addr: string) -> bool {
	_, ok := st.vals[addr]
	return ok
}

state_str :: proc(st: ^State, addr: string) -> string {
	if e, ok := st.vals[addr]; ok do return e.s
	return ""
}

// Saved file: {"/mix/in/0/14/fader": [-10.0], ...}
Mix_File :: map[string][]f32

state_set_mix_path :: proc(st: ^State, device_uid: string) {
	dir, err := os.user_config_dir(context.temp_allocator)
	if err != nil do return
	safe, _ := strings.replace_all(device_uid, "/", "_", context.temp_allocator)
	delete(st.mix_path)
	st.mix_path = fmt.aprintf("%s/oscmix-native/mix-%s.json", dir, safe)
}

// Loads saved playback sends for display. Never sent to the device; values
// the engine has already reported win. Input sends are not loaded: the unit
// reports every input send that is on in its refresh dump (session.odin).
state_load_mix :: proc(st: ^State) -> int {
	if st.mix_path == "" do return 0
	data, err := os.read_entire_file(st.mix_path, context.temp_allocator)
	if err != nil do return 0
	saved: Mix_File
	if json.unmarshal(data, &saved, allocator = context.temp_allocator) != nil {
		set_aside_unreadable(st.mix_path)
		return 0
	}
	n := 0
	for addr, vals in saved {
		if !strings.has_prefix(addr, "/mix/pb/") || state_has(st, addr) do continue
		msg := Osc_Msg{addr = addr}
		for v in vals[:min(len(vals), MAX_OSC_ARGS)] {
			msg.args[msg.argc] = v
			msg.argc += 1
		}
		state_apply(st, &msg)
		n += 1
	}
	st.mix_dirty = false
	return n
}

// Drops every value whose address starts with prefix.
state_forget_prefix :: proc(st: ^State, prefix: string) {
	doomed := make([dynamic]string, context.temp_allocator)
	for k in st.vals do if strings.has_prefix(k, prefix) do append(&doomed, k)
	for k in doomed {
		key, e := delete_key(&st.vals, k)
		delete(e.s)
		delete(key)
	}
}

state_save_mix :: proc(st: ^State) {
	if st.mix_path == "" || !st.mix_dirty do return
	out: Mix_File
	defer delete(out)
	for addr, &e in st.vals {
		if strings.has_prefix(addr, "/mix/") && e.n > 0 {
			out[addr] = e.f[:e.n]
		}
	}
	data, merr := json.marshal(out, {pretty = true}, context.temp_allocator)
	if merr != nil do return
	os.make_directory_all(filepath.dir(st.mix_path))
	tmp := strings.concatenate({st.mix_path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, data) == nil && os.rename(tmp, st.mix_path) == nil {
		st.mix_dirty = false
	}
}
