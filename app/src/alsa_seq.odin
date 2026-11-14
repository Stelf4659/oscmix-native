package oscmix_native

// Minimal ALSA sequencer client: finds the RME control port, sends and
// receives SysEx. A reader thread drains the sequencer continuously (the
// device streams meter data; polling once per frame overflows the kernel
// pool) and queues complete SysEx messages for the main thread.

import "core:c"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

foreign import asound "system:asound"

Seq :: struct {}
Seq_Client_Info :: struct {}
Seq_Port_Info :: struct {}

Seq_Addr :: struct {
	client, port: u8,
}

Seq_Ev_Ext :: struct #packed {
	len: u32,
	ptr: rawptr,
}

// snd_seq_event_t (alsa/seq_event.h), 28 bytes on all Linux ABIs.
Seq_Event :: struct {
	type:   u8,
	flags:  u8,
	tag:    u8,
	queue:  u8,
	time:   [2]u32,
	source: Seq_Addr,
	dest:   Seq_Addr,
	data:   struct #raw_union {
		ext: Seq_Ev_Ext,
		raw: [3]u32,
	},
}
#assert(size_of(Seq_Event) == 28)

SND_SEQ_OPEN_DUPLEX :: 3
SND_SEQ_NONBLOCK :: 1
SND_SEQ_KERNEL_CLIENT :: 2
SND_SEQ_EVENT_SYSEX :: 130
SND_SEQ_EVENT_LENGTH_VARIABLE :: 1 << 2
SND_SEQ_QUEUE_DIRECT :: 253
SND_SEQ_ADDRESS_SUBSCRIBERS :: 254
SND_SEQ_ADDRESS_UNKNOWN :: 253
SND_SEQ_PORT_CAP_READ :: 1 << 0
SND_SEQ_PORT_CAP_WRITE :: 1 << 1
SND_SEQ_PORT_CAP_SUBS_READ :: 1 << 5
SND_SEQ_PORT_CAP_SUBS_WRITE :: 1 << 6
SND_SEQ_PORT_TYPE_MIDI_GENERIC :: 1 << 1
SND_SEQ_PORT_TYPE_APPLICATION :: 1 << 20
EAGAIN :: 11
ENOSPC :: 28

@(default_calling_convention = "c")
foreign asound {
	snd_seq_open :: proc(seq: ^^Seq, name: cstring, streams: c.int, mode: c.int) -> c.int ---
	snd_seq_close :: proc(seq: ^Seq) -> c.int ---
	snd_seq_set_client_name :: proc(seq: ^Seq, name: cstring) -> c.int ---
	snd_seq_create_simple_port :: proc(seq: ^Seq, name: cstring, caps: c.uint, type: c.uint) -> c.int ---
	snd_seq_set_input_buffer_size :: proc(seq: ^Seq, size: c.size_t) -> c.int ---
	snd_seq_connect_from :: proc(seq: ^Seq, my_port, src_client, src_port: c.int) -> c.int ---
	snd_seq_connect_to :: proc(seq: ^Seq, my_port, dest_client, dest_port: c.int) -> c.int ---
	snd_seq_event_input :: proc(seq: ^Seq, ev: ^^Seq_Event) -> c.int ---
	snd_seq_event_output_direct :: proc(seq: ^Seq, ev: ^Seq_Event) -> c.int ---

	snd_seq_client_info_malloc :: proc(ptr: ^^Seq_Client_Info) -> c.int ---
	snd_seq_client_info_free :: proc(ptr: ^Seq_Client_Info) ---
	snd_seq_client_info_set_client :: proc(info: ^Seq_Client_Info, client: c.int) ---
	snd_seq_client_info_get_client :: proc(info: ^Seq_Client_Info) -> c.int ---
	snd_seq_client_info_get_name :: proc(info: ^Seq_Client_Info) -> cstring ---
	snd_seq_client_info_get_type :: proc(info: ^Seq_Client_Info) -> c.int ---
	snd_seq_query_next_client :: proc(seq: ^Seq, info: ^Seq_Client_Info) -> c.int ---

	snd_seq_port_info_malloc :: proc(ptr: ^^Seq_Port_Info) -> c.int ---
	snd_seq_port_info_free :: proc(ptr: ^Seq_Port_Info) ---
	snd_seq_port_info_set_client :: proc(info: ^Seq_Port_Info, client: c.int) ---
	snd_seq_port_info_set_port :: proc(info: ^Seq_Port_Info, port: c.int) ---
	snd_seq_port_info_get_port :: proc(info: ^Seq_Port_Info) -> c.int ---
	snd_seq_port_info_get_name :: proc(info: ^Seq_Port_Info) -> cstring ---
	snd_seq_port_info_get_capability :: proc(info: ^Seq_Port_Info) -> c.uint ---
	snd_seq_query_next_port :: proc(seq: ^Seq, info: ^Seq_Port_Info) -> c.int ---
	snd_seq_get_any_port_info :: proc(seq: ^Seq, client, port: c.int, info: ^Seq_Port_Info) -> c.int ---

	snd_seq_set_client_pool_input :: proc(seq: ^Seq, size: c.size_t) -> c.int ---
	snd_seq_poll_descriptors_count :: proc(seq: ^Seq, events: c.short) -> c.int ---
	snd_seq_poll_descriptors :: proc(seq: ^Seq, pfds: [^]posix.pollfd, space: c.uint, events: c.short) -> c.int ---

	snd_strerror :: proc(err: c.int) -> cstring ---
}

