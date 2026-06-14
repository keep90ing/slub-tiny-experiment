#!/bin/sh
# run_slub_seed_sweep.sh — run one seedable workload across several seeds
# (review point A2: report a distribution, not one trajectory).
#
# Run on the board:
#   sh /run_slub_seed_sweep.sh <slub_wl_NAME> "<args-before-seed>" <count>
# It runs `<args-before-seed> <seed>` for `count` fixed seeds, each
# bracketed by a reset + before/after snapshot, so the off-line parser
# can summarize the metric spread across seeds.
#
# The independent seed sweep is intended for mixlife. e.g.
#   sh /run_slub_seed_sweep.sh slub_wl_mixlife "run 40000" 8

PROC="$1"
PRE="$2"
COUNT="${3:-8}"
if [ -z "$PROC" ] || [ -z "$PRE" ]; then
	echo "usage: sh run_slub_seed_sweep.sh <slub_wl_NAME> \"<pre-args>\" <count>"
	exit 1
fi

# Fixed seed list (deterministic, reproducible across variants/boots).
SEEDS="3735928559 2654435761 40503 2246822519 3266489917 668265263 374761393 1560722633 12345 87654321"

i=0
for s in $SEEDS; do
	[ "$i" -ge "$COUNT" ] && break
	i=$((i + 1))
	echo "########## seed $i = $s : $PROC <- $PRE $s ##########"
	sh /measure_slub_phase.sh "$PROC" "$PRE $s" "seed_$i"
	if [ "$PROC" = "slub_wl_mixlife" ]; then
		echo drain > "/proc/$PROC"
		# Let deferred printk output drain before the next snapshot.
		sleep 1
	fi
done
echo "########## sweep done ($i seeds) ##########"
