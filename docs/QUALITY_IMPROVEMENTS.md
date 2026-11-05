# Quality improvement plan

This milestone turns the terminal-quality review into repeatable checks and inspectable evidence.
It builds on the prompt-history and clipboard fixes without assigning comparative product scores.

| Priority | Deliverable | Acceptance |
| --- | --- | --- |
| P0 | Daily-input regression protection | A second paste cannot queue another confirmation or paste through a different dialog. Don't ask again persists only after Paste, applies after reload, and can be restored in Settings. Unicode, enhanced-keyboard and multiline cancellation PTY tests remain green. |
| P0 | Public compatibility matrix | Each capability links to executable evidence and distinguishes curated automation, optional external-tool checks, manual qualification and unsupported behavior. |
| P0 | Reproducible Native/WASM benchmark | Both engines consume identical synthetic bytes, verify identical final state, retain raw samples and report p50/p95/p99 with source/workload/artifact identifiers. |
| P1 | Reproducible approved-agent demo | One request passes through the real companion and native approval UI. Dispatch and an independently observed marker are reported separately; denial, uncertain outcomes and human reclaim are explicit. |

## Implementation sequence

1. Add the paste dialog guard and regression tests.
2. Publish [the compatibility matrix](COMPATIBILITY.md), with links to the existing CI suites and manual gaps.
3. Add the release-mode benchmark, a shared workload manifest, result validation and a small CI smoke run.
4. Add a companion-driven demo and test its response handling and real native approval path.
5. Run the canonical verification gate, benchmark smoke and measured baseline, then build/smoke the app and commit.

## Evidence rules

- A passing curated test establishes the behavior it exercises, not full VT conformance or compatibility with every release of a TUI.
- Benchmarks keep parser/grid/reflow timings separate from PTY, rendering, input-to-photon latency and energy measurements.
- Native/WASM state disagreement fails the benchmark before publishing a result.
- Program identity/status and shell completion remain untrusted reports. An accepted receipt means queued input; the demo separately checks one expected filesystem effect.
- The demo never retries an ambiguous dispatch and never reclaims another actor's input lease automatically.
- Timing results carry their source/workload fingerprints and raw observations. They are not CI speed thresholds or competitor rankings.

## Subsequent qualification

Measure physical key-to-paint latency and idle/hidden-pane CPU, energy and memory on the same Mac with pinned app versions,
fonts, dimensions, scrollback and workload bytes. Publish repeated observations and configuration with each comparison.
Exercise physical IME and VoiceOver, sleep/wake, Vim/Neovim, tmux and SSH independently of protocol fixtures.
Additional agent adapters should use the demonstrated request/approval contract before optional policy/evidence integrations are added.

The existing ax-trust and AX Code products do not automatically supply shell-command policy or execution attestation.
Those integrations need an explicit executor/decision/correlation contract and independent acceptance tests.

## Implemented and validated

This milestone implements all four deliverables above. `scripts/verify.sh` passes, including 236 Rust tests,
639 Web unit tests, 20 local browser tests, the Native/WASM benchmark smoke, companion-demo checks, Clippy,
ABI/provenance, shell, release and installer checks. The final Swift suite executes 270 tests with one skip
and zero failures. Local Firefox retains the documented startup exception; its browser coverage remains required in CI.
The [30-sample baseline](../benchmarks/baseline-macos-arm64.json) preserves the exact measured source,
workload and harness fingerprints. Physical IME, VoiceOver, UI latency and competitor benchmarks remain the
separate qualification work described above.
