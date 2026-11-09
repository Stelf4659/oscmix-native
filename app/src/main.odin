package oscmix_native

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

usage :: proc() {
	fmt.eprintln(`usage: oscmix-native [-p CLIENT:PORT]
       oscmix-native [-p CLIENT:PORT] --probe [SECONDS] [ADDR VALUE]...

  -p CLIENT:PORT  ALSA sequencer control port (default: auto-detect RME)
  --probe         headless: connect, refresh, optionally send ADDR VALUE pairs,
                  then print parameter counts and every /level and /mix value seen`)
}

main :: proc() {
	port := ""
	probe := false
	probe_secs := 3.0
	sends: [dynamic][2]string
	defer delete(sends)

	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "-p":
			if i + 1 >= len(args) { usage(); os.exit(2) }
			i += 1
			port = args[i]
		case "--probe":
			probe = true
			if i + 1 < len(args) {
				if s, ok := strconv.parse_f64(args[i + 1]); ok { probe_secs = s; i += 1 }
			}
		case "-h", "--help":
			usage()
			return
		case:
			if probe && i + 1 < len(args) && strings.has_prefix(args[i], "/") {
				append(&sends, [2]string{args[i], args[i + 1]})
				i += 1
			} else {
				usage()
				os.exit(2)
			}
		}
	}

	app: App
	if probe {
		code := run_probe(&app, port, probe_secs, sends[:])
		app_shutdown(&app)
		os.exit(code)
	}
	if !instance_lock() {
		fmt.eprintln("oscmix-native is already running")
		os.exit(1)
	}
	run_ui(&app, port)
	app_shutdown(&app)
}

run_probe :: proc(app: ^App, port: string, secs: f64, sends: [][2]string) -> int {
	if !app_connect(app, port) {
		fmt.eprintln("error:", app.error)
		return 1
	}
	fmt.printfln("connected: %s (seq %d:%d)", app.device, app.midi.client, app.midi.port)
	pump :: proc(app: ^App, secs: f64) {
		start := time.tick_now()
		for time.duration_seconds(time.tick_since(start)) < secs {
			app_poll(app)
			time.sleep(2 * time.Millisecond)
		}
	}
	pump(app, secs)
	fmt.printfln("after refresh: %d parameters", len(app.st.vals))
	fmt.printfln("device: name=%q uid=%q inputs=%v outputs=%v",
		state_str(&app.st, "/device/name"), state_str(&app.st, "/device/uid"),
		state_get(&app.st, "/device/inputs"), state_get(&app.st, "/device/outputs"))
	for s in sends {
		v, ok := strconv.parse_f32(s[1])
		if !ok { fmt.eprintln("bad value:", s[1]); return 2 }
		app_send(app, s[0], v)
		fmt.printfln("sent %s %v", s[0], v)
		pump(app, 1)
		for addr, &e in app.st.vals {
			if (strings.has_prefix(addr, "/level/") && e.n > 0 && e.f[0] > -120) || strings.has_prefix(addr, "/mix/") {
				fmt.printfln("  %s %v", addr, e.f[:e.n])
			}
		}
	}
	nmix := 0
	for addr in app.st.vals do if strings.has_prefix(addr, "/mix/") do nmix += 1
	fmt.printfln("mix values known: %d, saved to %s", nmix, app.st.mix_path)
	return 0
}
