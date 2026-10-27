#!/usr/bin/env bash
# collisions-ci.sh: cross-repo collision check for the Blackshield Skyrim SE mods.
#
# Compares the package built from THIS repo against the latest published release of each
# sibling mod (script names, EditorIDs, plugin names, voice folders, SEQ files) by running
# `scripts/verify-release.sh --collisions`. It fails only on a collision that involves this
# repo's package. Missing sibling releases are skipped with a notice and never fail the run.
#
# Usage:
#   scripts/collisions-ci.sh --dist DIR [--repo OWNER/NAME] [--work DIR] [--siblings-dir DIR]
#
#   --dist DIR          directory holding this repo's freshly built release zip (exactly one *.zip)
#   --repo OWNER/NAME   this repo (default $GITHUB_REPOSITORY); it is left out of the sibling set
#   --work DIR          scratch directory (default: a temp dir, removed on exit)
#   --siblings-dir DIR  use pre-downloaded sibling zips (DIR/<repo>/*.zip) instead of `gh`
#
# Environment:
#   GH_TOKEN            token for `gh release download` (the workflow GITHUB_TOKEN is enough)
#   COLLISION_SIBLINGS  space-separated sibling repo names (default: the 15 mod repos below)
#   COLLISION_OWNER     owner of the sibling repos (default: Blackshield-Company)
#
# Exit codes: 0 pass or nothing to compare, 1 collision involving this package, 2 usage/input error.
# Shared file: the same copy lives in every mod repo; canonical home is synthalorian/.github.
set -uo pipefail

DEFAULT_SIBLINGS="contract-hunter barrow-iron-pact blackshield-codex blackshield-company bounties-of-oblivion champions-reforge ember-smithing oathbreakers-price roadwarden sellsword-roster steel-oath the-gray-mane-debt the-ledger-of-ash the-turncoat-contract war-banners"
OWNER="${COLLISION_OWNER:-Blackshield-Company}"
SIBLINGS="${COLLISION_SIBLINGS:-$DEFAULT_SIBLINGS}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFIER="$HERE/verify-release.sh"

dist="" ; self="${GITHUB_REPOSITORY:-}" ; work="" ; sibdir=""
need_val() {
  if [ "$2" -lt 2 ] || [ -z "$3" ] || [ "${3#--}" != "$3" ]; then
    echo "collisions-ci.sh: $1 requires a value" >&2; exit 2
  fi
}
while [ $# -gt 0 ]; do
  case "$1" in
    --dist) need_val "$1" $# "${2:-}"; dist="$2"; shift 2 ;;
    --repo) need_val "$1" $# "${2:-}"; self="$2"; shift 2 ;;
    --work) need_val "$1" $# "${2:-}"; work="$2"; shift 2 ;;
    --siblings-dir) need_val "$1" $# "${2:-}"; sibdir="$2"; shift 2 ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "collisions-ci.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$dist" ] && [ -d "$dist" ] || { echo "::error::collisions-ci: --dist DIR is required and must exist" >&2; exit 2; }
[ -x "$VERIFIER" ] || { echo "::error::collisions-ci: $VERIFIER not found or not executable" >&2; exit 2; }
self_name="${self##*/}"

