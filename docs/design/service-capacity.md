# Native service capacity

The production `Service.Make` and reducer hold 1/10/100/1000 scoped fake
sessions under the native Eio POSIX clock. The checked workflow permits 1000
Doing issues and polls every 10 ms. The fixture shares A's frozen tracker
authority; issues and replies are allocated before the memory baseline.

`Scenario.run` captures the supplied clock and a synchronous resource observer.
Manual simulations own their mock clocks; native runs use the host clocks.
Actual acquisition supplies entry timing. Owner entry can precede acquisition;
the plateau joins both independent issue/run maps. Completion requires prior
resource release. No open startup poll crosses the plateau into warmup.

## Run and evidence

From `ocaml/`, after `just build`:

```sh
python3 tools/capacity_check.py \
  --binary "$PWD/_build/default/test/capacity_main.exe" \
  --sessions 1000 --out "$PWD/_build/new-capacity-evidence"
```

The output directory must be new. Four acknowledged JSON checkpoints hold the
producer at baseline, all acquired/owner-started workers, after five warmup and
100 measured cycles, and after successful joined shutdown. The parent samples
its owned PID, adds RSS and retains bounded stdout/stderr plus a manifest.
The 60 s watchdog, output/event/sample budgets and 128 MiB sampled-RSS ceiling
fail explicitly. The ceiling has over threefold headroom against the largest
local and hosted samples below.

The launcher retains the native executable's PID and forks a quiet group guard.
The guard closes inherited protocol pipes before exec proceeds. Final group
KILL precedes the sole producer reap, including normal completion. This follows
the existing native sentinel pattern. Darwin excludes zombies from group
signals and may return EPERM for a zombie-only group; arbitrary EPERM is never
treated as successful cleanup. [Apple's signal implementation](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/kern/kern_sig.c)
supports this boundary, which a native owned-process probe reproduced.

## Local macOS gate measurements

One fresh process per row; OCaml 5.5.0, arm64, macOS 26.5.1. This is initial
capacity evidence, not an accepted latency regression baseline.

| Held sessions | All acquired, ms | Reducer step p95, ms | Full poll p95, ms | Plateau RSS, MiB | RSS delta/session, B |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 0.40 | 0.018 | 0.91 | 17.11 | 81920 |
| 10 | 0.47 | 0.035 | 1.30 | 17.20 | 19661 |
| 100 | 2.39 | 0.255 | 1.83 | 18.17 | 11796 |
| 1000 | 184.97 | 1.876 | 8.12 | 29.13 | 12354 |

At 1000, baseline RSS was 17.34 MiB and steady RSS 33.70 MiB. Managed live-heap
and stack/cache deltas were 5586 and 3879 B/session. All 1000 acquisitions,
owner starts, releases and owner completions matched; 1427 registered handles
retired, pending calls were zero, and all 100 measured cycles completed.
Receipts from the repository root:
`ocaml/_build/capacity-cSwJrp/{1,10,100,1000}/manifest.json`.
The earlier local 1000-session poll p95 samples were 5.80 and 25.44 ms;
this spread reinforces the need for matched repeated runs before regression budgets.

Native controls first exposed a wrong macOS ps path and case-sensitive fixture
reply selection. The finite event budget rejected the empty-candidate loop.
After correcting normalized state keys, a native run reproduced the invalid
entry-before-acquisition assumption; the corrected ten-session run passed.
Receipts: `_build/capacity-entry-order-red`, `capacity-order-red`,
`capacity-start-order-red` and `capacity-10-first`.

## Hosted capacity evidence

At implementation head `f4cb776`, all four workloads pass on Linux x86_64
and macOS arm64 in both [PR](https://github.com/ethan-wickstrom/symphony/actions/runs/37107154522)
and [push](https://github.com/ethan-wickstrom/symphony/actions/runs/37107130651)
workflows. All 16 manifests match supervisor/launcher digests and retained log
hashes, record a reaped zero-exit producer, and match lifecycle/handle counts.
Raw logs confirm 12 measurement examples/laws, 23 parent controls in both modes,
29 service examples, three service property groups and 335 source files.

The 1000-session samples use OCaml 5.5.0 on Linux 6.17/glibc 2.39 and macOS 26.6.2.
Each row is a separate hosted process, without matched runner/load controls.

| Host/event | All acquired, ms | Reducer step p95, ms | Full poll p95, ms | Plateau RSS, MiB | Maximum sampled RSS, MiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| Linux PR | 264.49 | 1.844 | 5.68 | 27.44 | 32.20 |
| Linux push | 205.04 | 1.517 | 4.65 | 27.58 | 32.34 |
| macOS PR | 185.69 | 1.403 | 6.26 | 25.08 | 29.73 |
| macOS push | 185.15 | 3.843 | 12.21 | 25.06 | 29.70 |

The `custody-*` artifacts retain each workload's manifest/stdout/stderr.
Independent local audit: `_build/capacity-ci-audit.json` and
`_build/capacity-ci-f4cb776-{pr,push}.log` from the repository root.

## Measurement laws and limits

Reducer samples cover actual step/projection cost. Full-cycle samples span
Poll_due receipt through Arm_poll observation, including fake effect scheduling
and delivery, excluding timer wait. GC/RSS/ACK pauses occur outside measured
populations. Numeric collections have explicit positive limits; overflow fails.
Exact nearest-rank p50/p95/p99/max and counts remain separate for startup,
steady reducer steps and full cycles. Seven examples and five independent
500-case laws check rank thresholds, permutations, bounds and GC arithmetic.

[OCaml 5.5.0 `Gc.stat`](https://github.com/ocaml/ocaml/blob/5.5.0/stdlib/gc.mli)
performs full major collection and supplies whole-program lifetime allocation
and live heap/stack/cache words. Each floating source counter must be finite,
integral and below 2^53;
Zarith combines them before byte conversion. Checkpoint allocation counters may
not reverse. Negative endpoint differences are reported as invalid samples,
never clamped. RSS uses Linux smaps_rollup or macOS `/bin/ps`, with 1024-byte
kernel units; missing or malformed measurements fail. Manifests record the
binary, supervisor and launcher digests, platform and effective GC settings.

The numbers include fake ports, bounded test history, service/core and runtime
overhead. They establish no Codex process, native workspace or infinite-run
capacity. Stack caches and allocator memory may remain after join. RSS is
sampled at four checkpoints; its ceiling is not a continuous peak-memory bound.
Five alternating accepted/candidate processes on one runner remain required
before enforcing relative latency regressions. Static release qualification,
the real closed runner, operator API and portable harness remain separate gates.
