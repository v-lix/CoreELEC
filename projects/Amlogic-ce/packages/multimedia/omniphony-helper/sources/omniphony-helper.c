/*
 * omniphony-helper.c - decode and render object audio in a process of its own.
 *
 * CoreELEC on this hardware runs a 32-bit userspace on a 64-bit kernel. The
 * renderer and its decoder bridge are shared libraries, so they take the word
 * size of whoever loads them - and that would be Kodi, at 32 bits. Measured on
 * an S922X, the same work costs roughly twice as much there: Dolby Digital Plus
 * Atmos decodes at 0.419 of realtime in 32-bit against 0.204 in 64-bit. The
 * only way to reach the faster figure without rebuilding the whole image is to
 * put the work in a 64-bit process and talk to it over pipes, which was
 * measured to cost nothing.
 *
 * So: this program reads commands on stdin and writes rendered stereo on
 * stdout. It owns no audio device and no clock. Kodi owns both, and a helper
 * that opened an output of its own would be fighting it.
 *
 * It deliberately does not use the engine's own `orender` CLI, which can
 * already do stdin to stdout: on Linux that binary depends unconditionally on
 * PipeWire, so it cannot be built without a PipeWire sysroot for the target.
 * This talks to the same C ABI and needs nothing else.
 *
 *
 * THE PROTOCOL
 *
 * Both directions are framed with a 16-byte header, so a reader can always
 * find the next boundary without parsing what came before.
 *
 * Host to helper:
 *
 *     "OMNC"  op:u8  flags:u8  reserved:u16  len:u32  reserved:u32
 *     payload, len bytes
 *
 * There is deliberately no presentation timestamp on the way in. The C ABI's
 * `orender_process` takes one and ignores it - the parameter is spelled
 * `_pts_us` - and the engine derives the timestamp it reports from the stream
 * itself. Carrying a field the engine discards would invite a host to believe
 * it was doing something.
 *
 *   OPEN  (1)  payload is `key=value` lines, one per line: `lib` (required,
 *              the engine to load), and `config`, `layout`, `bridge` and
 *              `codec`. Must come first. Unknown keys are ignored, so a newer
 *              host can send a key this build does not know.
 *   FEED  (2)  payload is one raw encoded packet, exactly as it comes off
 *              Kodi's stream parser before the passthrough packer.
 *   FLUSH (3)  no payload. See the note on its limits below.
 *   RESET (4)  no payload. A seek happened: drop decoder and renderer state.
 *   CLOSE (5)  no payload. Tear down and exit 0.
 *
 * Helper to host:
 *
 *     "OMNI"  frames:u32  pts_us:i64                 then frames*2 float32
 *     "OMNS"  code:u32    len:u32   reserved:u32     then len bytes of UTF-8
 *
 * Audio and status share the stream; the magic tells them apart and the length
 * is always in the header, so a host that does not care about status frames can
 * skip them without understanding them.
 *
 * All integers are little-endian, which every target this runs on is natively.
 *
 *
 * WHAT FLUSH CAN AND CANNOT DO
 *
 * The C ABI is push-only: `orender_process` renders what a packet yields and
 * there is no drain call. So FLUSH cannot extract audio the decoder is still
 * holding - it acknowledges, and nothing more. It exists so the host has a
 * defined way to mark the end of a segment now, rather than the protocol
 * gaining an incompatible sixth command later. If the ABI grows a drain, FLUSH
 * is where it goes.
 *
 *
 * ON DEADLOCK
 *
 * This program blocks when it reads and blocks when it writes. That is safe
 * only because the host polls both directions and drains output as it arrives -
 * the topology already validated in the out-of-process measurement. A host that
 * feeds without reading will fill the pipe and both processes will stop.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "orender.h"

/* ---- protocol ----------------------------------------------------------- */

#define HDR_LEN 16

#define OP_OPEN 1
#define OP_FEED 2
#define OP_FLUSH 3
#define OP_RESET 4
#define OP_CLOSE 5

