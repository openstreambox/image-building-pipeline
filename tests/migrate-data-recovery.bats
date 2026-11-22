#!/usr/bin/env bats

load 'lib/migrate-data.sh'

setup() {
  export PIPELINE_DIR
  PIPELINE_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  box="$BATS_TEST_TMPDIR/box"
  shared="$BATS_TEST_TMPDIR/data"
  mkdir -p "$box/etc/ceralive" "$box/nm" "$box/opt/ceralive" "$shared"
}

# The kernel refuses writes beyond the limit, including in child copy processes.
# Only the fixture is affected. A retry runs with the ordinary limit.
write_limited() (
  trap '' XFSZ
  ulimit -f 8
  bash "$1"
)

limited_migrate() { migrate "$box" "$shared" write_limited; }

@test "a failed legacy config copy leaves the source and no published partial config" {
  local src="$box/etc/ceralive/config.json" dest="$shared/ceralive/config.json"
  printf '{"padding":"%32768s"}\n' '' >"$src"
  cp "$src" "$box/expected"
  run limited_migrate
  [ "$status" -ne 0 ]
  [ -f "$src" ]
  [ ! -e "$dest" ]
  migrate "$box" "$shared"
  cmp "$box/expected" "$dest"
  [ ! -e "$src" ]
}

@test "an interrupted working-dir seed retries from the next slot" {
  printf '{"padding":"%32768s"}\n' '' >"$box/opt/ceralive/setup.json"
  run limited_migrate
  [ "$status" -ne 0 ]
  [ ! -e "$shared/ceralive/setup.json" ]
  printf '{}\n' >"$box/opt/ceralive/setup.json"
  migrate "$box" "$shared"
  cmp "$box/opt/ceralive/setup.json" "$shared/ceralive/setup.json"
}

@test "a failed hostname seed cannot discard the slot copy on retry" {
  local src="$box/etc/ceralive/hostname_consumers_pending"
  printf '%32768s\n' pending >"$src"
  cp "$src" "$box/expected"
  run limited_migrate
  [ "$status" -ne 0 ]
  [ ! -e "$shared/ceralive/hostname_consumers_pending" ]
  migrate "$box" "$shared"
  [ -L "$src" ]
  cmp "$box/expected" "$src"
}

@test "both slot directions preserve saved profiles and import missing keyfiles privately" {
  local standby="$BATS_TEST_TMPDIR/standby" profile=wifi.nmconnection
  mkdir -p "$standby/nm"
  printf 'old slot\n' >"$box/nm/$profile"
  printf 'new slot\n' >"$standby/nm/$profile"
  printf 'additional\n' >"$standby/nm/extra.nmconnection"
  chmod 600 "$box/nm/$profile" "$standby/nm/"*.nmconnection
  migrate "$box" "$shared"
  local saved="$shared/nm/system-connections"
  cmp "$box/nm/$profile" "$saved/$profile"
  printf 'saved choice\n' >"$saved/$profile"
  migrate "$standby" "$shared"
  [ "$(cat "$saved/$profile")" = 'saved choice' ]
  cmp "$standby/nm/extra.nmconnection" "$saved/extra.nmconnection"
  migrate "$box" "$shared"
  [ "$(cat "$saved/$profile")" = 'saved choice' ]
  [ "$(stat -c %a "$saved")" = 700 ]
  [ "$(stat -c %a "$saved/extra.nmconnection")" = 600 ]
}

@test "a failed profile seed keeps other state available and retries the missing file" {
  local profile=wifi.nmconnection
  printf '[connection]\nid=fixture\n#%32768s\n' '' >"$box/nm/$profile"
  chmod 600 "$box/nm/$profile"
  limited_migrate
  [ -f "$shared/ceralive/update.conf" ]
  [ ! -e "$shared/nm/system-connections/$profile" ]
  grep -qi 'warn.*profile' "$box/migrate.log"
  migrate "$box" "$shared"
  cmp "$box/nm/$profile" "$shared/nm/system-connections/$profile"
}

@test "an unusable persistent hostname entry preserves the recoverable slot file" {
  local src="$box/etc/ceralive/host_index"
  mkdir -p "$shared/ceralive"
  ln -s absent "$shared/ceralive/host_index"
  printf '3\n' >"$src"
  migrate "$box" "$shared"
  [ ! -L "$src" ]
  [ "$(cat "$src")" = 3 ]
  [ "$(readlink "$shared/ceralive/host_index")" = absent ]
}
