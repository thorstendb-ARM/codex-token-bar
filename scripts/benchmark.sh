#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="$project_dir"
if [[ "${1:-}" == "--help" ]]; then
    printf 'Usage: %s [--source CHECKOUT] [SESSIONS [EVENTS_PER_SESSION]]\n' "$0"
    printf 'Defaults: 2000 sessions, 100 events each; only synthetic temporary data is used.\n'
    exit 0
fi
if [[ "${1:-}" == "--source" ]]; then
    if [[ -z "${2:-}" ]]; then
        printf 'Missing checkout path after --source.\n' >&2
        exit 2
    fi
    source_dir="$(cd "$2" && pwd)"
    shift 2
fi

swift build --package-path "$source_dir" -c release
binary_dir="$(swift build --package-path "$source_dir" -c release --show-bin-path)"
if [[ -f "$binary_dir/TokenBarCore.o" ]]; then
    core_objects=("$binary_dir/TokenBarCore.o")
else
    shopt -s nullglob
    core_objects=("$binary_dir"/TokenBarCore.build/*.o)
fi
if [[ ${#core_objects[@]} -eq 0 ]]; then
    printf 'TokenBarCore object files were not found in %s.\n' "$binary_dir" >&2
    exit 1
fi

benchmark_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-token-bar-benchmark.XXXXXX")"
benchmark_binary="$benchmark_dir/ScanBenchmark"
benchmark_resources="$benchmark_dir/CodexTokenBar_TokenBarCore.bundle"
trap 'rm -f "$benchmark_binary" "$benchmark_resources"; rmdir "$benchmark_dir"' EXIT
ln -s "$binary_dir/CodexTokenBar_TokenBarCore.bundle" "$benchmark_resources"
swiftc -O -parse-as-library -module-name ScanBenchmark \
    -I "$binary_dir" -I "$binary_dir/Modules" \
    "$project_dir/Benchmarks/ScanBenchmark.swift" \
    "$source_dir/Sources/CodexTokenBar/AppConfiguration.swift" \
    "$source_dir/Sources/CodexTokenBar/UsageReport.swift" \
    "${core_objects[@]}" -o "$benchmark_binary"
"$benchmark_binary" "$@"
