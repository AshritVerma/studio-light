/*
 * studio-light-led: read and write the SMC keys behind the front light of a Mac Studio or Mac mini.
 *
 *   studio-light-led scan             list the light's SMC keys (LS*): name, type, size, value
 *   studio-light-led read KEY         print one key's value as hex
 *   studio-light-led write KEY HEX    set one light key (root; LS* keys only, exact size)
 *   studio-light-led check CONFIG     make sure CONFIG parses, without touching the SMC
 *   studio-light-led apply CONFIG     put the light in the state CONFIG asks for right now
 *                                     (root; launchd runs this once a minute). In the off
 *                                     hours it holds each key at its night value; in the on
 *                                     hours it only puts back keys still at the night value.
 *
 * No dependencies: IOKit is loaded at runtime, so this builds with just
 *   clang -O2 -o studio-light-led led.c
 *
 * CONFIG looks like this (studio-light.sh writes it):
 *   off 23:00            light off from 23:00...
 *   on 08:00             ...until 08:00 (equal times: always off)
 *   LSLN 0000 ffff       key, value in the off hours, value otherwise
 */

#include <ctype.h>
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <unistd.h>

#define MAX_BYTES 32
#define MAX_KEYS 16

/* ------------------------------------------------------------------ helpers */

static int hexval(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* "00ff" -> {0x00, 0xff}. Needs an even number of hex digits, 1..max bytes. */
static int parse_hex(const char *s, unsigned char *out, unsigned max, unsigned *len) {
    size_t n = strlen(s);
    if (n == 0 || n % 2 != 0 || n / 2 > max) return -1;
    for (size_t i = 0; i < n; i += 2) {
        int hi = hexval((unsigned char)s[i]), lo = hexval((unsigned char)s[i + 1]);
        if (hi < 0 || lo < 0) return -1;
        out[i / 2] = (unsigned char)(hi << 4 | lo);
    }
    *len = (unsigned)(n / 2);
    return 0;
}

static void to_hex(const unsigned char *data, unsigned n, char *out) {
    for (unsigned i = 0; i < n; i++) snprintf(out + 2 * i, 3, "%02x", data[i]);
    out[2 * n] = '\0';
}

/* The light's keys all start with "LS"; nothing else may ever be written. */
static int is_light_key(const char *k) {
    return strlen(k) == 4 && k[0] == 'L' && k[1] == 'S' && isgraph((unsigned char)k[2]) &&
           isgraph((unsigned char)k[3]);
}

/* "H:MM" or "HH:MM" -> minutes after midnight, or -1. */
static int parse_time(const char *s) {
    size_t n = strlen(s);
    if ((n != 4 && n != 5) || s[n - 3] != ':') return -1;
    for (size_t i = 0; i < n; i++)
        if (i != n - 3 && !isdigit((unsigned char)s[i])) return -1;
    int h = atoi(s), m = atoi(s + n - 2);
    if (h > 23 || m > 59) return -1;
    return h * 60 + m;
}

/* ---------------------------------------------------------------- SMC access */

typedef struct {
    char type[5];
    unsigned size;
    unsigned char data[MAX_BYTES];
} smc_value;

#ifndef MOCK_SMC
/* The real thing: the AppleSMC user client, as used by fan and sensor tools. */
#include <dlfcn.h>
#include <mach/mach.h>

typedef mach_port_t io_object_t;
typedef io_object_t io_service_t;
typedef io_object_t io_connect_t;

enum { KERNEL_INDEX_SMC = 2, SMC_READ_BYTES = 5, SMC_WRITE_BYTES = 6, SMC_READ_INDEX = 8, SMC_READ_KEYINFO = 9 };

typedef struct { char major, minor, build, reserved; uint16_t release; } smc_vers;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, mem; } smc_plimit;
typedef struct { uint32_t size, type; uint8_t attributes; } smc_keyinfo;
typedef struct {
    uint32_t key;
    smc_vers vers;
    smc_plimit plimit;
    smc_keyinfo info;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} smc_msg;
_Static_assert(sizeof(smc_msg) == 80, "AppleSMC messages are 80 bytes");

typedef io_object_t io_iterator_t;

static void *(*IOServiceMatching_)(const char *);
static kern_return_t (*IOServiceGetMatchingServices_)(mach_port_t, void *, io_iterator_t *);
static io_object_t (*IOIteratorNext_)(io_iterator_t);
static kern_return_t (*IORegistryEntryGetName_)(io_object_t, char *);
static kern_return_t (*IOServiceOpen_)(io_service_t, mach_port_t, uint32_t, io_connect_t *);
static kern_return_t (*IOServiceClose_)(io_connect_t);
static kern_return_t (*IOObjectRelease_)(io_object_t);
static kern_return_t (*IOConnectCallStructMethod_)(io_connect_t, uint32_t, const void *, size_t, void *,
                                                    size_t *);
