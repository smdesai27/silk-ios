#!/usr/bin/env bash
#
# Both suites, locally — the same two commands .github/workflows/ci.yml runs on
# a runner. CI is the authority; this is how you get the same answer without
# waiting on a round trip, and how .githooks/pre-push catches the cheap
# failures before they leave the machine.
#
#   scripts/ci.sh              both suites (~6 min)
#   scripts/ci.sh spine        SilkCore only (a tenth of a second, no simulator)
#   scripts/ci.sh ui           SilkUITests only (~5 min)
#
# If you change what runs here, change .github/workflows/ci.yml to match.

set -euo pipefail

cd "$(dirname "$0")/.."

# DerivedData/ is gitignored — and that matters more here than it looks. This
# tree once carried 73 MB of committed object files because a build was pointed
# somewhere tracked. Keep the path inside an ignored directory.
DERIVED="DerivedData/ci"

# OS=latest for the same reason CI pins it: several iPhone 17 Pro runtimes can
# be installed at once, and a bare name= can resolve to one below the
# deployment target and fail at install rather than in a test.
DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro,OS=latest'

what="${1:-all}"
failed=()

rule() { printf '\n\033[1m── %s\033[0m\n' "$1"; }

run_spine() {
  rule "SilkCore — swift test"
  if (cd SilkCore && swift test); then
    echo "SilkCore: pass"
  else
    failed+=("SilkCore")
  fi
}

run_ui() {
  rule "SilkUITests — xcodebuild test (~5 min)"
  mkdir -p "$DERIVED"
  local log="$DERIVED/xcodebuild.log"
  rm -rf "$DERIVED/SilkUITests.xcresult"

  # Full output to the log, only the test lines to the terminal — a passing run
  # is 11 lines instead of several thousand, and a failing one still has the
  # whole log next to the result bundle.
  #
  # CODE_SIGNING_ALLOWED=NO because project.yml sets DEVELOPMENT_TEAM for device
  # builds; the simulator installs unsigned bundles and does not need it.
  set +e
  xcodebuild test \
    -project Silk.xcodeproj \
    -scheme Silk \
    -destination "$DESTINATION" \
    -only-testing:SilkUITests \
    -derivedDataPath "$DERIVED" \
    -resultBundlePath "$DERIVED/SilkUITests.xcresult" \
    CODE_SIGNING_ALLOWED=NO \
    >"$log" 2>&1
  local status=$?
  set -e

  grep -E "^Test Case|^Test Suite 'All tests'|error:|\*\* TEST" "$log" || true

  if [ $status -eq 0 ]; then
    echo "SilkUITests: pass"
  else
    failed+=("SilkUITests")
    echo "log:           $log"
    echo "result bundle: $DERIVED/SilkUITests.xcresult"
  fi
}

case "$what" in
  spine) run_spine ;;
  ui)    run_ui ;;
  all)
    # The spine answers in a tenth of a second and the simulator takes five
    # minutes. If the spine is already red the push is already refused, so
    # don't spend the five minutes to learn it twice.
    run_spine
    if [ ${#failed[@]} -eq 0 ]; then
      run_ui
    else
      echo "skipping SilkUITests — the spine is red"
    fi
    ;;
  *)     echo "usage: scripts/ci.sh [all|spine|ui]" >&2; exit 2 ;;
esac

rule "Result"
if [ ${#failed[@]} -eq 0 ]; then
  echo "green"
else
  printf 'FAILED: %s\n' "${failed[*]}"
  exit 1
fi
