#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

gadget=/sys/kernel/config/usb_gadget/zero3w
controllers=(/sys/class/udc/*)

case "${1:-}" in
  check)
    if (( ${#controllers[@]} != 1 )); then
      echo "Expected one UDC, found ${#controllers[@]}"
      exit 1
    fi
    ;;
  start)
    (( ${#controllers[@]} == 1 ))
    modprobe libcomposite
    digest="$(sha256sum /etc/machine-id)"
    mkdir "$gadget"
    cd "$gadget"
    # Linux Foundation composite gadget ID for this development fixture.
    printf '0x1d6b\n' > idVendor
    printf '0x0104\n' > idProduct
    mkdir strings/0x409 configs/c.1 functions/ncm.usb0 functions/acm.usb0
    printf 'zero3usb%%d\n' > functions/ncm.usb0/ifname
    printf 'Radxa ZERO 3W Companion\n' > strings/0x409/product
    printf '%s\n' "${digest:0:16}" > strings/0x409/serialnumber
    printf '02:%s:%s:%s:%s:%s\n' "${digest:16:2}" "${digest:18:2}" \
      "${digest:20:2}" "${digest:22:2}" "${digest:24:2}" > functions/ncm.usb0/dev_addr
    printf '06:%s:%s:%s:%s:%s\n' "${digest:16:2}" "${digest:18:2}" \
      "${digest:20:2}" "${digest:22:2}" "${digest:24:2}" > functions/ncm.usb0/host_addr
    ln -s functions/ncm.usb0 configs/c.1/
    ln -s functions/acm.usb0 configs/c.1/
    printf '%s\n' "${controllers[0]##*/}" > UDC
    ;;
  stop)
    [[ -d "$gadget" ]] || exit 0
    cd "$gadget"
    if [[ -n "$(cat UDC)" ]]; then printf '\n' > UDC; fi
    for function in configs/c.1/*; do
      if [[ -L "$function" ]]; then unlink "$function"; fi
    done
    for directory in configs/c.1 functions/acm.usb0 functions/ncm.usb0 strings/0x409; do
      if [[ -d "$directory" ]]; then rmdir "$directory"; fi
    done
    cd ..
    rmdir "$gadget"
    ;;
  *) exit 2 ;;
esac
