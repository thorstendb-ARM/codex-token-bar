#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
test_flags=(--disable-xctest --enable-swift-testing)

# Command Line Tools ship Swift Testing without adding its search paths.
# A full Xcode installation supplies these paths automatically.
if [[ "$developer_dir" == */CommandLineTools ]]; then
    framework_dir="$developer_dir/Library/Developer/Frameworks"
    plugin_dir="$developer_dir/usr/lib/swift/host/plugins/testing"
    runtime_dir="$developer_dir/Library/Developer/usr/lib"
    if [[ -d "$framework_dir/Testing.framework" ]]; then
        test_flags+=(-Xswiftc -F -Xswiftc "$framework_dir"
                    -Xlinker -F -Xlinker "$framework_dir"
                    -Xlinker -rpath -Xlinker "$framework_dir")
    fi
    if [[ -d "$plugin_dir" ]]; then
        test_flags+=(-Xswiftc -plugin-path -Xswiftc "$plugin_dir")
    fi
    if [[ -f "$runtime_dir/lib_TestingInterop.dylib" ]]; then
        test_flags+=(-Xlinker -rpath -Xlinker "$runtime_dir")
    fi
fi

exec swift test --package-path "$project_dir" "${test_flags[@]}" "$@"
