#!/usr/bin/env python3
"""Analyze STM32F429 SLUB_TINY serial captures with raw instrumentation."""

import argparse
import re
import statistics

U32 = 1 << 32
PAGE_SIZE = 4096


def delta32(before, after):
    return (after - before) % U32


def blocks(text, begin, end):
    result = []
    current = None
    lines = []
    begin_re = re.compile(rf"==={begin} (.+?)===\s*$")
    end_re = re.compile(rf"==={end} (.+?)===\s*$")

    for line in text.splitlines():
        match = begin_re.match(line)
        if match:
            current = match.group(1)
            lines = []
            continue
        match = end_re.match(line)
        if match and current is not None:
            result.append((current, "\n".join(lines)))
            current = None
            continue
        if current is not None:
            lines.append(line)
    return result


def section(body, name):
    match = re.search(
        rf"--{re.escape(name)}--\n(.*?)(?=\n--|\Z)", body, re.S
    )
    return match.group(1) if match else ""


def parse_freq(body):
    values = {}
    keys = {
        "alloc", "free", "alloc_fail", "timestamp_ns",
        "slab_alloc", "slab_free", "inflight", "peak_inflight",
        "live_pages", "peak_live_pages",
    }
    for line in body.splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[0] in keys and fields[1].isdigit():
            values[fields[0]] = int(fields[1])
    return values


def parse_sizes(body):
    rows = {}
    for line in body.splitlines():
        fields = line.split()
        if (
            len(fields) == 4
            and (fields[0].startswith("slot-") or fields[0] == ">8192")
        ):
            try:
                rows[fields[0]] = {
                    "alloc": int(fields[1]),
                    "requested_B": int(fields[2]),
                    "allocated_B": int(fields[3]),
                }
            except ValueError:
                pass
    return rows


def parse_util(body):
    rows = {}
    total = {}
    for line in body.splitlines():
        fields = line.split()
        if not fields:
            continue
        if fields[0] == "TOTAL":
            for index in range(1, len(fields) - 1, 2):
                try:
                    total[fields[index]] = int(fields[index + 1])
                except ValueError:
                    pass
            continue
        if len(fields) == 9 and all(value.isdigit() for value in fields[1:]):
            rows[fields[0]] = {
                "object_size": int(fields[1]),
                "slot_size": int(fields[2]),
                "order": int(fields[3]),
                "objects_per_slab": int(fields[4]),
                "live_objects": int(fields[5]),
                "live_slabs": int(fields[6]),
                "live_pages": int(fields[7]),
                "peak_live_pages": int(fields[8]),
            }
    return rows, total


def parse_frag(body):
    rows = {}
    lines = body.splitlines()
    index = 0
    while index < len(lines):
        line = lines[index]
        report = re.search(r"(slub_wl_\w+|slub_tiny_vfs):", line)
        if report:
            line = line[:report.start()].rstrip()
        fields = line.split()
        if (
            len(fields) == 5
            and index + 1 < len(lines)
            and lines[index + 1].strip().isdigit()
        ):
            fields.append(lines[index + 1].strip())
            index += 1
        if len(fields) == 6 and all(value.isdigit() for value in fields[1:]):
            rows[fields[0]] = {
                "live_slabs": int(fields[1]),
                "empty_slabs": int(fields[2]),
                "partial_slabs": int(fields[3]),
                "partial_slots": int(fields[4]),
                "holes": int(fields[5]),
            }
        index += 1
    return rows


def parse_memfree(body):
    match = re.search(r"^MemFree:\s+(\d+)\s+kB", body, re.M)
    return int(match.group(1)) if match else None


def parse_buddy(body):
    orders = []
    for line in body.splitlines():
        match = re.match(r"Node\s+\d+,\s+zone\s+\S+\s+(.+)$", line)
        if not match:
            continue
        try:
            counts = [int(value) for value in match.group(1).split()]
        except ValueError:
            continue
        if len(orders) < len(counts):
            orders.extend([0] * (len(counts) - len(orders)))
        for order, count in enumerate(counts):
            orders[order] += count

    total_pages = sum(count << order for order, count in enumerate(orders))
    high_pages = sum(
        count << order for order, count in enumerate(orders) if order >= 2
    )
    largest = max((order for order, count in enumerate(orders) if count), default=-1)
    return {
        "orders": orders,
        "total_pages": total_pages,
        "high_pages": high_pages,
        "largest_order": largest,
    }


