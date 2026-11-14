# oscmix-native

A lightweight native TotalMix-style mixer for RME interfaces on Linux, in
Odin + raylib. It runs the oscmix engine from
[OscMix Web](https://huddx01.github.io/oscmix/) (huddx01) natively instead of
in a browser, and talks to the interface over ALSA MIDI (class-compliant mode).

> **Status:** used daily with a **Fireface UFX III in CC mode**; nothing else
> has been tested. The engine knows more RME devices, so others may work,
> but expect rough edges.

## Features

- Three mixer rows (hardware inputs, software playbacks, hardware outputs).
  Click an output to select its submix; input and playback faders then set
  the sends into it.
- Channel panels: preamp gain, 48V / Hi-Z / reference level, low cut, 3-band EQ
  with a draggable response graph, dynamics and auto level with a transfer
  curve, Room EQ on outputs.
- Control room column (Main Out, pinned phone outputs, Dim / Mono / Recall),
  plus an FX dock with reverb and echo.
- EQ / dynamics / Room EQ presets, 8 mixer snapshots, 4 fader and 4 mute
  groups, local channel names.
- The interface forgets its sends when powered off and never reports playback
  sends, so the app keeps the mix itself. It writes the last session back on
  connect (can be turned off; the first connect only records it, and sends the
  app has never seen are left alone) and offers a mixer reset.
- Peak + RMS meters, DSP load, auto-reconnect, UI scaling, a frame-rate setting
  (separate rates for focused and unfocused windows).

## Requirements

- Linux on x86-64 (the build links raylib's prebuilt `linux_amd64` release)
  with ALSA (`libasound`), an interface in **CC mode** (front panel:
  SETUP → Options → Interface Mode).
- Build tools: [Odin](https://odin-lang.org/) (tested with dev-2026-10),
  [WABT](https://github.com/WebAssembly/wabt) 1.0.42 (`wasm2c` and its runtime
  in `/usr/share/wabt/wasm2c`; adjust `WABT_RT` in the Makefile if yours
  lives elsewhere), a C compiler, `curl`, `sha256sum`.
- At run time: `fc-match` (fontconfig) to pick the UI font.

On Arch: `pacman -S odin wabt alsa-lib fontconfig curl`.

## Build and install

```sh
cd app
make            # builds ./oscmix-native; downloads checksum-pinned raylib 6.0 once
make install    # ~/.local/bin/oscmix-native + a launcher entry "oscmix"
```

`make install PREFIX=/usr/local` installs elsewhere (`DESTDIR` is honoured for packaging). `make wasm WASM=path/to/oscmix.wasm`
swaps in an engine from a newer OscMix Web release.

## Usage

```
oscmix-native [-p CLIENT:PORT]
oscmix-native [-p CLIENT:PORT] --probe [SECONDS] [ADDR VALUE]...
```

The app finds the RME control port on the ALSA sequencer by itself (the first
one the engine supports); `-p` picks any port by hand (see `aconnect -l`).
Only one window runs at a time.
`--probe` connects without a window, optionally sends OSC values, and prints
what the interface reported.

Mouse: drag faders (Shift = fine); Shift+wheel changes the value under the
pointer (Ctrl+Shift = finer); double-click = 0 dB, right-click = off. The plain
wheel only scrolls. Esc closes all panels. Ctrl +/−/0 scales the UI.

Settings and data live in `~/.config/oscmix-native/`:
- `ui.json`: window settings
- `presets.json`: presets
- `device-<uid>.json`: names, groups, snapshots, last session
- `mix-<uid>.json`: mix values

## Repository

| Path | Contents |
|---|---|
| `app/src/` | the app (Odin) |
| `app/engine/` | `oscmix.wasm`, its `wasm2c` output and the C shim around it |
| `app/raylib/` | Odin bindings for raylib 6.0 (linked statically) |
| `docs/NOTES.md` | protocol and engine findings (registers, readback limits, timing) |
| `tools/rtl/` | optional loopback round-trip latency probe (JACK or raw ALSA); not part of the app build: `cc -O2 -o rtl rtl.c $(pkg-config --cflags --libs jack alsa) -lm` |
| `contrib/` | optional patch for upstream oscmix's GTK UI (device detection, OSC drain); not used by this app |

## Credits

- [Michael Forney](https://github.com/michaelforney/oscmix): oscmix, the
  reverse-engineered RME protocol and OSC interface everything here builds on.
- [huddx01](https://github.com/huddx01/oscmix): the oscmix fork, OscMix Web
  and its V2 engine (`oscmix.wasm`), which this app embeds. Parameter ranges
  and layout follow OscMix Web.
- [raylib](https://github.com/raysan5/raylib) (Ramon Santamaria) and the
  [Odin](https://github.com/odin-lang/Odin) raylib bindings.
- [WABT](https://github.com/WebAssembly/wabt)'s `wasm2c`.

Not affiliated with or endorsed by RME.

## License

ISC, see [LICENSE](LICENSE). Bundled third-party code keeps its own license,
see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