Midi :: struct {
	seq:       ^Seq,
	watch:     ^Seq, // main-thread handle for port queries (see midi_port_present)
	my_port:   c.int,
	client:    int,
	port:      int,
	port_name: string, // as reported by ALSA; passed to engine_open
	// reader thread → main thread queue: [u32 length][bytes]...
	reader:    ^thread.Thread,
	stop:      bool, // atomic
	lock:      sync.Mutex,
	inbox:     [dynamic]u8,
	drain:     [dynamic]u8, // main-thread side of the swap
	overruns:  int, // atomic; kernel pool overflows
	sysex:     [dynamic]u8, // reader-thread reassembly buffer
}

// Kernel MIDI clients of RME interfaces that oscmix supports.
RME_CLIENT_NAMES :: []string{"Fireface", "Babyface", "MADIface", "RME"}

Found_Port :: struct {
	client, port: int,
	name:         string,
}

// Lists RME kernel clients; for each, its last duplex port (the TotalMix control port).
midi_find_rme_ports :: proc(seq: ^Seq, allocator := context.allocator) -> [dynamic]Found_Port {
	out := make([dynamic]Found_Port, allocator)
	ci: ^Seq_Client_Info
	pi: ^Seq_Port_Info
	snd_seq_client_info_malloc(&ci)
	snd_seq_port_info_malloc(&pi)
	defer snd_seq_client_info_free(ci)
	defer snd_seq_port_info_free(pi)

	snd_seq_client_info_set_client(ci, -1)
	for snd_seq_query_next_client(seq, ci) >= 0 {
		if snd_seq_client_info_get_type(ci) != SND_SEQ_KERNEL_CLIENT do continue
		cname := string(snd_seq_client_info_get_name(ci))
		rme := false
		for n in RME_CLIENT_NAMES do if strings.contains(cname, n) do rme = true
		if !rme do continue

		client := snd_seq_client_info_get_client(ci)
		last: Found_Port = {client = -1}
		snd_seq_port_info_set_client(pi, client)
		snd_seq_port_info_set_port(pi, -1)
		need :: SND_SEQ_PORT_CAP_READ | SND_SEQ_PORT_CAP_WRITE | SND_SEQ_PORT_CAP_SUBS_READ | SND_SEQ_PORT_CAP_SUBS_WRITE
		for snd_seq_query_next_port(seq, pi) >= 0 {
			if snd_seq_port_info_get_capability(pi) & need != need do continue
			delete(last.name, allocator)
			last = {int(client), int(snd_seq_port_info_get_port(pi)), string(snd_seq_port_info_get_name(pi))}
			last.name = strings.clone(last.name, allocator)
		}
		if last.client >= 0 do append(&out, last)
	}
	return out
}

