#!/usr/bin/env bash

# Summarise the mayastor images, helm chart and kubectl plugin published by a
# mayastor chart, from the published chart metadata.
#
# By default the chart metadata is read from the staging OCI chart on ghcr.io.
# Pass --released (optionally --chart-repo <url>) to instead report against a
# published chart from the Helm HTTP repo (via `helm show chart`).
#
# Usage: chart-report.sh --tag <tag> [--quick] [--quick-img] [--quick-bins]
#        chart-report.sh --tag <tag> --released    # report a released chart
#        chart-report.sh --tag <tag> --chart       # dump Chart.yaml (helm show chart)
#        chart-report.sh <tag>                     # positional tag still accepted
#
# Requires: crane, jq (and helm, yq for --released). Reads public ghcr.io
# packages and the public Helm repo (no auth needed). Writes markdown to
# $GITHUB_STEP_SUMMARY when set, otherwise to stdout so it can be run and
# inspected locally.

set -euo pipefail

usage() {
  echo "usage: $(basename "$0") --tag <tag> [--quick] [--quick-img] [--quick-bins] [--skip-dependencies] [--uncompressed] [--chart] [--released] [--chart-repo <url>]" >&2
  exit "${1:-1}"
}

TAG="${TAG:-}"
QUICK_IMG=""
QUICK_BINS=""
SKIP_DEPS=""
UNCOMPRESSED=""
CHART_ONLY=""
RELEASED=""
CHART_REPO=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag) shift; TAG="${1:-}" ;;
    --tag=*) TAG="${1#*=}" ;;
    --quick) QUICK_IMG="yes"; QUICK_BINS="yes" ;;
    --quick-img) QUICK_IMG="yes" ;;
    --quick-bins) QUICK_BINS="yes" ;;
    --skip-dependencies) SKIP_DEPS="yes" ;;
    --uncompressed) UNCOMPRESSED="yes" ;;
    --chart) CHART_ONLY="yes" ;;
    --released) RELEASED="yes" ;;
    --chart-repo) shift; RELEASED="yes"; CHART_REPO="${1:-}" ;;
    --chart-repo=*) RELEASED="yes"; CHART_REPO="${1#*=}" ;;
    -h|--help) usage 0 ;;
    -*) echo "error: unknown option '$1'" >&2; usage ;;
    *) TAG="$1" ;;  # positional tag
  esac
  shift
done

if [ -z "$TAG" ]; then
  usage
fi

# Emit the nix-command flag only when the installed nix needs it enabled.
nix_experimental() {
  if (nix eval 2>&1 || true) | grep "extra-experimental-features" >/dev/null; then
    echo -n " --extra-experimental-features nix-command "
  else
    echo -n " "
  fi
}

# Resolve a binary from nixpkgs and print its store path.
# Uses whatever <nixpkgs> resolves to; no pinned sources.
fetch_nix_bin() {
  local package="$1" bin="$2"
  nix shell --impure $(nix_experimental) --expr "(import <nixpkgs> {}).$package" \
    -c bash -c "type -P $bin" 2>/dev/null
}

# Ensure a binary is available, pulling it from nixpkgs when missing.
ensure_bin() {
  local bin="$1" package="$2" path
  command -v "$bin" >/dev/null 2>&1 && return 0
  if ! command -v nix >/dev/null 2>&1; then
    echo "error: '$bin' not found and nix is unavailable to fetch it" >&2
    exit 1
  fi
  echo "Fetching '$bin' from nixpkgs ($package)..." >&2
  path=$(fetch_nix_bin "$package" "$bin") || true
  if [ -z "$path" ]; then
    echo "error: failed to fetch '$bin' from nixpkgs package '$package'" >&2
    exit 1
  fi
  PATH="$(dirname "$path"):$PATH"
}

ensure_bin crane go-containerregistry
ensure_bin jq jq
ensure_bin curl curl

