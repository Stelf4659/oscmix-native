package oscmix_native

// Process helpers: running external commands and the single-instance lock.

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
	fd, err := linux.open(path, {.RDWR, .CREAT, .CLOEXEC}, {.IRUSR, .IWUSR})
	if err != .NONE do return true // no lock file possible: do not block the UI over it
	return linux.flock(fd, {.EX, .NB}) != .EWOULDBLOCK
}
