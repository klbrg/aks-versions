#!/usr/bin/env bash
# Publishes AKS Kubernetes version availability as annotated git tags, one tag per
# (region, channel, version), plus a GitHub Release per tag for the configured streams.
#
# Annotated tags are load-bearing. A lightweight tag has no date of its own and would
# inherit the date of the commit it points at, which in a repo that only ever gains tags
# is the initial commit. Every version would look months old and silently sail through
# Renovate's minimumReleaseAge. The tagger date is the only release date available at all,
# since Azure publishes none.
#
# Releases are what make Renovate render a "Release Notes" section. It matches a release by
# `r.tag === gitRef`, and github-tags sets gitRef to the raw tag name, so a release on the
# tag matches directly.
#
# Configuration, all optional:
#   REGIONS            space separated short names. Default: every AKS region. Setting this
#                      is the main way to keep a self-hosted instance small.
#   RELEASE_STREAMS    space separated globs. Default: rapid stable patch-*
#   BACKFILL_RELEASES  auto (default), true, or false. See the note below.
#   MIN_REGIONS        sanity floor for discovery. Ignored when REGIONS is set.
#   DRY_RUN            true to resolve everything and change nothing.
#
# On backfill: a Release's publishedAt OVERWRITES the tag's tagger date in Renovate
# whenever it is later. Creating releases alongside their tags is therefore always safe,
# and backfilling releases for tags created earlier is actively harmful: it resets the
# detection date and re-arms minimumReleaseAge on versions that already soaked. The only
# safe moment to backfill is a fresh instance, which BACKFILL_RELEASES=auto detects by
# checking that the repo has no releases yet. It keys on releases rather than tags because
# a fork or clone carries every tag but no releases, so a forked instance would otherwise
# never get any. On a fork the dates do restart at the fork's first run, which is honest:
# that instance genuinely observed those versions then.
set -euo pipefail

MIN_REGIONS="${MIN_REGIONS:-40}"
DRY_RUN="${DRY_RUN:-false}"
RELEASE_STREAMS="${RELEASE_STREAMS:-rapid stable patch-*}"
BACKFILL_RELEASES="${BACKFILL_RELEASES:-auto}"
REGIONS="${REGIONS:-}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
cleanup() { rm -r "$tmp" 2>/dev/null || true; }
trap cleanup EXIT
mkdir -p "$tmp/notes"

log() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

wants_release() {
  local s="$1" w
  for w in $RELEASE_STREAMS; do
    # shellcheck disable=SC2254  # $w is intentionally a glob
    case "$s" in $w) return 0 ;; esac
  done
  return 1
}

stream_label() {
  case "$1" in
    rapid)   printf '%s' 'the current **rapid** channel target, the latest patch on the newest supported minor' ;;
    stable)  printf '%s' 'the current **stable** channel target, the latest patch on minor N-1' ;;
    patch-*) printf 'the latest patch on minor `%s`' "${1#patch-}" ;;
    *)       printf 'the current **%s** target' "$1" ;;
  esac
}

# --- regions -----------------------------------------------------------------
if [ -n "$REGIONS" ]; then
  printf '%s\n' $REGIONS | sort -u > "$tmp/regions.txt"
  log "using the $(wc -l < "$tmp/regions.txt") region(s) from REGIONS"
else
  log "discovering AKS regions"
  az provider show --namespace Microsoft.ContainerService \
    --query "resourceTypes[?resourceType=='managedClusters'].locations | [0]" \
    -o json > "$tmp/display.json"
  az account list-locations --query "[].{name:name,display:displayName}" -o json > "$tmp/locs.json"

  # The provider lists display names ("Germany West Central"); ARM wants short names.
  jq -r --slurpfile locs "$tmp/locs.json" '
    ($locs[0] | map({key: .display, value: .name}) | from_entries) as $m
    | map($m[.] // empty) | sort | .[]' "$tmp/display.json" > "$tmp/regions.txt"

  regions=$(wc -l < "$tmp/regions.txt")
  log "found $regions AKS regions"
  if [ "$regions" -lt "$MIN_REGIONS" ]; then
    log "ERROR only $regions regions (expected >= $MIN_REGIONS); refusing to publish a partial set"
    exit 1
  fi
fi

# --- existing state ----------------------------------------------------------
git ls-remote --tags origin \
  | awk '{print $2}' | sed 's|refs/tags/||; s|\^{}$||' | sort -u > "$tmp/existing.txt"
tag_count=$(wc -l < "$tmp/existing.txt")
log "repo already has $tag_count tags"

# Keyed on releases, not tags. A fork or clone carries every tag but no releases, because
# releases are GitHub metadata rather than git objects. Keying on tags would leave a forked
# instance with no release notes forever.
: > "$tmp/have_releases.txt"
release_count=0
if gh release list --limit 2000 --json tagName --jq '.[].tagName' 2>/dev/null \
     | sort -u > "$tmp/have_releases.txt"; then
  release_count=$(wc -l < "$tmp/have_releases.txt")
fi
log "repo already has $release_count releases"

case "$BACKFILL_RELEASES" in
  auto)  if [ "$release_count" -eq 0 ]; then backfill=true; else backfill=false; fi ;;
  true)  backfill=true ;;
  *)     backfill=false ;;
