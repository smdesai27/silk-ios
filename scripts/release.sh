#!/usr/bin/env bash
#
# The release lane, as a mechanism rather than a habit. What produced
# 1.0.0 (2) was a person running the gate, committing, archiving and uploading
# in the right order by hand; this script refuses to do the last two until the
# first two are provably true of the exact tree it is about to archive.
#
#   scripts/release.sh            gate, tag, archive, upload
#   scripts/release.sh --no-gate  skip scripts/ci.sh all (only if it just ran
#                                 green on THIS tree — the script checks the
#                                 log's timestamp against the tree's)
#
# What it enforces, in order:
#   1. A clean, committed tree — an archive of uncommitted edits has no commit
#      to hot-fix from.
#   2. scripts/ci.sh all green on this tree (spine, unit, walks, Release).
#   3. The build number in project.yml is not one App Store Connect has
#      already taken — it must be greater than the last tag's.
#   4. Silk.xcodeproj is regenerated from project.yml, and that changed
#      nothing (drift ships otherwise: CI builds the committed project).
#   5. Archive into a DerivedData OUTSIDE the source root (with DerivedData
#      inside SRCROOT, -file-prefix-map makes dsymutil emit ~26 module-cache
#      warnings that train a reader to ignore warnings), warnings counted.
#   6. Export with scripts/ExportUpload.plist — destination=upload, automatic
#      signing, symbols on. Authentication is either the Apple ID Xcode is
#      signed in with (-allowProvisioningUpdates alone), or — because that
#      session expires and then xcodebuild answers "Failed to Use Accounts" —
#      an App Store Connect API key named by three environment variables:
#
#        SILK_ASC_KEY_PATH   the .p8 file (keep it outside the repo)
#        SILK_ASC_KEY_ID     the key ID from Users and Access → Integrations
#        SILK_ASC_ISSUER_ID  the issuer ID from the same page
#
#      Nothing here holds a credential; the values live in the shell that
#      runs this script.
#   7. Only then a tag v<MARKETING_VERSION>-build<CURRENT_PROJECT_VERSION> on
#      HEAD, so a failed archive leaves nothing to clean up before a retry.
#
# It does not touch App Store Connect beyond the upload. Attaching the build
# to the version, the release option, and Add for Review stay by hand.

set -euo pipefail
cd "$(dirname "$0")/.."

gate=1
if [ "${1:-}" = "--no-gate" ]; then gate=0; fi

rule() { printf '\n\033[1m── %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31m%s\033[0m\n' "$1"; exit 1; }

rule "Tree"
if [ -n "$(git status --porcelain)" ]; then
  git status --short
  fail "release.sh: the tree is not clean — commit first, so the archive has a commit to hot-fix from."
fi
head=$(git rev-parse HEAD)
echo "HEAD $head"
# The newest tracked file, read now — before xcodegen rewrites the project
# below — so --no-gate compares the gate log against the sources, not against
# a regeneration that changed nothing.
newest=$(git ls-files -z | xargs -0 stat -f '%m' | sort -n | tail -1)

marketing=$(sed -nE 's/^ *MARKETING_VERSION: *"?([0-9.]+)"?.*/\1/p' project.yml | head -1)
build=$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: *"?([0-9]+)"?.*/\1/p' project.yml | head -1)
[ -n "$marketing" ] && [ -n "$build" ] || fail "release.sh: could not read MARKETING_VERSION / CURRENT_PROJECT_VERSION from project.yml"
tag="v${marketing}-build${build}"
echo "version $marketing build $build → tag $tag"

rule "Build number"
# Builds 1 and 2 were uploaded before any tag existed, so the floor is 2 when
# the tag list is empty: App Store Connect refuses a build number it has seen.
last=$(git tag --list "v*-build*" | sed -nE 's/.*-build([0-9]+)$/\1/p' | sort -n | tail -1)
last=${last:-2}
if [ -n "$last" ] && [ "$build" -le "$last" ]; then
  fail "release.sh: build $build is not above the last tagged build ($last). Bump CURRENT_PROJECT_VERSION in project.yml and regenerate."
