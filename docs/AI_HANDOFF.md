# AdaptIPC — Full Engineering Handoff Document

**For:** any AI/engineer taking over the project (e.g., for the paper-revision task)
**Repository:** https://github.com/miskinabhijeet2025-ai/adaptipc
**State at handoff:** branch `main`, commit `ebc3bae`, working tree clean, everything pushed.
**Live website:** https://miskinabhijeet2025-ai.github.io/adaptipc/ (verified working)
**Local website:** `./scripts/start_website.sh` → http://localhost:8123/index.html
**Baseline tag:** `baseline-v1-size-only` (the original validated paper implementation)

---

## 1. WHAT THIS PROJECT IS

AdaptIPC is a C11 middleware that routes each IPC message individually
between two transports: a lock-free SPSC shared-memory ring buffer
(SHM, good for bulk) and an AF_UNIX datagram socket (UDS, good for
small control messages). Routing decisions come from a policy pipeline:

```
adapt_send()
  → Context Collector   (payload, EWMA arrival, ring occupancy,
                          consumer drain rate, consumer activity)
  → Cost Estimator      (cost_T(S) = fixed + slope·S per transport,
                          queue wait = occ/max(D, 50MB/s floor),
                          setup/switching/health/latency penalties)
  → Adaptive Policy     (Score(T) comparison; switch only if
                          Score(new) + H < Score(current))
  → SHM or UDS
```

Tau thresholds: τ_low = 1024 B, τ_high = 4096 B (EWMA of payload size).
Flow control: HW=80% / LW=20% watermark, futex park/wake (Linux) or
process-shared condvar (macOS).

## 2. COMPLETE HISTORY OF WORK DONE (chronological)

### Phase 0 — v1 baseline (paper implementation, tag `baseline-v1-size-only`)
- `src/shm_ringbuffer.c` — lock-free SPSC ring over POSIX shm.
- `src/uds_fallback.c` — AF_UNIX SOCK_DGRAM transport.
- `src/adapt_ipc.c` — EWMA classifier + hysteresis + escalation.
- `tests/benchmark_suite.c` — fork-based sweep/bimodal/thrash benchmarks.
- Paper's historical validated results: `benchmarks/summary*.txt`,
  `benchmarks/results_*.csv`, `experiments/raw/` (v2 campaigns).

### Phase 1 — Flow control + lazy negotiation (commit ~`6301ab4`)
- Ring gained HW/LW watermark flow control (HW 80%, LW 20%):
  `shm_ring_wait_writable()`, `shm_ring_push_scatter_blocking()`,
  park/wake via futex (Linux) or process-shared condvar (Apple),
  lost-wakeup-safe protocol, park counter `shm_ring_park_count()`.
- Lazy SHM negotiation: `adapt_init()` no longer maps SHM; first
  EWMA-classified SHM send triggers `SHM_SETUP_REQ/ACK` over UDS;
  `shm_ring_attach()` (no header-init wait) for the consumer.
- `macOS shm_open(O_TRUNC)` quirk: returns EINVAL on existing objects —
  ring now never uses O_TRUNC; producer re-inits cursors instead.
- Tests added: `test_flowcontrol.c`, `test_lazy_negotiation.c`,
  `test_backpressure_latency.c` (backlog gate: 14 frames / 57 KB).

### Phase 2 — Context-aware v2 (commits `fbb3c3c`, `2e7dccc`, `2a3b556`)
- **`src/runtime_context.c`** — per-send producer-side context: EWMA
  arrival rate, EWMA drain rate (positive-drain samples only), EWMA
  occupancy, last-drain timestamp, conservative 50 MB/s floor + 5 ms
  staleness window for queue-wait estimates.
- **`src/cost_model.c`** — decision engine in microseconds:
  `Score(T) = transport_cost(T,S) + queue_cost + setup_cost
  + switching_cost + health_penalty + latency_penalty`;
  switch only if `Score(new) + margin < Score(current)` (H = 5 µs);
  online two-class linear calibration per transport; learned crossover
  S* (clamped 512 B–1 MB, EWMA rate-limited); decision-log ring (512
  entries) dumped as CSV via `ADAPTIPC_DECISION_LOG`.
- **`src/transport_health.c`** — debounced state machine:
  UNAVAILABLE/HEALTHY/DEGRADED/BLOCKED/RECOVERING; occupancy ≥95% →
  BLOCKED, ≥80% or drain deficit → DEGRADED, ≤20% streak → RECOVERING;
  penalties 0/100/1000/25 µs; debounce = 8 samples.