#define ST_OK 0
#define ST_PROTOCOL 1
#define ST_OPEN_FAILED 2
#define ST_STATE 3
#define ST_DECODE 4
#define ST_INFO 5

/* A FEED payload is one encoded packet. TrueHD access units are the largest
 * thing we expect and they are far below this; the cap is here so a corrupt
 * length field cannot ask us to allocate the machine. */
#define MAX_PAYLOAD (1u << 20)

/* The renderer writes interleaved floats here. It starts modest and grows only
 * when the engine says the buffer was too small, up to a hard ceiling - a
 * stream that somehow demanded more than this is refused rather than allowed to
 * exhaust memory. 4 Mi floats is 16 MB, and about 43 seconds of stereo. */
#define OUT_FLOATS_INITIAL (1u << 16)
#define OUT_FLOATS_MAX (1u << 22)

/* ---- engine binding ----------------------------------------------------- */

typedef struct
{
  OrenderRenderer* (*create)(const OrenderConfig*);
  void (*destroy)(OrenderRenderer*);
  void (*reset)(OrenderRenderer*);
  int (*process)(OrenderRenderer*, const uint8_t*, uintptr_t, int64_t, float*, uintptr_t,
                 uintptr_t*, uint32_t*, int64_t*);
  int (*object_count)(const OrenderRenderer*);
  int (*has_objects)(const OrenderRenderer*);
  uint32_t (*bed_layout)(const OrenderRenderer*, uint8_t*, uint32_t);
  uint32_t (*version_major)(void);
  uint32_t (*version_minor)(void);
} Api;

static Api api;
static void* lib_handle;

/* ---- io ----------------------------------------------------------------- */

static int write_all(int fd, const void* buf, size_t len)
{
  const uint8_t* p = (const uint8_t*)buf;
  while (len)
  {
    const ssize_t n = write(fd, p, len);
    if (n > 0)
    {
      p += (size_t)n;
      len -= (size_t)n;
    }
    else if (n < 0 && errno == EINTR)
      continue;
    else
      return -1;
  }
  return 0;
}

/* Returns 1 on a full read, 0 on a clean end of stream before any byte, and -1
 * when the stream ended mid-way through - which is a truncated command, not an
 * orderly shutdown, and the caller reports it as such. */
static int read_exact(int fd, void* buf, size_t len)
{
  uint8_t* p = (uint8_t*)buf;
  size_t got = 0;
  while (got < len)
  {
    const ssize_t n = read(fd, p + got, len - got);
    if (n > 0)
      got += (size_t)n;
    else if (n == 0)
      return got == 0 ? 0 : -1;
    else if (errno == EINTR)
      continue;
    else
      return -1;
  }
  return 1;
}

static void put_u32(uint8_t* p, uint32_t v)
{
  memcpy(p, &v, 4);
}

static uint32_t get_u32(const uint8_t* p)
{
  uint32_t v;
  memcpy(&v, p, 4);
  return v;
}

/* A status frame is never worth dying for: if the host has stopped reading we
 * will find out on the next audio write, which is the one that matters. */
static void emit_status(uint32_t code, const char* fmt, ...)
{
  char text[512];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(text, sizeof(text), fmt, ap);
  va_end(ap);
  if (n < 0)
    return;
  if ((size_t)n >= sizeof(text))
    n = (int)sizeof(text) - 1;

  uint8_t hdr[HDR_LEN];
  memcpy(hdr, "OMNS", 4);
  put_u32(hdr + 4, code);
  put_u32(hdr + 8, (uint32_t)n);
  put_u32(hdr + 12, 0);
  if (write_all(STDOUT_FILENO, hdr, HDR_LEN) != 0)
    return;
  (void)write_all(STDOUT_FILENO, text, (size_t)n);
}

static int emit_audio(uint32_t frames, int64_t pts_us, const float* samples, size_t nfloats)
{
  uint8_t hdr[HDR_LEN];
  memcpy(hdr, "OMNI", 4);
  put_u32(hdr + 4, frames);
  memcpy(hdr + 8, &pts_us, 8);
  if (write_all(STDOUT_FILENO, hdr, HDR_LEN) != 0)
    return -1;
  return write_all(STDOUT_FILENO, samples, nfloats * sizeof(float));
}

