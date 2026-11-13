#define POWER_LINK_NO_MAIN
#include "power_link.c"
#include <assert.h>

static void frame(char *out, const char *body) {
    snprintf(out, 513, "%s crc=%04X\n", body, crc16(body, strlen(body)));
}
static void status(char *out, unsigned seq, const char *boot) {
    char body[450];
    snprintf(body, sizeof body, "OSB1 up=100 thermal=normal pack=ready/25.0C/00 pack_cal=datasheet start=on gaps=0000 gaps2=0000 seq=%u boot=%s rst=poweron alive=1 hot=none shutdowns=0 fw=field-12345678", seq, boot);
    frame(out, body);
}
int main(void) {
    assert(crc16("123456789", 9) == 0x29b1);
    struct state s = {0}; char line[513];
    status(line, 0, "01234567"); feed(&s, line, strlen(line), 1000);
    assert(get(&s, "pack_cal") != NULL);
    assert(s.rx_ms == 1000 && s.seq == 0 && s.accepted == 1);
    assert(!strcmp(s.fields[find_field(&s, "pack_cal")].value, "datasheet"));
    line[20] ^= 1; feed(&s, line, strlen(line), 2000);
    assert(s.bad_crc == 1 && s.rx_ms == 1000);
    status(line, 3, "01234567"); feed(&s, line, strlen(line), 3000);
    assert(s.missed == 2);
    frame(line, "OSB1 EVT up=101 example event seq=4 boot=01234567 rst=wdt alive=1 hot=none shutdowns=0 fw=field-12345678");
    feed(&s, line, strlen(line), 4000);
    assert(s.seq == 4 && s.rx_ms == 3000 && s.event_count == 1);
    status(line, 5, "01234567"); feed(&s, line, strlen(line), 5000);
    assert(s.missed == 2);
    status(line, 0, "89abcdef"); feed(&s, line, strlen(line), 6000);
    assert(s.restarts == 1 && s.missed == 2);
    feed(&s, line, strlen(line), 7000);
    assert(s.out_of_order == 1 && s.rx_ms == 6000);
    status(line, UINT32_MAX, "76543210"); feed(&s, line, strlen(line), 8000);
    status(line, 0, "76543210"); feed(&s, line, strlen(line), 9000);
    assert(s.restarts == 2 && s.missed == 2);
    assert(!strcmp(link_state(&s, 1, 13999), "ok"));
    assert(!strcmp(link_state(&s, 1, 14000), "silent"));
    assert(!strcmp(link_state(&s, 0, 14000), "absent"));
    struct state changed = {0}; status(line, 0, "01234567");
    feed(&changed, line, strlen(line), 1);
    frame(line, "OSB1 EVT up=0 restarted seq=0 boot=89abcdef rst=wdt alive=1 hot=none shutdowns=0 fw=field-12345678");
    feed(&changed, line, strlen(line), 2);
    assert(changed.restarts == 1 && !strcmp(link_state(&changed, 1, 2), "silent"));
    status(line, 1, "89abcdef"); feed(&changed, line, strlen(line), 3);
    disconnect_source(&changed);
    assert(!strcmp(link_state(&changed, 1, 4), "silent"));
    struct state truncated = {0}; status(line, 1, "01234567");
    feed(&truncated, line, 30, 1); assert(truncated.accepted == 0);
    disconnect_source(&truncated); feed(&truncated, line + 30, strlen(line) - 30, 2);
    assert(truncated.accepted == 0);
    struct state flood = {0}; char bytes[4096]; memset(bytes, 'X', sizeof bytes);
    for (int i = 0; i < 1000; ++i) feed(&flood, bytes, sizeof bytes, 1);
    assert(flood.used <= 512 && flood.oversize == 1);
    feed(&flood, "\n", 1, 1); status(line, 9, "01234567");
    feed(&flood, line, strlen(line), 2); assert(flood.accepted == 1);
    feed(&flood, "OSB2 x=1\n", 9, 3); assert(flood.unknown_version == 1);
    feed(&flood, "waiting for download\n", 21, 4);
    assert(!strcmp(link_state(&flood, 1, 4), "bootloader"));
    for (unsigned i = 10; i < 1510; ++i) {
        char body[200]; snprintf(body, sizeof body, "OSB1 EVT up=200 synthetic seq=%u boot=01234567 rst=poweron alive=1 hot=none shutdowns=0 fw=field-12345678", i);
        frame(line, body); feed(&flood, line, strlen(line), i);
    }
    assert(flood.event_count == 1000);
    assert(strstr(flood.events[flood.event_next], " seq=510 "));
    assert(strstr(flood.events[(flood.event_next + EVENTS - 1) % EVENTS], " seq=1509 "));
    struct state regression = {0};
    status(line, 500, "01234567"); feed(&regression, line, strlen(line), 1);
    for (unsigned i = 0; i < 5; ++i) {
        status(line, i, "01234567"); feed(&regression, line, strlen(line), 2+i);
    }
    assert(regression.restarts == 1 && regression.seq == 4 && regression.rx_ms == 6);
    assert(regression.out_of_order == 2 && regression.missed == 0);
    struct state opaque = {0};
    frame(line, "OSB1 EVT up=0 waiting for download crc=oops seq=77 left-out=ina left-out=storage restart-record=stale seq=0 boot=01234567 rst=wdt alive=1 hot=none shutdowns=0 fw=field-12345678");
    feed(&opaque, line, strlen(line), 1);
    assert(opaque.accepted == 1 && opaque.seq == 0 && opaque.event_count == 1 && !opaque.special);
    feed(&opaque, "OSBnoise\nOSB1\n", 14, 2);
    assert(!opaque.special && opaque.unknown_version == 0);
    FILE *gold = fopen("fixtures/firmware.txt", "r"); assert(gold);
    unsigned rows = 0;
    while (fgets(line, sizeof line, gold)) {
        struct state captured = {0}; feed(&captured, line, strlen(line), 1);
        assert(captured.accepted == 1 && captured.malformed == 0 && captured.bad_crc == 0);
        ++rows;
    }
    fclose(gold); assert(rows >= 6);
    puts("power-link parser/state tests passed");
}