- **Policy modes** in `adapt_config_t.policy`:
  `ADAPT_POLICY_DEFAULT`(=size_hysteresis)/SIZE_ONLY/SIZE_HYSTERESIS/
  QUEUE_AWARE/COST_AWARE/FULL_ADAPTIVE. QoS:
  `ADAPT_QOS_BALANCED/LATENCY/THROUGHPUT` + `latency_budget_us`.
  Env overrides: `ADAPTIPC_POLICY`, `ADAPTIPC_QOS`,
  `ADAPTIPC_LATENCY_BUDGET_US`, `ADAPTIPC_SWITCH_COST_US`,
  `ADAPTIPC_MARGIN_US`, `ADAPTIPC_STATS`, `ADAPTIPC_DECISION_LOG`,
  `ADAPTIPC_EAGER_SHM`, `ADAPTIPC_ALPHA`.
- **v2 experiment matrix:** `benchmarks/adaptive_ablation.c` —
  payload sweep / queue pressure / burst / adversarial switching /
  degradation+recovery / setup cost / QoS, across uds/shm baselines +
  5 policies; writes `experiments/raw/*.csv`.
- **v2.1 hardening:** `benchmarks/hardening_suite.c` — occupancy
  validation (instrumentation == cursor math), estimator noise (ε = 0
  steady state), margin sweep, queue-prediction accuracy (honest
  10–1000× under-prediction on stalled consumer), adversarial δ-sweep
  with mechanical switch classification (genuine/recovery/noise_flap;
  false_switch_rate 0.00 for hysteresis policies), stall timeline
  (escape <1 ms, recovery 2.7 ms), crossover learning (exact for 6
  ground truths), lazy-vs-eager setup.
- Key measured results: SHM ring 12,350 MB/s; UDS 300 MB/s; policies
  9.4–9.7 GB/s; 1M-message stress zero loss FIFO; 10/10 tests; ASan/
  LSan/TSan clean.
- **Known honest limitations:** queue prediction under-predicts 10–1000×
  when the consumer stops draining (reactive model); UDS SOCK_DGRAM
  drops datagrams silently on rx-overflow (>64 KB payloads excluded
  from pure-UDS sweeps); cost model linear.

### Phase 3 — Experiment Lab (commit `13d6c04`)
- **`demo/adaptipc_lab.sh`** — menu CLI + one-command experiments
  (correctness/transport/adaptive/hysteresis/ewma/latency/all),
  presentation mode, live mode; every run in a unique
  `experiments/runs/<ts>_<label>/` dir with `run_metadata.json`,
  raw/, processed/, plots/, tables/, report/.
