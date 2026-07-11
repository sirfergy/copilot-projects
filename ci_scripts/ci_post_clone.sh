#!/bin/sh
set -eu

ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"

export HOMEBREW_NO_AUTO_UPDATE=1
if ! command -v xcodegen >/dev/null 2>&1; then
    brew install xcodegen
fi

xcodegen generate \
    --spec "$ROOT/ios/project.yml" \
    --project "$ROOT/ios"

if [ -n "${CI_BUILD_NUMBER:-}" ]; then
    (
        cd "$ROOT/ios"
        xcrun agvtool new-version -all "$CI_BUILD_NUMBER"
    )
fi
