#!/usr/bin/env bash
# ============================================================================
# AdaptIPC Experiment Lab -- one-command experiment environment.
#
#   ./demo/adaptipc_lab.sh                    (menu)
#   ./demo/adaptipc_lab.sh -presentation      (fast, reliable demo)
#   ./demo/adaptipc_lab.sh -live              (live router dashboard)
#   ./demo/adaptipc_lab.sh -experiment all|correctness|transport|
#                                           adaptive|hysteresis|ewma|latency
#   ./demo/adaptipc_lab.sh -graphs|-tables|-report
#
# Every experiment writes into a unique run directory:
#   experiments/runs/<YYYY-MM-DD_HHMMSS>/
# Historical results are never overwritten. All numbers come from the
# real implementation; nothing is simulated.
# ============================================================================
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
RUNS_ROOT="$ROOT/experiments/runs"
BUILD="$ROOT/build-lab"
CC="${CC:-cc}"
CFLAGS="-std=c11 -O3 -Wall -Wextra -Wpedantic -pthread -Iinclude"
SRC="src/shm_ringbuffer.c src/uds_fallback.c src/adapt_ipc.c src/cost_model.c src/runtime_context.c src/transport_health.c"
TESTS="adapt_ipc shm_ringbuffer flowcontrol lazy_negotiation backpressure_latency cost_model policy_modes decision_log_consistency route_transition_accounting queue_occupancy_instrumentation"
RUN=""
STEP=0; STEPS=1
# Presentation flags (set from trailing -quiet / -show-results).
# Default: show the results summary. QUIET=1 suppresses it (for CI).
QUIET=0
SHOW_RESULTS=1

banner() {
    echo "=============================================="
    echo "  AdaptIPC Experiment Lab"
    echo "  Adaptive IPC Routing Middleware"
    echo "=============================================="
}

say() { echo "  $*"; }
ok()  { echo "  [OK] $*"; }
bad() { echo "  [FAIL] $*"; }

new_run() {  # new_run <label>
    local label="${1:-lab}"
    local ts; ts=$(date +%Y-%m-%d_%H%M%S)
    RUN="$RUNS_ROOT/${ts}_${label}"
    mkdir -p "$RUN/raw" "$RUN/processed" "$RUN/plots" "$RUN/tables" "$RUN/report"
}

step() { STEP=$((STEP+1)); echo "  [$STEP/$STEPS] $*"; }
step_ok() { echo "  [$STEP/$STEPS] $* ✓"; }
step_bad() { echo "  [$STEP/$STEPS] $* ✗"; return 1; }

write_metadata() {  # write_metadata <label> <mode>
    cat > "$RUN/run_metadata.json" <<JSON
{
  "label": "$1",
  "mode": "$2",
  "timestamp": "$(date +%Y-%m-%dT%H:%M:%S%z)",
  "hostname": "$(hostname 2>/dev/null || echo unknown)",
  "os": "$(uname -s)",
  "os_version": "$(uname -r)",
  "architecture": "$(uname -m)",
  "cpu_model": "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo unknown)",
  "compiler": "$("$CC" --version | head -1)",
  "cmake_version": "$(cmake --version 2>/dev/null | head -1 || echo 'not used (direct cc build)')",
  "python_version": "$(python3 --version 2>&1)",
  "git_commit": "$(git rev-parse HEAD 2>/dev/null || echo unknown)",
  "git_branch": "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)",
  "build_type": "Release (direct cc -O3)",
  "compiler_flags": "$CFLAGS",
  "environment": { "ADAPTIPC_STATS": "${ADAPTIPC_STATS:-unset}" }
}
JSON
}

# ---------------------------------------------------------------- build ---
do_build() {
    echo "── Building project ──────────────────────────"
    mkdir -p "$BUILD"
    for s_ in $SRC; do
        "$CC" $CFLAGS -c "$s_" -o "$BUILD/$(basename "${s_%.c}").o" \
            2>>"$RUN/stderr_build.log" || return 1
    done
    "$CC" $CFLAGS $SRC tests/benchmark_suite.c \
        -o "$BUILD/benchmark_suite" 2>>"$RUN/stderr_build.log" || return 1
    "$CC" $CFLAGS $SRC benchmarks/routing_trace.c \
        -o "$BUILD/routing_trace" 2>>"$RUN/stderr_build.log" || return 1
    "$CC" $CFLAGS $SRC benchmarks/live_demo.c \
        -o "$BUILD/live_demo" 2>>"$RUN/stderr_build.log" || return 1
    for t in $TESTS; do
        "$CC" $CFLAGS $SRC "tests/test_$t.c" -o "$BUILD/test_$t" \
            2>>"$RUN/stderr_build.log" || return 1
    done
    return 0
}

