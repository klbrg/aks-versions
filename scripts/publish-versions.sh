#!/usr/bin/env bash
# Publishes AKS Kubernetes version availability as annotated git tags, one tag per
# (region, channel, version), plus a GitHub Release for the rapid and stable streams.
#
# Annotated tags are load-bearing. A lightweight tag has no date of its own and would
# inherit the date of the commit it points at, which in a repo that only ever gains tags
# is the initial commit. Every version would look months old and silently sail through
# Renovate's minimumReleaseAge. The tagger date is the only release date available at all,
# since Azure publishes none.
#
# The Releases are what make Renovate render a "Release Notes" section in its PRs.
# Renovate matches a release by `r.tag === gitRef`, and github-tags sets gitRef to the raw
# tag name, so a release on the tag matches directly. Only rapid and stable get one:
# patch-<minor> streams never cross a minor, so their notes would never be read. Releases
# are created only for newly created tags, so there is no backfill for the tags that
# already exist.
#
# Note on Renovate's side: it needs two versions in a stream spanning current -> new before
# it will fetch notes at all. That is self-satisfying once a consumer follows a stream,
# because its pin came from that stream. Only the first adoption of a stream misses out.
set -euo pipefail

MIN_REGIONS="${MIN_REGIONS:-40}"
DRY_RUN="${DRY_RUN:-false}"
RELEASE_STREAMS="${RELEASE_STREAMS:-rapid stable}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
cleanup() { rm -r "$tmp" 2>/dev/null || true; }
trap cleanup EXIT
mkdir -p "$tmp/notes"

log() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

wants_release() {
  local s="$1" w
  for w in $RELEASE_STREAMS; do [ "$s" = "$w" ] && return 0; done
  return 1
}

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

    if wants_release "$stream"; then
      minor="${version%.*}"
      anchor="v$(printf '%s' "$version" | tr -d '.')"
      upgrades=$(jq -r --arg m "$minor" --arg v "$version" '
        .values[] | select(.version == $m) | .patchVersions[$v].upgrades // []
        | if length == 0 then "none" else join(", ") end' "$tmp/v.json")
      plan=$(jq -r --arg m "$minor" '
        .values[] | select(.version == $m) | .capabilities.supportPlan | join(", ")' "$tmp/v.json")

      cat > "$tmp/notes/$tag.md" <<NOTES
AKS offers Kubernetes \`$version\` in \`$region\`, and it is the current **$stream** channel target.

- Upstream Kubernetes changelog: https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-$minor.md#$anchor
- AKS release notes (rollout waves): https://github.com/Azure/AKS/releases

**Upgrade targets AKS permits from \`$version\`:** $upgrades

**Support plan:** $plan

Detected on first appearance in this region. AKS lags upstream, so a patch present in the
Kubernetes changelog is not necessarily offered here.
NOTES
    fi
  done < <(jq -r -f "$here/streams.jq" "$tmp/v.json")
done < "$tmp/regions.txt"

pending_notes=$(find "$tmp/notes" -name '*.md' | wc -l)
log "new tags: $created   releases to create: $pending_notes   regions that failed: $failed"

if [ "$DRY_RUN" = "true" ]; then
  log "dry run, nothing pushed"
  exit 0
fi
if [ "$created" -eq 0 ]; then
  log "nothing new to push"
  exit 0
fi

git push origin --tags
log "pushed $created tag(s)"

# Releases must come after the push: --verify-tag requires the tag to exist on the remote.
releases=0
while IFS= read -r f; do
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