fi
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  fail "release.sh: tag $tag already exists."
fi

rule "Project matches spec"
command -v xcodegen >/dev/null || fail "release.sh: xcodegen is not installed (brew install xcodegen)."
xcodegen generate --quiet
if [ -n "$(git status --porcelain)" ]; then
  git status --short
  fail "release.sh: xcodegen changed the committed project — project.yml and Silk.xcodeproj had drifted. Commit the regenerated project and run again."
fi

rule "Gate"
if [ "$gate" = 1 ]; then
  scripts/ci.sh all || fail "release.sh: the gate is red; nothing is archived."
else
  log="DerivedData/ci/xcodebuild-release.log"
  [ -f "$log" ] || fail "release.sh: --no-gate, but no Release log to trust."
  logtime=$(stat -f '%m' "$log")
  [ "$logtime" -gt "$newest" ] || fail "release.sh: --no-gate, but the tree changed after the last gate ran."
  echo "trusting the gate log at $(date -r "$logtime")"
fi

rule "Archive"
archive_dd="${TMPDIR:-/tmp}/silk-archive-derived"
archive="build/Silk-${tag}.xcarchive"
mkdir -p build
xcodebuild archive \
  -project Silk.xcodeproj \
  -scheme Silk \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$archive_dd" \
  -archivePath "$archive" \
  -allowProvisioningUpdates \
  > "build/archive-${tag}.log" 2>&1 || { tail -40 "build/archive-${tag}.log"; fail "release.sh: archive failed (build/archive-${tag}.log)"; }
warnings=$(grep -c "warning:" "build/archive-${tag}.log" || true)
echo "archived $archive — $warnings warning line(s) in build/archive-${tag}.log"

rule "Upload"
auth=()
if [ -n "${SILK_ASC_KEY_PATH:-}" ]; then
  [ -n "${SILK_ASC_KEY_ID:-}" ] && [ -n "${SILK_ASC_ISSUER_ID:-}" ] \
    || fail "release.sh: SILK_ASC_KEY_PATH is set, so SILK_ASC_KEY_ID and SILK_ASC_ISSUER_ID are needed too."
  [ -r "$SILK_ASC_KEY_PATH" ] || fail "release.sh: cannot read SILK_ASC_KEY_PATH."
  auth=(-authenticationKeyPath "$SILK_ASC_KEY_PATH"
        -authenticationKeyID "$SILK_ASC_KEY_ID"
        -authenticationKeyIssuerID "$SILK_ASC_ISSUER_ID")
  echo "authenticating with App Store Connect key $SILK_ASC_KEY_ID"
else
  echo "authenticating with the Apple ID signed in to Xcode (set SILK_ASC_KEY_PATH to use a key)"
fi
xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportOptionsPlist scripts/ExportUpload.plist \
  -exportPath "build/export-${tag}" \
  -allowProvisioningUpdates \
  ${auth[@]+"${auth[@]}"} \
  > "build/upload-${tag}.log" 2>&1 || { tail -40 "build/upload-${tag}.log"; fail "release.sh: export/upload failed (build/upload-${tag}.log)"; }
grep -E "EXPORT SUCCEEDED|Upload succeeded|uploaded" "build/upload-${tag}.log" | head -3 || true

# Tagged last, so a failed archive or upload leaves no tag behind and the
# retry is not blocked by its own bookkeeping.
rule "Tag"
git tag -a "$tag" -m "Silk $marketing ($build) — App Store build" "$head"
echo "tagged $tag on $head (push with: git push origin $tag)"
echo
echo "Silk $marketing ($build) uploaded from $head, tagged $tag."
echo "Next, by hand: push the tag, attach build $build to the version in App Store Connect, keep the release option on Manual, and run the device protocol on the TestFlight build."