# ------------------------------------------------------ experiment 1 ------
exp_correctness() {
    : > "$RUN/test_results.txt"
    local pass=0 fail=0
    for t in $TESTS; do
        if "$BUILD/test_$t" >>"$RUN/test_results.txt" 2>&1; then
            echo "  ✓ $t"; pass=$((pass+1))
        else
            echo "  ✗ $t"; fail=$((fail+1))
        fi
    done
    echo "tests: $pass passed, $fail failed (of $((pass+fail)))" \
        >> "$RUN/test_results.txt"
    [ "$fail" -eq 0 ]
}

# ------------------------------------------------------ experiment 2 ------
exp_transport() {
    local iters="${1:-3000}"
    for mode in uds shm adapt; do
        echo "  running $mode sweep..."
        "$BUILD/benchmark_suite" --mode "$mode" --workload sweep \
            --out "$RUN/raw/transport_${mode}.csv" \
            > "$RUN/raw/transport_${mode}.stdout" 2>&1 || return 1
    done
    return 0
}

# ------------------------------------------------------ experiment 3 ------
exp_adaptive() {
    local iters="${1:-3000}"
    "$BUILD/routing_trace" --out "$RUN/raw/routing_trace.csv" \
        --iters "$iters" >> "$RUN/stdout.log" 2>&1 || return 1
    return 0
}

# ------------------------------------------------------ experiment 4 ------
exp_hysteresis() {
    local iters="${1:-20000}"
    for pol in size_only size_hysteresis; do
        echo "  running thrash workload: $pol..."
        ADAPTIPC_POLICY="$pol" ADAPTIPC_EAGER_SHM=1 \
        "$BUILD/benchmark_suite" --mode adapt --workload thrash \
            --iters "$iters" \
            --out "$RUN/raw/hysteresis_${pol}.csv" \
            > "$RUN/raw/hysteresis_${pol}.stdout" 2>&1 || return 1
    done
    return 0
}

# ------------------------------------------------------ experiment 5 ------
exp_ewma() {
    local iters="${1:-10000}"
    for alpha in 0.05 0.1 0.2 0.3 0.5 0.8; do
        echo "  running bimodal workload: alpha=$alpha..."
        ADAPTIPC_ALPHA="$alpha" \
        "$BUILD/benchmark_suite" --mode adapt --workload bimodal \
            --iters "$iters" \
            --out "$RUN/raw/ewma_alpha_${alpha}.csv" \
            > "$RUN/raw/ewma_alpha_${alpha}.stdout" 2>&1 || return 1
    done
    return 0
}

# ------------------------------------------------------ experiment 6 ------
exp_latency() {
    local iters="${1:-10000}"
    echo "  running bimodal workload for latency breakdown..."
    ADAPTIPC_STATS=1 \
    "$BUILD/benchmark_suite" --mode adapt --workload bimodal \
        --iters "$iters" --out "$RUN/raw/latency_bimodal.csv" \
        > "$RUN/raw/latency_bimodal.stdout" 2>&1 || return 1
    # benchmark_suite writes latency_breakdown_*.txt next to --out
    return 0
}

# ------------------------------------------------------------ helpers -----
finish_run() {
    printf '%s\n' "$RUN" > "$RUNS_ROOT/LATEST"
    echo "$RUN"
}

common_prep() {
    step "Preparing environment"; write_metadata "$1" "$1"; step_ok "done"
    step "Building project"; do_build || { step_bad "build failed"; exit 1; }; step_ok "built"
}

analyze() { python3 scripts/lab_analyze.py "$RUN" >> "$RUN/stdout.log" 2>&1; }

# Print a scientific summary of a finished run by parsing that run's
# own raw result files (scripts/lab_results.py). Honors QUIET.
# show_summary <run_dir> <experiment>
show_summary() {
    local rundir="$1" exp="$2"
    if [ "$QUIET" -eq 1 ]; then return 0; fi
    echo ""
    python3 scripts/lab_results.py "$rundir" "$exp"
}

