/*
 * Round-trip latency probe for a physical loopback (out -> cable -> in).
 *
 *   rtl jack OUTPORT INPORT [seconds]
 *       Runs as a JACK client (use pw-jack under PipeWire). Emits a click
 *       on OUTPORT and measures frames until it shows up on INPORT.
 *   rtl alsa DEVICE CHANNELS OUTCH INCH PERIOD NPERIODS [seconds]
 *       Opens the hw device directly (full duplex, linked streams), i.e.
 *       the snd-usb-audio best case with no sound server in between.
 *
 * Latency = absolute capture frame of the click onset minus absolute
 * playback frame at which it was written. Onset = first sample >= 30 % of
 * the window peak, so the result includes AD/DA filter delay.
 */
#include <alsa/asoundlib.h>
#include <jack/jack.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define CLICK_LEN 4
#define CLICK_AMP 0.8f
#define MAXHITS 256

static double hits[MAXHITS];
static int nhits;

static int
cmpd(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return x < y ? -1 : x > y;
}

static void
report(const char *label, double rate)
{
	if (nhits == 0) {
		printf("%s: no click detected (check cable, routing, gain)\n", label);
		return;
	}
	qsort(hits, nhits, sizeof hits[0], cmpd);
	double med = hits[nhits / 2];
	printf("%s: n=%d  min=%.0f  median=%.0f  max=%.0f frames  ->  median %.3f ms @ %.0f Hz\n",
	       label, nhits, hits[0], med, hits[nhits - 1], med * 1000.0 / rate, rate);
}

/* Detector shared by both backends: feed captured samples with their
 * absolute frame index; a click emitted at frame `sent` is searched for in
 * the following `window` frames. */
struct det {
	int64_t sent;     /* -1: idle */
	int64_t window;
	float peak;
	int64_t peakpos;
	float *buf;       /* window samples */
};

static void
det_feed(struct det *d, const float *x, int64_t frame0, int n)
{
	if (d->sent < 0)
		return;
	for (int i = 0; i < n; i++) {
		int64_t f = frame0 + i - d->sent;
		if (f < 0 || f >= d->window)
			continue;
		d->buf[f] = x[i];
		if (fabsf(x[i]) > d->peak) {
			d->peak = fabsf(x[i]);
			d->peakpos = f;
		}
	}
	if (frame0 + n - d->sent >= d->window) {
		if (d->peak > 0.001f && nhits < MAXHITS) {
			for (int64_t f = 0; f <= d->peakpos; f++) {
				if (fabsf(d->buf[f]) >= 0.3f * d->peak) {
					hits[nhits++] = f;
					break;
				}
			}
		}
		d->sent = -1;
	}
}

/* ---------------- JACK ---------------- */

static jack_client_t *jc;
static jack_port_t *jout, *jin;
static struct det jdet;
static int64_t jnext;
static int64_t jinterval;

static int
jprocess(jack_nframes_t n, void *arg)
{
	(void)arg;
	float *out = jack_port_get_buffer(jout, n);
	const float *in = jack_port_get_buffer(jin, n);
	int64_t t = jack_last_frame_time(jc);

	memset(out, 0, n * sizeof *out);
	det_feed(&jdet, in, t, n);
	if (jdet.sent < 0 && t >= jnext) {
		for (int i = 0; i < CLICK_LEN && i < (int)n; i++)
			out[i] = CLICK_AMP;
		jdet.sent = t;
		jdet.peak = 0;
		memset(jdet.buf, 0, jdet.window * sizeof *jdet.buf);
		jnext = t + jinterval;
	}
	return 0;
}