def legacy_freq_key(tag):
    if tag == "start":
        return "workload", "single", True
    if tag == "end":
        return "workload", "single", False
    if tag.startswith("start_"):
        return "workload", tag[6:], True
    if tag.startswith("end_"):
        return "workload", tag[4:], False
    if tag.endswith("_start"):
        return "workload", tag[:-6], True
    if tag.endswith("_end"):
        return "workload", tag[:-4], False
    return None, None, None


def freq_key(tag):
    match = re.match(r"^(control|workload):(.+):(start|end)$", tag)
    if match:
        return match.group(1), match.group(2), match.group(3) == "start"
    return legacy_freq_key(tag)


def counter_delta(before, after):
    result = {}
    for key in ("alloc", "free", "alloc_fail", "slab_alloc", "slab_free"):
        result[key] = delta32(before.get(key, 0), after.get(key, 0))
    result["elapsed_ns"] = (
        after.get("timestamp_ns", 0) - before.get("timestamp_ns", 0)
    )
    result["peak_inflight"] = after.get("peak_inflight", 0)
    result["peak_live_pages"] = after.get("peak_live_pages", 0)
    return result


def timed_windows(freq_blocks):
    pending = {}
    counts = {}
    result = []

    for tag, body in freq_blocks:
        kind, phase, is_start = freq_key(tag)
        if phase is None:
            continue
        key = (kind, phase)
        values = parse_freq(body)
        if is_start:
            pending.setdefault(key, []).append(values)
            continue
        starts = pending.get(key, [])
        if not starts:
            continue
        start = starts.pop(0)
        if not start and not values:
            continue
        counts[key] = counts.get(key, 0) + 1
        label = phase if counts[key] == 1 else f"{phase}_{counts[key]}"
        result.append({
            "kind": kind,
            "phase": phase,
            "label": label,
            "before": start,
            "after": values,
            "delta": counter_delta(start, values),
        })
    return result


def adjusted_delta(raw, control):
    if not control:
        return None
    adjusted = {}
    for key in ("alloc", "free", "alloc_fail", "slab_alloc", "slab_free"):
        adjusted[key] = max(0, raw[key] - control[key])
    return adjusted


def print_timing(windows):
    if not windows:
        return
    controls = {}
    print("\n# FREQ counter windows (elapsed is diagnostic, not allocator latency)")
    print(
        f"{'kind':<10}{'window':<18}{'alloc':>9}{'free':>9}{'fail':>7}"
        f"{'slab+':>8}{'slab-':>8}{'a_adj':>9}{'f_adj':>9}"
        f"{'fail_a':>8}{'s+_adj':>9}{'s-_adj':>9}"
        f"{'elapsed_ms':>12}{'peak_pg':>9}"
    )
    for window in windows:
        delta = window["delta"]
        if window["kind"] == "control":
            controls.setdefault(window["phase"], []).append(delta)
            adjusted = None
        else:
            candidates = controls.get(window["phase"], [])
            control = candidates.pop(0) if candidates else None
            adjusted = adjusted_delta(delta, control)
        window["adjusted"] = adjusted
        adjusted_values = (
            ["-"] * 5 if adjusted is None else [
                str(adjusted[key]) for key in (
                    "alloc", "free", "alloc_fail", "slab_alloc", "slab_free"
                )
            ]
        )
        print(
            f"{window['kind']:<10}{window['label']:<18}"
            f"{delta['alloc']:>9}{delta['free']:>9}{delta['alloc_fail']:>7}"
            f"{delta['slab_alloc']:>8}{delta['slab_free']:>8}"
            f"{adjusted_values[0]:>9}{adjusted_values[1]:>9}"
            f"{adjusted_values[2]:>8}{adjusted_values[3]:>9}"
            f"{adjusted_values[4]:>9}"
            f"{delta['elapsed_ns'] / 1_000_000:>12.3f}"
            f"{delta['peak_live_pages']:>9}"
        )


def cache_fragmentation(util_rows, frag_rows):
    result = []
    for name in sorted(set(util_rows) | set(frag_rows)):
        util = util_rows.get(name, {})
        frag = frag_rows.get(name, {})
        live_slabs = frag.get("live_slabs", util.get("live_slabs", 0))
        partial = frag.get("partial_slabs", 0)
        empty = frag.get("empty_slabs", 0)
        holes = frag.get("holes", 0)
        slot_size = util.get("slot_size", 0)
        object_size = util.get("object_size", 0)
        live_objects = util.get("live_objects", 0)
        order = util.get("order", 0)
        partial_hole_b = holes * slot_size
        retained_empty_b = empty * (PAGE_SIZE << order)
        internal_padding_b = live_objects * max(0, slot_size - object_size)
        result.append({
            "cache": name,
            "live_slabs": live_slabs,
            "partial_slabs": partial,
            "partial_ratio": partial / live_slabs if live_slabs else 0.0,
            "holes": holes,
            "partial_hole_B": partial_hole_b,
            "retained_empty_B": retained_empty_b,
            "internal_padding_B": internal_padding_b,
            "stranded_B": (
                partial_hole_b + retained_empty_b + internal_padding_b
            ),
        })
    return result