static io_connect_t smc_conn;

static int load(void *lib, const char *name, void *fn) {
    void *p = dlsym(lib, name);
    memcpy(fn, &p, sizeof p);
    return p ? 0 : -1;
}

static int smc_open(void) {
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!iokit || load(iokit, "IOServiceMatching", &IOServiceMatching_) ||
        load(iokit, "IOServiceGetMatchingServices", &IOServiceGetMatchingServices_) ||
        load(iokit, "IOIteratorNext", &IOIteratorNext_) ||
        load(iokit, "IORegistryEntryGetName", &IORegistryEntryGetName_) ||
        load(iokit, "IOServiceOpen", &IOServiceOpen_) || load(iokit, "IOServiceClose", &IOServiceClose_) ||
        load(iokit, "IOObjectRelease", &IOObjectRelease_) ||
        load(iokit, "IOConnectCallStructMethod", &IOConnectCallStructMethod_))
        return -1;
    /* Apple Silicon Macs can list more than one AppleSMC service; the keys live on the
     * one named AppleSMCKeysEndpoint. Prefer it, else use the first match. */
    io_iterator_t it;
    if (IOServiceGetMatchingServices_(MACH_PORT_NULL, IOServiceMatching_("AppleSMC"), &it) != KERN_SUCCESS)
        return -1;
    io_service_t first = 0, keys = 0, s;
    while ((s = IOIteratorNext_(it)) != 0) {
        char name[128] = ""; /* io_name_t */
        if (!keys && IORegistryEntryGetName_(s, name) == KERN_SUCCESS &&
            strcmp(name, "AppleSMCKeysEndpoint") == 0)
            keys = s;
        else if (!first)
            first = s;
        else
            IOObjectRelease_(s);
    }
    IOObjectRelease_(it);
    io_service_t svc = keys ? keys : first;
    if (keys && first) IOObjectRelease_(first);
    if (!svc) return -1;
    kern_return_t r = IOServiceOpen_(svc, mach_task_self(), 0, &smc_conn);
    IOObjectRelease_(svc);
    return r == KERN_SUCCESS ? 0 : -1;
}

static void smc_close(void) {
    if (smc_conn) IOServiceClose_(smc_conn);
    smc_conn = 0;
}

static uint32_t fourcc(const char *s) {
    return (uint32_t)(unsigned char)s[0] << 24 | (uint32_t)(unsigned char)s[1] << 16 |
           (uint32_t)(unsigned char)s[2] << 8 | (uint32_t)(unsigned char)s[3];
}

static void unfourcc(uint32_t v, char out[5]) {
    out[0] = (char)(v >> 24), out[1] = (char)(v >> 16), out[2] = (char)(v >> 8), out[3] = (char)v;
    out[4] = '\0';
}

/* One round trip. The SMC reports its own verdict in `result` (0 = ok). */
static int smc_call(const smc_msg *in, smc_msg *out) {
    size_t n = sizeof *out;
    memset(out, 0, sizeof *out);
    if (IOConnectCallStructMethod_(smc_conn, KERNEL_INDEX_SMC, in, sizeof *in, out, &n) != KERN_SUCCESS)
        return -1;
    return out->result == 0 ? 0 : -1;
}

static int smc_info(const char *key, smc_keyinfo *info) {
    smc_msg in, out;
    memset(&in, 0, sizeof in);
    in.key = fourcc(key);
    in.data8 = SMC_READ_KEYINFO;
    if (smc_call(&in, &out)) return -1;
    *info = out.info;
    return 0;
}

static int smc_read(const char *key, smc_value *v) {
    smc_keyinfo info;
    if (smc_info(key, &info) || info.size == 0 || info.size > MAX_BYTES) return -1;
    smc_msg in, out;
    memset(&in, 0, sizeof in);
    in.key = fourcc(key);
    in.info.size = info.size;
    in.data8 = SMC_READ_BYTES;
    if (smc_call(&in, &out)) return -1;
    unfourcc(info.type, v->type);
    v->size = info.size;
    memcpy(v->data, out.bytes, info.size);
    return 0;
}

static int smc_write(const char *key, const unsigned char *data, unsigned size) {
    smc_keyinfo info;
    if (smc_info(key, &info) || info.size != size) return -1;
    smc_msg in, out;
    memset(&in, 0, sizeof in);
    in.key = fourcc(key);
    in.info.size = size;
    in.data8 = SMC_WRITE_BYTES;
    memcpy(in.bytes, data, size);
    return smc_call(&in, &out);
}

