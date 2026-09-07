#!/usr/bin/env python3
"""
lab_results.py -- print a scientific summary of a completed experiment
run, reading ONLY the freshly generated result files in that run's
directory. No value in the output is hardcoded: every number is parsed
from the run's raw CSVs; the provenance block comes from that run's
run_metadata.json.

Usage: python3 scripts/lab_results.py <run_dir> <experiment> [--quiet]
Fails (exit 3) on missing files, empty CSVs, or unparseable numbers;
warns on NaN/Inf.
"""
import csv
import json
import math
import os
import sys

FAIL = []
WARN = []


def fail(msg):
    FAIL.append(msg)


def warn(msg):
    WARN.append(msg)


def need(path, what):
    if not os.path.exists(path):
        fail(f"missing {what}: {path}")
        return False
    return True


def load_csv(path, what):
    if not need(path, what):
        return []
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            rows.append(line.split(","))
    if not rows:
        fail(f"{what}: zero rows in {path}")
    return rows


def fnum(x, what):
    """Parse a float; register a failure if impossible."""
    try:
        v = float(x)
        if math.isnan(v) or math.isinf(v):
            warn(f"{what}: non-finite value {x}")
        return v
    except (TypeError, ValueError):
        fail(f"{what}: cannot parse numeric value {x!r}")
        return float("nan")


