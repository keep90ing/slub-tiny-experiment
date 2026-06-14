#!/usr/bin/env bash
# slub-build.sh — build one minimal SLUB_TINY measurement image for the
# STM32F429-Discovery (8 MiB SDRAM target).
#
# Each image carries only the instrumentation needed by its measurement and
# at most one kernel workload driver. realvfs runs from userspace and needs
# no resident workload driver.
#   - the improvement patches selected by <variant>
# so per-image cost stays minimal, as required.
#
# The 0021..0029 base series is copied into Buildroot's board patch
# directory and applied at kernel extract time. The monolithic 0050 backup
# lives under patches/archive and is never auto-applied. The improvement
# patches in improvements/ are
# applied dynamically here, on top of the extracted tree, and reverted
# after the build so the tree returns to base-only.
#
# Usage:
#   ./slub-build.sh prepare
#       (re-extract the kernel so base patches 0021..0029 are present)
#   ./slub-build.sh <variant> <workload> [profile]
#       variant : baseline order0 nomerge sheafbypass minpartial
#                 reclaim bitmap rec combined
#       workload: small churn mixlife oom realvfs
#       profile : metrics (default, workload-specific instrumentation)
#                 perf (small only, instrumentation disabled)
#
# Output:
#   out/<variant>__<workload>__<profile>/{xipImage,image.bin,.config,size.txt}
set -euo pipefail

SLUB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SLUB_DIR/.." && pwd)
BR=$(echo "$ROOT_DIR"/buildroot-*/ | head -1); BR=${BR%/}
LINUX_DIR="$BR/output/build/linux-7.0"
IMAGES="$BR/output/images"
BOARD_CFG="$BR/board/stmicroelectronics/stm32f429-disco/linux.config"
IMP="$SLUB_DIR/improvements"
STAMP="$LINUX_DIR/.slub-applied"
BOARD_PATCHES="$BR/board/stmicroelectronics/stm32f429-disco/patches/linux"

# variant -> space-separated improvement patch stems (in apply order)
variant_patches() {
	case "$1" in
	baseline)    echo "" ;;
	order0)      echo "0009-slub-tiny-order0" ;;
	nomerge)     echo "0010-slub-tiny-unmerge-kconfig" ;;
	sheafbypass) echo "0011-slub-tiny-sheaf-bypass" ;;
	minpartial)  echo "0012-slub-tiny-min-partial" ;;
	reclaim)     echo "0013-slub-tiny-separate-reclaim" ;;
	bitmap)      echo "0014-slub-tiny-bitmap-freelist" ;;
	rec)         echo "0009-slub-tiny-order0 0011-slub-tiny-sheaf-bypass 0012-slub-tiny-min-partial" ;;
	combined)    echo "0009-slub-tiny-order0 0011-slub-tiny-sheaf-bypass 0012-slub-tiny-min-partial 0014-slub-tiny-bitmap-freelist" ;;
	*) echo "UNKNOWN" ;;
	esac
}

# variant -> extra kernel config lines (config flips beyond the patch)
variant_config() {
	case "$1" in
	nomerge) echo "# CONFIG_SLAB_MERGE_DEFAULT is not set" ;;
	reclaim) echo "CONFIG_SLUB_TINY_SEPARATE_RECLAIM=y" ;;
	*) : ;;
	esac
}