static int smc_key_count(unsigned *count) {
    smc_value v;
    if (smc_read("#KEY", &v) || v.size != 4) return -1;
    *count = (unsigned)v.data[0] << 24 | (unsigned)v.data[1] << 16 | (unsigned)v.data[2] << 8 | v.data[3];
    return 0;
}

static int smc_key_at(unsigned index, char key[5]) {
    smc_msg in, out;
    memset(&in, 0, sizeof in);
    in.data8 = SMC_READ_INDEX;
    in.data32 = index;
    if (smc_call(&in, &out)) return -1;
    unfourcc(out.key, key);
    return 0;
}

#else
/* Test double: the "SMC" is a text file ($MOCK_SMC_FILE) of "KEY TYPE HEX" lines.
 * HEX "!" marks a key that can't be read or written. Writes rewrite the file. */
#define MOCK_MAX 64
static struct {
    char key[5], type[5];
    unsigned size;
    unsigned char data[MAX_BYTES];
    int locked;
} mk[MOCK_MAX];
static unsigned mn;

static const char *mock_file(void) {
    const char *p = getenv("MOCK_SMC_FILE");
    return p && *p ? p : "mock-smc.txt";
}

static int smc_open(void) {
    FILE *f = fopen(mock_file(), "r");
    if (!f) return -1;
    char line[256], k[16], t[16], h[80];
    for (mn = 0; mn < MOCK_MAX && fgets(line, sizeof line, f);) {
        if (sscanf(line, "%15s %15s %79s", k, t, h) != 3 || strlen(k) != 4 || strlen(t) != 4) continue;
        memcpy(mk[mn].key, k, 5);
        memcpy(mk[mn].type, t, 5);
        mk[mn].locked = strcmp(h, "!") == 0;
        if (!mk[mn].locked && parse_hex(h, mk[mn].data, MAX_BYTES, &mk[mn].size)) continue;
        mn++;
    }
    fclose(f);
    return 0;
}

static void smc_close(void) {}

static int mock_find(const char *k) {
    for (unsigned i = 0; i < mn; i++)
        if (strcmp(mk[i].key, k) == 0) return (int)i;
    return -1;
}

static int smc_read(const char *key, smc_value *v) {
    int i = mock_find(key);
    if (i < 0 || mk[i].locked) return -1;
    memcpy(v->type, mk[i].type, 5);
    v->size = mk[i].size;
    memcpy(v->data, mk[i].data, mk[i].size);
    return 0;
}

static int smc_write(const char *key, const unsigned char *data, unsigned size) {
    int i = mock_find(key);
    const char *readonly = getenv("MOCK_SMC_READONLY"), *sticky = getenv("MOCK_SMC_STICKY");
    if (getenv("MOCK_SMC_FAIL_WRITE") || (readonly && strstr(readonly, key)) || i < 0 || mk[i].locked ||
        mk[i].size != size)
        return -1;
    memcpy(mk[i].data, data, size);
    /* MOCK_SMC_STICKY="KEY=HEX": that key accepts writes but always reads back HEX. */
    const char *at = sticky ? strstr(sticky, key) : NULL;
    unsigned n;
    if (at && at[4] == '=') {
        char hex[2 * MAX_BYTES + 1];
        snprintf(hex, sizeof hex, "%.*s", (int)strcspn(at + 5, " ,"), at + 5);
        if (parse_hex(hex, mk[i].data, MAX_BYTES, &n) || n != size) memcpy(mk[i].data, data, size);
    }
    FILE *f = fopen(mock_file(), "w");
    if (!f) return -1;
    for (unsigned j = 0; j < mn; j++) {
        char hex[2 * MAX_BYTES + 1];
        to_hex(mk[j].data, mk[j].size, hex);
        fprintf(f, "%s %s %s\n", mk[j].key, mk[j].type, mk[j].locked ? "!" : hex);
    }
    fclose(f);
    return 0;
}

static int smc_key_count(unsigned *count) {
    *count = mn;
    return 0;
}

static int smc_key_at(unsigned index, char key[5]) {
    if (index >= mn) return -1;
    memcpy(key, mk[index].key, 5);
    return 0;
}
#endif

static int is_root(void) {
#ifdef MOCK_SMC
    if (getenv("MOCK_NOT_ROOT")) return 0;
#endif
    return geteuid() == 0;
}

/* ------------------------------------------------------------------ commands */

static int usage(void) {
    fputs("usage: studio-light-led scan | read KEY | write KEY HEX | check CONFIG | apply CONFIG\n", stderr);
    return 64;
}

