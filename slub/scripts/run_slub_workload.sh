#!/bin/sh
# Run the fixed baseline protocol for the workload compiled into this image.

WORKLOAD="$1"
ROUNDS="${2:-10}"

case "$WORKLOAD" in
small)
	case "$ROUNDS" in
	''|*[!0-9]*|0)
		echo "small rounds must be a positive integer"
		exit 2
		;;
	esac
	sh /measure_slub_phase.sh slub_wl_small "imm 500000 64" warmup
	i=1
	while [ "$i" -le "$ROUNDS" ]; do
		sh /measure_slub_phase.sh slub_wl_small "imm 500000 64" "run_$i"
		i=$((i + 1))
	done
	;;
churn)
	echo "drain 2" > /proc/slub_wl_churn
	sh /measure_slub_phase.sh slub_wl_churn "fill 2048 64" fill
	sh /measure_slub_phase.sh slub_wl_churn "release 8 2 3735928559" release
	sh /measure_slub_phase.sh slub_wl_churn "refill" refill
	sh /measure_slub_phase.sh slub_wl_churn "churn 16 500 2 3735928559" churn
	sh /measure_slub_phase.sh slub_wl_churn "recycle 200 800" recycle
	sh /measure_slub_phase.sh slub_wl_churn "free 500 2 2654435761" release
	sh /measure_slub_phase.sh slub_wl_churn "refill" refill
	sh /measure_slub_phase.sh slub_wl_churn "drain 2" drain
	;;
mixlife)
	echo drain > /proc/slub_wl_mixlife
	sh /run_slub_seed_sweep.sh slub_wl_mixlife "run 80000" 8
	;;
oom)
	for size in 64 256 1024; do
		sh /measure_slub_phase.sh slub_wl_oom "fill $size" "fill_$size" drain
	done
	;;
realvfs)
	sh /realvfs.sh "${2:-1000}"
	;;
*)
	echo "usage: sh /run_slub_workload.sh small [rounds]|churn|mixlife|oom|realvfs [iterations]"
	exit 2
	;;
esac