run_all() {
    banner
    new_run "full"
    write_metadata "full" "research"
    echo "  Run directory: $RUN"
    echo "──────────────────────────────────────────────"
    STEPS=7
    step "Building project"; do_build || { step_bad "build failed"; exit 1; }; step_ok "built"
    step "Running correctness tests"
    if exp_correctness; then step_ok "all passed"
    else step_bad "tests failed"; exit 1; fi
    step "Running transport comparison (sweep)"; exp_transport && step_ok "done" || { step_bad "failed"; exit 1; }
    step "Running adaptive routing trace"; exp_adaptive && step_ok "done" || { step_bad "failed"; exit 1; }
    step "Running hysteresis stability (thrash)"; exp_hysteresis && step_ok "done" || { step_bad "failed"; exit 1; }
    step "Running EWMA alpha sensitivity"; exp_ewma && step_ok "done" || { step_bad "failed"; exit 1; }
    step "Analyzing, plotting, generating report"
    analyze && step_ok "done" || { step_bad "analysis failed"; exit 1; }
    finish_run >/dev/null
    echo "──────────────────────────────────────────────"
    echo "  RAW:     $RUN/raw/"
    echo "  GRAPHS:  $RUN/plots/"
    echo "  TABLES:  $RUN/tables/"
    echo "  REPORT:  $RUN/report/report.html"
}

presentation() {
    banner
    new_run "presentation"
    write_metadata "presentation" "demo"
    echo "  Run directory: $RUN"
    echo "──────────────────────────────────────────────"
    STEPS=8
    step "Environment"; step_ok "$(uname -s) $(uname -m), $(git rev-parse --short HEAD 2>/dev/null)"
    step "Build"; do_build || { step_bad "build failed"; exit 1; }; step_ok "built"
    step "Tests"; exp_correctness && step_ok "all passed" || { step_bad "failed"; exit 1; }
    step "Experiment: transport (reduced sweep)"; exp_transport >/dev/null 2>&1 && step_ok "UDS ✓ SHM ✓ AdaptIPC ✓" || { step_bad "failed"; exit 1; }
    step "Raw data saved"; step_ok "$RUN/raw/"
    step "Generating graphs"; analyze && step_ok "plots/" || { step_bad "failed"; exit 1; }
    step "Routing trace + tables"; exp_adaptive && analyze && step_ok "done" || { step_bad "failed"; exit 1; }
    step "Report"; finish_run >/dev/null; step_ok "$RUN/report/report.html"
    echo "──────────────────────────────────────────────"
    echo "  Open: $RUN/report/report.html"
}

live() {
    banner
    echo "  Live Adaptive Router (real implementation)"
    new_run "live"; write_metadata "live" "demo"
    mkdir -p "$BUILD"
    do_build || { echo "  build failed"; exit 1; }
    echo "──────────────────────────────────────────────"
    "$BUILD/live_demo" --phase-msgs "${LIVE_MSGS:-300}" --snap-every "${LIVE_SNAP:-25}" |
    while IFS= read -r line; do
        case "$line" in
            SNAPSHOT*)
                eval "$(echo "$line" | sed 's/SNAPSHOT //; s/ /\n/g')" 2>/dev/null
                printf "╔══════════════════════════════════════╗\n"
                printf "║ Message size : %8s B             ║\n" "$size"
                printf "║ EWMA         : %8s B             ║\n" "$ewma"
                printf "║ Low (tau_lo) : %8s B             ║\n" 1024
                printf "║ High(tau_hi) : %8s B             ║\n" 4096
                printf "║                                      ║\n"
                printf "║ Transport    : %20s ║\n" "$route"
                printf "║ Messages     : %8s                ║\n" "$msgs"
                printf "║ Switches     : %8s                ║\n" "$switches"
                printf "╚══════════════════════════════════════╝\n"
                sleep 0.15
                ;;
            DONE*) echo "  $line" ;;
        esac
    done
}