def snapshot_record(tag, body, cache=None):
    freq = parse_freq(section(body, "freq"))
    util_rows, total = parse_util(section(body, "util"))
    frag_rows = parse_frag(section(body, "frag"))
    memfree = parse_memfree(section(body, "mem"))
    buddy = parse_buddy(section(body, "buddy"))
    cache_frag = cache_fragmentation(util_rows, frag_rows)

    live_page_b = total.get("live_page_B", 0)
    live_slot_b = total.get("live_slot_B", 0)
    live_obj_b = total.get("live_obj_B", 0)
    slot_eff = 100.0 * live_slot_b / live_page_b if live_page_b else 0.0
    object_eff = 100.0 * live_obj_b / live_page_b if live_page_b else 0.0

    empty = sum(row["empty_slabs"] for row in frag_rows.values())
    partial = sum(row["partial_slabs"] for row in frag_rows.values())
    live_slabs = sum(row["live_slabs"] for row in frag_rows.values())
    holes = sum(row["holes"] for row in frag_rows.values())

    record = {
        "tag": tag,
        "live_pages": freq.get("live_pages", 0),
        "peak_pages": freq.get("peak_live_pages", 0),
        "slot_eff": slot_eff,
        "object_eff": object_eff,
        "empty": empty,
        "partial": partial,
        "partial_ratio": 100.0 * partial / live_slabs if live_slabs else 0.0,
        "holes": holes,
        "partial_hole_B": sum(row["partial_hole_B"] for row in cache_frag),
        "retained_empty_B": sum(row["retained_empty_B"] for row in cache_frag),
        "internal_padding_B": sum(
            row["internal_padding_B"] for row in cache_frag
        ),
        "memfree": memfree,
        "buddy": buddy,
        "cache_fragmentation": cache_frag,
    }
    if cache:
        record["cache_util"] = util_rows.get(cache)
        record["cache_frag"] = frag_rows.get(cache)
    return record


def print_snapshots(snapshot_blocks, cache, top_caches):
    if not snapshot_blocks:
        return []
    records = [
        snapshot_record(tag, body, cache) for tag, body in snapshot_blocks
    ]
    print("\n# Snapshot memory and fragmentation state")
    print(
        f"{'snapshot':<24}{'live_pg':>8}{'peak_pg':>9}"
        f"{'slot_eff%':>11}{'obj_eff%':>10}{'empty':>7}"
        f"{'partial':>9}{'part%':>8}{'holes':>8}"
        f"{'hole_B':>10}{'empty_B':>10}{'pad_B':>10}{'MemFree':>9}"
    )
    for record in records:
        memfree = "-" if record["memfree"] is None else record["memfree"]
        print(
            f"{record['tag']:<24}{record['live_pages']:>8}"
            f"{record['peak_pages']:>9}{record['slot_eff']:>11.2f}"
            f"{record['object_eff']:>10.2f}{record['empty']:>7}"
            f"{record['partial']:>9}{record['partial_ratio']:>8.2f}"
            f"{record['holes']:>8}{record['partial_hole_B']:>10}"
            f"{record['retained_empty_B']:>10}"
            f"{record['internal_padding_B']:>10}{str(memfree):>9}"
        )
        if cache:
            util = record.get("cache_util")
            frag = record.get("cache_frag")
            if util or frag:
                print(f"  {cache}: util={util or '-'} frag={frag or '-'}")
        if top_caches:
            rows = sorted(
                record["cache_fragmentation"],
                key=lambda row: row["stranded_B"],
                reverse=True,
            )
            rows = [row for row in rows if row["stranded_B"]][:top_caches]
            if rows:
                details = ", ".join(
                    f"{row['cache']}={row['stranded_B']}B"
                    f"(hole={row['partial_hole_B']},"
                    f"empty={row['retained_empty_B']},"
                    f"pad={row['internal_padding_B']})"
                    for row in rows
                )
                print(f"  top stranded: {details}")
    return records