/* ---- OPEN payload ------------------------------------------------------- */

/* `key=value` lines. Text rather than a packed struct so a failed open can be
 * diagnosed by reading the pipe, and so adding a key later cannot silently
 * shift the meaning of the bytes after it. Values are borrowed from the buffer,
 * which outlives the renderer. */
typedef struct
{
  const char* lib;
  const char* config;
  const char* layout;
  const char* bridge;
  const char* codec;
} OpenArgs;

static void parse_open(char* text, size_t len, OpenArgs* out)
{
  memset(out, 0, sizeof(*out));
  char* p = text;
  char* end = text + len;
  while (p < end)
  {
    char* nl = memchr(p, '\n', (size_t)(end - p));
    if (nl)
      *nl = '\0';
    else
      end[0] = '\0'; /* the caller reserved room for this */

    char* eq = strchr(p, '=');
    if (eq)
    {
      *eq = '\0';
      const char* k = p;
      const char* v = eq + 1;
      if (strcmp(k, "lib") == 0)
        out->lib = v;
      else if (strcmp(k, "config") == 0)
        out->config = v;
      else if (strcmp(k, "layout") == 0)
        out->layout = v;
      else if (strcmp(k, "bridge") == 0)
        out->bridge = v;
      else if (strcmp(k, "codec") == 0)
        out->codec = v;
      /* Unknown keys are ignored on purpose: a newer host may send a key this
       * build does not know, and refusing the whole stream over it would be a
       * worse failure than proceeding without it. */
    }
    if (!nl)
      break;
    p = nl + 1;
  }
}

static int bind_engine(const char* path)
{
  lib_handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (!lib_handle)
  {
    emit_status(ST_OPEN_FAILED, "dlopen %s: %s", path, dlerror());
    return -1;
  }

#define SYM(field, name)                                                                           \
  do                                                                                               \
  {                                                                                                \
    *(void**)(&api.field) = dlsym(lib_handle, name);                                               \
    if (!api.field)                                                                                \
    {                                                                                              \
      emit_status(ST_OPEN_FAILED, "engine is missing %s", name);                                   \
      return -1;                                                                                   \
    }                                                                                              \
  } while (0)

  SYM(version_major, "orender_version_major");
  if (api.version_major() != ORENDER_ABI_MAJOR)
  {
    emit_status(ST_OPEN_FAILED, "engine ABI major %u, this helper wants %u",
                api.version_major(), ORENDER_ABI_MAJOR);
    return -1;
  }
  SYM(create, "orender_create");
  SYM(destroy, "orender_destroy");
  SYM(reset, "orender_reset");
  SYM(process, "orender_process");
#undef SYM

  /* Optional, and probed rather than required: they exist to tell the host what
   * the stream turned out to contain, and an engine without them should still
   * render. */
  *(void**)(&api.object_count) = dlsym(lib_handle, "orender_object_count");
  *(void**)(&api.has_objects) = dlsym(lib_handle, "orender_has_objects");
  *(void**)(&api.bed_layout) = dlsym(lib_handle, "orender_bed_layout");
  *(void**)(&api.version_minor) = dlsym(lib_handle, "orender_version_minor");
  return 0;
}

/* ---- what the stream turned out to be ----------------------------------- */

/* OrenderChannelLabel discriminants, in the order the enum declares them. A
 * table rather than a switch because the labels are contiguous from zero and
 * the host wants the engine's own spelling: these strings end up on Kodi's
 * player-process screen, and inventing a second vocabulary for them here would
 * mean two places to keep in step with the ABI. */
static const char* const CHANNEL_LABELS[] = {
    "L",   "R",   "C",   "LFE", "Ls",  "Rs",  "Tfl", "Tfr", "Tsl", "Tsr", "Tbl", "Tbr", "Lsc",
    "Rsc", "Lb",  "Rb",  "Cb",  "Tc",  "Lsd", "Rsd", "Lw",  "Rw",  "Tfc", "LFE2", "Object"};