// "CLIENT:PORT" of every RME control port, in sequencer order (temp-allocated).
midi_rme_candidates :: proc() -> [dynamic]string {
	out := make([dynamic]string, context.temp_allocator)
	seq: ^Seq
	if snd_seq_open(&seq, "default", SND_SEQ_OPEN_DUPLEX, SND_SEQ_NONBLOCK) < 0 do return out
	defer snd_seq_close(seq)
	for p in midi_find_rme_ports(seq, context.temp_allocator) do append(&out, fmt.tprintf("%d:%d", p.client, p.port))
	return out
}

// Name of any sequencer port (temp-allocated); ok false if it does not exist.
@(private = "file")
port_name :: proc(seq: ^Seq, client, port: int) -> (name: string, ok: bool) {
	pi: ^Seq_Port_Info
	snd_seq_port_info_malloc(&pi)
	defer snd_seq_port_info_free(pi)
	if snd_seq_get_any_port_info(seq, c.int(client), c.int(port), pi) < 0 do return "", false
	return strings.clone(string(snd_seq_port_info_get_name(pi)), context.temp_allocator), true
}

// Opens the sequencer and connects to `target` ("CLIENT:PORT", any port).
midi_open :: proc(m: ^Midi, target: string) -> (err: string) {
	if r := snd_seq_open(&m.seq, "default", SND_SEQ_OPEN_DUPLEX, SND_SEQ_NONBLOCK); r < 0 {
		return fmt.aprintf("snd_seq_open: %s", snd_strerror(r))
	}
	snd_seq_set_client_name(m.seq, "oscmix-native")
	snd_seq_set_input_buffer_size(m.seq, 1 << 20)
	snd_seq_set_client_pool_input(m.seq, 2000) // kernel maximum per client
	m.my_port = snd_seq_create_simple_port(
		m.seq,
		"oscmix-native",
		SND_SEQ_PORT_CAP_READ | SND_SEQ_PORT_CAP_WRITE,
		SND_SEQ_PORT_TYPE_MIDI_GENERIC | SND_SEQ_PORT_TYPE_APPLICATION,
	)
	if m.my_port < 0 do return fmt.aprintf("create port: %s", snd_strerror(m.my_port))

	cs, _, ps := strings.partition(target, ":")
	client, cok := strconv.parse_int(cs, 10)
	port, pok := strconv.parse_int(ps, 10)
	name, found := port_name(m.seq, client, port)
	if !cok || !pok || !found do return fmt.aprintf("MIDI port %s not found", target)
	m.client, m.port, m.port_name = client, port, strings.clone(name)
	if r := snd_seq_connect_from(m.seq, m.my_port, c.int(m.client), c.int(m.port)); r < 0 {
		return fmt.aprintf("connect from %d:%d: %s", m.client, m.port, snd_strerror(r))
	}
	if r := snd_seq_connect_to(m.seq, m.my_port, c.int(m.client), c.int(m.port)); r < 0 {
		return fmt.aprintf("connect to %d:%d: %s", m.client, m.port, snd_strerror(r))
	}
	m.reader = thread.create_and_start_with_data(m, midi_reader)
	return ""
}

midi_close :: proc(m: ^Midi) {
	if m.reader != nil {
		sync.atomic_store(&m.stop, true)
		thread.join(m.reader)
		thread.destroy(m.reader)
	}
	if m.seq != nil do snd_seq_close(m.seq)
	if m.watch != nil do snd_seq_close(m.watch)
	delete(m.sysex)
	delete(m.inbox)
	delete(m.drain)
	delete(m.port_name)
	m^ = {}
}