def print_buddy(records):
    available = [record for record in records if record["buddy"]["orders"]]
    if not available:
        return
    max_orders = max(len(record["buddy"]["orders"]) for record in available)
    print("\n# Buddy allocator state")
    print(
        f"{'snapshot':<24}{'free_pages':>11}{'order>=2_pg':>13}"
        f"{'largest':>9}  blocks by order 0..{max_orders - 1}"
    )
    for record in available:
        buddy = record["buddy"]
        counts = buddy["orders"] + [0] * (max_orders - len(buddy["orders"]))
        print(
            f"{record['tag']:<24}{buddy['total_pages']:>11}"
            f"{buddy['high_pages']:>13}{buddy['largest_order']:>9}  "
            + " ".join(str(value) for value in counts)
        )


def snapshot_pair_key(tag):
    match = re.match(r"^(.+):(before|after)$", tag)
    if match:
        return match.group(1), match.group(2)
    if tag == "before":
        return "single", "before"
    if tag == "after":
        return "single", "after"
    if tag.startswith("before_"):
        return tag[7:], "before"
    if tag.startswith("after_"):
        return tag[6:], "after"
    return None, None


def snapshot_pairs(snapshot_blocks):
    pending = {}
    pairs = []
    counts = {}
    for tag, body in snapshot_blocks:
        key, side = snapshot_pair_key(tag)
        if key is None:
            continue
        if side == "before":
            pending.setdefault(key, []).append(body)
        elif pending.get(key):
            counts[key] = counts.get(key, 0) + 1
            label = key if counts[key] == 1 else f"{key}_{counts[key]}"
            pairs.append((label, pending[key].pop(0), body))
    return pairs


def print_size_deltas(snapshot_blocks):
    pairs = snapshot_pairs(snapshot_blocks)
    rows_printed = False
    for label, before, after in pairs:
        old = parse_sizes(section(before, "sizes"))
        new = parse_sizes(section(after, "sizes"))
        rows = []
        for name, row in new.items():
            previous = old.get(name, {})
            alloc = delta32(previous.get("alloc", 0), row["alloc"])
            requested = delta32(
                previous.get("requested_B", 0), row["requested_B"]
            )
            allocated = delta32(
                previous.get("allocated_B", 0), row["allocated_B"]
            )
            if alloc or requested or allocated:
                rows.append((name, alloc, requested, allocated))
        if not rows:
            continue
        if not rows_printed:
            print("\n# Size histogram deltas")
            rows_printed = True
        print(f"## {label}")
        print(
            f"{'slot_class':<14}{'alloc':>10}{'requested_B':>14}"
            f"{'allocated_B':>14}{'waste_B':>12}{'waste%':>9}"
        )
        total_alloc = total_requested = total_allocated = 0
        for name, alloc, requested, allocated in rows:
            waste_b = max(0, allocated - requested)
            waste_pct = 100.0 * waste_b / allocated if allocated else 0.0
            print(
                f"{name:<14}{alloc:>10}{requested:>14}{allocated:>14}"
                f"{waste_b:>12}{waste_pct:>9.2f}"
            )
            total_alloc += alloc
            total_requested += requested
            total_allocated += allocated
        total_waste = max(0, total_allocated - total_requested)
        total_pct = (
            100.0 * total_waste / total_allocated if total_allocated else 0.0
        )
        print(
            f"{'TOTAL':<14}{total_alloc:>10}{total_requested:>14}"
            f"{total_allocated:>14}{total_waste:>12}{total_pct:>9.2f}"
        )


def median_abs_deviation(values):
    if not values:
        return 0.0
    median = statistics.median(values)
    return statistics.median(abs(value - median) for value in values)


def print_stats(title, rows):
    if not any(len(values) >= 2 for _, values in rows):
        return
    print(f"\n# {title}")
    print(f"{'metric':<24}{'n':>5}{'min':>14}{'median':>14}{'max':>14}{'MAD':>14}")
    for name, values in rows:
        if len(values) < 2:
            continue
        print(
            f"{name:<24}{len(values):>5}{min(values):>14.2f}"
            f"{statistics.median(values):>14.2f}{max(values):>14.2f}"
            f"{median_abs_deviation(values):>14.2f}"
        )


def measure_blocks(text):
    return blocks(text, "MEASURE", "ENDMEASURE")


