#ifndef OSCMIX_ENGINE_H
#define OSCMIX_ENGINE_H
#include <stdint.h>

/* Called synchronously from inside engine_* calls. buf is only valid during the call. */
typedef void (*engine_out_fn)(void *user, const uint8_t *buf, uint32_t len);

/* port: ALSA MIDI port name of the device, e.g. "Fireface UFX III (SERIAL) Port 4".
 * Returns 0 on success, -1 if no supported device matches or the engine trapped. */
int  engine_open(const char *port, engine_out_fn midi, engine_out_fn osc, void *user);
void engine_close(void);
void engine_sysex(const uint8_t *buf, uint32_t len); /* one complete F0 … F7 message */
int  engine_osc(const uint8_t *buf, uint32_t len);   /* one OSC message or bundle */
void engine_timer(int levels);                       /* call every ~33 ms */
int  engine_oscapi_json(const char **json, uint32_t *len);

#endif