shopt -s nullglob
own_zips=("$dist"/*.zip)
if [ "${#own_zips[@]}" -ne 1 ]; then
  echo "::error::collisions-ci: expected exactly one zip in $dist, found ${#own_zips[@]}" >&2
  exit 2
fi
own_zip="${own_zips[0]}"

cleanup_work=0
if [ -z "$work" ]; then work="$(mktemp -d)"; cleanup_work=1; else mkdir -p "$work"; fi
trap '[ "$cleanup_work" = 1 ] && rm -rf "$work"' EXIT
sib_root="$work/siblings"
rm -rf "$sib_root"   # never reuse sibling zips left by an earlier run
mkdir -p "$sib_root" || { echo "::error::collisions-ci: cannot create $sib_root" >&2; exit 2; }

compared=() ; skipped=() ; args=()
note() { echo "::notice::$*"; }

# Overall wall-clock budget (seconds) for fetching sibling releases; per-call timeouts are
# clamped to what is left, and once it runs out the remaining siblings are skipped.
DOWNLOAD_BUDGET=420
budget_start=$SECONDS
budget_left() { echo $(( DOWNLOAD_BUDGET - (SECONDS - budget_start) )); }
# Never returns less than 1: `timeout 0` would disable the timeout altogether.
clamp() { local left; left="$(budget_left)"; [ "$left" -lt 1 ] && left=1; [ "$left" -lt "$1" ] && echo "$left" || echo "$1"; }
budget_noted=0

for name in $SIBLINGS; do
  [ "$name" = "$self_name" ] && continue
  if [ -z "$sibdir" ] && [ "$(budget_left)" -le 0 ]; then
    if [ "$budget_noted" = 0 ]; then
      note "download time budget (${DOWNLOAD_BUDGET}s) exhausted; skipping remaining siblings"
      budget_noted=1
    fi
    skipped+=("$name|download time budget exhausted")
    continue
  fi
  dest="$sib_root/$name"
  mkdir -p "$dest"
  tag="local"
  if [ -n "$sibdir" ]; then
    cp "$sibdir/$name"/*.zip "$dest"/ 2>/dev/null || true
  else
    tag=""
    if tag="$(timeout "$(clamp 30)" gh api "repos/$OWNER/$name/releases/latest" --jq '.tag_name' 2>/dev/null)"; then :; else tag=""; fi
    case "$tag" in *[!A-Za-z0-9._+/-]*) tag="" ;; esac
    if [ -z "$tag" ]; then
      note "$OWNER/$name: no published release (or not readable with this token); skipped"
      skipped+=("$name|no published release or not readable")
      continue
    fi
    ok=0 ; out_of_time=0
    for attempt in 1 2; do
      if [ "$(budget_left)" -le 0 ]; then out_of_time=1; break; fi
      if timeout "$(clamp 90)" gh release download "$tag" -R "$OWNER/$name" --pattern '*.zip' --dir "$dest" --clobber >/dev/null 2>&1; then ok=1; break; fi
      [ "$attempt" = 1 ] && [ "$(budget_left)" -gt 3 ] && sleep 3
    done
    if [ "$ok" != 1 ] && { [ "$out_of_time" = 1 ] || [ "$(budget_left)" -le 0 ]; }; then
      rm -f "$dest"/*.zip
      note "$OWNER/$name@$tag: download time budget (${DOWNLOAD_BUDGET}s) exhausted; skipped"
      budget_noted=1
      skipped+=("$name|download time budget exhausted")
      continue
    fi
    if [ "$ok" != 1 ]; then
      note "$OWNER/$name@$tag: could not download a .zip asset; skipped"
      skipped+=("$name|$tag has no downloadable .zip asset")
      continue
    fi
  fi
  good=0
  for z in "$dest"/*.zip; do
    if python3 - "$z" <<'PY'
import sys, zipfile
try:
    with zipfile.ZipFile(sys.argv[1]) as zf:
        sys.exit(0 if zf.namelist() else 1)
except Exception:
    sys.exit(1)
PY
    then args+=("$z"); good=$((good + 1))
    else note "$OWNER/$name@$tag: $(basename "$z") is not a readable zip; ignored"; rm -f "$z"; fi
  done
  if [ "$good" -eq 0 ]; then
    [ -n "$sibdir" ] && note "$name: no zip in $sibdir/$name; skipped"
    skipped+=("$name|no usable zip asset")
  else
    compared+=("$name|$tag|$(cd "$dest" && ls *.zip | paste -sd, -)")
  fi
done

summary() { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"; return 0; }

echo "collisions-ci: package under test: $(basename "$own_zip")"
echo "collisions-ci: siblings compared (${#compared[@]}):"
for c in "${compared[@]}"; do IFS='|' read -r n t a <<<"$c"; echo "  - $n @ $t ($a)"; done
echo "collisions-ci: siblings skipped (${#skipped[@]}):"
for s in "${skipped[@]}"; do IFS='|' read -r n why <<<"$s"; echo "  - $n: $why"; done

summary "## Cross-repo collision check"
summary ""
summary "Package under test: \`$(basename "$own_zip")\` (built from this ref)."
summary ""
summary "| Sibling | Release | Compared asset |"
summary "|---|---|---|"
for c in "${compared[@]}"; do IFS='|' read -r n t a <<<"$c"; summary "| $n | $t | $a |"; done
if [ "${#skipped[@]}" -gt 0 ]; then
  summary ""
  summary "Skipped (never a failure): "
  for s in "${skipped[@]}"; do IFS='|' read -r n why <<<"$s"; summary "- $n: $why"; done
fi

if [ "${#compared[@]}" -eq 0 ]; then
  note "no sibling release could be fetched; nothing to compare"
  summary ""; summary "No sibling release was available, so nothing was compared."
  exit 0
fi

report="$work/collisions.json"
out="$work/collisions.txt"
rm -f "$report" "$out"
timeout 300 "$VERIFIER" --collisions "$own_zip" "${args[@]}" --json "$report" >"$out" 2>&1
rc=$?
[ -f "$out" ] && cat "$out"

# 0 = no collision, 1 = collision (report still written); anything else (incl. 124 timeout)
# or a missing report means the run did not complete.
if { [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; } || [ ! -s "$report" ]; then
  echo "::error::collisions-ci: verify-release.sh --collisions failed to run (exit $rc$([ -s "$report" ] || echo ', no report'))" >&2
  summary ""; summary "**Result: ERROR**: the collision run did not complete (exit $rc)."
  exit 2
fi

python3 - "$report" "$own_zip" "${GITHUB_STEP_SUMMARY:-}" <<'PY'
import json, os, sys
report, own_zip, summary = sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else ""
rep = json.load(open(report))
own_real = os.path.realpath(own_zip)
own = [p["name"] for p in rep["packages"] if os.path.realpath(p.get("realpath", "")) == own_real]
if len(own) != 1:
    print("::error::collisions-ci: could not identify this repo's package in the report")
    sys.exit(2)
own = own[0]
mine = [d for d in rep["duplicates"] if own in d["packages"]]
others = [d for d in rep["duplicates"] if own not in d["packages"]]
own_err = [e for e in rep["errors"] if e["package"] == own]
oth_err = [e for e in rep["errors"] if e["package"] != own]
lines = []
for d in mine:
    where = ", ".join(d["packages"])
    print("::error title=Cross-repo collision (%s)::%s '%s' also appears in: %s" % (d["kind"], d["kind"], d["name"], where))
    lines.append("- **%s** `%s`: %s" % (d["kind"], d["name"], where))
for e in own_err:
    print("::error title=Plugin not parsable::%s: %s" % (e["path"], e["error"]))
    lines.append("- unparsable plugin in this package `%s`: %s" % (e["path"], e["error"]))
for d in others:
    print("::warning title=Collision between siblings (not this repo)::%s '%s' in %s" % (d["kind"], d["name"], ", ".join(d["packages"])))
for e in oth_err:
    print("::warning title=Sibling plugin not parsable::%s %s: %s" % (e["package"], e["path"], e["error"]))
bad = bool(mine or own_err)
if summary:
    with open(summary, "a") as f:
        f.write("\n")
        if bad:
            f.write("**Result: FAIL**: collisions involving this package:\n\n" + "\n".join(lines) + "\n")
        else:
            f.write("**Result: PASS**: no name in this package appears in any compared sibling release.\n")
        if others or oth_err:
            f.write("\nNote: %d collision(s) between sibling releases only and %d unparsable sibling plugin(s) were ignored (see warnings).\n" % (len(others), len(oth_err)))
print("collisions-ci: RESULT %s (%d collision(s) involving %s)" % ("FAIL" if bad else "PASS", len(mine) + len(own_err), own))
sys.exit(1 if bad else 0)
PY
exit $?