def small_timings(text):
    pattern = re.compile(
        r"slub_wl_small: size=(\d+) requested=(\d+) completed=(\d+) "
        r"elapsed_ns=(\d+)"
    )
    results = []
    measured = measure_blocks(text)
    if measured:
        for phase, body in measured:
            match = pattern.search(body)
            if match:
                results.append((phase, *map(int, match.groups())))
    else:
        for index, match in enumerate(pattern.finditer(text), 1):
            results.append((f"run_{index}", *map(int, match.groups())))
    return results


def print_internal_timing(text):
    timings = small_timings(text)
    if not timings:
        return
    print("\n# Small workload internal timing")
    print(
        f"{'phase':<18}{'size':>8}{'requested':>12}{'completed':>12}"
        f"{'elapsed_ms':>12}{'ns/pair':>11}"
    )
    measured = []
    for phase, size, requested, completed, elapsed in timings:
        ns_per_pair = elapsed / max(completed, 1)
        print(
            f"{phase:<18}{size:>8}{requested:>12}{completed:>12}"
            f"{elapsed / 1_000_000:>12.3f}{ns_per_pair:>11.1f}"
        )
        if phase != "warmup":
            measured.append(ns_per_pair)
    print_stats("Small timing distribution (warmup excluded)", [
        ("ns/pair", measured),
    ])


def print_workload_reports(text):
    lines = []
    for line in text.splitlines():
        match = re.search(r"(slub_wl_\w+|slub_tiny_vfs):.*", line)
        if match:
            lines.append(match.group(0))
    if not lines:
        return
    print("\n# Workload-reported results")
    for line in lines:
        print(line)


def statistics_group(phase):
    if re.match(r"^run_\d+$", phase):
        return "run"
    if re.match(r"^seed_\d+$", phase) or phase.isdigit():
        return "seed"
    return None


def print_window_stats(windows):
    groups = {}
    adjusted_groups = {}
    for window in windows:
        if window["kind"] != "workload" or window["phase"] == "warmup":
            continue
        group = statistics_group(window["phase"])
        if group:
            groups.setdefault(group, []).append(window["delta"])
            if window.get("adjusted") is not None:
                adjusted_groups.setdefault(group, []).append(window["adjusted"])
    for group, workload in groups.items():
        print_stats(f"Raw '{group}' window distribution", [
            ("alloc", [row["alloc"] for row in workload]),
            ("free", [row["free"] for row in workload]),
            ("slab_alloc", [row["slab_alloc"] for row in workload]),
            ("slab_free", [row["slab_free"] for row in workload]),
            ("peak_live_pages", [row["peak_live_pages"] for row in workload]),
        ])
    for group, workload in adjusted_groups.items():
        print_stats(f"Control-adjusted '{group}' window distribution", [
            ("alloc", [row["alloc"] for row in workload]),
            ("free", [row["free"] for row in workload]),
            ("slab_alloc", [row["slab_alloc"] for row in workload]),
            ("slab_free", [row["slab_free"] for row in workload]),
        ])


def print_snapshot_stats(records):
    groups = {}
    for record in records:
        key, side = snapshot_pair_key(record["tag"])
        if side != "after" or key == "warmup":
            continue
        group = statistics_group(key)
        if group:
            groups.setdefault(group, []).append(record)
    for group, after in groups.items():
        print_stats(f"'{group}' after-snapshot distribution", [
            ("live_pages", [row["live_pages"] for row in after]),
            ("partial_slabs", [row["partial"] for row in after]),
            ("partial_ratio_pct", [row["partial_ratio"] for row in after]),
            ("holes", [row["holes"] for row in after]),
            ("partial_hole_B", [row["partial_hole_B"] for row in after]),
            ("buddy_free_pages", [row["buddy"]["total_pages"] for row in after]),
        ])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("log")
    parser.add_argument("--cache", help="show one cache's raw util/frag rows")
    parser.add_argument(
        "--top-caches", type=int, default=5,
        help="show this many caches ranked by stranded bytes (default: 5)",
    )
    args = parser.parse_args()

    with open(args.log, errors="replace") as capture:
        text = capture.read().replace("\0", "")

    snapshot_blocks = blocks(text, "SNAP", "ENDSNAP")
    freq_blocks = blocks(text, "FREQ", "ENDFREQ")
    windows = timed_windows(freq_blocks)

    print(f"# {args.log}")
    print_timing(windows)
    records = print_snapshots(snapshot_blocks, args.cache, args.top_caches)
    print_buddy(records)
    print_size_deltas(snapshot_blocks)
    print_internal_timing(text)
    print_workload_reports(text)
    print_window_stats(windows)
    print_snapshot_stats(records)


if __name__ == "__main__":
    main()
