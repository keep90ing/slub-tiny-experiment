#!/bin/sh
# sweep_small_sizes.sh — sweep slub_wl_small across object sizes on the board.
#
# Isolates the 0005 bitmap page-end cost: object sizes that map to <= 32
# objects/slab keep the bitmap inline in slab->freelist (in the memmap),
# while smaller objects (>32 objects/slab, i.e. < 128 B on a 4 KiB page,
# 32-bit) place it at the slab page end. Sweeping size lets the host
# compare per-size bitmap-vs-baseline latency: a near-zero delta at 128 B
# (inline) with a large delta at 32/64 B (page-end) proves the cost is
# placement, not the bitmap algorithm.
#
# Run on the serial console (use a perf image, instrumentation disabled):
#   sh /sweep_small_sizes.sh [iterations] [rounds] [sizes...]
# Defaults: iterations=500000 rounds=10 sizes="32 64 128".
# One warm-up pass per size is emitted first and must be discarded by the
# host parser (it is the first slub_wl_small line for each size). Capture
# with picocom -g and analyse with:
#   python3 slub/scripts/analyze_slub_capture.py --timing-only run.log

PROC=/proc/slub_wl_small
ITERS="${1:-500000}"
ROUNDS="${2:-10}"
if [ "$#" -gt 2 ]; then
	shift 2
	SIZES="$*"
else
	SIZES="32 64 128"
fi

case "$ITERS$ROUNDS" in
	*[!0-9]*)
		echo "iterations and rounds must be positive integers"
		exit 2
		;;
esac
if [ ! -w "$PROC" ]; then
	echo "$PROC not writable — build with CONFIG_SLUB_WL_SMALL=y (perf image)"
	exit 1
fi

# Record which kernel binary produced this capture. The compile timestamp in
# /proc/version differs between separately built images, so the host can prove
# baseline and variant logs came from different binaries (guards against a
# missed reflash producing identical numbers).
echo "===KERNEL ID==="
cat /proc/version
echo "uptime: $(cat /proc/uptime 2>/dev/null)"
echo "===END KERNEL ID==="

echo "===SWEEP iters=$ITERS rounds=$ROUNDS sizes=$SIZES==="
for s in $SIZES; do
	echo "===SIZE $s WARMUP==="
	echo "imm $ITERS $s" > "$PROC"
	echo "===SIZE $s MEASURED==="
	n=1
	while [ "$n" -le "$ROUNDS" ]; do
		echo "imm $ITERS $s" > "$PROC"
		n=$((n + 1))
	done
done
echo "===SWEEP done==="