/* Bed channels of the last rendered frame, comma separated, into `out`.
 *
 * This is what turns a bare object count into something a listener can read:
 * fifteen objects over an LFE-only bed is "15 Objects + LFE", and the bed half
 * of that sentence exists nowhere else in the protocol. Empty for plain
 * multichannel, for an engine too old to export the call, and on any error -
 * all three mean the same thing to the host, which is "say nothing about a
 * bed" rather than "say there is none". */
static void describe_bed(OrenderRenderer* r, char* out, size_t cap)
{
  out[0] = '\0';
  if (!api.bed_layout)
    return;

  /* Query, then fill. The ABI writes nothing unless cap >= N, so a bed wider
   * than this buffer yields an empty description rather than a truncated one -
   * which is the honest answer, since a half-listed bed reads as a whole one. */
  uint8_t labels[32];
  const uint32_t n = api.bed_layout(r, NULL, 0);
  if (n == 0 || n > sizeof(labels) || api.bed_layout(r, labels, n) != n)
    return;

  size_t at = 0;
  for (uint32_t i = 0; i < n; i++)
  {
    const uint8_t label = labels[i];
    const char* name =
        label < sizeof(CHANNEL_LABELS) / sizeof(CHANNEL_LABELS[0]) ? CHANNEL_LABELS[label] : "?";
    const int wrote = snprintf(out + at, cap - at, "%s%s", i ? "," : "", name);
    if (wrote < 0 || (size_t)wrote >= cap - at)
    {
      /* Same reasoning as the width check above: rather than hand the host a
       * bed that stops mid-list and looks complete, hand it nothing. */
      out[0] = '\0';
      return;
    }
    at += (size_t)wrote;
  }
}

/* ---- main --------------------------------------------------------------- */