workload_config() {
	local workload="$1"
	local profile="$2"

	case "$profile" in
	metrics)
		echo "CONFIG_SLUB_TINY_INSTRUMENTATION=y"
		echo "# CONFIG_SLUB_TINY_INST_SIZES is not set"
		echo "# CONFIG_SLUB_TINY_INST_UTIL is not set"
		echo "# CONFIG_SLUB_TINY_INST_FRAG is not set"
		case "$workload" in
		churn|oom|realvfs)
			echo "CONFIG_SLUB_TINY_INST_UTIL=y"
			echo "CONFIG_SLUB_TINY_INST_FRAG=y"
			;;
		mixlife)
			echo "CONFIG_SLUB_TINY_INST_SIZES=y"
			echo "CONFIG_SLUB_TINY_INST_UTIL=y"
			echo "CONFIG_SLUB_TINY_INST_FRAG=y"
			;;
		esac
		;;
	perf)
		echo "# CONFIG_SLUB_TINY_INSTRUMENTATION is not set"
		echo "# CONFIG_SLUB_TINY_INST_SIZES is not set"
		echo "# CONFIG_SLUB_TINY_INST_UTIL is not set"
		echo "# CONFIG_SLUB_TINY_INST_FRAG is not set"
		;;
	esac

	echo "# CONFIG_SLUB_WL_SMALL is not set"
	echo "# CONFIG_SLUB_WL_CHURN is not set"
	echo "# CONFIG_SLUB_WL_MIXLIFE is not set"
	echo "# CONFIG_SLUB_WL_OOM is not set"

	case "$workload" in
	small)
		echo "CONFIG_SLUB_WL_SMALL=y"
		;;
	churn)
		echo "CONFIG_SLUB_WL_CHURN=y"
		;;
	mixlife)
		echo "CONFIG_SLUB_WL_MIXLIFE=y"
		;;
	oom)
		echo "CONFIG_SLUB_WL_OOM=y"
		;;
	realvfs)
		echo "CONFIG_EXT2_FS_XATTR=y"
		echo "CONFIG_SYSCTL=y"
		echo "CONFIG_PROC_SYSCTL=y"
		;;
	esac
}

workload_known() {
	case "$1" in
	small|churn|mixlife|oom|realvfs) return 0 ;;
	*) return 1 ;;
	esac
}

base_present() {
	[ -f "$LINUX_DIR/mm/slub_wl_small.c" ] &&
	[ -f "$LINUX_DIR/tools/testing/selftests/mm/slub_tiny_xattr.c" ]
}

sync_base_patches() {
	local patch

	rm -f "$BOARD_PATCHES"/0050*.patch
	rm -f "$BOARD_PATCHES"/002[1-9]-*.patch
	for patch in "$ROOT_DIR"/patches/linux/002[1-9]-*.patch; do
		cp "$patch" "$BOARD_PATCHES/"
	done
}

# Copy the on-board measurement scripts into the romfs source root and
# regenerate rootfs.romfs. romfs mounts as / and the SD card mounts as
# /root (shadowing romfs's /root), so scripts go at the romfs ROOT and
# are run as `sh /measure_slub_phase.sh ...` on the console.
embed_scripts_romfs() {
	local rfs="$ROOT_DIR/rootfs"
	local gen="$BR/output/host/bin/genromfs"
	local workload="$1"
	if [ ! -d "$rfs" ] || [ ! -x "$gen" ]; then
		echo "  [warn] rootfs/ or genromfs missing; run 'make initromfs' once"
		return 0
	fi
	rm -f "$rfs/measure_slub_phase.sh" "$rfs/run_slub_seed_sweep.sh" \
	      "$rfs/run_slub_workload.sh" "$rfs/smeasure.sh" \
	      "$rfs/sweep_seeds.sh" "$rfs/run_slub_baseline.sh" \
	      "$rfs/realvfs.sh" "$rfs/slub_xattr"
	cp "$SLUB_DIR/scripts/run_slub_workload.sh" "$rfs/"
	case "$workload" in
	realvfs)
		cp "$LINUX_DIR/tools/testing/selftests/mm/slub_tiny_realvfs.sh" \
		   "$rfs/realvfs.sh"
		"$BR/output/host/bin/arm-linux-gcc" -Os \
			-o "$rfs/slub_xattr" \
			"$LINUX_DIR/tools/testing/selftests/mm/slub_tiny_xattr.c"
		"$BR/output/host/bin/arm-linux-strip" "$rfs/slub_xattr"
		;;
	mixlife)
		cp "$SLUB_DIR/scripts/measure_slub_phase.sh" \
		   "$SLUB_DIR/scripts/run_slub_seed_sweep.sh" "$rfs/"
		;;
	*)
		cp "$SLUB_DIR/scripts/measure_slub_phase.sh" "$rfs/"
		;;
	esac
	"$gen" -d "$rfs" -f "$IMAGES/rootfs.romfs"
	echo "  [romfs] embedded scripts for workload=$workload"
}

