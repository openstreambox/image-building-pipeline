#!/usr/bin/env bats

setup() {
  repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  tree="$BATS_TEST_TMPDIR/linux/arch/arm64/boot/dts/rockchip"
  board="$tree/rk3588-rock-5b-plus.dts"
  dtb="$BATS_TEST_TMPDIR/board.dtb"
  mkdir -p "$tree"
  zone=/thermal-zones/package-thermal
  profile="$repo/manifests/kernel/rock-5b-plus-fan.dtsi"
  # Point at the pinned kernel tree after applying the configured patch series.
  if [[ -n "${CERALIVE_ROCK_FAN_DTS_TREE:-}" ]]; then
    dts_source="$CERALIVE_ROCK_FAN_DTS_TREE/arch/arm64/boot/dts/rockchip"
    includes="$CERALIVE_ROCK_FAN_DTS_TREE/include"
    cp "$dts_source/rk3588-rock-5b-plus.dts" "$board"
    return
  fi

  dts_source="$tree"
  includes="$BATS_TEST_TMPDIR/include"
  cat >"$board" <<'DTS'
/dts-v1/;
#define RK_PA0 0
#define RK_PC0 16
#define RK_FUNC_GPIO 0
#define GPIO_ACTIVE_HIGH 0
/ {
  pinctrl: pinctrl {
    pcfg_pull_none: pull-none { bias-disable; };
    pcfg_output_high: output-high { output-high; };
    gpio0: gpio0 {
      gpio-controller;
      #gpio-cells = <2>;
      interrupt-controller;
      #address-cells = <0>;
      #interrupt-cells = <2>;
    };
  };
  pwm1: pwm1 { #pwm-cells = <3>; status = "okay"; };
  fan: pwm-fan {
    compatible = "pwm-fan";
    fan-supply = <&supply>;
    pwms = <&pwm1 0 50000 0>;
    cooling-levels = <0 120 150 180 210 240 255>;
    #cooling-cells = <2>;
  };
  supply: regulator { compatible = "regulator-fixed"; };
  sensor: thermal-sensor { #thermal-sensor-cells = <1>; };
  thermal-zones {
    package_thermal: package-thermal {
      thermal-sensors = <&sensor 0>;
      polling-delay = <1000>;
      trips {
        package-crit { temperature = <115000>; hysteresis = <0>; type = "critical"; };
        package_fan0: package-fan0 { temperature = <55000>; hysteresis = <2000>; type = "active"; };
        package_fan1: package-fan1 { temperature = <65000>; hysteresis = <2000>; type = "active"; };
      };
      cooling-maps {
        map0 { trip = <&package_fan0>; cooling-device = <&fan 0xffffffff 1>; };
        map1 { trip = <&package_fan1>; cooling-device = <&fan 2 0xffffffff>; };
      };
    };
  };
};
DTS
  inc="$includes/dt-bindings"
  mkdir -p "$inc/pwm" "$inc/interrupt-controller"
  printf '#define PWM_POLARITY_INVERTED 1\n' >"$inc/pwm/pwm.h"
  printf '#define IRQ_TYPE_EDGE_FALLING 2\n' >"$inc/interrupt-controller/irq.h"
}

render() {
  bash "$repo/lib/kernel/rock-5b-plus-fan.sh" "$BATS_TEST_TMPDIR/linux" "$1"
  bash "$repo/lib/kernel/rock-5b-plus-fan.sh" "$BATS_TEST_TMPDIR/linux" "$1"
  [ "$(grep -Fxc '#include "ceralive-rock-5b-plus-fan.dtsi"' "$board")" = 1 ]
  cpp -nostdinc -undef -x assembler-with-cpp -I "$includes" -I "$dts_source" "$board" |
    dtc -@ -i "$dts_source" -I dts -O dtb -o "$dtb"
  [ "$(fdtget -tu "$dtb" "$zone/trips/package-crit" temperature)" = 115000 ]
}

prop() {
  fdtget -t "$1" "$dtb" "$2" "$3"
}

symbol() {
  prop s /__symbols__ "$1"
}

@test "Rock 5B+ default fan switches its gate as GPIO at 55/50 C" {
  render "$profile"
  [ "$(prop s "$(symbol pwm1)" status)" = disabled ]
  [ "$(prop s /pwm-fan status)" = disabled ]
  [ "$(prop s /case-fan compatible)" = gpio-fan ]
  [ "$(prop s /case-fan status)" = okay ]
  [ "$(prop u /case-fan gpios)" = "$(prop u "$(symbol gpio0)" phandle) 16 0" ]
  [ "$(prop s /pinctrl pinctrl-names)" = default ]
  [ "$(prop u /pinctrl pinctrl-0)" = "$(prop u "$(symbol case_fan_boot_on)" phandle)" ]
  [ "$(prop u "$(symbol case_fan_boot_on)" rockchip,pins)" = "0 16 0 $(prop u "$(symbol pcfg_output_high)" phandle)" ]
  fdtget -t x "$dtb" "$(symbol pcfg_output_high)" output-high
  fdtget -t x "$dtb" /case-fan fan-keep-running-on-detach
  [ "$(prop u /case-fan gpio-fan,speed-map)" = '0 0 11000 1' ]
  run fdtget "$dtb" /case-fan pwms
  [ "$status" -ne 0 ]
  [ "$(fdtget -l "$dtb" "$zone/trips")" = $'package-crit\npackage-fan0' ]
  [ "$(prop s "$zone/trips/package-fan0" type)" = active ]
  [ "$(prop u "$zone/trips/package-fan0" temperature)" = 55000 ]
  [ "$(prop u "$zone/trips/package-fan0" hysteresis)" = 5000 ]
  [ "$(fdtget -l "$dtb" "$zone/cooling-maps")" = map0 ]
  [ "$(prop u "$zone/cooling-maps/map0" cooling-device)" = "$(prop u /case-fan phandle) 0 1" ]
  [ "$(prop u "$zone/cooling-maps/map0" trip)" = "$(prop u "$zone/trips/package-fan0" phandle)" ]
}

@test "Rock 5B+ S99 profile renders all three active trips, inverted PWM and tach" {
  sed 's/^#define ROCK_5B_PLUS_FAN_S99 0$/#define ROCK_5B_PLUS_FAN_S99 1/' "$profile" >"$BATS_TEST_TMPDIR/s99.dtsi"
  render "$BATS_TEST_TMPDIR/s99.dtsi"
  [ "$(prop s "$(symbol pwm1)" status)" = okay ]
  [ "$(prop s /pwm-fan status)" = okay ]
  [ "$(prop u /pwm-fan pwms)" = "$(prop u "$(symbol pwm1)" phandle) 0 40000 1" ]
  [ "$(prop u /pwm-fan cooling-levels)" = '0 150 153 255' ]
  [ "$(prop u /pwm-fan interrupt-parent)" = "$(prop u "$(symbol gpio0)" phandle)" ]
  [ "$(prop s /pwm-fan pinctrl-names)" = default ]
  [ "$(prop u /pwm-fan pinctrl-0)" = "$(prop u "$(symbol case_fan_tach)" phandle)" ]
  [ "$(prop u "$(symbol case_fan_tach)" rockchip,pins)" = "0 0 0 $(prop u "$(symbol pcfg_pull_none)" phandle)" ]
  fdtget -t x "$dtb" "$(symbol pcfg_pull_none)" bias-disable
  [ "$(prop u /pwm-fan interrupts)" = '0 2' ]
  [ "$(prop u /pwm-fan pulses-per-revolution)" = 2 ]
  [ "$(prop u /pwm-fan fan-stop-to-start-percent)" = 30 ]
  [ "$(prop u /pwm-fan fan-shutdown-percent)" = 100 ]
  run fdtget "$dtb" /pwm-fan fan-supply
  [ "$status" -ne 0 ]
  fan="$(prop u /pwm-fan phandle)"
  for spec in '0 package-fan0 45000 1' '1 package-fan1 50000 2' '2 case-fan-full 70000 3'; do
    read -r map trip temp state <<< "$spec"
    [ "$(prop s "$zone/trips/$trip" type)" = active ]
    [ "$(prop u "$zone/trips/$trip" temperature)" = "$temp" ]
    [ "$(prop u "$zone/trips/$trip" hysteresis)" = 2500 ]
    [ "$(prop u "$zone/cooling-maps/map$map" trip)" = "$(prop u "$zone/trips/$trip" phandle)" ]
    [ "$(prop u "$zone/cooling-maps/map$map" cooling-device)" = "$fan $state $state" ]
  done
}

@test "Rock 5B+ fan profiles are wired to the kernel build and legacy helpers defer to them" {
  grep -Fq 'bash /in/rock-5b-plus-fan.sh /src/linux /in/rock-5b-plus-fan.dtsi' "$repo/lib/build-kernel.sh"
  for unit in ceralive-fan-curve.service ceralive-fan-kickstart.service; do
    grep -Fxq 'ConditionPathExists=!/sys/firmware/devicetree/base/case-fan' "$repo/mkosi/runtime/$unit"
    grep -Fxq 'ConditionPathExists=!/sys/firmware/devicetree/base/thermal-zones/package-thermal/trips/case-fan-full' "$repo/mkosi/runtime/$unit"
  done
}

@test "Rock fan sampler joins thermal and hwmon data by device-tree identity" {
  local sys="$BATS_TEST_TMPDIR/sys"
  local zone="$sys/class/thermal/thermal_zone4"
  local cdev="$sys/class/thermal/cooling_device7"
  local other="$sys/class/hwmon/hwmon0"
  local bound="$sys/class/hwmon/hwmon2"
  mkdir -p "$zone" "$cdev" "$other/device" "$bound/device" "$sys/of/"{other,bound}
  ln -s "$cdev" "$zone/cdev1"
  ln -s "$sys/of/bound" "$cdev/of_node"
  ln -s "$sys/of/other" "$other/device/of_node"
  ln -s "$sys/of/bound" "$bound/device/of_node"
  echo package-thermal >"$zone/type"
  echo 51000 >"$zone/temp"
  echo pwm-fan >"$cdev/type"
  echo 2 >"$cdev/cur_state"
  for hwmon in "$other" "$bound"; do
    echo pwmfan >"$hwmon/name"
    echo 2 >"$hwmon/pwm1_enable"
  done
  echo 55 >"$other/pwm1"
  echo 1200 >"$other/fan1_input"
  echo 153 >"$bound/pwm1"
  echo 6200 >"$bound/fan1_input"

  run env FAN_SYS_CLASS="$sys/class" bash "$repo/tools/read-rock-5b-plus-fan.sh"
  [ "$status" = 0 ]
  [[ "${lines[1]}" == *,51000,pwmfan,2,153,2,6200 ]]
  [ -z "${lines[2]:-}" ]

  # The unrelated fan is still present after the chosen one loses its identity.
  rm "$bound/device/of_node"
  run env FAN_SYS_CLASS="$sys/class" bash "$repo/tools/read-rock-5b-plus-fan.sh"
  [ "$status" -ne 0 ]
  [ "$output" = 'Missing hwmon device pwmfan' ]
}
