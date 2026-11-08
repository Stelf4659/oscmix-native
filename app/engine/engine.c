/* Host shim around huddx01's oscmix.wasm (converted to C by wasm2c).
 * Exposes a small C API for the Odin app; see engine.h. */
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "wasm-rt-exceptions.h"
#include "wasm-rt-impl.h"
#include "oscmix_w2c.h"
#include "engine.h"

struct w2c_env { int unused; };
struct w2c_wasi__snapshot__preview1 { int unused; };

static w2c_oscmix inst;
static struct w2c_env env;
static struct w2c_wasi__snapshot__preview1 wasi;
static engine_out_fn midi_cb, osc_cb;
static void *cb_user;
static int opened;

enum { WASI_ESUCCESS = 0, WASI_EBADF = 8, WASI_ENOSYS = 52 };

static u8 *mem(void) { return w2c_oscmix_memory(&inst)->data; }
static u64 memsize(void) { return w2c_oscmix_memory(&inst)->size; }
static int inbounds(u32 p, u64 n) { return (u64)p + n <= memsize(); }
static void put32(u32 p, u32 v) { if (inbounds(p, 4)) memcpy(mem() + p, &v, 4); }
static void put64(u32 p, u64 v) { if (inbounds(p, 8)) memcpy(mem() + p, &v, 8); }
static u32 get32(u32 p) { u32 v = 0; if (inbounds(p, 4)) memcpy(&v, mem() + p, 4); return v; }

/* imports: env */
void w2c_env_writemidi(struct w2c_env *e, u32 p, u32 l)
{
	(void)e;
	if (midi_cb && inbounds(p, l)) midi_cb(cb_user, mem() + p, l);
}

void w2c_env_writeosc(struct w2c_env *e, u32 p, u32 l)
{
	(void)e;
	if (osc_cb && inbounds(p, l)) osc_cb(cb_user, mem() + p, l);
}

/* imports: WASI (only stdout/stderr logging and the clock do anything) */
#define W struct w2c_wasi__snapshot__preview1 *w
u32 w2c_wasi__snapshot__preview1_fd_write(W, u32 fd, u32 iovs, u32 n, u32 nwritten)
{
	(void)w;
	u32 total = 0;
	for (u32 i = 0; i < n; i++) {
		u32 p = get32(iovs + i * 8), l = get32(iovs + i * 8 + 4);
		if ((fd == 1 || fd == 2) && inbounds(p, l)) fwrite(mem() + p, 1, l, stderr);
		total += l;
	}
	put32(nwritten, total);
	return WASI_ESUCCESS;
}
u32 w2c_wasi__snapshot__preview1_clock_time_get(W, u32 id, u64 prec, u32 out)
{
	(void)w; (void)prec;
	struct timespec ts;
	clock_gettime(id == 0 ? CLOCK_REALTIME : CLOCK_MONOTONIC, &ts);
	put64(out, (u64)ts.tv_sec * 1000000000u + (u64)ts.tv_nsec);
	return WASI_ESUCCESS;
}
u32 w2c_wasi__snapshot__preview1_environ_sizes_get(W, u32 c, u32 s) { (void)w; put32(c, 0); put32(s, 0); return 0; }
u32 w2c_wasi__snapshot__preview1_environ_get(W, u32 a, u32 b) { (void)w; (void)a; (void)b; return 0; }
u32 w2c_wasi__snapshot__preview1_fd_prestat_get(W, u32 fd, u32 p) { (void)w; (void)fd; (void)p; return WASI_EBADF; }
u32 w2c_wasi__snapshot__preview1_fd_prestat_dir_name(W, u32 a, u32 b, u32 c) { (void)w; (void)a; (void)b; (void)c; return WASI_EBADF; }
u32 w2c_wasi__snapshot__preview1_fd_close(W, u32 fd) { (void)w; (void)fd; return WASI_ENOSYS; }
u32 w2c_wasi__snapshot__preview1_fd_fdstat_get(W, u32 fd, u32 p) { (void)w; (void)fd; (void)p; return WASI_ENOSYS; }
u32 w2c_wasi__snapshot__preview1_fd_fdstat_set_flags(W, u32 fd, u32 f) { (void)w; (void)fd; (void)f; return WASI_ENOSYS; }
u32 w2c_wasi__snapshot__preview1_fd_read(W, u32 a, u32 b, u32 c, u32 d) { (void)w; (void)a; (void)b; (void)c; (void)d; return WASI_ENOSYS; }
u32 w2c_wasi__snapshot__preview1_fd_seek(W, u32 a, u64 b, u32 c, u32 d) { (void)w; (void)a; (void)b; (void)c; (void)d; return WASI_ENOSYS; }
u32 w2c_wasi__snapshot__preview1_path_create_directory(W, u32 a, u32 b, u32 c) { (void)w; (void)a; (void)b; (void)c; return WASI_ENOSYS; }
u32 w2c_wasi__snapshot__preview1_path_open(W, u32 a, u32 b, u32 c, u32 d, u32 e, u64 f, u64 g, u32 h, u32 i)
{ (void)w; (void)a; (void)b; (void)c; (void)d; (void)e; (void)f; (void)g; (void)h; (void)i; return WASI_ENOSYS; }
void w2c_wasi__snapshot__preview1_proc_exit(W, u32 code)
{
	(void)w;
	fprintf(stderr, "oscmix.wasm: proc_exit(%u)\n", code);
	wasm_rt_trap(WASM_RT_TRAP_UNREACHABLE);
}
#undef W