int main(void)
{
  OrenderRenderer* renderer = NULL;
  float* out = NULL;
  size_t out_floats = OUT_FLOATS_INITIAL;
  uint8_t* payload = NULL;
  size_t payload_cap = 0;

  /* What the last stream-information frame said, so the next one is only sent
   * when it would say something different. See the report site in OP_FEED. */
  int reported_info = 0;
  int last_objects = -2; /* -1 is a value the engine can report, so start outside it */
  int last_spatial = -2;
  uint32_t last_bed_n = UINT32_MAX;
  uint32_t timeline_epoch = 0;
  uint64_t frames_rendered = 0;
  uint64_t decode_errors = 0;
  int exit_code = 0;

  out = (float*)malloc(out_floats * sizeof(float));
  if (!out)
  {
    emit_status(ST_OPEN_FAILED, "out of memory for the render buffer");
    return 4;
  }

  for (;;)
  {
    uint8_t hdr[HDR_LEN];
    const int got = read_exact(STDIN_FILENO, hdr, HDR_LEN);
    if (got == 0)
    {
      /* The host closed the pipe without saying CLOSE. That is how a killed
       * Kodi looks, and it is not an error worth a non-zero exit. */
      break;
    }
    if (got < 0)
    {
      emit_status(ST_PROTOCOL, "stdin ended part-way through a command header");
      exit_code = 5;
      break;
    }

    if (memcmp(hdr, "OMNC", 4) != 0)
    {
      emit_status(ST_PROTOCOL, "bad command magic %02x%02x%02x%02x", hdr[0], hdr[1], hdr[2],
                  hdr[3]);
      exit_code = 5;
      break;
    }

    const uint8_t op = hdr[4];
    const uint32_t len = get_u32(hdr + 8);

    if (len > MAX_PAYLOAD)
    {
      emit_status(ST_PROTOCOL, "payload of %u bytes exceeds the %u cap", len, MAX_PAYLOAD);
      exit_code = 5;
      break;
    }

    if (len)
    {
      /* One extra byte so parse_open can terminate the last line in place. */
      if (payload_cap < (size_t)len + 1)
      {
        uint8_t* grown = (uint8_t*)realloc(payload, (size_t)len + 1);
        if (!grown)
        {
          emit_status(ST_PROTOCOL, "out of memory for a %u byte payload", len);
          exit_code = 4;
          break;
        }
        payload = grown;
        payload_cap = (size_t)len + 1;
      }
      if (read_exact(STDIN_FILENO, payload, len) != 1)
      {
        emit_status(ST_PROTOCOL, "stdin ended part-way through a %u byte payload", len);
        exit_code = 5;
        break;
      }
      payload[len] = '\0';
    }

    switch (op)
    {
      case OP_OPEN:
      {
        if (renderer)
        {
          emit_status(ST_STATE, "OPEN while already open");
          exit_code = 5;
          goto done;
        }
        OpenArgs a;
        parse_open((char*)payload, len, &a);
        if (!a.lib)
        {
          emit_status(ST_OPEN_FAILED, "OPEN needs at least lib=<path to liborender.so>");
          exit_code = 5;
          goto done;
        }
        if (bind_engine(a.lib) != 0)
        {
          exit_code = 3;
          goto done;
        }

        OrenderConfig cfg;
        memset(&cfg, 0, sizeof(cfg));
        cfg.sample_rate = 48000;
        cfg.config_yaml_path = a.config;
        cfg.speaker_layout_path = a.layout;
        cfg.bridge_path = a.bridge;
        cfg.codec = a.codec;

        renderer = api.create(&cfg);
        if (!renderer)
        {
          emit_status(ST_OPEN_FAILED, "orender_create failed - check the bridge path in %s",
                      a.config ? a.config : "(default config)");
          exit_code = 3;
          goto done;
        }
        emit_status(ST_OK, "open codec=%s engine=%u.%u", a.codec ? a.codec : "(sniffed)",
                    api.version_major(), api.version_minor ? api.version_minor() : 0);
        break;
      }

      case OP_FEED:
      {
        if (!renderer)
        {
          emit_status(ST_STATE, "FEED before OPEN");
          exit_code = 5;
          goto done;
        }
        if (!len)
          break;

        uintptr_t frames = 0;
        uint32_t channels = 0;
        int64_t pts_out = 0;
        int rc;

        /* The engine answers ">0" to mean the buffer was too small and nothing
         * was written. The measurement prototype treated that as "no audio this
         * packet" and silently dropped it; here it grows and retries, and only
         * gives up at the ceiling. */
        for (;;)
        {
          rc = api.process(renderer, payload, len, 0, out, out_floats, &frames, &channels,
                           &pts_out);
          if (rc <= 0)
            break;
          if (out_floats >= OUT_FLOATS_MAX)
          {
            emit_status(ST_DECODE, "a packet needed more than %u floats of output",
                        OUT_FLOATS_MAX);
            break;
          }
          size_t want = out_floats * 2;
          if (want > OUT_FLOATS_MAX)
            want = OUT_FLOATS_MAX;
          float* grown = (float*)realloc(out, want * sizeof(float));
          if (!grown)
          {
            emit_status(ST_DECODE, "out of memory growing the render buffer");
            break;
          }
          out = grown;
          out_floats = want;
        }

        if (rc < 0)
        {
          /* A malformed packet is expected on a damaged file and on the first
           * packets after a seek. It is counted, not fatal: the decoder
           * resynchronises on its own and audio resumes. */
          decode_errors++;
          break;
        }
        if (rc > 0 || frames == 0)
          break;

        /* What the engine is being handed, whenever it changes.
         *
         * This used to be sent once, after the first rendered frame, on the
         * reasoning that the first frame is the earliest the count can be
         * truthful. The first half of that is right and the second half does
         * not follow. The ABI is explicit that this is "a live, observable fact
         * about the stream" which "may flip in either direction mid-stream and
         * must not be latched", and orender_object_count answers for the last
         * rendered frame rather than for the stream. A bed-only or
         * pre-metadata frame legitimately carries no objects, and that is what
         * a mid-film resume tends to land on first - so reporting once meant
         * resuming a film reported zero objects and never corrected itself.
         *
         * Reporting every frame is not the answer either: at 1200 access units
         * a second a TrueHD stream would fill the host's log. So the counts are
         * read each frame - two integer calls into the engine - and a frame is
         * only sent when one of them differs from what was last sent. A steady
         * stream sends one. */
        const int objects = api.object_count ? api.object_count(renderer) : -1;
        const int spatial = api.has_objects ? api.has_objects(renderer) : -1;
        /* Querying with a NULL buffer returns the bed width without writing
         * anything, which is cheap enough to ask every frame; the labels are
         * only spelled out when something has actually moved. */
        const uint32_t bed_n = api.bed_layout ? api.bed_layout(renderer, NULL, 0) : 0;

        if (!reported_info || objects != last_objects || spatial != last_spatial ||
            bed_n != last_bed_n)
        {
          /* Last, and never containing a space, so a host can read it to the
           * end of the line without the key order mattering. */
          char bed[128];
          describe_bed(renderer, bed, sizeof(bed));
          emit_status(ST_INFO, "stream objects=%d spatial=%d channels=%u bed=%s", objects, spatial,
                      channels, bed);
          reported_info = 1;
          last_objects = objects;
          last_spatial = spatial;
          last_bed_n = bed_n;
        }

        if (channels != 2)
        {
          /* The host sizes an audio frame as frames * 2 * float32 from the
           * header alone - it has to, because the header carries no channel
           * count. Anything else would not be mis-rendered, it would be
           * mis-framed, and every following frame would land at the wrong
           * offset. Refuse rather than hand back a stream that decodes into
           * nonsense. */
          emit_status(ST_DECODE, "engine returned %u channels, not stereo", channels);
          exit_code = 6;
          goto done;
        }

        const size_t nfloats = (size_t)frames * channels;
        if (nfloats > out_floats)
        {
          emit_status(ST_DECODE, "engine reported %zu frames x %u channels, beyond the buffer",
                      (size_t)frames, channels);
          exit_code = 6;
          goto done;
        }
        if (emit_audio((uint32_t)frames, pts_out, out, nfloats) != 0)
        {
          /* The host stopped reading. Nothing left to do and nothing wrong. */
          goto done;
        }
        frames_rendered += frames;
        break;
      }

      case OP_FLUSH:
        if (!renderer)
        {
          emit_status(ST_STATE, "FLUSH before OPEN");
          exit_code = 5;
          goto done;
        }
        emit_status(ST_OK, "flush");
        break;

      case OP_RESET:
        if (!renderer)
        {
          emit_status(ST_STATE, "RESET before OPEN");
          exit_code = 5;
          goto done;
        }
        api.reset(renderer);
        /* The engine's reported timestamp is a count from the start of the
         * stream it is decoding, and `orender_reset` starts that count again -
         * measured, not assumed. So the numbers on OMNI frames after this point
         * belong to a new timeline and will be lower than the ones before it.
         *
         * This status frame is the boundary. Because the helper finishes
         * writing a packet's audio before it reads the next command, everything
         * written before this frame is the old timeline and everything after it
         * is the new one, with no overlap. The epoch is here so a host can tell
         * the two apart in a log without counting frames. */
        timeline_epoch++;
        /* Say what the stream is again once it resumes, even if it turns out
         * to be saying the same thing. A host flushing a seek discards status
         * frames along with the stale audio - it cannot tell them apart from
         * the position it is leaving - so a report that crossed with a seek
         * would otherwise be the only one ever sent and would be thrown away. */
        reported_info = 0;
        last_objects = -2;
        last_spatial = -2;
        last_bed_n = UINT32_MAX;
        emit_status(ST_OK, "reset epoch=%u", timeline_epoch);
        break;

      case OP_CLOSE:
        emit_status(ST_OK, "close frames=%llu decode_errors=%llu",
                    (unsigned long long)frames_rendered, (unsigned long long)decode_errors);
        goto done;

      default:
        emit_status(ST_PROTOCOL, "unknown op %u", (unsigned)op);
        exit_code = 5;
        goto done;
    }
  }

done:
  if (renderer)
    api.destroy(renderer);
  if (lib_handle)
    dlclose(lib_handle);
  free(out);
  free(payload);
  return exit_code;
}
