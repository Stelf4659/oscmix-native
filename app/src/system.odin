package oscmix_native

// Host audio integration: jackd settings (~/.config/jackd/jackd.env +
// jackd.service), live buffer size via libjack, and the audio-mode script.

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"

foreign import libjack "system:jack"

Jack_Client :: struct {}
JACK_NO_START_SERVER :: 0x01

@(default_calling_convention = "c")
foreign libjack {
	jack_client_open :: proc(name: cstring, options: c.int, status: ^c.int, #c_vararg args: ..any) -> ^Jack_Client ---
	jack_client_close :: proc(client: ^Jack_Client) -> c.int ---
	jack_get_sample_rate :: proc(client: ^Jack_Client) -> u32 ---
	jack_get_buffer_size :: proc(client: ^Jack_Client) -> u32 ---
	jack_set_buffer_size :: proc(client: ^Jack_Client, nframes: u32) -> c.int ---
}

JACK_RATES :: []int{44100, 48000, 88200, 96000, 176400, 192000}
JACK_PERIODS :: []int{16, 32, 64, 128, 256, 512, 1024}
JACK_NPERIODS :: []int{2, 3}

Jack_Settings :: struct {
	rate, period, nperiods: int,
}

Jack_Live :: struct {
	running:      bool,
	rate, period: int,
}

@(private = "file")
home_path :: proc(rel: string, allocator := context.temp_allocator) -> string {
	home, _ := os.user_home_dir(context.temp_allocator)
	return strings.concatenate({home, "/", rel}, allocator)
}

jack_env_path :: proc() -> string {return home_path(".config/jackd/jackd.env")}

jack_env_read :: proc() -> (s: Jack_Settings, ok: bool) {
	data, err := os.read_entire_file(jack_env_path(), context.temp_allocator)
	if err != nil do return
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		key, _, val := strings.partition(strings.trim_space(line), "=")
		n := strconv.parse_int(val) or_continue
		switch key {
		case "JACK_RATE":     s.rate = n
		case "JACK_PERIOD":   s.period = n
		case "JACK_NPERIODS": s.nperiods = n
		}
	}
	return s, s.rate > 0 && s.period > 0 && s.nperiods > 0
}

// Rewrites the three keys in place, keeping every other line (JACK_DEVICE, comments).
jack_env_write :: proc(s: Jack_Settings) -> bool {
	path := jack_env_path()
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return false
	b := strings.builder_make(context.temp_allocator)
	seen: bit_set[0 ..< 3]
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		key, _, _ := strings.partition(strings.trim_space(line), "=")
		switch key {
		case "JACK_RATE":     fmt.sbprintfln(&b, "JACK_RATE=%d", s.rate); seen += {0}
		case "JACK_PERIOD":   fmt.sbprintfln(&b, "JACK_PERIOD=%d", s.period); seen += {1}
		case "JACK_NPERIODS": fmt.sbprintfln(&b, "JACK_NPERIODS=%d", s.nperiods); seen += {2}
		case:                 fmt.sbprintln(&b, line)
		}
	}
	if 0 not_in seen do fmt.sbprintfln(&b, "JACK_RATE=%d", s.rate)
	if 1 not_in seen do fmt.sbprintfln(&b, "JACK_PERIOD=%d", s.period)
	if 2 not_in seen do fmt.sbprintfln(&b, "JACK_NPERIODS=%d", s.nperiods)
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	return os.write_entire_file(tmp, strings.to_string(b)) == nil && os.rename(tmp, path) == nil
}

@(private = "file")
jack_open :: proc() -> ^Jack_Client {
	status: c.int
	return jack_client_open("oscmix-native", JACK_NO_START_SERVER, &status)
}

jack_live :: proc() -> (l: Jack_Live) {
	client := jack_open()
	if client == nil do return
	defer jack_client_close(client)
	return {true, int(jack_get_sample_rate(client)), int(jack_get_buffer_size(client))}
}

// Changes the period size of the running server without a restart.
jack_set_period_live :: proc(period: int) -> bool {
	client := jack_open()
	if client == nil do return false
	defer jack_client_close(client)
	return jack_set_buffer_size(client, u32(period)) == 0
}

// Runs a command; returns success and trimmed stdout+stderr (temp allocated).
run_cmd :: proc(argv: ..string) -> (ok: bool, output: string) {
	state, out, errout, err := os.process_exec({command = argv}, context.temp_allocator)
	if err != nil do return false, fmt.tprintf("%s: %v", argv[0], err)
	text := strings.trim_space(strings.concatenate({string(out), string(errout)}, context.temp_allocator))
	return state.exited && state.exit_code == 0, text
}

jackd_restart :: proc() -> (ok: bool, output: string) {
	return run_cmd("systemctl", "--user", "restart", "jackd.service")
}

audio_mode_script :: proc() -> string {return home_path(".local/bin/audio-mode")}

// "rme", "soundgrid", or "" if the script is missing.
audio_mode_get :: proc() -> string {
	ok, out := run_cmd(audio_mode_script(), "status")
	if !ok do return ""
	for line in strings.split_lines_iterator(&out) {
		if i := strings.index(line, "Mode:"); i >= 0 {
			return strings.trim_space(line[i + len("Mode:"):])
		}
	}
	return ""
}

audio_mode_set :: proc(mode: string) -> (ok: bool, output: string) {
	return run_cmd(audio_mode_script(), mode)
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
