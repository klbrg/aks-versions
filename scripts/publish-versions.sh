#!/usr/bin/env bash
# Publishes AKS Kubernetes version availability as annotated git tags, one tag per
# (region, channel, version). Annotated is load-bearing: a lightweight tag has no
# date of its own and would inherit this repo's last commit date, which would make
# every version look months old and silently defeat Renovate's minimumReleaseAge.
set -euo pipefail

MIN_REGIONS="${MIN_REGIONS:-40}"
DRY_RUN="${DRY_RUN:-false}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
cleanup() { rm -r "$tmp" 2>/dev/null || true; }
trap cleanup EXIT

log() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

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
    grep -qxF "$tag" "$tmp/existing.txt" && continue
    if [ "$DRY_RUN" = "true" ]; then
      log "would tag $tag"
    else
      git tag -a "$tag" -m "AKS $version is the $stream target in $region (detected $(date -u +%FT%TZ))"
    fi
    created=$((created + 1))
  done < <(jq -r -f "$here/streams.jq" "$tmp/v.json")
done < "$tmp/regions.txt"

log "new tags: $created   regions that failed: $failed"

if [ "$DRY_RUN" = "true" ]; then
  log "dry run, nothing pushed"
  exit 0
fi
if [ "$created" -eq 0 ]; then
  log "nothing new to push"
  exit 0
fi

git push origin --tags
log "pushed"