static int
run_jack(const char *outport, const char *inport, int secs)
{
	jc = jack_client_open("rtl", JackNoStartServer, NULL);
	if (!jc) {
		fprintf(stderr, "jack_client_open failed\n");
		return 1;
	}
	double rate = jack_get_sample_rate(jc);
	jout = jack_port_register(jc, "out", JACK_DEFAULT_AUDIO_TYPE, JackPortIsOutput, 0);
	jin = jack_port_register(jc, "in", JACK_DEFAULT_AUDIO_TYPE, JackPortIsInput, 0);
	jdet.sent = -1;
	jdet.window = (int64_t)(rate * 0.1);
	jdet.buf = calloc(jdet.window, sizeof *jdet.buf);
	jinterval = (int64_t)(rate * 0.25);
	jack_set_process_callback(jc, jprocess, NULL);
	if (jack_activate(jc)) {
		fprintf(stderr, "jack_activate failed\n");
		return 1;
	}
	if (jack_connect(jc, "rtl:out", outport) || jack_connect(jc, inport, "rtl:in")) {
		fprintf(stderr, "connect failed (%s / %s)\n", outport, inport);
		return 1;
	}
	sleep(1);
	nhits = 0;
	sleep(secs);
	jack_deactivate(jc);
	char label[64];
	snprintf(label, sizeof label, "jack bufsize=%u", jack_get_buffer_size(jc));
	report(label, rate);
	jack_client_close(jc);
	return 0;
}

/* ---------------- raw ALSA ---------------- */

static snd_pcm_t *
aopen(const char *dev, snd_pcm_stream_t dir, unsigned ch, unsigned rate,
      snd_pcm_uframes_t period, unsigned nper)
{
	snd_pcm_t *p;
	snd_pcm_hw_params_t *hw;
	snd_pcm_sw_params_t *sw;
	int err;

	if ((err = snd_pcm_open(&p, dev, dir, 0)) < 0) {
		fprintf(stderr, "open %s: %s\n", dev, snd_strerror(err));
		exit(1);
	}
	snd_pcm_hw_params_alloca(&hw);
	snd_pcm_hw_params_any(p, hw);
	snd_pcm_hw_params_set_access(p, hw, SND_PCM_ACCESS_RW_INTERLEAVED);
	snd_pcm_hw_params_set_format(p, hw, SND_PCM_FORMAT_S32_LE);
	snd_pcm_hw_params_set_channels(p, hw, ch);
	snd_pcm_hw_params_set_rate(p, hw, rate, 0);
	if ((err = snd_pcm_hw_params_set_period_size(p, hw, period, 0)) < 0) {
		fprintf(stderr, "period %lu: %s\n", period, snd_strerror(err));
		exit(1);
	}
	if ((err = snd_pcm_hw_params_set_periods(p, hw, nper, 0)) < 0) {
		fprintf(stderr, "periods %u: %s\n", nper, snd_strerror(err));
		exit(1);
	}
	if ((err = snd_pcm_hw_params(p, hw)) < 0) {
		fprintf(stderr, "hw_params: %s\n", snd_strerror(err));
		exit(1);
	}
	snd_pcm_sw_params_alloca(&sw);
	snd_pcm_sw_params_current(p, sw);
	snd_pcm_sw_params_set_start_threshold(p, sw, dir == SND_PCM_STREAM_PLAYBACK ? period * nper : 1);
	snd_pcm_sw_params_set_avail_min(p, sw, period);
	snd_pcm_sw_params(p, sw);
	return p;
}

