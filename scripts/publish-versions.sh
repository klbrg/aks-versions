#!/usr/bin/env bash
# Publishes AKS Kubernetes version availability two ways:
#
#   1. versions/<region>.json  committed, so `git log` is an audit trail of how version
#      availability moved over time. The files carry no timestamp on purpose: the commit
#      date is the timestamp, so a file changes only when Azure's answer changes and the
#      history shows real transitions instead of one empty commit per day.
#
#   2. annotated git tags, one per (region, channel, version), for Renovate to consume
#      via the github-tags datasource. Annotated is load-bearing: a lightweight tag has
#      no date of its own and would inherit the commit date it points at, which would
#      silently defeat Renovate's minimumReleaseAge.
#
# Snapshots are committed before tags are created, so each tag points at the commit that
# recorded the data it describes.
set -euo pipefail

MIN_REGIONS="${MIN_REGIONS:-40}"
DRY_RUN="${DRY_RUN:-false}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
tmp="$(mktemp -d)"
cleanup() { rm -r "$tmp" 2>/dev/null || true; }
trap cleanup EXIT

log() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

cd "$repo"

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

# Fetch the remote tag list once rather than per region.
git ls-remote --tags origin \
  | awk '{print $2}' | sed 's|refs/tags/||; s|\^{}$||' | sort -u > "$tmp/existing.txt"
log "repo already has $(wc -l < "$tmp/existing.txt") tags"

git config user.name  "aks-versions-bot"
git config user.email "aks-versions-bot@users.noreply.github.com"

mkdir -p versions
: > "$tmp/desired.txt"

failed=0
while read -r region; do
  if ! az aks get-versions --location "$region" -o json > "$tmp/v.json" 2> "$tmp/err"; then
    log "WARN  $region: get-versions failed: $(tr -d '\n' < "$tmp/err" | cut -c1-110)"
    failed=$((failed + 1))
    continue
  fi

  # -S sorts keys so the committed diff is stable across runs.
  jq -S --arg region "$region" -f "$here/snapshot.jq" "$tmp/v.json" > "versions/$region.json"

  while IFS='|' read -r stream version; do
    printf '%s|%s|%s\n' "$region" "$stream" "$version" >> "$tmp/desired.txt"
  done < <(jq -r -f "$here/streams.jq" "$tmp/v.json")
done < "$tmp/regions.txt"

# --- snapshots ---------------------------------------------------------------
git add versions
if git diff --cached --quiet; then
  log "snapshots unchanged"
  committed=false
else
  changed=$(git diff --cached --name-only | wc -l)
  if [ "$DRY_RUN" = "true" ]; then
    log "would commit $changed changed snapshot(s):"
    git diff --cached --name-only | sed 's/^/    /' >&2
    committed=false
  else
    git commit -q -m "chore: refresh AKS version snapshots ($changed region(s) changed)"
    log "committed $changed changed snapshot(s)"
    committed=true
  fi
fi

# --- tags --------------------------------------------------------------------
created=0
while IFS='|' read -r region stream version; do
  tag="${region}-${stream}-v${version}"
  if grep -qxF "$tag" "$tmp/existing.txt"; then
    continue
  fi
  if [ "$DRY_RUN" = "true" ]; then
    log "would tag $tag"
  else
    git tag -a "$tag" \
      -m "AKS $version is the $stream target in $region (detected $(date -u +%FT%TZ))"
  fi
  created=$((created + 1))
done < "$tmp/desired.txt"

log "new tags: $created   regions that failed: $failed"

if [ "$DRY_RUN" = "true" ]; then
  log "dry run, nothing committed or pushed"
  exit 0
fi

if [ "$committed" = "true" ]; then
  git push -q origin HEAD:main
  log "pushed snapshot commit"
fi
if [ "$created" -gt 0 ]; then
  git push -q origin --tags
  log "pushed $created tag(s)"
fi
if [ "$committed" != "true" ] && [ "$created" -eq 0 ]; then
  log "nothing to push"
fi
