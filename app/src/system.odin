package oscmix_native

// Process helpers: running external commands, the single-instance lock and
// unreadable config files.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

// Runs a command; returns success and trimmed stdout+stderr (temp allocated).
run_cmd :: proc(argv: ..string) -> (ok: bool, output: string) {
	state, out, errout, err := os.process_exec({command = argv}, context.temp_allocator)
	if err != nil do return false, fmt.tprintf("%s: %v", argv[0], err)
	text := strings.trim_space(strings.concatenate({string(out), string(errout)}, context.temp_allocator))
	return state.exited && state.exit_code == 0, text
}

// Takes the per-user UI lock. False means another window already holds it:
// two instances would each keep their own mixer state and both write to the
// interface. The descriptor stays open for the life of the process; the
// kernel drops the lock on exit, however the process ends.
instance_lock :: proc() -> bool {
	dir := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	path := dir != "" ? fmt.ctprintf("%s/oscmix-native.lock", dir) : fmt.ctprintf("/tmp/oscmix-native-%d.lock", linux.getuid())
	fd, err := linux.open(path, {.RDWR, .CREAT, .CLOEXEC, .NOFOLLOW}, {.IRUSR, .IWUSR})
	if err != .NONE do return true // no lock file possible: do not block the UI over it
	return linux.flock(fd, {.EX, .NB}) != .EWOULDBLOCK
}

// Moves a config file that failed to parse to <path>.bad, so the next save
// does not overwrite what the user may still want to recover.
set_aside_unreadable :: proc(path: string) {
	bad := strings.concatenate({path, ".bad"}, context.temp_allocator)
	if os.rename(path, bad) == nil {
		fmt.eprintfln("could not read %s; moved it to %s", path, bad)
	} else {
		fmt.eprintfln("could not read %s", path)
	}
}