static int fail(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fputs("studio-light-led: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    return 1;
}

static void printable(const char *in, char out[5]) {
    for (int i = 0; i < 4; i++) out[i] = isgraph((unsigned char)in[i]) ? in[i] : '_';
    out[4] = '\0';
}

static int cmd_scan(void) {
    unsigned n;
    if (smc_open() || smc_key_count(&n)) return fail("can't read the SMC");
    for (unsigned i = 0; i < n; i++) {
        char k[5], t[5], hex[2 * MAX_BYTES + 1];
        smc_value v;
        if (smc_key_at(i, k) || k[0] != 'L' || k[1] != 'S') continue;
        if (smc_read(k, &v) == 0) {
            printable(v.type, t);
            to_hex(v.data, v.size, hex);
            printf("%s %s %u %s\n", k, t, v.size, hex);
        } else {
            printf("%s - - unreadable\n", k);
        }
    }
    smc_close();
    return 0;
}

static int cmd_read(const char *key) {
    smc_value v;
    char hex[2 * MAX_BYTES + 1];
    if (strlen(key) != 4) return fail("SMC keys are 4 characters");
    if (smc_open()) return fail("can't open the SMC");
    int r = smc_read(key, &v);
    smc_close();
    if (r) return fail("can't read %s", key);
    to_hex(v.data, v.size, hex);
    puts(hex);
    return 0;
}

static int cmd_write(const char *key, const char *hex) {
    unsigned char data[MAX_BYTES];
    unsigned len;
    smc_value before, after;
    char was[2 * MAX_BYTES + 1], now[2 * MAX_BYTES + 1];

    if (!is_light_key(key)) return fail("only the light's keys (LS..) can be written");
    if (parse_hex(hex, data, MAX_BYTES, &len)) return fail("'%s' isn't hex bytes", hex);
    if (!is_root()) return fail("writing needs root: use sudo");
    if (smc_open()) return fail("can't open the SMC");
    if (smc_read(key, &before)) return smc_close(), fail("can't read %s", key);
    if (before.size != len) return smc_close(), fail("%s holds %u bytes, not %u", key, before.size, len);
    if (smc_write(key, data, len)) return smc_close(), fail("the SMC refused the write to %s", key);
    to_hex(before.data, before.size, was);
    if (smc_read(key, &after) == 0) {
        to_hex(after.data, after.size, now);
        if (strcasecmp(now, hex) == 0)
            printf("%s %s -> %s\n", key, was, now);
        else
            printf("%s %s -> %s (reads back as %s)\n", key, was, hex, now);
    } else {
        printf("%s %s -> %s\n", key, was, hex);
    }
    smc_close();
    return 0;
}

typedef struct {
    char name[5];
    unsigned len;
    unsigned char night[MAX_BYTES], day[MAX_BYTES];
} light_key;

typedef struct {
    int off, on;
    unsigned nkeys;
    light_key keys[MAX_KEYS];
} config;

static int load_config(const char *path, config *c, char *err, size_t errlen) {
    FILE *f = fopen(path, "r");
    if (!f) return snprintf(err, errlen, "can't read %s: %s", path, strerror(errno)), -1;
    memset(c, 0, sizeof *c);
    c->off = c->on = -1;
    char line[512];
    int lineno = 0, bad = 0;
    while (!bad && fgets(line, sizeof line, f)) {
        char *tok[4], *hash = strchr(line, '#');
        int nt = 0;
        lineno++;
        if (hash) *hash = '\0';
        for (char *p = strtok(line, " \t\r\n"); p && nt < 4; p = strtok(NULL, " \t\r\n")) tok[nt++] = p;
        if (nt == 0) continue;
        if (nt == 2 && strcmp(tok[0], "off") == 0) {
            bad = (c->off = parse_time(tok[1])) < 0;
        } else if (nt == 2 && strcmp(tok[0], "on") == 0) {
            bad = (c->on = parse_time(tok[1])) < 0;
        } else if (nt == 3 && is_light_key(tok[0]) && c->nkeys < MAX_KEYS) {
            light_key *k = &c->keys[c->nkeys];
            unsigned a, b;
            bad = parse_hex(tok[1], k->night, MAX_BYTES, &a) || parse_hex(tok[2], k->day, MAX_BYTES, &b) || a != b;
            if (!bad) memcpy(k->name, tok[0], 5), k->len = a, c->nkeys++;
        } else {
            bad = 1;
        }
    }
    fclose(f);
    if (bad) return snprintf(err, errlen, "%s line %d isn't valid", path, lineno), -1;
    if (c->off < 0 || c->on < 0 || c->nkeys == 0)
        return snprintf(err, errlen, "%s needs an 'off' time, an 'on' time and a key line", path), -1;
    return 0;
}

/* Off hours run from `off` up to (not including) `on`, wrapping past midnight.
 * Equal times mean the light is always off. */
static int in_off_hours(int now, int off, int on) {
    if (off == on) return 1;
    return off < on ? (now >= off && now < on) : (now >= off || now < on);
}

static int now_minutes(void) {
    const char *fake = getenv("STUDIO_LIGHT_NOW"); /* tests only */
    if (fake && parse_time(fake) >= 0) return parse_time(fake);
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    return tm.tm_hour * 60 + tm.tm_min;
}

static void stamp(char *buf, size_t n) {
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    strftime(buf, n, "%Y-%m-%d %H:%M:%S", &tm);
}

/* launchd runs `apply` every minute, so a lasting problem is logged once, not 1,440 times a day. */
static const char *err_file(void) {
    const char *p = getenv("STUDIO_LIGHT_ERRFILE");
    return p && *p ? p : "/var/run/studio-light.err";
}

static int fail_once(const char *fmt, ...) {
    char msg[512], old[512] = "", ts[32];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);
    FILE *f = fopen(err_file(), "r");
    if (f) {
        if (!fgets(old, sizeof old, f)) old[0] = '\0';
        old[strcspn(old, "\n")] = '\0';
        fclose(f);
    }
    if (strcmp(old, msg) != 0) {
        stamp(ts, sizeof ts);
        fprintf(stderr, "%s error: %s\n", ts, msg);
        if ((f = fopen(err_file(), "w"))) fprintf(f, "%s\n", msg), fclose(f);
    }
    return 1;
}

