# Crash logs across warm resets (draft)

A silent reset can leave no clue about the preceding failure. On ROCK 5B and
ROCK 5B+, the source kernel build adds a ramoops reserved-memory node to the
board device trees. Ramoops lets the kernel keep its last crash log in RAM.
Stock systemd-pstore saves and clears that log on the next boot.

## Kernel device tree

`manifests/kernel/rk3588-ramoops.dtsi` reserves 1 MiB at
`0x1f000000–0x1f0fffff`: 128 KiB crash records, 512 KiB console, and
`max-reason=2` (oops and panic). The rest holds four crash records.
`lib/kernel/ramoops.sh` includes this node in both Rock board sources before
`bindeb-pkg` compiles and packages the DTBs. The include and helper are kernel
fingerprint inputs. Package revisions advance to avoid reusing released bytes.
The boot script is unchanged. A device-tree build failure fails the build,
not a boot-time edit. Existing required symbols are PSTORE, PSTORE_RAM and
PSTORE_CONSOLE, built in.

This applies to newly built kernels, not existing released kernel packages.
Production image assembly requires the matching authenticated kernel release;
this draft does not publish one or alter the release admission checks.

## Stock archive and read-only access

`Storage=external` and `Unlink=yes` select systemd-pstore's own archive and
acknowledgement. Its service waits for the required `/data` mount and tmpfiles
setup. Tmpfiles is ordered after the `/data` mount attempt even when fstab
marks it `nofail`. A service-local bind maps `/data/ceralive/pstore` to
`/var/lib/systemd/pstore`; the original stock unit and binary remain in use.
The bind exists only in that service's mount namespace. Outside it, read the
persistent directory directly. Missing `/data` prevents service execution, so
pstore remains available for recovery. Tmpfiles creates the private 0700
archive and ages its contents out after 30 days. This is age retention, not a
byte cap; filesystem free-space monitoring remains necessary.

For support export, use stock files (root permissions are required):

```sh
sudo find /data/ceralive/pstore -type f -name '*ramoops*' -exec cat -- '{}' +
sudo journalctl -u systemd-pstore.service
```

The find command is read-only, supports both direct and nested archive files,
and prints nothing for an empty archive. systemd owns the filenames and layout;
there is no custom JSON schema, latest-boot reader, collector or clearing script.
CeraUI currently has no consumer of the removed reader. Watchdog bootstatus and
U-Boot reset causes belong in a separate boot record; they are not collected here.
Persistent `/data` survives A/B rootfs replacement. No custom archive-count or
collection-size limiter is retained.

## Qualification still required

The proposed address is below 512 MiB, but it needs measured checks of the
firmware reservations, full loader relocation/load ranges, DT and `/proc/iomem`
for every RAM size and kernel/bootloader pair. Confirm registration, then repeat
panic and watchdog warm resets and verify the stock saved files and clearing.
DDR initialization can erase RAM. Power loss destroys RAM contents; a hang may
leave only console output. No hardware qualification is claimed by host tests.

TODO: other RK3588 boards (including Orange Pi 5 Plus), other ARM families and
x86 need their own address/backend and preservation checks. Do not copy this
reservation to them without qualification. No watchdog policy changes.