static int
run_alsa(const char *dev, unsigned ch, unsigned och, unsigned ich,
         unsigned period, unsigned nper, int secs)
{
	const unsigned rate = 48000;
	snd_pcm_t *pb = aopen(dev, SND_PCM_STREAM_PLAYBACK, ch, rate, period, nper);
	snd_pcm_t *cp = aopen(dev, SND_PCM_STREAM_CAPTURE, ch, rate, period, nper);
	int32_t *obuf = calloc((size_t)period * ch, sizeof *obuf);
	int32_t *ibuf = calloc((size_t)period * ch, sizeof *ibuf);
	float *mono = calloc(period, sizeof *mono);
	struct det d = {.sent = -1, .window = rate / 10};
	int64_t rpos = 0, next = rate;

	d.buf = calloc(d.window, sizeof *d.buf);
	if (snd_pcm_link(cp, pb) < 0)
		fprintf(stderr, "warning: snd_pcm_link failed, streams start separately\n");
	/* Prefill the playback buffer; with linked streams this starts both. */
	for (unsigned i = 0; i < nper; i++)
		snd_pcm_writei(pb, obuf, period);
	snd_pcm_start(cp);

	int64_t end = (int64_t)rate * (secs + 1);
	nhits = 0;
	while (rpos < end) {
		snd_pcm_sframes_t r = snd_pcm_readi(cp, ibuf, period);
		if (r < 0) {
			fprintf(stderr, "capture: %s\n", snd_strerror(r));
			return 1;
		}
		for (snd_pcm_sframes_t i = 0; i < r; i++)
			mono[i] = ibuf[i * ch + ich] / 2147483648.0f;
		if (rpos >= rate) /* skip the first second (settling) */
			det_feed(&d, mono, rpos, r);
		rpos += r;

		memset(obuf, 0, (size_t)period * ch * sizeof *obuf);
		/* Time the click on the capture clock: it is written right after
		 * capture frame `rpos` was read, so the onset offset from rpos is
		 * the input-to-output round trip of a pass-through app. */
		if (d.sent < 0 && rpos >= next) {
			for (int i = 0; i < CLICK_LEN; i++)
				obuf[i * ch + och] = (int32_t)(CLICK_AMP * 2147483647.0f);
			d.sent = rpos;
			d.peak = 0;
			memset(d.buf, 0, d.window * sizeof *d.buf);
			next = rpos + rate / 4;
		}
		snd_pcm_sframes_t w = snd_pcm_writei(pb, obuf, period);
		if (w < 0) {
			fprintf(stderr, "playback: %s\n", snd_strerror(w));
			return 1;
		}
	}
	char label[64];
	snprintf(label, sizeof label, "alsa period=%u nperiods=%u", period, nper);
	report(label, rate);
	snd_pcm_close(pb);
	snd_pcm_close(cp);
	return 0;
}

int
main(int argc, char *argv[])
{
	if (argc >= 2 && strcmp(argv[1], "ports") == 0) {
		jack_client_t *c = jack_client_open("rtl-ports", JackNoStartServer, NULL);
		if (!c) {
			fprintf(stderr, "no JACK server\n");
			return 1;
		}
		const char **p = jack_get_ports(c, argc > 2 ? argv[2] : NULL, NULL, 0);
		printf("rate %u, buffer %u, ports %d\n", jack_get_sample_rate(c), jack_get_buffer_size(c), 0);
		for (; p && *p; p++) {
			const char **conn = jack_port_get_all_connections(c, jack_port_by_name(c, *p));
			printf("%s", *p);
			for (const char **q = conn; q && *q; q++)
				printf("  -> %s", *q);
			putchar('\n');
		}
		jack_client_close(c);
		return 0;
	}
	if (argc >= 4 && strcmp(argv[1], "jack") == 0)
		return run_jack(argv[2], argv[3], argc > 4 ? atoi(argv[4]) : 5);
	if (argc >= 8 && strcmp(argv[1], "alsa") == 0) {
		int ch = atoi(argv[3]), och = atoi(argv[4]), ich = atoi(argv[5]);
		int period = atoi(argv[6]), nper = atoi(argv[7]);
		if (ch > 0 && och >= 0 && och < ch && ich >= 0 && ich < ch && period > 0 && nper > 0)
			return run_alsa(argv[2], ch, och, ich, period, nper, argc > 8 ? atoi(argv[8]) : 5);
		fprintf(stderr, "rtl: need CHANNELS > 0, 0 <= OUTCH/INCH < CHANNELS, PERIOD and NPERIODS > 0\n");
		return 2;
	}
	fprintf(stderr, "usage: rtl jack OUTPORT INPORT [secs]\n"
	                "       rtl alsa DEVICE CHANNELS OUTCH INCH PERIOD NPERIODS [secs]\n");
	return 2;
}
