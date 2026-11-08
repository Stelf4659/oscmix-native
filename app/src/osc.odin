package oscmix_native

// OSC 1.0 encode/decode for the engine's in-process OSC stream.

import "core:encoding/endian"

MAX_OSC_ARGS :: 4

Osc_Arg :: union {
	f32,
	i32,
	string, // aliases the input buffer; copy before keeping
	bool,
}

Osc_Msg :: struct {
	addr: string,
	args: [MAX_OSC_ARGS]Osc_Arg,
	argc: int,
}

@(private = "file")
osc_pad :: proc(n: int) -> int {return (n + 4) &~ 3}

@(private = "file")
read_str :: proc(b: []u8, i: int) -> (s: string, next: int, ok: bool) {
	for j in i ..< len(b) {
		if b[j] == 0 {
			return string(b[i:j]), i + osc_pad(j - i), true
		}
	}
	return "", 0, false
}

// Calls fn for every message in buf (message or nested bundles).
osc_decode :: proc(buf: []u8, fn: proc(msg: ^Osc_Msg, user: rawptr), user: rawptr) {
	if len(buf) >= 16 && string(buf[:8]) == "#bundle\x00" {
		i := 16
		for i + 4 <= len(buf) {
			n := int(endian.unchecked_get_u32be(buf[i:]))
			i += 4
			if n < 0 || i + n > len(buf) do return
			osc_decode(buf[i:i + n], fn, user)
			i += n
		}
		return
	}
	msg: Osc_Msg
	addr, i, ok := read_str(buf, 0)
	if !ok || len(addr) == 0 || addr[0] != '/' do return
	msg.addr = addr
	tags: string
	if i < len(buf) && buf[i] == ',' {
		tags, i, ok = read_str(buf, i)
		if !ok do return
		tags = tags[1:]
	}
	for t in tags {
		arg: Osc_Arg
		switch t {
		case 'f':
			if i + 4 > len(buf) do return
			arg = transmute(f32)endian.unchecked_get_u32be(buf[i:])
			i += 4
		case 'i':
			if i + 4 > len(buf) do return
			arg = i32(endian.unchecked_get_u32be(buf[i:]))
			i += 4
		case 's':
			s: string
			s, i, ok = read_str(buf, i)
			if !ok do return
			arg = s
		case 'T':
			arg = true
		case 'F':
			arg = false
		case 'N':
			arg = nil
		case:
			return // unknown tag: skip message
		}
		if msg.argc < MAX_OSC_ARGS {
			msg.args[msg.argc] = arg
			msg.argc += 1
		}
	}
	fn(&msg, user)
}

// Encodes `addr` with float args (the engine accepts 'f' for every numeric param).
osc_encode :: proc(out: ^[dynamic]u8, addr: string, args: ..f32) {
	clear(out)
	append(out, addr)
	for _ in len(addr) ..< osc_pad(len(addr)) do append(out, 0)
	tags := len(args) + 1
	append(out, ',')
	for _ in args do append(out, 'f')
	for _ in tags ..< osc_pad(tags) do append(out, 0)
	for a in args {
		be: [4]u8
		endian.unchecked_put_u32be(be[:], transmute(u32)a)
		append(out, ..be[:])
	}
}
