#!/usr/bin/env bash
#
# All three suites, locally — the same commands .github/workflows/ci.yml runs on
# a runner. The workflow is the authority: it runs on every pull request and
# every push to main. This script is the same lanes on your own machine, and
# `scripts/ci.sh all` green on the exact tree is what scripts/release.sh refuses
# to archive without. .githooks/pre-push catches the cheap failures before they
# leave the machine.
#
#   scripts/ci.sh              all three suites + the Release build (~25 min)
#   scripts/ci.sh spine        SilkCore only (~4 s, no simulator, runs on Linux)
#   scripts/ci.sh unit         SilkTests only — the app's own logic (~1 min)
#   scripts/ci.sh ui           SilkUITests only (~5 min)
#   scripts/ci.sh release      Release compiles at all (~4 min, no simulator)
#
# Three and not two since the wait arrived. The spine proves the arithmetic, the
# walks prove the product, and neither could reach `AppModel`'s state machine:
# raise, pause, resume, land, drop is a few hundred lines whose branches have no
# pixel and whose windows are minutes long. SilkTests is hosted by the app, so it
# reaches them in milliseconds. Ordered by what a failure costs to learn.
#
# The spine is seconds rather than milliseconds because of how much text it
# parses. Its two most expensive tests are ratios, and a ratio has to run both
# its arms enough times for a clock to see them: `hugeInputStaysCheapAndSilent`
# in StressTests and `aHugePasteIsSilentAndCheap` in SpendShapeAdversarialTests
# each parse ten thousand words per arm, seven rounds over. Skipping those two
# takes about a third off the run; the thousand tests behind them are the rest.
# The wait's own frame-budget bounds are about one percent of it, and worth
# knowing about anyway: they and HotPathCostTests are the assertions here that
# can fail on "buttery smooth", and PerformanceMeasurement.swift says what a
# bound like that holds and, just as importantly, what it cannot.
#
# The seconds above are with SilkCore/.build warm; a fresh clone pays the
# SwiftPM compile first, which is minutes.
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

