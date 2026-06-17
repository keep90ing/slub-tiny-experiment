# STM32F429 Linux SLUB_TINY Experiment

This project is forked from
[rota1001/stm32f429-linux](https://github.com/rota1001/stm32f429-linux),
which provides the base BSP (Board Support Package) environment for running
Linux on the STM32F429-Discovery board. This branch uses that BSP as a
hardware experiment platform for studying Linux `SLUB_TINY` on STM32F429-Discovery.
 
The main purpose of this branch is to quantify `SLUB_TINY` memory efficiency,
fragmentation, allocation churn, and allocator latency trade-offs, then
evaluate small allocator changes with repeatable on-board workloads.

## SLUB_TINY Experiment Components

The SLUB_TINY experiment is built from two patch groups:

```text
patches/linux/0021..0024   Lightweight SLUB_TINY instrumentation
patches/linux/0025..0029   Board-runnable allocator workloads
```

Instrumentation covers allocation/free frequency, allocation size
distribution, per-cache utilization, and partial-slab fragmentation snapshots.

Workloads cover immediate small-object pairs, retained-set churn, mixed-size
lifetimes, fixed-headroom capacity probing, and a ramfs-backed real VFS
metadata workload.

## Variants

`slub/slub-build.sh` can build these main variants:

```text
baseline     no allocator improvement patch
order0       default SLUB_TINY `slub_max_order` to 0
nomerge      make slab merging configurable for SLUB_TINY
sheafbypass  bypass per-CPU sheaves for SLUB_TINY
minpartial   set SLUB_TINY `min_partial` to 2
bitmap       replace SLUB_TINY pointer freelist with a bitmap
```
 
## Dependencies 

On a Debian/Ubuntu host:

```sh
sudo apt -y install unzip bc build-essential libncurses-dev rsync cpio \
    python3 wget git file
```

OpenOCD is built by Buildroot and used by the flash helper.

## Quick Start

Fetch and patch Buildroot:

```sh
./fetch.sh
```

Build the base system:

```sh
make
```

Prepare the SLUB_TINY base patch series:

```sh
./slub/slub-build.sh prepare
```

Build a measurement image:

```sh
./slub/slub-build.sh <variant> <workload> [metrics|perf]
```

## Flash And Run

Flash a built image:

```sh
./slub/slub-flash.sh <variant> <workload> [metrics|perf]
```

Run the workload on the board:

```sh
sh /run_slub_workload.sh <workload>
```

## Analyze Captures

Parse a captured log on the host:

```sh
python3 slub/scripts/analyze_slub_capture.py \
    slub/logs/baseline__realvfs__metrics.log
```

The parser reports counter deltas, control-adjusted slab churn, size
histograms, utilization snapshots, fragmentation metrics, buddy allocator
state, small-workload `ns/pair`, and multi-run statistics.
