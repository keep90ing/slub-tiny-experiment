#!/bin/sh
# measure_slub_phase.sh — measure one SLUB_TINY workload phase on target.
#
# Embedded in the romfs root by slub-build.sh; run from the serial console:
#   sh /measure_slub_phase.sh <workload-proc> "<write-args>" [phase] [cleanup-args]
# It re-bases the instrumentation high-water marks, takes a "before"
# snapshot, drives the workload, then takes an "after" snapshot. All
# output goes to the console (capture it with picocom's logging, e.g.
# `picocom -b 115200 -g run.log /dev/ttyACM0`) and is differenced
# off-line by slub/scripts/analyze_slub_capture.py.
#
# The workload's internal ktime result is the allocator-latency metric.
# The FREQ timestamp window also includes serial output around the start
# sample, so use it for counter deltas rather than latency comparisons.
#
# Examples:
#   sh /measure_slub_phase.sh slub_wl_small   "imm 200000"
#   sh /measure_slub_phase.sh slub_wl_churn   "fill 1280 64"
#   sh /measure_slub_phase.sh slub_wl_mixlife "run 40000 3735928559"
#
# Memory budget note: this is the 8 MiB SDRAM board (MemTotal ~7.8 MB,
# ~6 MB free after boot). Keep one workload's live set well under that;
# the churn driver caps retained data at 2 MiB, but size N conservatively.

PROC="$1"
ARGS="$2"
PHASE="${3:-single}"
CLEANUP="${4:-}"
if [ -z "$PROC" ] || [ -z "$ARGS" ]; then
	echo "usage: sh measure_slub_phase.sh <slub_wl_NAME> \"<args>\" [phase] [cleanup-args]"
	exit 1
fi

snap() {
	echo "===SNAP $1==="
	for name in freq sizes snapshot; do
		echo "--$name--"
		path="/proc/slub_tiny_$name"
		if [ -r "$path" ]; then
			cat "$path"
		else
			echo "unavailable"
		fi
	done
	if [ ! -r /proc/slub_tiny_snapshot ]; then
		for name in util frag; do
			echo "--$name--"
			path="/proc/slub_tiny_$name"
			if [ -r "$path" ]; then
				cat "$path"
			else
				echo "unavailable"
			fi
		done
	fi
	echo "--mem--";   head -3 /proc/meminfo
	echo "--buddy--"; cat /proc/buddyinfo
	echo "===ENDSNAP $1==="
}

print_freq() {
	echo "===FREQ $1==="
	if [ -r /proc/slub_tiny_freq ]; then
		cat /proc/slub_tiny_freq
	else
		echo "unavailable"
	fi
	echo "===ENDFREQ $1==="
}

window() {
	kind="$1"
	phase="$2"
	command="$3"
	print_freq "$kind:$phase:start"
	if [ "$command" = workload ]; then
		echo "$ARGS" > "/proc/$PROC"
	else
		:
	fi
	print_freq "$kind:$phase:end"
}

echo "===MEASURE $PHASE==="
echo "########## SLUB measure: phase=$PHASE $PROC <- $ARGS ##########"
snap "$PHASE:before"
window control "$PHASE" noop
if [ -w /proc/slub_tiny_freq ]; then
	echo reset > /proc/slub_tiny_freq
fi
window workload "$PHASE" workload
snap "$PHASE:after"
if [ -n "$CLEANUP" ]; then
	echo "########## cleanup: $PROC <- $CLEANUP ##########"
	echo "$CLEANUP" > "/proc/$PROC"
	snap "$PHASE:drained"
fi
echo "########## done ##########"
echo "===ENDMEASURE $PHASE==="
