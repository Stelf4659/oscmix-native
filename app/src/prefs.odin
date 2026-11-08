package oscmix_native

// Window preferences: ~/.config/oscmix-native/ui.json

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

Prefs :: struct {
	scale: f32,
}

@(private = "file")
prefs_path :: proc() -> string {
	dir, err := os.user_config_dir(context.temp_allocator)
	if err != nil do return ""
	return fmt.tprintf("%s/oscmix-native/ui.json", dir)
}

prefs_load :: proc() -> (p: Prefs, ok: bool) {
	path := prefs_path()
	if path == "" do return
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return
	if json.unmarshal(data, &p, allocator = context.temp_allocator) != nil do return
	return p, p.scale > 0
}

prefs_save :: proc(p: Prefs) {
	path := prefs_path()
	if path == "" do return
	data, merr := json.marshal(p, {pretty = true}, context.temp_allocator)
	if merr != nil do return
	os.make_directory_all(filepath.dir(path))
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, data) == nil do os.rename(tmp, path)
}