- **`benchmarks/routing_trace.c`** — real per-message trace:
  `seq,payload_bytes,ewma_bytes,route,switched` (uses eager SHM;
  sequential send/recv can't complete the async lazy handshake).
- **`benchmarks/live_demo.c`** — live 3-phase demo printing snapshot
  lines (size/ewma/route/switches) rendered as a terminal dashboard.
- **`scripts/lab_analyze.py`** — raw CSV → processed → plots → tables →
  `report/report.html`.

### Phase 4 — Visual showcase + website (commits `2d75888`, `7ced31f`, `4bcf804`, `1481683`, `30f03fd`, `ebc3bae`)
- **`showcase/`** — `run_demo.sh` (one command: build → run
  `benchmarks/decision_demo.c` → decision log CSV → JSON → serve on
  :8123), `dashboard/` (HTML/JS/CSS visualizing 512 real
  full_adaptive decisions with cost bars, reasons, timeline), `outputs/`
  (committed real `decisions.csv`), `scripts/generate_figures.py` +
  `generate_diagrams.py` (fig01–fig10 from run CSVs), `serve_dashboard.py`.
- **`assets/`** — architecture/decision-pipeline/before-vs-adaptive
  conceptual diagrams; 8 figures from real measurement CSVs; 2 real
  browser screenshots of the dashboard.
- **`website/`** — GitHub Pages static site (dark/light, responsive,
  prefers-reduced-motion): hero with animated routing paths,
  hover-annotated architecture, **interactive policy simulator**
  (browser model of the decision rule, clearly labeled), Chart.js
  charts from `website/data/*.json` (exported from real CSVs by
  `scripts/export_web_data.py`), 512-decision timeline, health state
  machine, cost breakdown, experiment explorer, paper section,
  reproducibility section, demo.html replay page.
- **`.github/workflows/pages.yml`** — deploys `website/` to GitHub
  Pages. Pages was ENABLED via API (`build_type=workflow`) after the
  first run failed with 404 (site not enabled); second run succeeded.
- **README.md** — hero redesign: before-vs-adaptive visual, badges,
  architecture image, decision pipeline, key-results table (measured),
  figure gallery with per-figure provenance, repo navigation table,
  website/demo links (Pages URL, never localhost).
- **`experiments/README.md`** — experiment index. **`docs/demo.md`**,
  **`docs/EXPERIMENT_GUIDE.md`**, **`docs/PROFESSOR_DEMO.md`** (8–10 min
  script).

### Phase 5 — Lab CLI real-number summaries (commit `ebc3bae`) — LATEST
- **`scripts/lab_results.py`** — after an experiment finishes, parses
  THAT run's own raw files and prints a scientific summary:
  - transport: median latency per payload size per transport
    (UDS/SHM/AdaptIPC), aggregate p50 latency + throughput per mode,
    sample counts, units (µs, MB/s).
  - adaptive: route distribution (UDS/SHM counts + %), payload classes
    per route, EWMA range, route transitions, switch rate per 1000.
  - hysteresis: switches per policy per 1000 messages, latency p50.
  - ewma: switches + p50/p99 per alpha value.
  - latency: message count, p50/p99, producer counter breakdown.
  - correctness: per-test ✓/✗ + summary line.
  - Provenance block: run id, git commit, host, platform, compiler,
    timestamp, run dir. Artifact checklist (✓/✗ per expected file).
  - Validation: fails (exit 3) on missing files, zero-row CSVs,
    unparseable numbers; warns on NaN/Inf. `--quiet` suppresses.
- **`demo/adaptipc_lab.sh`** — after `-experiment <name>`, automatically
  calls `show_summary "$RUN" <name>`; trailing `-quiet`/`-show-results`
  flags parsed in the main shell (subshell version lost the QUIET
  global — fixed by inlining).

## 3. KEY FILES MAP

| Purpose | File |
|---|---|
| Router core | `src/adapt_ipc.c`, `include/adapt_ipc.h` |
| Policy/cost engine | `src/cost_model.c`, `include/cost_model.h` |
| Context estimator | `src/runtime_context.c` |
| Transport health | `src/transport_health.c` |
| SHM ring (flow control) | `src/shm_ringbuffer.c` |
| UDS transport | `src/uds_fallback.c` |
| Experiment lab CLI | `demo/adaptipc_lab.sh` |
| Run summarizer | `scripts/lab_results.py` |
| Run analysis/plots | `scripts/lab_analyze.py` |
| Paper-figure generators | `showcase/scripts/generate_figures.py`, `scripts/generate_showcase_figures.py` |
| Website data export | `scripts/export_web_data.py` |
| Benchmark suite | `tests/benchmark_suite.c` |
| Routing trace tool | `benchmarks/routing_trace.c` |
| Decision-log demo | `benchmarks/decision_demo.c` |
| Hardening experiments | `benchmarks/hardening_suite.c` |
| Ablation matrix | `benchmarks/adaptive_ablation.c` |
| v2 raw data | `experiments/raw/*.csv` |
| v2.1 raw data | `experiments/v2_1/raw/*.csv` |
| Paper | `paper/main_FIXED.tex`, `paper/Dynamic_IPC_Routing.pdf` |
| Fresh laptop runs | `experiments/runs/<ts>_<label>/` |

## 4. HOW TO RUN THINGS

```sh
# build + 10 test suites
./demo/adaptipc_lab.sh -experiment correctness
# experiments (each prints a real-data summary at the end)
./demo/adaptipc_lab.sh -experiment transport
./demo/adaptipc_lab.sh -experiment adaptive
./demo/adaptipc_lab.sh -experiment hysteresis
./demo/adaptipc_lab.sh -experiment ewma
./demo/adaptipc_lab.sh -experiment latency
./demo/adaptipc_lab.sh -experiment all
# with/without terminal summary
./demo/adaptipc_lab.sh -experiment transport -show-results
./demo/adaptipc_lab.sh -experiment transport -quiet
# full campaign + report
./demo/adaptipc_lab.sh -runall
./demo/adaptipc_lab.sh -presentation
# live terminal dashboard
./demo/adaptipc_lab.sh -live
# website (local) / regenerate showcase
./scripts/start_website.sh        # http://localhost:8123/index.html
./scripts/generate_showcase.sh
# regenerate website JSON from real CSVs
python3 scripts/export_web_data.py
```

## 5. BUILD ENVIRONMENT QUIRKS (IMPORTANT)

1. **No cmake on this machine** — build directly with clang:
   `clang -std=c11 -O3 -Wall -Wextra -Wpedantic -pthread -Iinclude`.
2. **zsh does not word-split** `$VAR` — use explicit args or bash -c.
3. **macOS `shm_open(O_TRUNC)`** returns EINVAL on existing objects —
   the ring never uses O_TRUNC (producer re-inits cursors instead).
   Never reintroduce O_TRUNC.
4. **Sequential send→recv cannot complete the lazy SHM handshake**
   (consumer must be inside `adapt_recv()` when the first SHM send
   fires). Tools/tests that are sequential use eager SHM
   (`ADAPTIPC_EAGER_SHM=1`) or a concurrent consumer thread. A
   sequential loop with a UDS-escape policy can deadlock on ENOBUFS
   (producer blocks, consumer drains ring-first).
5. **UDS SOCK_DGRAM drops silently on rx-overflow** — never trust
   pure-UDS bulk >64 KB payloads; adapt escalates bulk to SHM.
6. **`timeout` command doesn't exist on this macOS** — use background +
   sleep + kill, or `sample <pid>` for stuck processes.
7. Tests are standalone binaries: compile src/*.c once to .o, then link
   each test with the .o files (no cmake).

## 6. DATA PROVENANCE RULES (do not violate)

- Paper's historical validated results: `benchmarks/summary*.txt` +
  `benchmarks/results_*.csv` (median-of-3 campaigns). DO NOT overwrite.
- v2/v2.1 campaign data: `experiments/raw/`, `experiments/v2_1/raw/`.
- Fresh laptop runs: `experiments/runs/<ts>_<label>/` (gitignored).
- The terminal summary (`scripts/lab_results.py`) reads ONLY the run
  directory given to it. Never hardcode displayed values.
- Reference platform numbers (README key results): 12,350 MB/s SHM,
  ~9.4–9.7 GB/s adaptive policies, 300 MB/s UDS, 14-frame bounded
  backlog, ε(steady)=0.00 µs, false-switch rate 0.00 (hysteresis),
  1M-msg zero loss.

## 7. CURRENT BRANCH/STATE

- Branch with everything: `feature/visual-showcase-demo` == `main` ==
  `feature/professor-experiment-lab`, all at `ebc3bae`, pushed.
- One commit of interest for the paper task: the fresh CLI runs cited
  in the paper-revision prompt (transport: 19 rows/transport, 57 total;
  adaptive: 3000 decisions, 66.2% UDS / 33.8% SHM, 2 transitions;
  hysteresis fresh run: 0 switches for BOTH size_only and
  size_hysteresis — because the thrash EWMA stays inside the deadband;
  the dramatic size_only-vs-hysteresis contrast lives in
  `experiments/v2_1/raw/adversarial_delta.csv` instead: 39,796 vs 8
  switches over 200k messages).
- Live website: https://miskinabhijeet2025-ai.github.io/adaptipc/
  (Pages enabled, workflow green, 13/13 resources 200).

## 8. THINGS AN AI TAKING OVER MUST NOT DO

1. Do not modify `src/cost_model.c` decision math for presentation.
2. Do not overwrite `benchmarks/summary*.txt` or `experiments/raw/`.
3. Do not push to `main` without checking `git status` first.
4. Do not use `timeout` (missing on this macOS); use bg+sleep+kill.
5. Do not fabricate numbers for the paper — the CLI now prints real
   summaries; quote those or the committed campaign CSVs, and label
   which campaign/run produced them.
6. Do not trust `git branch --show-current` across session boundaries —
   a parallel session created `feature/visual-showcase-demo` while
   work continued on `feature/professor-experiment-lab`; always check.
7. LaTeX: `paper/main_FIXED.tex` is the current source (the older
   `paper/main.tex` also exists); the PDF is `paper/Dynamic_IPC_Routing.pdf`.