midi_send :: proc(m: ^Midi, data: []u8) {
	ev := Seq_Event {
		type   = SND_SEQ_EVENT_SYSEX,
		flags  = SND_SEQ_EVENT_LENGTH_VARIABLE,
		queue  = SND_SEQ_QUEUE_DIRECT,
		source = {port = u8(m.my_port)},
		dest   = {client = SND_SEQ_ADDRESS_SUBSCRIBERS, port = SND_SEQ_ADDRESS_UNKNOWN},
	}
	ev.data.ext = {len = u32(len(data)), ptr = raw_data(data)}
	if r := snd_seq_event_output_direct(m.seq, &ev); r < 0 {
		fmt.eprintfln("midi send: %s", snd_strerror(r))
	}
}

// Max queued input while the main loop is stalled (e.g. window hidden).
MIDI_INBOX_MAX :: 8 << 20

@(private = "file")
midi_reader :: proc(data: rawptr) {
	m := (^Midi)(data)
	pfds: [4]posix.pollfd
	n := snd_seq_poll_descriptors(m.seq, &pfds[0], len(pfds), c.short(posix.POLLIN))
	last_report := time.tick_now()
	reported := 0
	for !sync.atomic_load(&m.stop) {
		posix.poll(&pfds[0], posix.nfds_t(max(n, 0)), 100)
		for {
			ev: ^Seq_Event
			r := snd_seq_event_input(m.seq, &ev)
			if r == -EAGAIN do break
			if r == -ENOSPC {
				sync.atomic_add(&m.overruns, 1)
				continue
			}
			if r < 0 do break
			if ev.type != SND_SEQ_EVENT_SYSEX do continue
			chunk := ([^]u8)(ev.data.ext.ptr)[:ev.data.ext.len]
			for b in chunk {
				if b == 0xf0 do clear(&m.sysex)
				else if len(m.sysex) == 0 do continue
				append(&m.sysex, b)
				if b == 0xf7 {
					sync.mutex_lock(&m.lock)
					if len(m.inbox) + len(m.sysex) + 4 <= MIDI_INBOX_MAX {
						n := u32(len(m.sysex))
						append(&m.inbox, ..([^]u8)(&n)[:4])
						append(&m.inbox, ..m.sysex[:])
					}
					sync.mutex_unlock(&m.lock)
					clear(&m.sysex)
				}
			}
		}
		if total := sync.atomic_load(&m.overruns); total != reported && time.duration_seconds(time.tick_since(last_report)) >= 5 {
			fmt.eprintfln("midi: %d input overruns (events lost)", total - reported)
			reported, last_report = total, time.tick_now()
		}
	}
}

// Delivers every SysEx message received since the last call (main thread);
// returns how many there were.
midi_poll :: proc(m: ^Midi, on_sysex: proc(msg: []u8, user: rawptr), user: rawptr) -> (count: int) {
	sync.mutex_lock(&m.lock)
	m.inbox, m.drain = m.drain, m.inbox
	sync.mutex_unlock(&m.lock)
	for i := 0; i + 4 <= len(m.drain); {
		n: u32
		copy(([^]u8)(&n)[:4], m.drain[i:i + 4])
		i += 4
		on_sysex(m.drain[i:i + int(n)], user)
		i += int(n)
		count += 1
	}
	clear(&m.drain)
	return
}

// True while the connected port still exists on the sequencer. Uses its own
// handle: the main one is busy in the reader thread.
midi_port_present :: proc(m: ^Midi) -> bool {
	if m.watch == nil && snd_seq_open(&m.watch, "default", SND_SEQ_OPEN_DUPLEX, SND_SEQ_NONBLOCK) < 0 {
		m.watch = nil
		return true // cannot tell; rely on the receive timeout
	}
	name, ok := port_name(m.watch, m.client, m.port)
	return ok && name == m.port_name
}
