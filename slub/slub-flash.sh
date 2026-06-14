#!/usr/bin/env bash
# slub-flash.sh — flash one already-assembled SLUB measurement image to
# the STM32F429-Discovery via OpenOCD. Each
# slub/out/<variant>__<workload>__<profile>/image.bin is self-contained
# (bootloader + dtb + that variant's xipImage
# + romfs with the measurement scripts at /), so this just writes it.
#
# Usage:
#   ./slub-flash.sh out/rec__mixlife__metrics/image.bin
#   ./slub-flash.sh rec mixlife metrics    # shorthand for the above
set -euo pipefail

SLUB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SLUB_DIR/.." && pwd)
BR=$(echo "$ROOT_DIR"/buildroot-*/ | head -1); BR=${BR%/}

if [ $# -eq 3 ]; then
	IMG="$SLUB_DIR/out/${1}__${2}__${3}/image.bin"
elif [ $# -eq 2 ]; then
	IMG="$SLUB_DIR/out/${1}__${2}__metrics/image.bin"
elif [ $# -eq 1 ]; then
	IMG="$1"
else
	echo "usage: $0 <image.bin> | <variant> <workload> [profile]"; exit 1
fi
[ -f "$IMG" ] || { echo "no such image: $IMG"; exit 1; }

echo "[flash] writing $IMG ($(stat -c%s "$IMG") bytes) to 0x08000000"
"$BR/output/host/bin/openocd" -f "board/stm32f429discovery.cfg" \
	-c "init" -c "reset init" -c "flash probe 0" -c "flash info 0" \
	-c "flash write_image erase $IMG 0x08000000" \
	-c "reset run" -c "shutdown"
echo "[flash] done. Connect: picocom -b 115200 -g run.log /dev/ttyACM0"
echo "[flash] run on console: sh /run_slub_workload.sh <workload>"