esac
if [ "$backfill" = "true" ]; then
  log "backfilling releases for pre-existing tags as well"
fi

git config user.name  "aks-versions-bot"
git config user.email "aks-versions-bot@users.noreply.github.com"

# --- collect -----------------------------------------------------------------
created=0
failed=0
while read -r region; do
  if ! az aks get-versions --location "$region" -o json > "$tmp/v.json" 2> "$tmp/err"; then
    log "WARN  $region: get-versions failed: $(tr -d '\n' < "$tmp/err" | cut -c1-110)"
    failed=$((failed + 1))
    continue
  fi
  while IFS='|' read -r stream version; do
    tag="${region}-${stream}-v${version}"
    is_new=true
    if grep -qxF "$tag" "$tmp/existing.txt"; then
      is_new=false
    fi

    if [ "$is_new" = "true" ]; then
      if [ "$DRY_RUN" = "true" ]; then
        log "would tag $tag"
      else
        git tag -a "$tag" \
          -m "AKS $version is the $stream target in $region (detected $(date -u +%FT%TZ))"
      fi
      created=$((created + 1))
    fi

    # A release is wanted for a new tag, or for an old one only while backfilling.
    if ! wants_release "$stream"; then continue; fi
    if [ "$is_new" != "true" ] && [ "$backfill" != "true" ]; then continue; fi
    if grep -qxF "$tag" "$tmp/have_releases.txt"; then continue; fi

    minor="${version%.*}"
    anchor="v$(printf '%s' "$version" | tr -d '.')"
    upgrades=$(jq -r --arg m "$minor" --arg v "$version" '
      .values[] | select(.version == $m) | .patchVersions[$v].upgrades // []
      | if length == 0 then "none" else join(", ") end' "$tmp/v.json")
    plan=$(jq -r --arg m "$minor" '
      .values[] | select(.version == $m) | .capabilities.supportPlan | join(", ")' "$tmp/v.json")
    label="$(stream_label "$stream")"

    cat > "$tmp/notes/$tag.md" <<NOTES
AKS offers Kubernetes \`$version\` in \`$region\`, and it is $label.

- Upstream Kubernetes changelog: https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-$minor.md#$anchor
- AKS release notes (rollout waves): https://github.com/Azure/AKS/releases

**Upgrade targets AKS permits from \`$version\`:** $upgrades

**Support plan:** $plan

AKS lags upstream, so a patch present in the Kubernetes changelog is not necessarily
offered here. Verify against \`az aks get-versions --location $region\`.
NOTES
  done < <(jq -r -f "$here/streams.jq" "$tmp/v.json")
done < "$tmp/regions.txt"

pending=$(find "$tmp/notes" -name '*.md' | wc -l)
log "new tags: $created   releases to create: $pending   regions that failed: $failed"

if [ "$DRY_RUN" = "true" ]; then
  log "dry run, nothing pushed"
  exit 0
fi

# --- publish -----------------------------------------------------------------
if [ "$created" -gt 0 ]; then
  git push origin --tags
  log "pushed $created tag(s)"
fi

# Releases must come after the push: --verify-tag requires the tag to exist on the remote.
releases=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  tag="$(basename "$f" .md)"
  if gh release create "$tag" \
       --title "${tag%-v*} ${tag##*-v}" \
       --notes-file "$f" \
       --verify-tag >/dev/null 2>"$tmp/relerr"; then
    releases=$((releases + 1))
  else
    log "WARN  release for $tag failed: $(tr -d '\n' < "$tmp/relerr" | cut -c1-110)"
  fi
done < <(find "$tmp/notes" -name '*.md')
log "created $releases release(s)"

if [ "$created" -eq 0 ] && [ "$releases" -eq 0 ]; then
  log "nothing to do"
fi
