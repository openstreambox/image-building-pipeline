/* Host-only adapter: exercise the actual C parser without a serial device. */
#define POWER_LINK_NO_MAIN
#include "power_link.c"

int main(int argc, char **argv) {
    static struct state s;
    char *line = NULL; size_t capacity = 0; ssize_t n; uint64_t now = 0;
    while ((n = getline(&line, &capacity, stdin)) >= 0) {
        now += 1000; feed(&s, line, (size_t)n, now);
        if (argc == 2 && !strcmp(argv[1], "--semantics")) {
            semantics(stdout, &s); putchar('\n'); continue;
        }
        printf("{\"accepted\":%" PRIu64 ",\"restarts\":%" PRIu64 ",\"missed\":%" PRIu64
               ",\"crc\":%" PRIu64 ",\"malformed\":%" PRIu64 ",\"oversize\":%" PRIu64
               ",\"ignored\":%" PRIu64 ",\"unknown_version\":%" PRIu64 ",\"out_of_order\":%" PRIu64 ",\"link\":",
               s.accepted, s.restarts, s.missed, s.bad_crc, s.malformed, s.oversize,
               s.ignored, s.unknown_version, s.out_of_order);
        json_string(stdout, link_state(&s, 1, now));
        printf(",\"seq\":%" PRIu32 ",\"boot\":", s.seq); json_string(stdout, s.boot);
        printf(",\"have_status\":%s,\"rx_ms\":%" PRIu64 ",\"fields\":{", s.have_status ? "true" : "false", s.rx_ms);
        for (size_t i = 0; i < s.nfields; ++i) {
            if (i) putchar(',');
            json_string(stdout, s.fields[i].key); putchar(':'); json_string(stdout, s.fields[i].value);
        }
        fputs("},\"events\":[", stdout);
        size_t first = (s.event_next + EVENTS - s.event_count) % EVENTS;
        for (size_t i = 0; i < s.event_count; ++i) {
            if (i) putchar(',');
            json_string(stdout, s.events[(first+i)%EVENTS]);
        }
        puts("]}");
    }
    disconnect_source(&s);
    free(line); return ferror(stdin) ? 1 : 0;
}