# Released mode reads the published chart from a Helm HTTP repo instead of the
# staging OCI chart; that needs helm (metadata) and yq (YAML -> JSON).
CHART_REPO="${CHART_REPO:-https://openebs.github.io/mayastor-extensions}"
if [ -n "$RELEASED" ]; then
  ensure_bin helm kubernetes-helm
  ensure_bin yq yq-go
fi

REG="ghcr.io/openebs/mayastor/dev"
CHART_VERSION="${TAG#v}"
CHART_REF="$REG/helm/mayastor:$CHART_VERSION"
PLUGIN_REF="$REG/plugin/kubectl-mayastor:v$CHART_VERSION"

human() { numfmt --to=iec-i --suffix=B --format='%.1f' "${1:-0}" 2>/dev/null || echo "${1:-0}"; }
short() { echo "$1"; }

# Build a markdown link from an image/chart ref to its registry web UI, wrapping
# the given display text. Unknown hosts fall back to the plain display text.
#
# ghcr.io  -> the exact version page on github.com. The per-tag numeric version
#             id is scraped from the (public) org package page filtered by tag;
#             GitHub redirects the org URL to the owning repo automatically. If
#             scraping fails we fall back to the tag-filtered package page.
# docker.io/quay.io -> the repository (tags) page on the respective registry.
image_link() {
  local display="$1" ref="$2" repo tag host path org pkg enc url="" base id tag_re
  repo="$ref"; tag=""
  case "$ref" in *:*) repo="${ref%:*}"; tag="${ref##*:}" ;; esac
  host="${repo%%/*}"; path="${repo#*/}"
  case "$host" in
    ghcr.io)
      org="${path%%/*}"; pkg="${path#*/}"
      enc="${pkg//\//%2F}"
      base="https://github.com/orgs/$org/packages/container/package/$enc"
      url="$base${tag:+?tag=$tag}"
      if [ -n "$tag" ]; then
        # The tag-filtered page lists a link `.../$enc/<id>?tag=<tag>`; grab the
        # id for our exact tag to build the specific version URL.
        tag_re="${tag//./\\.}"
        id=$(curl -fsSL "$base?tag=$tag" 2>/dev/null \
          | grep -oE "$enc/[0-9]{5,}\?tag=$tag_re\"" \
          | grep -oE '[0-9]{5,}' | head -1) || id=""
        [ -n "$id" ] && url="https://github.com/orgs/$org/packages/container/$enc/$id?tag=$tag"
      fi
      ;;
    docker.io)
      case "$path" in
        library/*) url="https://hub.docker.com/_/${path#library/}${tag:+/tags?name=$tag}" ;;
        *)         url="https://hub.docker.com/r/$path${tag:+/tags?name=$tag}" ;;
      esac
      ;;
    quay.io)
      url="https://quay.io/repository/$path${tag:+/tag/$tag}"
      ;;
  esac
  if [ -n "$url" ]; then echo "[$display]($url)"; else echo "$display"; fi
}

# Map a rust target triple (e.g. x86_64-apple-darwin) to "os/arch".
platform_of_triple() {
  local t="$1" os="?" arch="?"
  case "$t" in
    *linux*)          os="linux" ;;
    *apple*|*darwin*) os="darwin" ;;
    *windows*)        os="windows" ;;
  esac
  case "$t" in
    x86_64*|amd64*)   arch="x86_64" ;;
    aarch64*|arm64*)  arch="aarch64" ;;
  esac
  echo "$os/$arch"
}

# Compressed size (config + layers) for a single platform. Accepts an optional
# pre-fetched manifest as $2 to avoid a network call. For multi-arch indexes it
# reports the linux/amd64 image (one sub-manifest fetch), i.e. the pull size for
# that platform rather than the sum of every architecture.
image_size() {
  local ref="$1" m="${2:-}" repo mt d
  repo="${ref%:*}"
  [ -n "$m" ] || m=$(crane manifest "$ref" 2>/dev/null) || { echo 0; return; }
  mt=$(jq -r '.mediaType // ""' <<<"$m")
  if grep -qiE 'index|manifest.list' <<<"$mt"; then
    d=$(jq -r '(first(.manifests[] | select(.platform.os=="linux" and .platform.architecture=="amd64") | .digest)) // .manifests[0].digest' <<<"$m")
    m=$(crane manifest "${repo}@${d}" 2>/dev/null) || { echo 0; return; }
  fi
  jq '([.config.size // 0] + [ (.layers // [])[].size ]) | add // 0' <<<"$m"
}

# Uncompressed on-disk size = sum of decompressed layer sizes for a single platform.
# This matches what `docker image ls` reports. Prefers linux/amd64 for multi-arch.
#
# For gzip layers we read the 4-byte ISIZE trailer via a ranged GET instead of
# downloading the whole blob (gzip stores the uncompressed size mod 2^32 there).
# Other media types fall back to streaming the blob through the decompressor.
image_uncompressed_size() {
  local ref="$1" m="${2:-}" repo mt d total=0 digest media csize
  repo="${ref%:*}"
  [ -n "$m" ] || m=$(crane manifest "$ref" 2>/dev/null) || { echo 0; return; }
  mt=$(jq -r '.mediaType // ""' <<<"$m")
  if grep -qiE 'index|manifest.list' <<<"$mt"; then
    d=$(jq -r '(first(.manifests[] | select(.platform.os=="linux" and .platform.architecture=="amd64") | .digest)) // .manifests[0].digest' <<<"$m")
    m=$(crane manifest "${repo}@${d}" 2>/dev/null) || { echo 0; return; }
  fi
  while IFS=$'\t' read -r digest media csize; do
    [ -n "$digest" ] || continue
    case "$media" in
      *gzip)
        total=$((total + $(gzip_isize "$repo" "$digest" "$csize"))) ;;
      *zstd)
        total=$((total + $(crane blob "${repo}@${digest}" 2>/dev/null | zstd -dc 2>/dev/null | wc -c))) ;;
      *)
        total=$((total + csize)) ;;
    esac
  done < <(jq -r '.layers[] | "\(.digest)\t\(.mediaType)\t\(.size)"' <<<"$m")
  echo "$total"
}

# Read a gzip layer's uncompressed size from its 4-byte ISIZE trailer via a
# ranged request, avoiding a full download. Falls back to streaming on failure.
declare -A _TOKEN_CACHE=()
gzip_isize() {
  local repo="$1" digest="$2" csize="$3" host path reg realm service sep token url eff trailer hex ok tmp
  # Need at least the 4-byte trailer to range-read it.
  if ! [ "${csize:-0}" -ge 4 ] 2>/dev/null; then
    crane blob "${repo}@${digest}" 2>/dev/null | gunzip -c 2>/dev/null | wc -c
    return
  fi
  host="${repo%%/*}"; path="${repo#*/}"
  # docker.io images are served by the registry-1.docker.io registry, not docker.io
  # (which redirects unauthenticated requests to the marketing site).
  reg="$host"; [ "$host" = "docker.io" ] && reg="registry-1.docker.io"
  url="https://${reg}/v2/${path}/blobs/${digest}"

  # OCI token flow: the registry advertises its auth server (realm) and service in
  # the WWW-Authenticate header of a 401. Discover it (per registry the endpoint
  # differs: ghcr uses ghcr.io/token, docker uses auth.docker.io, quay uses
  # quay.io/v2/auth, ...) and cache the resulting pull token per repo. Registries
  # that serve blobs anonymously (e.g. registry.k8s.io) yield no realm.
  token="${_TOKEN_CACHE[$repo]:-}"
  if [ -z "$token" ]; then
    local www
    www=$(curl -sSI "$url" 2>/dev/null | tr -d '\r' \
      | awk 'tolower($1)=="www-authenticate:"{sub(/^[^ ]+ /,""); print}')
    realm=$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<<"$www")
    service=$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<<"$www")
    if [ -n "$realm" ]; then
      sep="?"; case "$realm" in *\?*) sep="&" ;; esac
      token=$(curl -fsSL "${realm}${sep}service=${service}&scope=repository:${path}:pull" 2>/dev/null \
        | jq -r '.token // .access_token // empty' 2>/dev/null) || token=""
    fi
    _TOKEN_CACHE[$repo]="$token"
  fi

  # Fetch the last 4 bytes (little-endian ISIZE = uncompressed size mod 2^32).
  # Only trust them when the server honoured the Range AND the URL we actually
  # read from references this blob's digest: an unauthenticated/redirected
  # request can land on an unrelated page whose 4 bytes would parse as a bogus,
  # huge size. Anything else falls back to streaming the blob through gunzip.
  hex="${digest#*:}"
  tmp=$(mktemp)
  eff=$(curl -fsSL ${token:+-H "Authorization: Bearer ${token}"} \
    -r "$((csize - 4))-$((csize - 1))" "$url" -o "$tmp" \
    -w '%{url_effective}' 2>/dev/null) || eff=""
  trailer=$(od -An -tu1 "$tmp" | tr -s ' \n' ' ' | sed 's/^ //;s/ $//')
  rm -f "$tmp"
  ok=""
  if [ "$(wc -w <<<"$trailer")" -eq 4 ] && [ "${#hex}" -ge 8 ]; then
    case "$eff" in *"$hex"*) ok="yes" ;; esac
  fi
  if [ -n "$ok" ]; then
    # shellcheck disable=SC2086
    set -- $trailer
    echo "$(( $1 + $2*256 + $3*65536 + $4*16777216 ))"
  else
    crane blob "${repo}@${digest}" 2>/dev/null | gunzip -c 2>/dev/null | wc -c
  fi
}

