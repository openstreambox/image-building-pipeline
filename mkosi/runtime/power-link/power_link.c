#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#define MAX_FIELDS 48
#define EVENTS 1000
struct field { char key[32], value[160]; };
struct fieldset { struct field fields[MAX_FIELDS]; size_t nfields; };
struct state {
    char input[513]; size_t used; int dropping;
    struct field fields[MAX_FIELDS]; size_t nfields;
    uint32_t seq; char boot[9]; int have_seq, have_status, expected;
    uint64_t rx_ms, accepted, missed, restarts, bad_crc, malformed;
    uint64_t oversize, ignored, unknown_version, out_of_order;
    char events[EVENTS][513]; size_t event_count, event_next;
    uint64_t event_generation, published_generation;
    int events_published, persist_error, open_error, stopped, opening;
    uint32_t up;
    unsigned regressions; uint32_t regression_seq;
    int special; /* 1 download mode, 2 unsupported version */
};
static uint16_t crc16(const char *p, size_t n) {
    uint16_t crc = 0xffff;
    while (n--) {
        crc ^= (uint16_t)(unsigned char)*p++ << 8;
        for (int i = 0; i < 8; ++i)
            crc = crc & 0x8000 ? (crc << 1) ^ 0x1021 : crc << 1;
    }
    return crc;
}
static int find_fields(const struct field *fields, size_t nfields, const char *key) {
    for (size_t i = 0; i < nfields; ++i)
        if (!strcmp(fields[i].key, key)) return (int)i;
    return -1;
}
static const char *get_fields(const struct fieldset *s, const char *key) {
    int i = find_fields(s->fields, s->nfields, key);
    return i < 0 ? NULL : s->fields[i].value;
}
static int find_field(const struct state *s, const char *key) {
    return find_fields(s->fields, s->nfields, key);
}
static const char *get(const struct state *s, const char *key) {
    int i = find_field(s, key); return i < 0 ? NULL : s->fields[i].value;
}
static int number(const char *p, unsigned base, uint32_t *out) {
    if (!p || !*p) return 0;
    for (const char *c = p; *c; ++c)
        if (base == 10 ? !isdigit((unsigned char)*c) : !isxdigit((unsigned char)*c)) return 0;
    char *end; errno = 0; unsigned long long n = strtoull(p, &end, base);
    if (errno || *end || n > UINT32_MAX) return 0;
    *out = (uint32_t)n; return 1;
}
static void line_received(struct state *s, char *line, uint64_t now) {
    if (strncmp(line, "OSB1 ", 5)) {
        const char *version = line + (strlen(line) >= 3 ? 3 : strlen(line));
        while (isdigit((unsigned char)*version)) ++version;
        if (!strncmp(line, "OSB", 3) && version > line + 3 && *version == ' ') {
            ++s->unknown_version; s->special = 2;
        } else {
            if (strncmp(line, "OSB", 3) && strstr(line, "waiting for download")) s->special = 1;
            ++s->ignored;
        }
        return;
    }
    char *tail = strrchr(line, ' '); uint32_t checksum;
    if (!tail || strncmp(tail, " crc=", 5) || strlen(tail) != 9 ||
        !number(tail + 5, 16, &checksum) ||
        checksum != crc16(line, (size_t)(tail - line))) { ++s->bad_crc; return; }
    for (char *p = line; *p; ++p)
        if ((unsigned char)*p < 32 || (unsigned char)*p > 126) { ++s->malformed; return; }
    char original[513]; strcpy(original, line); *tail = 0;
    int event = !strncmp(line + 5, "EVT ", 4);
    struct fieldset parsed;
    parsed.nfields = 0; memset(parsed.fields, 0, sizeof parsed.fields);
    char *start = line + 5;
    uint32_t up;
    if (event) {
        /* The seven firmware trailer fields have fixed order. Text before them
         * is opaque, including anything resembling a field or checksum. */
        const char *keys[] = {"seq", "boot", "rst", "alive", "hot", "shutdowns", "fw"};
        char *end = tail;
        for (int i = 6; i >= 0; --i) {
            char *space = end;
            while (space > line && space[-1] != ' ') --space;
            size_t n = strlen(keys[i]);
            if (space == line || strncmp(space, keys[i], n) || space[n] != '=' || space+n+1 == end) {
                ++s->malformed; return;
            }
            if (!i) start = space;
            end = space - 1;
        }
        char value[32];
        const char *space = strchr(line + 9, ' ');
        if (strncmp(line + 9, "up=", 3) || !space || space >= start || space-(line+12) >= 32) {
            ++s->malformed; return;
        }
        memcpy(value, line+12, (size_t)(space-(line+12))); value[space-(line+12)] = 0;
        if (!number(value, 10, &up)) { ++s->malformed; return; }
    }
    char *save, *token = strtok_r(start, " ", &save);
    while (token) {
        char *eq = strchr(token, '=');
        if (!eq) { if (!event) { ++s->malformed; return; } }
        else {
            *eq++ = 0;
            if (!*token || !*eq || strlen(token) >= sizeof parsed.fields[0].key ||
                strlen(eq) >= sizeof parsed.fields[0].value || parsed.nfields == MAX_FIELDS ||
                find_fields(parsed.fields, parsed.nfields, token) >= 0) { ++s->malformed; return; }
            for (const char *p = token; *p; ++p)
                if (!isalnum((unsigned char)*p) && *p != '_') { ++s->malformed; return; }
            strcpy(parsed.fields[parsed.nfields].key, token);
            strcpy(parsed.fields[parsed.nfields++].value, eq);
        }
        token = strtok_r(NULL, " ", &save);
    }
    uint32_t seq, boot;
    const char *boot_text = get_fields(&parsed, "boot");
    if (!number(get_fields(&parsed, "seq"), 10, &seq) || !boot_text || strlen(boot_text) != 8 ||
        !number(boot_text, 16, &boot)) { ++s->malformed; return; }
    if (!event) {
        if (!number(get_fields(&parsed, "up"), 10, &up)) { ++s->malformed; return; }
    }
    char canonical[9]; snprintf(canonical, sizeof canonical, "%08" PRIx32, boot);
    if (s->have_seq && !strcmp(s->boot, canonical) && up >= s->up) {
        uint32_t delta = seq - s->seq;
        if (!delta || delta >= UINT32_C(0x80000000)) {
            if (delta && (!s->regressions || seq - s->regression_seq == 1)) ++s->regressions;
            else s->regressions = delta ? 1 : 0;
            s->regression_seq = seq;
            if (s->regressions < 3) { ++s->out_of_order; return; }
            ++s->restarts; s->have_status = 0;
        } else s->missed += delta - 1;
    } else if (s->have_seq) {
        ++s->restarts;
        /* An event from a new boot invalidates the old status immediately. */
        s->have_status = 0;
    }
    s->regressions = 0;
    strcpy(s->boot, canonical); s->seq = seq; s->up = up; s->have_seq = 1;
    s->expected = 1; ++s->accepted; s->special = 0;
    if (event) {
        snprintf(s->events[s->event_next], 513, "%s", original);
        ++s->event_generation;
        s->event_next = (s->event_next + 1) % EVENTS;
        if (s->event_count < EVENTS) ++s->event_count;
    } else {
        memcpy(s->fields, parsed.fields, sizeof s->fields); s->nfields = parsed.nfields;
        s->rx_ms = now; s->have_status = 1;
    }
}
static void feed(struct state *s, const char *p, size_t n, uint64_t now) {
    while (n--) {
        unsigned char c = (unsigned char)*p++;
        if (c == '\n') {
            if (!s->dropping) { s->input[s->used] = 0; line_received(s, s->input, now); }
            s->used = 0; s->dropping = 0;
        } else if (!s->dropping) {
            if (s->used == 511) { ++s->oversize; s->dropping = 1; s->used = 0; }
            else if (!c) { ++s->malformed; s->dropping = 1; s->used = 0; }
            else s->input[s->used++] = (char)c;
        }
    }
}
static void disconnect_source(struct state *s) { s->used = 0; s->dropping = 0; s->special = 0; s->have_status = 0; }
static const char *link_state(const struct state *s, int connected, uint64_t now) {
    if (s->stopped) return "stopped";
    if (!connected && s->opening) return "silent";
    if (!connected) return s->open_error ? "error" : "absent";
    if (s->special == 1) return "bootloader";
    if (s->special == 2) return "unknown_version";
    return s->have_status && now >= s->rx_ms && now - s->rx_ms < 5000 ? "ok" : "silent";
}
#ifndef POWER_LINK_NO_MAIN
static uint64_t mono_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
static void json_string(FILE *f, const char *p) {
    fputc('"', f);
    for (; *p; ++p) {
        if (*p == '"' || *p == '\\') fputc('\\', f);
        fputc(*p, f);
    }
    fputc('"', f);
}
static FILE *atomic_start(const char *dir, const char *name, char *tmp, size_t size) {
    if (snprintf(tmp, size, "%s/.%s.XXXXXX", dir, name) >= (int)size) return NULL;
    int fd = mkstemp(tmp); if (fd < 0) return NULL;
    if (fchmod(fd, 0644)) { close(fd); unlink(tmp); return NULL; }
    FILE *f = fdopen(fd, "w"); if (!f) { close(fd); unlink(tmp); }
    return f;
}
static int atomic_finish(FILE *f, const char *tmp, const char *dir, const char *name) {
    char dest[4096]; int bad = ferror(f);
    if (fflush(f) || fsync(fileno(f))) bad = 1;
    if (fclose(f)) bad = 1;
    if (snprintf(dest, sizeof dest, "%s/%s", dir, name) >= (int)sizeof dest) bad = 1;
    if (!bad && !rename(tmp, dest)) {
        int directory = open(dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (directory < 0) return -1;
        int result = fsync(directory); close(directory); return result;
    }
    unlink(tmp); return -1;
}
static void temperature(FILE *f, const char *raw, int bank) {
    char value[160]; value[0] = 0;
    if (raw) {
        snprintf(value, sizeof value, "%s", raw);
        /* Bank: state/V/A/C/flags. Pack: state/C/flags. */
        char *part = value;
        for (int i = 0; i < (bank ? 3 : 1); ++i) {
            part = strchr(part, '/');
            if (!part) break;
            ++part;
        }
        if (part) {
            char *end = strchr(part, '/');
            if (end) *end = 0;
        }
        if (part) {
            if (!strcmp(part, "na") || !strcmp(part, "uncal")) {
                fprintf(f, "{\"celsius\":null,\"quality\":\"%s\"}", part); return;
            }
            char *end; double n = strtod(part, &end);
            if (end != part && !strcmp(end, "C") && n >= -273.15 && n <= 1000) {
                fprintf(f, "{\"celsius\":%.3f,\"quality\":\"reported\"}", n); return;
            }
        }
    }
    fputs("{\"celsius\":null,\"quality\":\"unknown\"}", f);
}
static int publish(struct state *s, int connected, int ambiguous, uint64_t now, const char *dir) {
    char tmp[4096]; FILE *f = atomic_start(dir, "supervisor.json", tmp, sizeof tmp);
    if (!f) return -1;
    const char *link = link_state(s, connected, now);
    fprintf(f, "{\"schema_version\":1,\"link\":\"%s\",\"ambiguous\":%s,\"expected\":%s,\"stale\":%s,\"rx_mono_ms\":",
            link, ambiguous ? "true" : "false", s->expected ? "true" : "false", strcmp(link, "ok") ? "true" : "false");
    if (s->rx_ms) fprintf(f, "%" PRIu64, s->rx_ms); else fputs("null", f);
    fprintf(f, ",\"published_mono_ms\":%" PRIu64, now);
    fprintf(f, ",\"persist_error\":%s,\"open_error\":%d", s->persist_error ? "true" : "false", s->open_error);
    fputs(",\"fields\":{", f);
    for (size_t i = 0; i < s->nfields; ++i) {
        if (i) fputc(',', f);
        json_string(f, s->fields[i].key); fputc(':', f); json_string(f, s->fields[i].value);
    }
    fputs("},\"temperatures\":{", f);
    const char *keys[] = {"a", "b", "pack"};
    for (int i = 0; i < 3; ++i) {
        if (i) fputc(',', f);
        json_string(f, keys[i]); fputc(':', f); temperature(f, get(s, keys[i]), i < 2);
    }
    fprintf(f, "},\"restarts\":%" PRIu64 ",\"missed_lines\":%" PRIu64 ",\"accepted_lines\":%" PRIu64
            ",\"rejected\":{\"crc\":%" PRIu64 ",\"malformed\":%" PRIu64 ",\"oversize\":%" PRIu64
            ",\"ignored\":%" PRIu64 ",\"unknown_version\":%" PRIu64 ",\"out_of_order\":%" PRIu64 "}}\n",
            s->restarts, s->missed, s->accepted, s->bad_crc, s->malformed, s->oversize, s->ignored, s->unknown_version, s->out_of_order);
    if (atomic_finish(f, tmp, dir, "supervisor.json")) return -1;
    if (s->events_published && s->published_generation == s->event_generation) return 0;
    f = atomic_start(dir, "events.jsonl", tmp, sizeof tmp); if (!f) return -1;
    size_t first = (s->event_next + EVENTS - s->event_count) % EVENTS;
    for (size_t i = 0; i < s->event_count; ++i) {
        fputs("{\"line\":", f); json_string(f, s->events[(first+i)%EVENTS]); fputs("}\n", f);
    }
    if (atomic_finish(f, tmp, dir, "events.jsonl")) return -1;
    s->events_published = 1; s->published_generation = s->event_generation;
    return 0;
}
/* Only read access is requested. No modem-control ioctl and no device writes. */
static int open_serial(const char *path, int *opened) {
    int fd = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return -1;
    *opened = 1;
    struct termios t;
    if (ioctl(fd, TIOCEXCL) || tcgetattr(fd, &t)) { int error = errno; close(fd); errno = error; return -1; }
    cfmakeraw(&t); t.c_cflag &= ~(HUPCL | CRTSCTS); t.c_cflag |= CLOCAL | CREAD;
    t.c_cc[VMIN] = 0; t.c_cc[VTIME] = 0;
    if (tcsetattr(fd, TCSANOW, &t)) { int error = errno; close(fd); errno = error; return -1; }
    return fd;
}
static int attr_equals(const char *dir, const char *attr, const char *value) {
    char path[4096], text[64];
    if (snprintf(path, sizeof path, "%s/%s", dir, attr) >= (int)sizeof path) return 0;
    FILE *f = fopen(path, "r"); if (!f) return 0;
    int ok = fgets(text, sizeof text, f) != NULL; fclose(f);
    if (!ok) return 0;
    text[strcspn(text, "\r\n")] = 0; return !strcmp(text, value);
}
static int discover(const char *sysfs, char *device, size_t size) {
    DIR *d = opendir(sysfs); if (!d) return 0;
    int matches = 0; struct dirent *entry;
    while ((entry = readdir(d))) {
        if (strncmp(entry->d_name, "ttyACM", 6)) continue;
        char path[4096], real[4096];
        if (snprintf(path, sizeof path, "%s/%s/device", sysfs, entry->d_name) >= (int)sizeof path) continue;
        if (!realpath(path, real) || !attr_equals(real, "bInterfaceNumber", "00")) continue;
        char *slash = strrchr(real, '/'); if (!slash) continue; *slash = 0;
        if (attr_equals(real, "idVendor", "303a") && attr_equals(real, "idProduct", "1001")) {
            ++matches; snprintf(device, size, "/dev/%s", entry->d_name);
        }
    }
    closedir(d); return matches;
}
static int persistence_available(const char *persist) {
    struct stat data_stat, root_stat;
    return strcmp(persist, "/data/osb-power") ||
        (!stat("/data", &data_stat) && !stat("/", &root_stat) && data_stat.st_dev != root_stat.st_dev);
}
static volatile sig_atomic_t stopping;
static void stop(int sig) { (void)sig; stopping = 1; }
int main(int argc, char **argv) {
    const char *sysfs = "/sys/class/tty";
    const char *explicit_device = NULL, *dir = "/run/ceralive/power", *persist = "/data/osb-power";
    for (int i = 1; i < argc; i += 2) {
        if (i+1 == argc) return 2;
        if (!strcmp(argv[i], "--device")) explicit_device = argv[i+1];
        else if (!strcmp(argv[i], "--sysfs-dir")) sysfs = argv[i+1];
        else if (!strcmp(argv[i], "--state-dir")) dir = argv[i+1];
        else if (!strcmp(argv[i], "--persistent-dir")) persist = argv[i+1];
        else return 2;
    }
    static struct state s;
    char expected[4096]; snprintf(expected, sizeof expected, "%s/expected", persist);
    s.expected = persistence_available(persist) && access(expected, F_OK) == 0; int saved = s.expected;
    signal(SIGTERM, stop); signal(SIGINT, stop);
    int fd = -1, ambiguous = 0; uint64_t next_scan = 0, next_publish = 0, next_save = 0;
    unsigned open_failures = 0, retry_seconds = 1;
    char retry_device[4096] = "";
    while (!stopping) {
        uint64_t now = mono_ms();
        if (now >= next_scan) {
            char device[4096]; int count;
            if (explicit_device) { snprintf(device, sizeof device, "%s", explicit_device); count = 1; }
            else count = discover(sysfs, device, sizeof device);
            ambiguous = count > 1;
            if (count != 1 && fd >= 0) { close(fd); fd = -1; disconnect_source(&s); }
            if (count != 1 || strcmp(device, retry_device)) {
                s.open_error = 0; s.opening = 0; open_failures = 0; retry_seconds = 1;
            }
            unsigned scan_seconds = 1;
            if (count == 1 && fd < 0) {
                snprintf(retry_device, sizeof retry_device, "%s", device);
                int opened = 0;
                fd = open_serial(device, &opened);
                int error = fd < 0 && errno != ENOENT && errno != ENODEV ? errno : 0;
                if (error) {
                    ++open_failures;
                    s.opening = open_failures < 2;
                    s.open_error = s.opening ? 0 : error;
                    if (opened) {
                        scan_seconds = retry_seconds;
                        retry_seconds = retry_seconds < 16 ? retry_seconds * 2 : 30;
                    }
                } else {
                    s.open_error = 0; s.opening = 0; open_failures = 0; retry_seconds = 1;
                }
            }
            next_scan = now + scan_seconds * 1000;
        }
        if (s.expected && !saved && now >= next_save) {
            /* Never write beneath an unmounted production /data mountpoint. */
            char tmp[4096];
            FILE *f = persistence_available(persist) ? atomic_start(persist, "expected", tmp, sizeof tmp) : NULL;
            if (f) {
                fputs("1\n", f);
                saved = atomic_finish(f, tmp, persist, "expected") == 0;
            }
            if (!saved && !s.persist_error) fputs("persist expected: unavailable; retrying quietly\n", stderr);
            s.persist_error = !saved;
            next_save = now + 1000;
        }
        if (now >= next_publish) {
            if (publish(&s, fd >= 0, ambiguous, now, dir)) { perror("publish"); return 1; }
            next_publish = now + 1000;
        }
        struct pollfd pfd = {.fd = fd, .events = POLLIN};
        int ready = poll(&pfd, 1, 100);
        if (ready > 0) {
            char data[4096]; ssize_t n = read(fd, data, sizeof data);
            if (n > 0) feed(&s, data, (size_t)n, mono_ms());
            if ((n < 0 && errno != EAGAIN && errno != EINTR) || (pfd.revents & (POLLERR|POLLHUP|POLLNVAL))) {
                close(fd); fd = -1; disconnect_source(&s);
            }
        } else if (ready < 0 && errno != EINTR) return 1;
    }
    if (fd >= 0) close(fd);
    s.stopped = 1; s.opening = 0;
    return publish(&s, 0, ambiguous, mono_ms(), dir) ? 1 : 0;
}
#endif