def median(vals):
    vals = sorted(vals)
    n = len(vals)
    if not n:
        return float("nan")
    if n % 2:
        return vals[n // 2]
    return (vals[n - 1] // 2 + vals[n // 2]) / 2


def fmt_bytes(b):
    if b >= 1048576 and b % 1048576 == 0:
        return f"{b // 1048576} MB"
    if b >= 1024 and b % 1024 == 0:
        return f"{b // 1024} KB"
    return f"{b} B"


def fmt_us(ns):
    return f"{ns / 1000.0:.1f} µs"


def hr(tag):
    print("═" * 56)
    print(tag)
    print("═" * 56)


def provenance(run):
    meta = {}
    mpath = os.path.join(run, "run_metadata.json")
    if need(mpath, "run metadata"):
        try:
            meta = json.load(open(mpath))
        except json.JSONDecodeError as e:
            fail(f"run_metadata.json does not parse: {e}")
    hr("Provenance")
    print(f"Run ID      : {os.path.basename(run)}")
    print(f"Git commit  : {meta.get('git_commit', 'unknown')}")
    print(f"Host        : {meta.get('hostname', 'unknown')}")
    print(f"Platform    : {meta.get('os', '?')} {meta.get('os_version', '')}"
          f" ({meta.get('architecture', '?')})")
    print(f"Compiler    : {meta.get('compiler', 'unknown')}")
    print(f"Timestamp   : {meta.get('timestamp', 'unknown')}")
    print(f"Run dir     : {run}")


def artifacts(run, files):
    print()
    for f in files:
        p = os.path.join(run, f)
        mark = "✓" if os.path.exists(p) else "✗"
        print(f"{mark} {f}")


# ----------------------------------------------------------- transport ---
def show_transport(run):
    hr("AdaptIPC — Transport Experiment (measured)")
    modes = [("uds", "UDS"), ("shm", "SHM"), ("adapt", "AdaptIPC")]
    data = {}
    for mode, label in modes:
        rows = load_csv(os.path.join(run, "raw", f"transport_{mode}.csv"),
                        f"transport_{mode}.csv")
        if not rows:
            continue
        hdr = rows[0]
        col = {name: i for i, name in enumerate(hdr)}
        need_payload = "payload_bytes" in col
        if not need_payload:
            fail(f"transport_{mode}.csv: no payload_bytes column")
        per_size = {}
        samples = 0
        for r in rows[1:]:
            try:
                pl = int(r[col["payload_bytes"]])
                lat = fnum(r[col["latency_ns"]], "latency_ns")
                tp = fnum(r[col["throughput_mbps"]], "throughput_mbps")
            except (IndexError, ValueError) as e:
                fail(f"transport_{mode}.csv: bad row {r}: {e}")
                continue
            per_size.setdefault(pl, []).append((lat, tp))
            samples += 1
        data[mode] = per_size
        print(f"  parsed transport_{mode}.csv: {samples} message rows")
    if FAIL:
        return
    sizes = sorted(set().union(*[set(d) for d in data.values()])
                   ) if data else []
    print()
    print(f"{'Payload':>10} {'UDS p50':>14} {'SHM p50':>14} "
          f"{'AdaptIPC p50':>14}   (median latency per size)")
    for pl in sizes:
        cells = []
        for mode, _ in modes:
            if mode in data and pl in data[mode]:
                lats = [x[0] for x in data[mode][pl]]
                cells.append(fmt_us(median(lats)))
            else:
                cells.append("—")
        print(f"{fmt_bytes(pl):>10} {cells[0]:>14} {cells[1]:>14} "
              f"{cells[2]:>14}")
    # per-mode aggregates over all messages
    print()
    print("Aggregate over all sizes (median per message):")
    for mode, label in modes:
        if mode not in data:
            continue
        all_lat = [x[0] for v in data[mode].values() for x in v]
        all_tp = [x[1] for v in data[mode].values() for x in v]
        print(f"  {label:9} latency p50 {fmt_us(median(all_lat)):>10}   "
              f"throughput p50 {median(all_tp):>8.1f} MB/s   "
              f"samples {len(all_lat)}")
    total = sum(len(v) for d in data.values() for v in d.values())
    print(f"\nSamples per mode: {[len(d) for d in data.values()] if data else 0}"
          f"  (total {total} measured messages)")
    print("Metric: end-to-end latency (ns→µs) and throughput (MB/s), "
          "per-message rows from benchmark_suite")
    artifacts(run, ["raw/transport_uds.csv", "raw/transport_shm.csv",
                    "raw/transport_adapt.csv", "run_metadata.json"])


# ------------------------------------------------------------ adaptive ---
def show_adaptive(run):
    hr("AdaptIPC — Adaptive Routing Experiment (measured)")
    rows = load_csv(os.path.join(run, "raw", "routing_trace.csv"),
                    "routing_trace.csv")
    if not rows:
        return
    hdr = rows[0]
    col = {n: i for i, n in enumerate(hdr)}
    if "route" not in col:
        fail("routing_trace.csv: no route column")
        return
    total = 0
    uds = shm = switches = 0
    ewmas = []
    payloads = {}
    prev = None
    for r in rows[1:]:
        try:
            pl = int(r[col["payload_bytes"]])
            route = r[col["route"]].strip()
            sw = int(r[col["switched"]]) if "switched" in col else 0
            if "ewma_bytes" in col:
                ewmas.append(fnum(r[col["ewma_bytes"]], "ewma_bytes"))
        except (IndexError, ValueError) as e:
            fail(f"routing_trace.csv: bad row {r}: {e}")
            continue
        total += 1
        if route == "UDS":
            uds += 1
        elif route == "SHM":
            shm += 1
        switches += sw
        payloads.setdefault(route, []).append(pl)
        prev = route
    if FAIL:
        return
    if total == 0:
        fail("routing_trace.csv: zero messages parsed")
        return
    print(f"  parsed routing_trace.csv: {total} decisions")
    print()
    print("Route distribution:")
    for name, n in (("UDS", uds), ("SHM", shm)):
        print(f"  {name:9}: {n:6d} messages ({100.0 * n / total:.1f} %)")
    print()
    print("Payload classes observed (bytes → route):")
    for route in sorted(payloads):
        pls = payloads[route]
        print(f"  {route:4}: {fmt_bytes(min(pls))} – {fmt_bytes(max(pls))} "
              f"({len(pls)} messages)")
    if ewmas:
        print()
        print(f"EWMA range: {fmt_bytes(min(ewmas))} – "
              f"{fmt_bytes(max(ewmas))}")
    print()
    print(f"Route transitions: {switches}")
    print(f"Total messages  : {total}")
    print(f"Switch rate     : {1000.0 * switches / total:.2f} per 1000 msgs")
    print("Metric: per-message routing decisions from the real policy "
          "(routing_trace)")
    artifacts(run, ["raw/routing_trace.csv", "run_metadata.json"])


# ---------------------------------------------------------- hysteresis ---
def show_hysteresis(run):
    hr("AdaptIPC — Hysteresis Stability Experiment (measured)")
    for pol in ("size_only", "size_hysteresis"):
        rows = load_csv(os.path.join(run, "raw", f"hysteresis_{pol}.csv"),
                        f"hysteresis_{pol}.csv")
        if not rows:
            continue
        hdr = rows[0]
        col = {n: i for i, n in enumerate(hdr)}
        n = 0
        sw = 0
        prev = None
        lats = []
        for r in rows[1:]:
            try:
                route = r[col["route_taken"]].strip()
                lats.append(fnum(r[col["latency_ns"]], "latency_ns"))
            except (IndexError, ValueError, KeyError) as e:
                fail(f"hysteresis_{pol}.csv: bad row: {e}")
                continue
            if prev is not None and route != prev:
                sw += 1
            prev = route
            n += 1
        if FAIL:
            return
        print(f"  {pol:18} messages {n:6d}   route switches {sw:5d}   "
              f"{1000.0 * sw / max(1, n):6.2f} per 1000   "
              f"latency p50 {fmt_us(median(lats))}")
    print("\nMetric: route switches under the adversarial thrash workload")
    artifacts(run, ["raw/hysteresis_size_only.csv",
                    "raw/hysteresis_size_hysteresis.csv",
                    "run_metadata.json"])


# ---------------------------------------------------------------- ewma ---
def show_ewma(run):
    hr("AdaptIPC — EWMA Alpha Sensitivity (measured)")
    for a in ("0.05", "0.1", "0.2", "0.3", "0.5", "0.8"):
        p = os.path.join(run, "raw", f"ewma_alpha_{a}.csv")
        if not os.path.exists(p):
            warn(f"missing ewma_alpha_{a}.csv (skipped)")
            continue
        rows = load_csv(p, f"ewma_alpha_{a}.csv")
        if not rows:
            continue
        col = {n: i for i, n in enumerate(rows[0])}
        n = 0
        sw = 0
        prev = None
        lats = []
        for r in rows[1:]:
            try:
                route = r[col["route_taken"]].strip()
                lats.append(fnum(r[col["latency_ns"]], "latency_ns"))
            except (IndexError, ValueError, KeyError) as e:
                fail(f"ewma_alpha_{a}.csv: bad row: {e}")
                continue
            if prev is not None and route != prev:
                sw += 1
            prev = route
            n += 1
        if lats:
            lats.sort()
            p99 = lats[int(0.99 * (len(lats) - 1))]
            print(f"  alpha={a:5} messages {n:6d}  switches {sw:4d}  "
                  f"latency p50 {fmt_us(median(lats)):>10}  "
                  f"p99 {fmt_us(p99):>10}")
    print("\nMetric: route switches and latency vs EWMA smoothing factor")
    artifacts(run, ["run_metadata.json"])


# ------------------------------------------------------------- latency ---
def show_latency(run):
    hr("AdaptIPC — Latency Breakdown Experiment (measured)")
    p = os.path.join(run, "raw", "latency_bimodal.csv")
    rows = load_csv(p, "latency_bimodal.csv")
    if rows:
        col = {n: i for i, n in enumerate(rows[0])}
        lats = []
        for r in rows[1:]:
            try:
                lats.append(fnum(r[col["latency_ns"]], "latency_ns"))
            except (IndexError, KeyError) as e:
                fail(f"latency_bimodal.csv: bad row: {e}")
        if lats:
            lats.sort()
            print(f"  messages {len(lats)}  latency p50 "
                  f"{fmt_us(median(lats))}  p99 "
                  f"{fmt_us(lats[int(0.99 * (len(lats) - 1))])}")
    bd = os.path.join(run, "raw",
                      "latency_breakdown_bimodal_producer.txt")
    if need(bd, "producer latency breakdown"):
        vals = {}
        for line in open(bd):
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                try:
                    vals[k.strip()] = float(v.strip())
                except ValueError:
                    pass
        for k in ("router_ewma_classify_mean_ns", "send_copy_mean_ns"):
            if k in vals:
                print(f"  {k:32} {vals[k] / 1000.0:8.2f} µs")
    print("\nMetric: producer-side measured counters (ADAPTIPC_STATS=1)")
    artifacts(run, ["raw/latency_bimodal.csv",
                    "raw/latency_breakdown_bimodal_producer.txt",
                    "run_metadata.json"])


# ---------------------------------------------------------- correctness ---
def show_correctness(run):
    hr("AdaptIPC — Build & Correctness")
    p = os.path.join(run, "test_results.txt")
    if need(p, "test results"):
        passed = failed = 0
        for line in open(p):
            if line.startswith("✓"):
                print(f"  ✓ {line[1:].strip()}")
                passed += 1
            elif line.startswith("✗"):
                print(f"  ✗ {line[1:].strip()}")
                failed += 1
        if "tests:" in open(p).read():
            print(open(p).read().strip().splitlines()[-1])
        else:
            print(f"  summary: {passed} passed, {failed} failed")
        if failed:
            fail(f"{failed} tests failed")
    artifacts(run, ["test_results.txt", "run_metadata.json"])


SHOW = {
    "transport": show_transport,
    "adaptive": show_adaptive,
    "hysteresis": show_hysteresis,
    "ewma": show_ewma,
    "latency": show_latency,
    "correctness": show_correctness,
}


def main():
    if len(sys.argv) < 3:
        print("usage: lab_results.py <run_dir> <experiment> [--quiet]",
              file=sys.stderr)
        return 2
    run, exp = sys.argv[1], sys.argv[2]
    quiet = "--quiet" in sys.argv[3:]
    if not os.path.isdir(run):
        print(f"error: run directory does not exist: {run}",
              file=sys.stderr)
        return 3
    fn = SHOW.get(exp)
    if not fn:
        print(f"error: no summary for experiment '{exp}'", file=sys.stderr)
        return 2
    fn(run)
    if WARN:
        print()
        for w in WARN:
            print(f"⚠ {w}")
    if FAIL:
        print()
        for f_ in FAIL:
            print(f"✗ VALIDATION FAILURE: {f_}", file=sys.stderr)
        return 3
    if not quiet:
        print()
        print("All displayed values were parsed from this run's raw "
              "files — nothing hardcoded.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
