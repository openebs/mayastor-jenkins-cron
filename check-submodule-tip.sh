#!/usr/bin/env bash

# Verify that a parent repository pins a submodule at the tip of that submodule's
# branch. Useful before cutting a release: e.g. mayastor-extensions vendors
# mayastor-control-plane as a submodule, and its develop should pin the
# control-plane develop tip so releasing control-plane from develop does not
# advance extensions past the commit it was integrated/tested against.
#
# Usage:
#   check-submodule-tip.sh --parent <org/repo> --submodule <org/repo> [--ref <ref>]
#   check-submodule-tip.sh --parent openebs/mayastor-extensions \
#     --submodule openebs/mayastor-control-plane
#
# --ref is the branch checked on both the parent (to read the pinned commit) and
# the submodule (to read its tip); defaults to develop.
#
# Auth: set GH_TOKEN (or GITHUB_TOKEN) for private repos; used as an
# x-access-token bearer in the clone URL. Unset => anonymous https clone.
#
# Prints progress to stderr and the two SHAs to stdout:
#   pinned=<commit>
#   tip=<commit>
# When $GITHUB_OUTPUT is set (GitHub Actions) the same key=value pairs are also
# appended there. Exits non-zero (with a ::error::) when the pin is stale.

set -euo pipefail

PARENT=""
SUBMODULE=""
REF="develop"

usage() {
  echo "usage: $(basename "$0") --parent <org/repo> --submodule <org/repo> [--ref <ref>]" >&2
  exit "${1:-1}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --parent) shift; PARENT="${1:-}" ;;
    --parent=*) PARENT="${1#*=}" ;;
    --submodule) shift; SUBMODULE="${1:-}" ;;
    --submodule=*) SUBMODULE="${1#*=}" ;;
    --ref) shift; REF="${1:-}" ;;
    --ref=*) REF="${1#*=}" ;;
    -h|--help) usage 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage ;;
  esac
  shift
done

[ -n "$PARENT" ] || { echo "error: --parent is required" >&2; usage; }
[ -n "$SUBMODULE" ] || { echo "error: --submodule is required" >&2; usage; }

# Build the clone URL prefix, embedding a token when available.
token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [ -n "$token" ]; then
  base="https://x-access-token:${token}@github.com"
else
  base="https://github.com"
fi

work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# Blobless, checkout-free clone of the parent, used only to read .gitmodules and
# the pinned gitlink SHA at $REF.
git clone --quiet --filter=blob:none --no-checkout --branch "$REF" \
  "${base}/${PARENT}.git" "$work/parent"
git -C "$work/parent" show "${REF}:.gitmodules" > "$work/.gitmodules"

sub_name="${SUBMODULE##*/}"

# Locate the submodule entry whose URL points at $SUBMODULE.
name=$(git config -f "$work/.gitmodules" --get-regexp '\.url$' \
  | awk -v s="$sub_name" 'tolower($2) ~ s "(\\.git)?$" {print $1; exit}')
if [ -z "${name:-}" ]; then
  echo "::error::${SUBMODULE} submodule not found in ${PARENT}" >&2
  exit 1
fi
path=$(git config -f "$work/.gitmodules" --get "${name%.url}.path")
pinned=$(git -C "$work/parent" ls-tree "$REF" -- "$path" | awk '{print $3}')

tip=$(git ls-remote "${base}/${SUBMODULE}.git" "refs/heads/${REF}" | awk '{print $1}')

echo "${PARENT} (${REF}) pins ${SUBMODULE}: ${pinned}" >&2
echo "${SUBMODULE} ${REF} tip:            ${tip}" >&2

echo "pinned=${pinned}"
echo "tip=${tip}"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "pinned=${pinned}"
    echo "tip=${tip}"
  } >> "$GITHUB_OUTPUT"
fi

if [ "$pinned" != "$tip" ]; then
  echo "::error::${PARENT}/${REF} pins ${SUBMODULE} ${pinned}, but ${SUBMODULE} ${REF} tip is ${tip}." >&2
  exit 1
fi
