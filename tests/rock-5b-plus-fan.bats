#!/usr/bin/env bats

setup() {
  repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  tree="$BATS_TEST_TMPDIR/linux/arch/arm64/boot/dts/rockchip"
  board="$tree/rk3588-rock-5b-plus.dts"
  dtb="$BATS_TEST_TMPDIR/board.dtb"
  mkdir -p "$tree"
  cat >"$board" <<'DTS'
/dts-v1/;
#define RK_PA0 0
#define RK_PC0 16
#define RK_FUNC_GPIO 0
#define GPIO_ACTIVE_HIGH 0
/ {
  pinctrl: pinctrl {
    pcfg_pull_none: pull-none { bias-disable; };
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
    pwms = <&pwm1 0 50000 0>;
    cooling-levels = <0 120 150 180 210 240 255>;
    #cooling-cells = <2>;
  };
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
  inc="$BATS_TEST_TMPDIR/include/dt-bindings"
  mkdir -p "$inc/pwm" "$inc/interrupt-controller"
  printf '#define PWM_POLARITY_INVERTED 1\n' >"$inc/pwm/pwm.h"
  printf '#define IRQ_TYPE_EDGE_FALLING 2\n' >"$inc/interrupt-controller/irq.h"
  zone=/thermal-zones/package-thermal
  profile="$repo/manifests/kernel/rock-5b-plus-fan.dtsi"
}

render() {
  bash "$repo/lib/kernel/rock-5b-plus-fan.sh" "$BATS_TEST_TMPDIR/linux" "$1"
  bash "$repo/lib/kernel/rock-5b-plus-fan.sh" "$BATS_TEST_TMPDIR/linux" "$1"
  [ "$(grep -c '^#include' "$board")" = 1 ]
  cpp -nostdinc -undef -x assembler-with-cpp -I "$BATS_TEST_TMPDIR/include" "$board" |
    dtc -I dts -O dtb -o "$dtb"
  [ "$(fdtget -tu "$dtb" "$zone/trips/package-crit" temperature)" = 115000 ]
}

prop() {
  fdtget -t "$1" "$dtb" "$2" "$3"
}

@test "Rock 5B+ default fan switches its gate as GPIO at 55/50 C" {
  render "$profile"
  [ "$(prop s /pwm1 status)" = disabled ]
  [ "$(prop s /pwm-fan status)" = disabled ]
  [ "$(prop s /case-fan compatible)" = gpio-fan ]
  [ "$(prop u /case-fan gpios)" = "$(prop u /pinctrl/gpio0 phandle) 16 0" ]
  [ "$(prop u /case-fan gpio-fan,speed-map)" = '0 0 11000 1' ]
  run fdtget "$dtb" /case-fan pwms
  [ "$status" -ne 0 ]
  [ "$(fdtget -l "$dtb" "$zone/trips")" = $'package-crit\npackage-fan0' ]
  [ "$(prop u "$zone/trips/package-fan0" temperature)" = 55000 ]
  [ "$(prop u "$zone/trips/package-fan0" hysteresis)" = 5000 ]
  [ "$(fdtget -l "$dtb" "$zone/cooling-maps")" = map0 ]
  [ "$(prop u "$zone/cooling-maps/map0" cooling-device)" = "$(prop u /case-fan phandle) 0 1" ]
  [ "$(prop u "$zone/cooling-maps/map0" trip)" = "$(prop u "$zone/trips/package-fan0" phandle)" ]
}

@test "Rock 5B+ S99 profile renders all three active trips, inverted PWM and tach" {
  sed 's/^#define ROCK_5B_PLUS_FAN_S99 0$/#define ROCK_5B_PLUS_FAN_S99 1/' "$profile" >"$BATS_TEST_TMPDIR/s99.dtsi"
  render "$BATS_TEST_TMPDIR/s99.dtsi"
  [ "$(prop s /pwm1 status)" = okay ]
  [ "$(prop u /pwm-fan pwms)" = "$(prop u /pwm1 phandle) 0 40000 1" ]
  [ "$(prop u /pwm-fan cooling-levels)" = '0 150 153 255' ]
  [ "$(prop u /pwm-fan interrupt-parent)" = "$(prop u /pinctrl/gpio0 phandle)" ]
  [ "$(prop u /pwm-fan interrupts)" = '0 2' ]
  [ "$(prop u /pwm-fan pulses-per-revolution)" = 2 ]
  [ "$(prop u /pwm-fan fan-stop-to-start-percent)" = 30 ]
  fan="$(prop u /pwm-fan phandle)"
  for spec in '0 package-fan0 45000 1' '1 package-fan1 50000 2' '2 case-fan-full 70000 3'; do
    read -r map trip temp state <<< "$spec"
    [ "$(prop s "$zone/trips/$trip" type)" = active ]
    [ "$(prop u "$zone/trips/$trip" temperature)" = "$temp" ]
    [ "$(prop u "$zone/trips/$trip" hysteresis)" = 0 ]
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