platforms_of() {
  local m="${2:-}"
  [ -n "$m" ] || m=$(crane manifest "$1" 2>/dev/null) || { echo "-"; return; }
  if grep -qiE 'index|manifest.list' <<<"$(jq -r '.mediaType // ""' <<<"$m")"; then
    jq -r '[.manifests[] | select((.platform.os // "unknown") != "unknown") | "\(.platform.os)/\(.platform.architecture)"] | unique | join(", ")' <<<"$m"
  else
    echo "linux/amd64"
  fi
}

# Render the rows for a single image: a header row (image ref + all supported
# platforms) followed by one indented row per architecture (amd64, arm64), so a
# missing/failed arch is easy to spot. Kept separate for parallelism.
# Honours $QUICK_IMG/$UNCOMPRESSED.
ARCHES=(amd64 arm64)
image_rows() {
  local ref="$1" name tag m mt is_index plats arch d sm dl un digest pad blank
  name="${ref%:*}"
  tag="${ref##*:}"
  pad="&nbsp;&nbsp;&nbsp;&nbsp;"
  # Placeholder for cells that don't apply. (GitHub Actions step summaries do
  # NOT render KaTeX math, so colour/greying isn't available there.)
  blank=""

  if [ -n "$QUICK_IMG" ]; then
    echo "| **$(image_link "\`$name:$tag\`" "$ref")** | $blank | $blank |$([ -n "$UNCOMPRESSED" ] && echo " $blank |") $blank |"
    for arch in "${ARCHES[@]}"; do
      if [ -n "$UNCOMPRESSED" ]; then
        echo "| $blank | ${pad}$arch | - | - | - |"
      else
        echo "| $blank | ${pad}$arch | - | - |"
      fi
    done
    return
  fi

  m=$(crane manifest "$ref" 2>/dev/null) || m=""
  mt=$(jq -r '.mediaType // ""' <<<"$m" 2>/dev/null || echo "")
  is_index=""
  grep -qiE 'index|manifest.list' <<<"$mt" && is_index="yes"

  if [ -z "$m" ]; then
    plats="_fetch failed_"
  else
    plats="$(platforms_of "$ref" "$m")"
  fi

  # Buffer the per-arch rows so the header row can show the image totals (sum of
  # the download / uncompressed sizes across all published architectures).
  local rows="" tot_dl=0 tot_un=0 dl_bytes un_bytes have_size=""
  for arch in "${ARCHES[@]}"; do
    # The arch label (in the Platforms column) turns red when that platform is
    # not published for the image.
    local label="$arch"
    dl_bytes=""; un_bytes=""
    # Distinguish "couldn't fetch" (rate limit / network) from "arch not published".
    if [ -z "$m" ]; then
      dl="?"; un="?"; digest="_fetch failed_"
    else
      dl="—"; un="—"; digest="—"; label="🔴 ~~$arch~~"
      if [ -n "$is_index" ]; then
        d=$(jq -r --arg a "$arch" 'first(.manifests[] | select(.platform.os=="linux" and .platform.architecture==$a) | .digest) // empty' <<<"$m")
        if [ -n "$d" ]; then
          sm=$(crane manifest "${ref%:*}@${d}" 2>/dev/null) || sm=""
          if [ -n "$sm" ]; then
            dl_bytes="$(image_size "$ref" "$sm")"; dl="$(human "$dl_bytes")"
            [ -n "$UNCOMPRESSED" ] && { un_bytes="$(image_uncompressed_size "$ref" "$sm")"; un="$(human "$un_bytes")"; }
            digest="\`$(short "$d")\`"; label="$arch"
          else
            dl="?"; un="?"; digest="_fetch failed_"; label="$arch"
          fi
        fi
      elif [ "$arch" = "amd64" ]; then
        # Single-platform image manifest (the mayastor images); treat as amd64.
        dl_bytes="$(image_size "$ref" "$m")"; dl="$(human "$dl_bytes")"
        [ -n "$UNCOMPRESSED" ] && { un_bytes="$(image_uncompressed_size "$ref" "$m")"; un="$(human "$un_bytes")"; }
        digest="\`$(short "sha256:$(printf '%s' "$m" | sha256sum | cut -d' ' -f1)")\`"; label="$arch"
      fi
    fi
    if [ -n "$dl_bytes" ]; then have_size="yes"; tot_dl=$((tot_dl + dl_bytes)); fi
    if [ -n "$un_bytes" ]; then tot_un=$((tot_un + un_bytes)); fi
    if [ -n "$UNCOMPRESSED" ]; then
      rows+="| $blank | ${pad}$label | $dl | $un | $digest |"$'\n'
    else
      rows+="| $blank | ${pad}$label | $dl | $digest |"$'\n'
    fi
  done

  # Header row: bold image ref, supported platforms, and the aggregate size(s).
  local htot_dl="$blank" htot_un="$blank"
  [ -n "$have_size" ] && htot_dl="$(human "$tot_dl")"
  [ -n "$have_size" ] && [ -n "$UNCOMPRESSED" ] && htot_un="$(human "$tot_un")"
  local hlink; hlink="$(image_link "\`$name:$tag\`" "$ref")"
  if [ -n "$UNCOMPRESSED" ]; then
    echo "| **$hlink** | ${plats} | $htot_dl | $htot_un | $blank |"
  else
    echo "| **$hlink** | ${plats} | $htot_dl | $blank |"
  fi
  printf '%s' "$rows"
}

# Render a markdown table for a set of image refs. First arg is the "empty" note.
# Each image is a group: a header row plus one row per architecture. Rows are
# computed in parallel (network-bound) and emitted in input order.
images_table() {
  local empty_note="$1"; shift
  local refs=("$@") ref i tmp pids=()
  if [ "${#refs[@]}" -eq 0 ]; then
    echo "_${empty_note} in the chart metadata for \`$TAG\`._"
    return
  fi
  if [ -n "$UNCOMPRESSED" ]; then
    echo "| Image | Platforms | Download | Size | Digest |"
    echo "| --- | --- | --- | --- | --- |"
  else
    echo "| Image | Platforms | Download | Digest |"
    echo "| --- | --- | --- | --- |"
  fi
  tmp=$(mktemp -d)
  for i in "${!refs[@]}"; do
    image_rows "${refs[$i]}" >"$tmp/$i" &
    pids+=("$!")
    # Cap concurrency to avoid hammering registries into rate limits.
    if [ "$(( (i + 1) % 8 ))" -eq 0 ]; then wait "${pids[@]}"; pids=(); fi
  done
  wait "${pids[@]}" 2>/dev/null || true
  for i in "${!refs[@]}"; do cat "$tmp/$i"; done
  rm -rf "$tmp"
}

report() {
  # Helm's OCI config blob is the Chart.yaml serialised to JSON (name, version, appVersion, annotations).
  # Released mode reads the same fields from the published chart via `helm show chart`.
  local cfg heading
  if [ -n "$RELEASED" ]; then
    cfg=$(helm show chart mayastor --repo "$CHART_REPO" --version "$CHART_VERSION" 2>/dev/null \
      | yq -o=json '.' 2>/dev/null) || cfg=""
    heading="release"
  else
    cfg=$(crane config "$CHART_REF" 2>/dev/null) || cfg=""
    heading="staging"
  fi

  echo "## mayastor ${heading} \`${TAG}\`"
  echo

  echo "### Helm chart"
  echo
  if [ -n "$cfg" ]; then
    local cname cver cappver csize cdig clink
    cver=$(jq -r '.version // empty' <<<"$cfg")
    cappver=$(jq -r '.appVersion // empty' <<<"$cfg")
    if [ -n "$RELEASED" ]; then
      # Size + digest of the packaged chart come from the repo index.
      local idx="" ctgz=""
      idx=$(curl -fsSL "$CHART_REPO/index.yaml" 2>/dev/null) || idx=""
      if [ -n "$idx" ]; then
        cdig=$(yq -r ".entries.mayastor[] | select(.version==\"$CHART_VERSION\") | .digest // \"-\"" <<<"$idx" 2>/dev/null)
        ctgz=$(yq -r ".entries.mayastor[] | select(.version==\"$CHART_VERSION\") | .urls[0] // \"\"" <<<"$idx" 2>/dev/null)
      fi
      [ -n "$ctgz" ] && csize=$(curl -fsSLI "$ctgz" 2>/dev/null \
        | awk 'tolower($1)=="content-length:"{print $2}' | tr -d '\r')
      clink="[\`mayastor\`]($CHART_REPO)"
    else
      cname="${CHART_REF%:*}"
      csize=$(image_size "$CHART_REF")
      cdig=$(crane digest "$CHART_REF" 2>/dev/null || echo "-")
      clink="$(image_link "\`$cname\`" "$CHART_REF")"
    fi
    echo "| Chart | Version | App version | Size | Digest |"
    echo "| --- | --- | --- | --- | --- |"
    echo "| $clink | ${cver:-$CHART_VERSION} | ${cappver:-$TAG} | $(human "${csize:-0}") | \`$(short "${cdig:--}")\` |"
  elif [ -n "$RELEASED" ]; then
    echo "_Chart \`mayastor\` version \`$CHART_VERSION\` not found in \`$CHART_REPO\`._"
  else
    echo "_Chart \`$CHART_REF\` not found._"
  fi
  echo

  echo "### Mayastor images"
  echo
  # Enumerate images from the chart metadata, split into mayastor vs the rest.
  local all_images mayastor_images other_images ref
  mapfile -t all_images < <(jq -r '.annotations["helm.sh/images"] // ""' <<<"$cfg" \
    | awk '/image:/ {print $2}' | sort -u || true)
  mayastor_images=(); other_images=()
  for ref in "${all_images[@]}"; do
    if grep -qi 'mayastor' <<<"$ref"; then mayastor_images+=("$ref"); else other_images+=("$ref"); fi
  done
  images_table "No mayastor images found" "${mayastor_images[@]}"
  echo

  echo "### Dependency images"
  echo
  if [ -n "$SKIP_DEPS" ]; then
    echo "_Dependency images skipped (--skip-dependencies)._"
  else
    images_table "No dependency images found" "${other_images[@]}"
  fi
  echo

  echo "### kubectl plugin"
  echo
  local pm artifact_type psize pdig repo
  if pm=$(crane manifest "$PLUGIN_REF" 2>/dev/null); then
    artifact_type=$(jq -r '.artifactType // .config.mediaType // "-"' <<<"$pm")
    psize=$(image_size "$PLUGIN_REF")
    pdig=$(crane digest "$PLUGIN_REF" 2>/dev/null || echo "-")
    echo "| Artifact | Tag | Artifact type | Size | Digest |"
    echo "| --- | --- | --- | --- | --- |"
    echo "| $(image_link "\`kubectl-mayastor\`" "$PLUGIN_REF") | $TAG | \`$artifact_type\` | $(human "$psize") | \`$(short "$pdig")\` |"
    echo

    # --quick-bins stops here: listing per-arch binaries requires downloading and
    # extracting the bundle, which is the expensive part.
    if [ -n "$QUICK_BINS" ]; then
      echo "_Bundle contents skipped (--quick-bins)._"
      echo
      return
    fi

    # The bundle layer(s) contain per-arch archives (kubectl-mayastor-<triple>.tar.gz),
    # each wrapping the actual binary. Extract to inspect os/arch and binary size.
    repo="${PLUGIN_REF%:*}"
    local tmp rows="" i count digest archive fname triple platform
    tmp=$(mktemp -d)
    count=$(jq '.layers | length' <<<"$pm")
    for (( i=0; i<count; i++ )); do
      digest=$(jq -r ".layers[$i].digest" <<<"$pm")
      # Pipe the blob straight into tar; capturing it in a variable would strip null bytes.
      crane blob "${repo}@${digest}" 2>/dev/null | tar -xzf - -C "$tmp" 2>/dev/null || true
    done

    while IFS= read -r archive; do
      fname="${archive##*/}"
      triple="${fname%.tar.gz}"; triple="${triple#kubectl-mayastor-}"
      platform=$(platform_of_triple "$triple")

      # Inner tar: list the real binary entries with their uncompressed sizes.
      local found=""
      while IFS= read -r line; do
        case "$line" in d*|"") continue ;; esac
        local bsize bname
        bsize=$(awk '{print $3}' <<<"$line")
        bname=$(awk '{print $NF}' <<<"$line" | sed 's#^\./##')
        case "$bname" in */) continue ;; esac
        case "${bname##*/}" in kubectl-mayastor|kubectl-mayastor.exe) ;; *) continue ;; esac
        rows+="| \`${bname##*/}\` | $platform | $(human "$bsize") | $(human "$(stat -c%s "$archive" 2>/dev/null || echo 0)") |"$'\n'
        found="yes"
      done < <(tar -tzvf "$archive" 2>/dev/null || true)

      [ -z "$found" ] && rows+="| \`$fname\` | $platform | - | $(human "$(stat -c%s "$archive" 2>/dev/null || echo 0)") |"$'\n'
    done < <(find "$tmp" -type f -name '*.tar.gz' | sort)

    rm -rf "$tmp"

    if [ -n "$rows" ]; then
      echo "| Binary | OS/Arch | Binary size | Archive size |"
      echo "| --- | --- | --- | --- |"
      printf '%s' "$rows"
    else
      echo "_Could not read bundle contents._"
    fi
  else
    echo "_Plugin \`$PLUGIN_REF\` not found._"
  fi
  echo
}

# --chart dumps the Chart.yaml (the OCI config blob is Chart.yaml serialised to
# JSON) as YAML, like `helm show chart`, then exits.
if [ -n "$CHART_ONLY" ]; then
  if [ -n "$RELEASED" ]; then
    helm show chart mayastor --repo "$CHART_REPO" --version "$CHART_VERSION" 2>/dev/null || {
      echo "error: chart 'mayastor' version '$CHART_VERSION' not found in '$CHART_REPO'" >&2; exit 1;
    }
  else
    ensure_bin yq yq-go
    cfg=$(crane config "$CHART_REF" 2>/dev/null) || {
      echo "error: chart '$CHART_REF' not found" >&2; exit 1;
    }
    yq -P '.' <<<"$cfg"
  fi
  exit 0
fi

report >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
