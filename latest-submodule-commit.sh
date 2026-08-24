#!/usr/bin/env bash

# Resolve the most recent commit of a shared submodule as pinned by one or more
# parent repositories. Useful when a submodule (e.g. mayastor-dependencies) is
# vendored by several repos and you want to branch from whichever parent pins the
# newest submodule commit rather than the submodule's own branch tip.
#
# Usage:
#   latest-submodule-commit.sh --submodule <org/repo> --parent <org/repo> [--parent <org/repo> ...] [--ref <ref>]
#   latest-submodule-commit.sh --submodule openebs/mayastor-dependencies \
#     --parent openebs/mayastor --parent openebs/mayastor-control-plane
#
# Parents may also be given space-separated via --parents "<org/repo> <org/repo>".
#
# Auth: set GH_TOKEN (or GITHUB_TOKEN) for private repos; used as an
# x-access-token bearer in the clone URL. Unset => anonymous https clone.
#
# Prints progress to stderr. On success prints two lines to stdout:
#   sha=<commit>
#   parent=<org/repo>
# When $GITHUB_OUTPUT is set (GitHub Actions) the same key=value pairs are also
# appended there.

set -euo pipefail

SUBMODULE=""
PARENTS=""
PARENTS_REF="develop"

usage() {
  echo "usage: $(basename "$0") --submodule <org/repo> --parent <org/repo> [--parent ...] [--parents \"<a> <b>\"] [--ref <ref>]" >&2
  exit "${1:-1}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --submodule) shift; SUBMODULE="${1:-}" ;;
    --submodule=*) SUBMODULE="${1#*=}" ;;
    --parent) shift; PARENTS="${PARENTS} ${1:-}" ;;
    --parent=*) PARENTS="${PARENTS} ${1#*=}" ;;
    --parents) shift; PARENTS="${PARENTS} ${1:-}" ;;
    --parents=*) PARENTS="${PARENTS} ${1#*=}" ;;
    --ref) shift; PARENTS_REF="${1:-}" ;;
    --ref=*) PARENTS_REF="${1#*=}" ;;
    -h|--help) usage 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage ;;
  esac
  shift
done

[ -n "$SUBMODULE" ] || { echo "error: --submodule is required" >&2; usage; }
[ -n "${PARENTS// /}" ] || { echo "error: at least one --parent is required" >&2; usage; }

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

# Blobless clone of the submodule repo, used only to date candidate commits.
git clone --quiet --filter=blob:none --no-checkout "${base}/${SUBMODULE}.git" "$work/sub"

sub_name="${SUBMODULE##*/}"

newest_sha=""
newest_parent=""
newest_date=0
for parent in $PARENTS; do
  dir="$work/${parent##*/}"
  git clone --quiet --depth 1 --branch "$PARENTS_REF" "${base}/${parent}.git" "$dir"

  # Locate the submodule entry whose URL points at $SUBMODULE.
  name=$(git -C "$dir" config -f .gitmodules --get-regexp '\.url$' \
    | awk -v s="$sub_name" 'tolower($2) ~ s "(\\.git)?$" {print $1; exit}')
  if [ -z "${name:-}" ]; then
    echo "::error::${SUBMODULE} submodule not found in ${parent}" >&2
    exit 1
  fi
  key="${name%.url}"
  path=$(git -C "$dir" config -f .gitmodules --get "${key}.path")

  sha=$(git -C "$dir" ls-tree "HEAD" -- "$path" | awk '{print $3}')
  git -C "$work/sub" fetch --quiet --depth 1 origin "$sha"
  date=$(git -C "$work/sub" show -s --format=%ct "$sha")
  echo "${parent} (${PARENTS_REF}) pins ${SUBMODULE} ${sha} — committed $(date -u -d "@${date}" +%Y-%m-%dT%H:%M:%SZ)" >&2

  if [ "$date" -gt "$newest_date" ]; then
    newest_date="$date"; newest_sha="$sha"; newest_parent="$parent"
  fi
done

echo "Most recent ${SUBMODULE} commit: ${newest_sha} (from ${newest_parent})" >&2

echo "sha=${newest_sha}"
echo "parent=${newest_parent}"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "sha=${newest_sha}"
    echo "parent=${newest_parent}"
  } >> "$GITHUB_OUTPUT"
fi
