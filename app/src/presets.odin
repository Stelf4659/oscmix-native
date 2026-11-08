package oscmix_native

// Local EQ / dynamics / room EQ presets: ~/.config/oscmix-native/presets.json.
// A preset holds a channel's settings (shape only, not the on/off switches);
// recalling it writes each value to the interface. The device's own preset
// slots (*/loadpreset) do nothing on the UFX III over this engine.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

Preset :: struct {
	name:   string,
	values: map[string]f32, // channel-relative address ("eq/band1freq") → value
}

Preset_File :: struct {
	eq:       [dynamic]Preset,
	dynamics: [dynamic]Preset,
	roomeq:   [dynamic]Preset,
}

presets_of :: proc(f: ^Preset_File, kind: Panel_Kind) -> ^[dynamic]Preset {
	#partial switch kind {
	case .EQ:
		return &f.eq
	case .Dynamics:
		return &f.dynamics
	case .Room_EQ:
		return &f.roomeq
	}
	return nil
}

// Channel-relative parameters a preset of this kind covers.
preset_params :: proc(kind: Panel_Kind) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	#partial switch kind {
	case .EQ:
		append(&out, "lowcut/freq", "lowcut/slope", "eq/band1type", "eq/band3type")
		for n in 1 ..= 3 do for p in ([]string{"freq", "gain", "q"}) do append(&out, fmt.tprintf("eq/band%d%s", n, p))
	case .Dynamics:
		for p in ([]string{"gain", "attack", "release", "compthres", "compratio", "expthres", "expratio"}) {
			append(&out, fmt.tprintf("dynamics/%s", p))
		}
		append(&out, "autolevel/maxgain", "autolevel/headroom", "autolevel/risetime")
	case .Room_EQ:
		append(&out, "delay", "gain", "roomeq/band1type", "roomeq/band8type", "roomeq/band9type")
		for n in 1 ..= 9 do for p in ([]string{"freq", "gain", "q"}) do append(&out, fmt.tprintf("roomeq/band%d%s", n, p))
	}
	return out[:]
}

@(private = "file")
presets_path :: proc() -> string {
	dir, err := os.user_config_dir(context.temp_allocator)
	if err != nil do return ""
	return fmt.tprintf("%s/oscmix-native/presets.json", dir)
}

@(private = "file")
preset_free :: proc(p: ^Preset) {
	delete(p.name)
	for k in p.values do delete(k)
	delete(p.values)
}

presets_load :: proc(f: ^Preset_File) {
	path := presets_path()
	if path == "" do return
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	if json.unmarshal(data, f) != nil {
		presets_destroy(f)
		f^ = {}
	}
}

presets_destroy :: proc(f: ^Preset_File) {
	for kind in ([]Panel_Kind{.EQ, .Dynamics, .Room_EQ}) {
		list := presets_of(f, kind)
		for &p in list do preset_free(&p)
		delete(list^)
	}
}

presets_save :: proc(f: ^Preset_File) -> bool {
	path := presets_path()
	if path == "" do return false
	data, merr := json.marshal(f^, {pretty = true}, context.temp_allocator)
	if merr != nil do return false
	os.make_directory_all(filepath.dir(path))
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	return os.write_entire_file(tmp, data) == nil && os.rename(tmp, path) == nil
}

// Stores the channel's current settings as `name` (replacing a preset of the same name).
preset_store :: proc(f: ^Preset_File, kind: Panel_Kind, e: ^Ed, name: string) -> bool {
	list := presets_of(f, kind)
	p := Preset{name = strings.clone(name)}
	for sub in preset_params(kind) {
		if ed_has(e, sub) do p.values[strings.clone(sub)] = ed_get(e, sub)
	}
	for &old, i in list {
		if old.name == name {
			preset_free(&old)
			list[i] = p
			return presets_save(f)
		}
	}
	append(list, p)
	slice.sort_by(list[:], proc(a, b: Preset) -> bool {return strings.compare(a.name, b.name) < 0})
	return presets_save(f)
}

// Writes the preset's values to the channel (only parameters of this kind
// that the channel has). Returns how many were sent.
preset_recall :: proc(kind: Panel_Kind, p: ^Preset, e: ^Ed) -> (n: int) {
	for sub in preset_params(kind) {
		if v, ok := p.values[sub]; ok && ed_has(e, sub) {
			ed_set(e, sub, v)
			n += 1
		}
	}
	return
}

preset_delete :: proc(f: ^Preset_File, kind: Panel_Kind, index: int) -> bool {
	list := presets_of(f, kind)
	preset_free(&list[index])
	ordered_remove(list, index)
	return presets_save(f)
}
