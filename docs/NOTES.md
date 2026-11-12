# Technical notes

Findings behind the app's design, measured on a Fireface UFX III in CC mode.
Other RME devices supported by the oscmix engine may behave differently.

## Engine

The OscMix Web release v2.0.17 (v0.9.6-3f06346) of
[huddx01/oscmix](https://github.com/huddx01/oscmix) ships its V2 engine as a
standalone WASI module, `oscmix.wasm`, with the same API as `oscmix.h`:
exports `init`, `handlesysex`, `handleosc`, `handletimer` and a 4096-byte
`jsdata` buffer; imports only `env.writeosc`, `env.writemidi` and trivial WASI
calls. `app/engine/oscmix.wasm` is that file
(SHA-256 `00667e558fc41f6c25431208640668b2f79460ab089f896963337485be3c7d80`).
`wasm2c` turns it into C; `engine.c` adds the WASI stubs, trap handling and a
five-function API (`engine.h`).

The older C core on the `dev` branch cannot set submix levels on V2-mixer
devices such as the UFX III (`ctltoreg(MIX)` has no register for them), which
is why the app uses the released module.

The module keeps its function names (`newmix`, `reportmix`, `setv2reg`,
`setrefresh`, `cache_*`, …) and debug strings. Its debug log prints when the
word at memory 67684 has the category bit set (byte 67688 enables category 7);
a host can set them after `init`, output goes through WASI `fd_write`.

## OSC addresses

- Mix matrix: `/mix/(in|pb)/<source>/<submix>/<param>`, 0-based; params
  `fader` (dB, −300 = off), `faderlin`, `balpan`, `mute`, `solo`, `stereo`,
  `width`, …
- Meters: `/level/(in|pb|out)/<ch>` with peak and RMS in dBFS.
- `/hardware/interfacemode` (register `0x307C`): Auto / USB2 / USB3 / CC.
  Leaving CC for a USB mode works over SysEx; switching back needs the front
  panel (SETUP → Options → Interface Mode), since Linux has no driver for the
  USB modes.
- `/hardware/dspload`: low byte of the DSP version/load register; 9 idle,
  23 with EQ + dynamics on 8 channels.

## Registers

- Refresh: `0x3E07=1`, `0x3E04=0x67CD` (dump v2), `0x3E05=0x3481`,
  `0x3E03=0x234A` (dump v1). `0x3F00` counts 0–15 as a keepalive; SysEx
  sub-ID 2 requests meters.
- V2 mix cell: `0x4000 + in*0x40 + out/2` for inputs, `0x5780 + pb*0x40 + out/2`
  for playbacks. Value: bit 15 = right half of the output pair, bit 14 = pan
  word (`0x4000` = centre), low 13 bits signed in 0.1 dB (`0x1F38` = −20 dB,
  `0x001E` = +3 dB, off = −300 dB `0x1448`).

## Mixer readback

- The refresh dump contains every input → output cell that is on (both halves)
  and none that are off. It ends with `0x403F = 0x8000`, outside the matrix,
  which works as an end marker (`session.odin`).
- Playback cells are never dumped, also not after writing one, and writes are
  not echoed. The app therefore keeps the matrix itself
  (`~/.config/oscmix-native/`).
- The unit forgets its sends when switched off, so the app writes the last
  session back after each connect (Settings → Mixer turns this off).
- `/controlroom/phones1..4` are ignored and no `mainoutb` is reported, so
  phone outputs are pinned to the control room column locally.
- Not available: solo (no OSC parameter), device EQ/dynamics presets
  (`*/loadpreset` changes nothing), device-stored channel names.

## Pacing and timing

- **Writes:** the unit silently drops writes sent in a burst (3760 at once: about
  5 % applied, no errors). Bulk writes are queued and sent 12 per 2 ms poll
  (~6000/s); 188 of 188 distinct changes landed among 10152 paced writes.
- **Meters:** level values change every other engine tick, and the engine
  sends at most ~40 meter requests/s. With a 33 ms tick (OscMix Web) that is
  15 updates/s; 16 ms gives 20, and shorter ticks no more. Incoming SysEx stays
  ~360 messages/s regardless. The app uses 16 ms and draws meters that rise
  at once and glide down (τ 60 ms) between updates.
- **MIDI input:** the meter stream overflows the ALSA sequencer pool if it is read
  once per frame; a reader thread and a 2000-event pool fix that.
- **Rendering:** a hidden window can block in `EndDrawing` for about a second
  per frame, so the interface is polled on its own thread.

## Performance (1256×1366 window at 125 %)

Idle at 30 fps: 3.0 % of one core (9.7 % with raylib's busy-waiting frame
limiter, hence the sleep pacing). Meter stream alone: 0.3 %. Memory: 92 MB
RSS, 26.5 MB of it private; the rest is shared libraries, mostly the GPU
driver.