# Re-assemble image.bin the same way the board flash.sh does:
# bootloader @0x08000000, dtb @0x08000800, xipImage @0x08005800,
# rootfs.romfs @0x08169000. Output to $1.
assemble_image() {
	local out="$1"
	local base=$((0x08000000)) dtb_b=$((0x08000800))
	local kern_b=$((0x08005800)) romfs_b=$((0x08169000))
	local boot="$IMAGES/stm32f429i-disco.bin"
	cp "$boot" "$out"
	local sz
	pad_to() { # pad $out so next blob starts at absolute addr $1
		local target=$1 cur
		cur=$(stat -c%s "$out")
		dd if=/dev/zero bs=1 count=$((target - base - cur)) \
			status=none >> "$out"
	}
	pad_to "$dtb_b";   cat "$IMAGES/stm32f429-disco.dtb" >> "$out"
	pad_to "$kern_b";  cat "$IMAGES/xipImage"            >> "$out"
	pad_to "$romfs_b"; cat "$IMAGES/rootfs.romfs"        >> "$out"
	echo "  [image] assembled $(stat -c%s "$out") bytes"
}

revert_improvements() {
	if [ -f "$STAMP" ]; then
		# reverse order
		local rev=""
		for p in $(cat "$STAMP"); do rev="$p $rev"; done
		for p in $rev; do
			patch -s -d "$LINUX_DIR" -p1 -R < "$IMP/$p.patch" || true
		done
		rm -f "$STAMP"
	fi
}

cmd_prepare() {
	echo "[prepare] installing base patches 0021..0029 and re-extracting kernel..."
	sync_base_patches
	make -C "$BR" linux-dirclean
	# linux-rebuild re-extracts and applies the split board patch series.
	make -C "$BR" linux-rebuild -j"$(nproc)"
	base_present && echo "[prepare] five-workload base present" \
		|| { echo "[prepare] ERROR: base patches did not land"; exit 1; }
	echo "[prepare] done. Now run: ./slub-build.sh baseline <workload>"
}