menu() {
    while true; do
        clear 2>/dev/null || true
        echo "╔══════════════════════════════════════╗"
        echo "║        AdaptIPC Experiment Lab       ║"
        echo "╠══════════════════════════════════════╣"
        echo "║ 1. Build & Test                      ║"
        echo "║ 2. Transport Comparison              ║"
        echo "║ 3. Adaptive Routing                  ║"
        echo "║ 4. Hysteresis Stability              ║"
        echo "║ 5. EWMA Sensitivity                  ║"
        echo "║ 6. Latency Breakdown                 ║"
        echo "║ 7. Run All Experiments               ║"
        echo "║ 8. Generate Graphs (latest run)      ║"
        echo "║ 9. Generate Tables (latest run)      ║"
        echo "║ 10. Generate Report (latest run)     ║"
        echo "║ 11. Live Demo                        ║"
        echo "║ 0. Exit                              ║"
        echo "╚══════════════════════════════════════╝"
        printf "Select: "
        read -r choice
        case "$choice" in
            1)  new_run correctness; write_metadata correctness cli
                do_build && exp_correctness && echo "  all tests passed" \
                    || echo "  FAILED (see $RUN)"
                finish_run >/dev/null
                show_summary "$RUN" correctness
                echo "  Run: $RUN"; read -r x ;;
            2)  new_run transport; write_metadata transport cli
                do_build && exp_transport && analyze \
                    && echo "  done: $RUN" || echo "  FAILED"
                finish_run >/dev/null
                show_summary "$RUN" transport
                read -r x ;;
            3)  new_run adaptive; write_metadata adaptive cli
                do_build && exp_adaptive && analyze \
                    && echo "  done: $RUN" || echo "  FAILED"
                finish_run >/dev/null
                show_summary "$RUN" adaptive
                read -r x ;;
            4)  new_run hysteresis; write_metadata hysteresis cli
                do_build && exp_hysteresis && analyze \
                    && echo "  done: $RUN" || echo "  FAILED"
                finish_run >/dev/null
                show_summary "$RUN" hysteresis
                read -r x ;;
            5)  new_run ewma; write_metadata ewma cli
                do_build && exp_ewma && analyze \
                    && echo "  done: $RUN" || echo "  FAILED"
                finish_run >/dev/null
                show_summary "$RUN" ewma
                read -r x ;;
            6)  new_run latency; write_metadata latency cli
                do_build && exp_latency && analyze \
                    && echo "  done: $RUN" || echo "  FAILED"
                finish_run >/dev/null
                show_summary "$RUN" latency
                read -r x ;;
            7)  run_all; read -r x ;;
            8|9|10) local r; r=$(cat "$RUNS_ROOT/LATEST" 2>/dev/null || true)
                [ -z "$r" ] && { echo "  no runs yet"; sleep 2; continue; }
                RUN="$r"; analyze && echo "  updated: $r" \
                    || echo "  analysis failed"; sleep 2 ;;
            11) live; read -r x ;;
            0)  exit 0 ;;
        esac
    done
}

graphs_cmd() { local r; r="${1:-$(cat "$RUNS_ROOT/LATEST" 2>/dev/null)}"; RUN="$r" python3 scripts/lab_analyze.py "$r"; }
tables_cmd() { graphs_cmd "$@"; }
report_cmd() { graphs_cmd "$@"; }

# --------------------------------------------------------------- main -----
# Scan "$@" for display flags first (must run in the current shell so
# QUIET persists), then strip them from the positional arguments.
for _a in "$@"; do
    case "$_a" in
        -quiet|--quiet) QUIET=1 ;;
        -show-results|--show-results) QUIET=0 ;;
    esac
done
_FILTERED=""
for _a in "$@"; do
    case "$_a" in
        -quiet|--quiet|-show-results|--show-results) ;;
        *) _FILTERED="$_FILTERED $_a" ;;
    esac
done
set -- $_FILTERED
case "${1:---menu}" in
    -h|--help|help)
        sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -p|-presentation|--presentation|presentation) presentation ;;
    -l|-live|--live|live) live ;;
    -r|-runall|--runall|runall|all) run_all ;;
    -g|-graphs|--graphs) shift; graphs_cmd "${1:-}" ;;
    -t|-tables|--tables) shift; tables_cmd "${1:-}" ;;
    -report|--report|-report) shift; report_cmd "${1:-}" ;;
    -e|-experiment|--experiment)
        [ $# -lt 2 ] && { echo "missing experiment name"; exit 2; }
        exp="$2"
        case "$exp" in
            correctness) new_run correctness; write_metadata correctness cli
                do_build || { echo "build failed"; exit 1; }
                if exp_correctness; then echo "ALL TESTS PASSED"
                else echo "TESTS FAILED"; exit 1; fi
                show_summary "$RUN" correctness || exit 3
                exit 0 ;;
            transport) new_run transport; write_metadata transport cli
                do_build && exp_transport && analyze || exit 1
                echo "OK: $RUN"
                show_summary "$RUN" transport || exit 3 ;;
            adaptive) new_run adaptive; write_metadata adaptive cli
                do_build && exp_adaptive && analyze || exit 1
                echo "OK: $RUN"
                show_summary "$RUN" adaptive || exit 3 ;;
            hysteresis) new_run hysteresis; write_metadata hysteresis cli
                do_build && exp_hysteresis && analyze || exit 1
                echo "OK: $RUN"
                show_summary "$RUN" hysteresis || exit 3 ;;
            ewma) new_run ewma; write_metadata ewma cli
                do_build && exp_ewma && analyze || exit 1
                echo "OK: $RUN"
                show_summary "$RUN" ewma || exit 3 ;;
            latency) new_run latency; write_metadata latency cli
                do_build && exp_latency && analyze || exit 1
                echo "OK: $RUN"
                show_summary "$RUN" latency || exit 3 ;;
            all) run_all ;;
            *) echo "unknown experiment: $exp"; exit 2 ;;
        esac ;;
    --menu|menu|"") menu ;;
    *) echo "unknown option: $1 (try --help)"; exit 2 ;;
esac