# WARNING — THIS WIPES THE APP GROUP ON WHATEVER IT RUNS AGAINST. SilkTests is
# hosted by the app and nearly every suite in it starts from
# `SharedStore.wipeAll()`: the policy, the ledger, the door bindings, the
# attempts history and the day log, gone, in the real App Group of the real
# install.
#
# Harmless on the simulator below, which is the only destination this script
# ever names. Not harmless on a phone: pointing this at the device carrying the
# build the re-lock protocol is being run against destroys the install's state
# mid-protocol and the run has to start over from onboarding.
run_unit() {
  rule "SilkTests — xcodebuild test (~1 min)"
  mkdir -p "$DERIVED"
  local log="$DERIVED/xcodebuild-unit.log"
  rm -rf "$DERIVED/SilkTests.xcresult"

  # Same DerivedData as the walks on purpose: they share a build of the app, so
  # running this first costs the build once and hands the walks a warm one.
  set +e
  xcodebuild test \
    -project Silk.xcodeproj \
    -scheme Silk \
    -destination "$DESTINATION" \
    -only-testing:SilkTests \
    -derivedDataPath "$DERIVED" \
    -resultBundlePath "$DERIVED/SilkTests.xcresult" \
    CODE_SIGNING_ALLOWED=NO \
    >"$log" 2>&1
  local status=$?
  set -e

  # swift-testing reports through its own lines, not XCTest's "Test Case" ones,
  # so both shapes are pulled out or a passing run looks empty.
  grep -E "^✔ Test run|^✘|error:|\*\* TEST" "$log" || true

  if [ $status -eq 0 ]; then
    echo "SilkTests: pass"
  else
    failed+=("SilkTests")
    echo "log:           $log"
    echo "result bundle: $DERIVED/SilkTests.xcresult"
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

run_release() {
  rule "Release build — xcodebuild build (~4 min)"
  mkdir -p "$DERIVED"
  local log="$DERIVED/xcodebuild-release.log"

  # The only thing in this repo that compiles Release. The scheme pins Debug for
  # build, test, run and analyze, and neither test invocation above passes
  # -configuration — so without this, the Release-only settings are first
  # exercised by an App Store archive, which is the worst possible place to
  # learn one is wrong. Specifically unguarded otherwise: every setting under
  # `configs: Release` in project.yml — -file-prefix-map, ENABLE_TESTABILITY NO,
  # the asset-catalog optimization — plus wholemodule -O and every `#if DEBUG`
  # block, which compile *out* here and nowhere else.
  #
  # Build, not test: the suites already ran under Debug. The question this asks
  # is only whether Release still compiles and links.
  set +e
  xcodebuild build \
    -project Silk.xcodeproj \
    -scheme Silk \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    >"$log" 2>&1
  local status=$?
  set -e

  grep -E "error:|\*\* BUILD" "$log" || true

  if [ $status -eq 0 ]; then
    echo "Release build: pass"
  else
    failed+=("Release build")
    echo "log:           $log"
  fi
}

# A missing toolchain is not a red suite. Without this, `swift` absent from a
# fresh container reports as "FAILED: SilkCore" — the one failure message in
# this script that would send you reading the spine's source for a bug that is
# not there.
if ! command -v swift >/dev/null 2>&1; then
  echo "scripts/ci.sh: no swift toolchain on PATH — nothing here can run." >&2
  echo "macOS: install Xcode. Linux: a swift.org toolchain, or the swift:6.2-noble image CI uses." >&2
  exit 2
fi

# Three of the four lanes are built out of xcodebuild, which exists only on a
# Mac. The spine is not: SilkCore is a plain SwiftPM package importing
# Foundation and nothing else, so `swift test` answers for it on Linux exactly
# as it does here — 1,060 of the repo's 1,200 tests, one short of the spine's
# whole 1,061 because a single Darwin-shaped ratio names itself and skips. That
# is deliberate, and .github/workflows/ci.yml has a job holding it true: it is
# what lets the tests that matter most run in a container or a cloud session
# instead of waiting on a runner.
#
# Without this check those three fail as `xcodebuild: command not found` inside
# a redirected log, which reads like a broken script rather than a machine that
# was never going to be able to answer.
darwin_only_skipped=0
if ! command -v xcodebuild >/dev/null 2>&1; then
  case "$what" in
    spine) darwin_only_skipped=1 ;;
    all)
      # Refused rather than quietly narrowed: `all` is what scripts/release.sh
      # asks for, and an exit 0 that ran the spine alone would archive a build
      # nothing else had looked at. Ask for `spine` by name on a machine that
      # can only answer that.
      echo "scripts/ci.sh all needs xcodebuild, which exists only on macOS." >&2
      echo "Only 'spine' can run here — ask for it by name; 'all' is not green." >&2
      exit 2
      ;;
    *)
      echo "scripts/ci.sh $what needs xcodebuild, which exists only on macOS." >&2
      echo "Only 'spine' can run here; push and let CI answer for the rest." >&2
      exit 2
      ;;
  esac
fi

case "$what" in
  spine)   run_spine ;;
  unit)    run_unit ;;
  ui)      run_ui ;;
  release) run_release ;;
  all)
    # Cheapest answer first, every time. The spine is four seconds, the unit
    # suite about a minute (most of it the app build the walks need anyway),
    # the walks five. A red one already refuses the push, so nothing below it
    # is worth paying for.
    run_spine
    if [ ${#failed[@]} -ne 0 ]; then
      echo "skipping SilkTests and SilkUITests — the spine is red"
    else
      run_unit
      if [ ${#failed[@]} -eq 0 ]; then
        run_ui
        # Last because it is a cold full compile and the least likely to be
        # red — but it runs, because nothing else here ever builds Release.
        if [ ${#failed[@]} -eq 0 ]; then
          run_release
        else
          echo "skipping the Release build — the walks are red"
        fi
      else
        echo "skipping SilkUITests — the unit suite is red"
      fi
    fi
    ;;
  *)     echo "usage: scripts/ci.sh [all|spine|unit|ui|release]" >&2; exit 2 ;;
esac

rule "Result"
if [ ${#failed[@]} -eq 0 ]; then
  if [ "$darwin_only_skipped" -eq 1 ]; then
    # Not "green": the spine passed and three lanes never ran. Saying green
    # here would be the script claiming an answer it does not have.
    echo "spine green — SilkTests, SilkUITests and the Release build did not run"
  else
    echo "green"
  fi
else
  printf 'FAILED: %s\n' "${failed[*]}"
  exit 1
fi