cmd_build() {
	local variant="$1" workload="$2" profile="${3:-metrics}"
	local pats; pats=$(variant_patches "$variant")
	[ "$pats" = UNKNOWN ] && { echo "unknown variant $variant"; exit 1; }
	workload_known "$workload" ||
		{ echo "unknown workload $workload"; exit 1; }
	case "$profile" in
	metrics) ;;
	perf)
		[ "$workload" = small ] ||
			{ echo "profile perf is supported only for small"; exit 1; }
		;;
	*) echo "unknown profile $profile"; exit 1 ;;
	esac

	base_present || { echo "base not present; run './slub-build.sh prepare' first"; exit 1; }

	echo "[build] variant=$variant workload=$workload profile=$profile"
	revert_improvements
	if [ -n "$pats" ]; then
		for p in $pats; do
			echo "  apply $p"
			patch -s -d "$LINUX_DIR" -p1 < "$IMP/$p.patch"
		done
		echo "$pats" > "$STAMP"
	fi

	# Build the kernel .config with only the instrumentation required by
	# this workload. small uses its internal timer with instrumentation
	# disabled; realvfs is entirely userspace-driven.
	local cfg="$LINUX_DIR/.config"
	cp "$BOARD_CFG" "$cfg"
	{
		workload_config "$workload" "$profile"
		# Trim everything outside the measurement path: a SLUB image needs
		# only the serial console (ttySTM0) + SD shell, not the LCD/touch
		# GUI stack or the SoC peripherals that only ever served it. This
		# frees XIP flash so instrumentation + one workload + any improvement
		# combo fit the kernel region (0x5800..0x169000), and -- more useful
		# for the study -- drops these drivers' boot-time probe kmallocs so
		# the Slab baseline in the "before" snapshot is lower and more
		# reproducible, and the big DRM coherent block no longer perturbs
		# buddyinfo. MMC/EXT2 and the fixed 3.3 V regulator are required:
		# the board's SDIO node references v3v3 through vmmc-supply.
		# Display stack (LCD / panel / backlight):
		echo "# CONFIG_DRM is not set"
		echo "# CONFIG_DRM_STM is not set"
		echo "# CONFIG_DRM_PANEL_ILITEK_ILI9341 is not set"
		echo "# CONFIG_BACKLIGHT_CLASS_DEVICE is not set"
		echo "# CONFIG_FB is not set"
		# Touch / input stack (STMPE expander on I2C/SPI) -- GUI only:
		echo "# CONFIG_INPUT_EVDEV is not set"
		echo "# CONFIG_INPUT_TOUCHSCREEN is not set"
		echo "# CONFIG_TOUCHSCREEN_STMPE is not set"
		echo "# CONFIG_MFD_STMPE is not set"
		# Unused SoC peripherals (only ever drove the touch/panel):
		echo "# CONFIG_I2C_STM32F4 is not set"
		echo "# CONFIG_SPI is not set"
		echo "# CONFIG_SPI_STM32 is not set"
		echo "CONFIG_REGULATOR=y"
		echo "CONFIG_REGULATOR_FIXED_VOLTAGE=y"
		echo "# CONFIG_RTC_CLASS is not set"
		variant_config "$variant"
	} >> "$cfg"
	make -C "$LINUX_DIR" ARCH=arm \
		CROSS_COMPILE="$BR/output/host/bin/arm-linux-" olddefconfig >/dev/null

	# Rebuild the kernel (produces a fresh xipImage). NOTE: buildroot's
	# linux-rebuild does NOT re-assemble image.bin, so we do it below.
	make -C "$BR" linux-rebuild -j"$(nproc)"

	# Embed the measurement scripts into the romfs ROOT (not /root, which
	# the SD card mount shadows) so they ride along inside image.bin and
	# are present at / on boot — no SD-card juggling needed.
	embed_scripts_romfs "$workload"
	# Assemble a self-contained image.bin (bootloader+dtb+THIS xipImage+
	# romfs-with-scripts) for this variant.
	assemble_image "$IMAGES/image.bin"

	local out="$SLUB_DIR/out/${variant}__${workload}__${profile}"
	mkdir -p "$out"
	cp "$IMAGES/xipImage" "$out/" 2>/dev/null || true
	cp "$IMAGES/image.bin" "$out/" 2>/dev/null || true
	cp "$cfg" "$out/.config"
	"$BR/output/host/bin/arm-linux-size" "$LINUX_DIR/vmlinux" \
		> "$out/size.txt" 2>/dev/null || true
	grep -E "SLUB_TINY_INST|SLUB_WL_|SLAB_MERGE|SEPARATE_RECLAIM|EXT2_FS_XATTR|PROC_SYSCTL|CONFIG_SYSCTL" \
		"$cfg" | grep -v "^#.*is not set$" > "$out/enabled.txt" || true

	echo "[build] image -> $out/"
	cat "$out/size.txt" 2>/dev/null || true

	# leave the tree base-only for the next build
	revert_improvements
}

case "${1:-}" in
prepare) cmd_prepare ;;
"")  echo "usage: $0 prepare | <variant> <workload> [metrics|perf]"; exit 1 ;;
*)   [ $# -ge 2 ] ||
	{ echo "usage: $0 <variant> <workload> [metrics|perf]"; exit 1; }
     cmd_build "$1" "$2" "${3:-metrics}" ;;
esac
