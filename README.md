# Codex Token Bar

A small native macOS menu-bar app for local Codex token usage and estimated USD cost.
No Tokenpet, API key, server, subscription or network connection required.

## Use

Download the Apple Silicon (`arm64`) ZIP from
[Releases](https://github.com/thorstendb-ARM/codex-token-bar/releases).
Extract it, move `Codex Token Bar.app` to
`~/Applications` and open it. Requires macOS 13 or later. The app is ad-hoc signed,
not notarized by Apple.

The menu bar shows, for example:

```text
C: 12.3M / $4.56
```

Click to select **Current** (manual measurement), **Day** (today), **Week** (this
week, Monday onwards), **Month** (this calendar month) or **Overall**. The dropdown
shows all five totals, with Current first; the menu bar keeps the compact
**C/D/W/M/O** labels. Check **Tokens** and
**Dollar** independently to select what is displayed; at least one stays enabled.
The app remembers these choices. It refreshes every 30 seconds while running.
There is no Dock icon and no automatic login item.

**Current zurücksetzen** starts a new manual measurement at zero and selects
Current in the menu bar. Its start time is shown in the menu and tooltip. The first
measurement starts when the app first opens with this feature; it survives app
restarts, cache rebuilds and calendar boundaries until you reset it again. Resetting
Current leaves Day, Week, Month and Overall unchanged. Usage and estimated cost are
assigned by the timestamp of each recorded token event; a request that spans the
reset cannot be split into before/after portions.

Periods use the Mac's local time zone. `K`, `M`, `B` and `T` mean thousand, million,
billion and trillion tokens. Hover for the exact token count, freshness and warnings.

## Build and test

Requires macOS 13 or later and Apple's Swift 6 command-line tools; no third-party dependencies.

```sh
bash scripts/test.sh
bash scripts/build-app.sh
open "dist/Codex Token Bar.app"
```

The build is signed locally (ad-hoc), not notarized for public distribution. The
resulting `.app` can be moved to `~/Applications` manually.
The test wrapper also locates Swift Testing in Command Line Tools-only installations.

### CI builds

[macOS Release Build](https://github.com/thorstendb-ARM/codex-token-bar/actions/workflows/release-build.yml)
runs tests and builds the release app for Apple Silicon (`arm64`)
on pushes to `main`, version tags (`v*`), pull requests and manual runs.
Download the artifact from a successful workflow run and extract the app ZIP.
Artifacts are retained for 14 days. These builds are ad-hoc signed, not notarized;
the workflow does not automatically publish GitHub Releases.

For a machine-readable check without opening the menu-bar app:

```sh
"dist/Codex Token Bar.app/Contents/MacOS/CodexTokenBar" --report
```

Optional arguments: `--codex-home PATH` (repeatable), `--cache PATH`, `--help`.
Otherwise the source is `CODEX_HOME` or `~/.codex`. Finder-launched applications
usually do not inherit shell environment variables.

The report includes `currentStartedAt` and a `current` total using the app's saved
measurement start. Before the first app launch, Current is zero and the start is
omitted. Running `--report` does not start or reset a measurement.

## Counting and privacy

- Reads `sessions/**/*.jsonl` and `archived_sessions/**/*.jsonl` locally, read-only.
- Uses timestamped token-count events, not thread modification dates. Cached input
  is part of input; reasoning is part of output. Neither is added twice.
- Normalizes cumulative counters and ignores repeated snapshots. Separate agent
  sessions contribute their own usage; inherited fork history must not be billed again.
- Maintains an incremental cache at `~/Library/Caches/CodexTokenBar/index.json`.
  It stores usage/model/time and file metadata, not messages or credentials.
- The first scan of a large history takes longer. Subsequent scans read appended data.
  An unchanged cache is not rewritten. Errors remain visible and are retried.
  Individual JSONL records are bounded at 16 MiB; skipped records are reported.
  Codex's files are never modified.
- Overall means the history available locally. Deleted or never-recorded sessions,
  other computers, ChatGPT usage and unreported backend usage cannot be reconstructed.

## Estimated cost

Dollar values are **API-equivalent estimates, not an invoice**. The bundled
[`prices.json`](Sources/TokenBarCore/Resources/prices.json) records standard USD rates
from the [official OpenAI pricing page](https://developers.openai.com/api/docs/pricing),
verified on 2026-09-24. Rates are applied to the whole available history; historic
price changes are not reconstructed. Update the file and rebuild when prices change.

The estimate separates ordinary input, cached input, cache writes and output. Where
applicable, the long-context tier uses the input count of the recorded usage event.
Missing per-request detail in a log can reduce cost accuracy. Service-tier/fast-mode
surcharges, regional uplifts, tool fees, subscriptions, taxes and negotiated proxy
or enterprise rates are not included. Unknown models are shown as `+ ?`, never as
free. Token totals still include them.

## Layout

- `Sources/TokenBarCore`: incremental index, period aggregation and price calculation.
- `Sources/CodexTokenBar`: AppKit menu and optional JSON-report entry point.
- `Tests/TokenBarCoreTests`: synthetic fixtures; no private session data in the project.
- `Packaging`, `scripts`: reproducible local `.app` bundle.
