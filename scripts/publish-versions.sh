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
STANDARD_SUPPORT_ONLY="${STANDARD_SUPPORT_ONLY:-false}"
# Days a newly appeared region must be tracked before it can bind the regionless streams.
REGION_GRACE_DAYS="${REGION_GRACE_DAYS:-30}"

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

# Writes the release body for one tag. $4 is a region for a per-region stream, or the
# literal "all" for a regionless one, in which case $5 is the binding region.
write_notes() {
  local tag="$1" stream="$2" version="$3" region="$4" binding="${5:-}"
  local minor="${version%.*}"
  local anchor="v$(printf '%s' "$version" | tr -d '.')"
  local changelog="https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-$minor.md#$anchor"
  local label; label="$(stream_label "$stream")"

  if [ "$region" = "all" ]; then
    cat > "$tmp/notes/$tag.md" <<NOTES
Kubernetes \`$version\` is available in **every one of the $mature_total regions this
instance counts**, and it is $label.

The binding constraint is \`$binding\`, the slowest tracked region to offer it. Pin this
stream when several clusters in different regions must share one version string.

- Upstream Kubernetes changelog: $changelog
- AKS release notes (rollout waves): https://github.com/Azure/AKS/releases

Per-region tags carry the upgrade graph and support plan, which are region specific.
NOTES
    return
  fi

  local upgrades plan
  upgrades=$(jq -r --arg m "$minor" --arg v "$version" '
    .values[] | select(.version == $m) | .patchVersions[$v].upgrades // []
    | if length == 0 then "none" else join(", ") end' "$tmp/v.json")
  plan=$(jq -r --arg m "$minor" '
    .values[] | select(.version == $m) | .capabilities.supportPlan | join(", ")' "$tmp/v.json")

  cat > "$tmp/notes/$tag.md" <<NOTES
AKS offers Kubernetes \`$version\` in \`$region\`, and it is $label.

- Upstream Kubernetes changelog: $changelog
- AKS release notes (rollout waves): https://github.com/Azure/AKS/releases

**Upgrade targets AKS permits from \`$version\`:** $upgrades

**Support plan:** $plan

AKS lags upstream, so a patch present in the Kubernetes changelog is not necessarily
offered here. Verify against \`az aks get-versions --location $region\`.
NOTES
}

git config user.name  "aks-versions-bot"
git config user.email "aks-versions-bot@users.noreply.github.com"

# --- collect -----------------------------------------------------------------
created=0
failed=0
: > "$tmp/observed.txt"
while read -r region; do
  if ! az aks get-versions --location "$region" -o json > "$tmp/v.json" 2> "$tmp/err"; then
    log "WARN  $region: get-versions failed: $(tr -d '\n' < "$tmp/err" | cut -c1-110)"
    failed=$((failed + 1))
    continue
  fi
  while IFS='|' read -r stream version; do
    printf '%s|%s|%s\n' "$stream" "$version" "$region" >> "$tmp/observed.txt"
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

    write_notes "$tag" "$stream" "$version" "$region"
  done < <(jq -r --argjson standard_only "${STANDARD_SUPPORT_ONLY:-false}" -f "$here/streams.jq" "$tmp/v.json")
done < "$tmp/regions.txt"

# --- regionless streams ------------------------------------------------------
# For each stream, the lowest version across the tracked regions, i.e. the newest version
# actually available everywhere. Two guards, both for the same failure mode: AKS adds
# regions, and a brand new region offering an older patch would otherwise set the value for
# everyone and stall the stream on a region nobody uses.
#
#   1. A region is excluded until it has been tracked for REGION_GRACE_DAYS, measured from
#      its oldest tag. A newly appeared region therefore cannot bind the intersection
#      before it has had a fair chance to catch up. A bootstrap is exempt, since on a
#      bootstrap every region is new and excluding them all would emit nothing.
#   2. A tag is only created when the candidate is HIGHER than the current stream head, so
#      the stream is monotonic. Without this, a lagging region would add a backwards tag
#      dated today, which is noise at best.
#
# A stall is still possible once a region is past its grace period and genuinely behind.
# That is the stream being honest. The binding region is logged every run so it is visible.
: > "$tmp/mature.txt"
if [ "$tag_count" -eq 0 ]; then
  cp "$tmp/regions.txt" "$tmp/mature.txt"
  log "bootstrap: every region counts toward the regionless streams"
else
  cutoff=$(( $(date -u +%s) - REGION_GRACE_DAYS * 86400 ))
  git for-each-ref --format='%(refname:short) %(taggerdate:unix)' refs/tags \
    | awk -v cutoff="$cutoff" '
        { split($1, p, "-"); if (p[1] != "" && $2 != "") {
            if (!(p[1] in oldest) || $2 + 0 < oldest[p[1]]) oldest[p[1]] = $2 + 0 } }
        END { for (r in oldest) if (oldest[r] <= cutoff) print r }' \
    | sort -u > "$tmp/seen_mature.txt"
  comm -12 "$tmp/regions.txt" "$tmp/seen_mature.txt" > "$tmp/mature.txt"
  excluded=$(( $(wc -l < "$tmp/regions.txt") - $(wc -l < "$tmp/mature.txt") ))
  if [ "$excluded" -gt 0 ]; then
    log "excluding $excluded region(s) from the regionless streams: tracked for under $REGION_GRACE_DAYS days"
  fi
fi

mature_total=$(wc -l < "$tmp/mature.txt")
if [ "$mature_total" -gt 0 ]; then
  awk -F'|' 'NR==FNR { keep[$1]; next } ($3 in keep)' "$tmp/mature.txt" "$tmp/observed.txt" \
    > "$tmp/observed_mature.txt"
  while IFS='|' read -r stream version binding count; do
    [ "$count" -eq "$mature_total" ] || continue
    head_now="$(git tag --list "${stream}-v*" | sed "s|^${stream}-v||" | sort -V | tail -1)"
    if [ -n "$head_now" ] && [ "$head_now" = "$(printf '%s\n%s\n' "$head_now" "$version" | sort -V | tail -1)" ] \
       && [ "$head_now" != "$version" ]; then
      log "regionless $stream stalls at $head_now: $binding only offers $version"
      continue
    fi
    tag="${stream}-v${version}"
    if grep -qxF "$tag" "$tmp/existing.txt"; then
      is_new=false
    else
      is_new=true
      if [ "$DRY_RUN" = "true" ]; then
        log "would tag $tag (available in all $mature_total regions, bound by $binding)"
      else
        git tag -a "$tag" \
          -m "Kubernetes $version is the $stream target in all $mature_total tracked regions, bound by $binding (detected $(date -u +%FT%TZ))"
      fi
      created=$((created + 1))
    fi
    if ! wants_release "$stream"; then continue; fi
    if [ "$is_new" != "true" ] && [ "$backfill" != "true" ]; then continue; fi
    if grep -qxF "$tag" "$tmp/have_releases.txt"; then continue; fi
    write_notes "$tag" "$stream" "$version" "all" "$binding"
  done < <(sort "$tmp/observed_mature.txt" | awk -F'|' '
      { if (!(($1) in best) || cmp($2, best[$1]) < 0) { best[$1] = $2; who[$1] = $3 }
        n[$1]++ }
      function cmp(a, b,   x, y, i) {
        split(a, x, "."); split(b, y, ".")
        for (i = 1; i <= 3; i++) { if (x[i] + 0 < y[i] + 0) return -1
                                   if (x[i] + 0 > y[i] + 0) return 1 }
        return 0
      }
      END { for (st in best) printf "%s|%s|%s|%d\n", st, best[st], who[st], n[st] }')
fi

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
       --verify-tag --latest=false >/dev/null 2>"$tmp/relerr"; then
    releases=$((releases + 1))
  else
    log "WARN  release for $tag failed: $(tr -d '\n' < "$tmp/relerr" | cut -c1-110)"
  fi
done < <(find "$tmp/notes" -name '*.md')
log "created $releases release(s)"

# Designate a meaningful "Latest". GitHub always picks one and offers no way to opt out;
# left alone it compares dates and semver across every region's tag namespace and lands
# somewhere arbitrary. The regionless rapid head is the one genuinely canonical summary:
# the newest GA version available in every tracked region.
latest_tag="$(git tag --list 'rapid-v*' | sed 's|^rapid-v||' | sort -V | tail -1)"
if [ -n "$latest_tag" ]; then
  if gh release edit "rapid-v${latest_tag}" --latest >/dev/null 2>&1; then
    log "marked rapid-v${latest_tag} as the latest release"
  fi
fi

if [ "$created" -eq 0 ] && [ "$releases" -eq 0 ]; then
  log "nothing new to publish"
fi
