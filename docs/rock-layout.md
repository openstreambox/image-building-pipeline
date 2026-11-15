# ROCK 5B+ storage layout

ROCK 5B+ uses two 3 GiB root slots, a 256 MiB boot partition and a data partition that grows on first boot. Media must measure at least 8 GiB (8589934592 bytes); retail 8 GB media is too small. Signed updates require matching root geometry. Each populated root must retain at least 512 MiB actual free space. Release qualification requires a complete image build, first boot, data readiness, signed update and rollback on hardware.

APT package indexes use a 192 MiB volatile mount on ROCK 5B+; binary metadata caches are disabled to bound root writes.
