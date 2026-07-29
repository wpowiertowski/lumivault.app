#!/bin/bash
#
# Non-view line coverage gate.
#
# The headline coverage number for this app is dominated by ~14,800 lines of
# SwiftUI view code that unit tests do not reach, so it moves for reasons that
# have nothing to do with test quality — adding a settings screen lowers it,
# deleting one raises it. This gate measures the part tests are actually
# responsible for: everything outside `LumiVault/Views/` and `ContentView.swift`.
#
# Usage: Scripts/coverage-gate.sh [minimum-percent]
set -euo pipefail

MINIMUM="${1:-0}"

# Ask SwiftPM where it built rather than hardcoding `arm64-apple-macosx`: on an
# Intel Mac, or after any toolchain change to the triple directory name, the
# hardcoded path made this report "no profdata — run swift test first" when
# coverage had just been generated.
BIN_DIR="$(swift build --show-bin-path)"
BIN="$BIN_DIR/LumiVaultPackageTests.xctest/Contents/MacOS/LumiVaultPackageTests"
PROF="$BIN_DIR/codecov/default.profdata"

if [ ! -f "$PROF" ]; then
  echo "::error::No profdata at $PROF — run 'swift test --enable-code-coverage' first"
  exit 1
fi

# Per-invocation, so a local run and the pre-commit hook cannot overwrite each
# other's export mid-read.
EXPORT_JSON="$(mktemp -t lumivault-coverage)"
trap 'rm -f "$EXPORT_JSON"' EXIT

xcrun llvm-cov export "$BIN" \
  -instr-profile "$PROF" \
  -ignore-filename-regex='(Tests|\.build|checkouts)/' \
  --format=text > "$EXPORT_JSON"

python3 - "$MINIMUM" "$EXPORT_JSON" <<'PY'
import json, sys

minimum = float(sys.argv[1])
data = json.load(open(sys.argv[2]))["data"][0]

def is_view(path):
    return "/Views/" in path or path.endswith("ContentView.swift")

rows, covered, total = [], 0, 0
view_covered, view_total = 0, 0
for f in data["files"]:
    s = f["summary"]["lines"]
    if is_view(f["filename"]):
        view_covered += s["covered"]; view_total += s["count"]
        continue
    covered += s["covered"]; total += s["count"]
    rows.append((f["filename"].split("/")[-1], s["covered"], s["count"]))

pct = covered / total * 100 if total else 0.0
overall = data["totals"]["lines"]

print(f"non-view : {covered}/{total} = {pct:.2f}%   <-- the gated number")
print(f"views    : {view_covered}/{view_total} = "
      f"{view_covered / view_total * 100 if view_total else 0:.2f}%   (needs UI tests)")
print(f"overall  : {overall['covered']}/{overall['count']} = {overall['percent']:.2f}%")

print("\nleast-covered non-view files:")
for name, c, t in sorted(rows, key=lambda r: (r[1] / r[2] if r[2] else 1))[:10]:
    if t:
        print(f"  {c / t * 100:5.1f}%  {name}  ({c}/{t})")

if pct + 1e-9 < minimum:
    print(f"\n::error::Non-view coverage {pct:.2f}% is below the {minimum:.2f}% floor")
    sys.exit(1)
print(f"\nOK: {pct:.2f}% >= {minimum:.2f}% floor")
PY