static u32 jsdata(void) { return *w2c_oscmix_jsdata(&inst); }
static u32 jsdatalen(void) { return get32(*w2c_oscmix_jsdatalen(&inst)); }

static int trapped(wasm_rt_trap_t t, const char *where)
{
	fprintf(stderr, "oscmix engine trap in %s: %s\n", where, wasm_rt_strerror(t));
	return -1;
}

int engine_open(const char *port, engine_out_fn midi, engine_out_fn osc, void *user)
{
	if (opened) return -1;
	midi_cb = midi, osc_cb = osc, cb_user = user;
	wasm_rt_init();
	wasm2c_oscmix_instantiate(&inst, &env, &wasi);
	opened = 1;
	wasm_rt_trap_t t = wasm_rt_impl_try();
	if (t) {
		trapped(t, "init");
		engine_close();
		return -1;
	}
	w2c_oscmix_0x5Finitialize(&inst);
	size_t n = strlen(port) + 1;
	if (n <= jsdatalen()) {
		memcpy(mem() + jsdata(), port, n);
		if (w2c_oscmix_init(&inst, jsdata()) == 0) return 0;
	}
	engine_close(); /* allow a later retry */
	return -1;
}

void engine_close(void)
{
	if (!opened) return;
	wasm2c_oscmix_free(&inst);
	wasm_rt_free();
	opened = 0;
}

void engine_sysex(const uint8_t *buf, uint32_t len)
{
	if (!opened || len > jsdatalen()) return;
	wasm_rt_trap_t t = wasm_rt_impl_try();
	if (t) { trapped(t, "handlesysex"); return; }
	memcpy(mem() + jsdata(), buf, len);
	w2c_oscmix_handlesysex(&inst, jsdata(), len, jsdata());
}

int engine_osc(const uint8_t *buf, uint32_t len)
{
	if (!opened || len > jsdatalen()) return -1;
	wasm_rt_trap_t t = wasm_rt_impl_try();
	if (t) return trapped(t, "handleosc");
	memcpy(mem() + jsdata(), buf, len);
	return (int)w2c_oscmix_handleosc(&inst, jsdata(), len);
}

void engine_timer(int levels)
{
	if (!opened) return;
	wasm_rt_trap_t t = wasm_rt_impl_try();
	if (t) { trapped(t, "handletimer"); return; }
	w2c_oscmix_handletimer(&inst, levels ? 1 : 0);
}

int engine_oscapi_json(const char **json, uint32_t *len)
{
	if (!opened) return -1;
	*json = (const char *)mem() + *w2c_oscmix_oscapi_json(&inst);
	*len = get32(*w2c_oscmix_oscapi_json_len(&inst));
	return 0;
}