static int cmd_check(const char *path) {
    config c;
    char err[600];
    if (load_config(path, &c, err, sizeof err)) return fail("%s", err);
    printf("ok: off %d:%02d, on %d:%02d, %u key%s\n", c.off / 60, c.off % 60, c.on / 60, c.on % 60, c.nkeys,
           c.nkeys == 1 ? "" : "s");
    return 0;
}

static void append(char *buf, size_t size, const char *fmt, ...) {
    size_t used = strlen(buf);
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf + used, size - used, fmt, ap);
    va_end(ap);
}

static int cmd_apply(const char *path) {
    config c;
    char err[600], changed[1200] = "", problems[1200] = "", ts[32], hex[2 * MAX_BYTES + 1];
    if (load_config(path, &c, err, sizeof err)) return fail_once("%s", err);
    if (!is_root()) return fail_once("apply needs root (launchd runs it as root)");
    if (smc_open()) return fail_once("can't open the SMC");

    int off_hours = in_off_hours(now_minutes(), c.off, c.on);
    for (unsigned i = 0; i < c.nkeys; i++) {
        const light_key *k = &c.keys[i];
        const unsigned char *want = off_hours ? k->night : k->day;
        smc_value v, after;
        int known = smc_read(k->name, &v) == 0 && v.size == k->len;
        /* Steady state costs one read per key and writes nothing. */
        if (known && memcmp(v.data, want, k->len) == 0) continue;
        /* In the on hours, only undo our own off-hours value; any other value is the Mac's business. */
        if (!off_hours && known && memcmp(v.data, k->night, k->len) != 0) continue;
        if (smc_write(k->name, want, k->len)) {
            append(problems, sizeof problems, " %s (write refused)", k->name);
            continue;
        }
        if (smc_read(k->name, &after) == 0 && after.size == k->len && memcmp(after.data, want, k->len) != 0) {
            to_hex(after.data, after.size, hex);
            append(problems, sizeof problems, " %s (reads back as %s)", k->name, hex);
            continue;
        }
        to_hex(want, k->len, hex);
        append(changed, sizeof changed, "%s%s=%s", *changed ? " " : "", k->name, hex);
    }
    smc_close();
    if (*changed) {
        stamp(ts, sizeof ts);
        printf("%s light %s (%s)\n", ts, off_hours ? "off" : "on", changed);
        fflush(stdout);
    }
    if (*problems) return fail_once("couldn't set%s", problems);
    unlink(err_file());
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "scan") == 0) return cmd_scan();
    if (argc == 3 && strcmp(argv[1], "read") == 0) return cmd_read(argv[2]);
    if (argc == 4 && strcmp(argv[1], "write") == 0) return cmd_write(argv[2], argv[3]);
    if (argc == 3 && strcmp(argv[1], "check") == 0) return cmd_check(argv[2]);
    if (argc == 3 && strcmp(argv[1], "apply") == 0) return cmd_apply(argv[2]);
    return usage();
}
