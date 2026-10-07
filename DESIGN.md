# Design notes

Why `aks-versions` works the way it does. The [README](README.md) covers what it publishes and
how to consume it. This file is the reasoning, and the traps that are not obvious from the
code.

## Contents

- [Streams](#streams)
- [Why the tag dates matter](#why-the-tag-dates-matter)
- [Staging](#staging)
- [Legal upgrade paths](#legal-upgrade-paths)
- [Gotchas](#gotchas)

## Streams

Tags come as `<region>-<channel>-v<version>` and, for versions available everywhere, as
`<channel>-v<version>`. Channels mirror the AKS autoupgrade channels: `rapid` is the latest GA
patch on the newest supported minor, `stable` the latest on minor N-1, `patch-<minor>` the
latest on one minor. Preview minors are never tagged, because autoupgrade never targets them.
GA minors carry `isPreview: null` rather than `false`, so the filter is `!= true`.

56 regions times roughly 8 streams is about 450 tags at steady state, growing near 4,700 a year
at the observed cadence of 1.3 patches per supported minor per month. `REGIONS` is the lever
that controls this and the main reason to set it.

### Regionless streams

AKS rolls patches out region by region, so at any moment some regions lag. A single version
string shared across regions must therefore be the **lowest** of the per-region heads, or it
fails to apply in the laggard. That is what the regionless streams publish, over the regions
this instance tracks.

Two guards, both for the same failure: AKS adds regions, and a new region offering an older
patch would otherwise set the value for everyone.

- **A grace period.** A region is ignored until tracked for `REGION_GRACE_DAYS`, measured from
  its oldest tag. The rule applies only once the **instance** is older than the grace period;
  while it is younger every region counts, since otherwise a bootstrap publishes nothing.
- **Monotonicity.** A regionless tag is created only when the candidate is higher than the
  current head, so a lagging region cannot add a backwards tag dated today.

A stall is still possible once a region is past its grace period and genuinely behind. That is
the stream being honest, and the run logs which region is responsible. A stream is skipped
entirely, rather than guessed at, when a tracked region does not offer that minor.

## Why the tag dates matter

The tag date is the only release date available. Azure publishes none, not in the ARM response
and not in the release tracker, so "when did this patch appear in my region" exists nowhere
except as the moment this job first saw it.

**Tags must therefore be annotated.** A lightweight tag has no date of its own and inherits the
date of the commit it points at, which in a repo that only ever gains tags is the initial
commit. Every version would look months old and sail through `minimumReleaseAge` with no error
and no warning. There is a second, independent reason: Renovate's `minimumReleaseAgeBehaviour`
defaults to `timestamp-required`.

**Releases must be created alongside their tags.** A release's `publishedAt` overwrites the
tag's tagger date in Renovate whenever it is later, so backfilling a release for an older tag
resets the detection date and re-arms the soak on a version that already soaked. Creating both
together is always safe.

`BACKFILL_RELEASES=auto` therefore keys on the repo having **no releases**, not no tags,
because a clone or a fork carries every tag but no releases. Keying on tags would leave a
forked instance with no release notes forever.

### Release notes

`github-tags` derives `sourceUrl` from `packageName`, so Renovate looks for changelogs in this
repo. It matches a release by `r.tag === gitRef`, and the tags adapter sets `gitRef` to the raw
tag name, so a release on `swedencentral-stable-v1.35.8` matches before `extractVersion` strips
the prefix.

Renovate also needs **two** versions spanning current to new, or it logs
`Not enough valid releases` and never reaches the matcher. That is self-satisfying in steady
state, because a consumer's pin came from the same stream; only the first adoption misses out.

## Staging

Two ways to roll a version through environments in order, both keeping the exact patch in the
config and both giving a reviewed PR per stage.

**Time-based.** Every stage tracks the same stream with a different `minimumReleaseAge`.
Measured: with the source tag dated that morning, the dev dependency was releasable while the
prod one carried `pendingChecks: true` under a five-day soak. Each stage needs its own
`depName`, or Renovate treats them as one dependency and a single rule cannot give them
different ages.

It is a timer, not a gate. Nothing verifies the earlier stage succeeded, so if dev's apply
failed, prod's clock runs anyway.

**Success-based.** After a stage applies, its CI pushes an annotated tag recording what it
applied, and the next stage tracks that tag instead of the upstream stream. A version then
cannot reach prod until it ran in test, and each stage's soak is measured from when that stage
adopted it. Those applied-tags must be annotated for the same reason the ones here are.

Neither performs the upgrade, respects a maintenance window, touches node images, or controls
surge. Those belong to whatever applies the config.

## Legal upgrade paths

AKS permits a version to move within its own minor and one minor forward. Inside standard
support that is the whole rule; a minor that has fallen to `AKSLongTermSupport` may jump
several minors at once to get back inside the support window, so the cost of falling behind is
not linear.

Renovate cannot derive this, but it can be told, in one rule with nothing hardcoded:

```json
{ "allowedVersions": "<{{{major}}}.{{add minor 2}}.0" }
```

`allowedVersions` carries `supportsTemplating: true` and Renovate ships an `add` helper, so the
bound comes from whatever version the file holds. Measured with one rule across two fixtures:
from 1.34.5 it blocked a 1.36.4 proposal, and from 1.35.0 it allowed 1.36.4. Without it, the
two-minor jump was proposed with `updateType: minor`.

**The guard is not what strands a lagging cluster.** A cluster two minors behind following
`rapid` can never legally reach anything in that stream, so it gets nothing, with
`updates: []` and no warning. Point it at `stable` or its own `patch-<minor>` and it climbs. So
the marker is not set once and forgotten: a lagging consumer follows `stable` or
`patch-<minor>` until it catches up.

Downgrades are blocked outright, with `rollbackPrs: false` plus a rule disabling the `rollback`
update type. AKS never permits one: across all 403 upgrade edges in the payload, every target
is strictly higher than its source. The cost is silence, since a dependency pinned above its
stream then produces no PR and no warning.

## Gotchas

Each of these cost real time and none is visible from the code.

- **`--platform=local` reads committed content, not the working tree.** Uncommitted fixtures
  are invisible, which looks exactly like a broken regex.
- **Renovate reads repo config from the default branch.** A `renovate.json` on a feature branch
  is ignored, Renovate decides the repo is not onboarded, and the onboarding config silently
  replaces your managers. `--use-base-branch-config=branch` does not change this.
- **`--platform=local` never builds a PR body**, so it cannot validate `prBodyNotes`. Use
  `--platform=github --dry-run=full`, and note that even then Renovate stops after committing
  to the branch and never calls `ensurePr`, so only a real PR proves the body.
- **`allowedVersions` appears in both `exposedConfigOptions` and `supportsTemplating`.** Only
  the second means templated; the source comment says the lists are distinct.
- **An arbitrary capture group reaches the templates.** `stream` is not one of Renovate's
  `validMatchFields` and still interpolates, which is what lets one manager serve every stream.
- **Two-part versions need `loose` versioning.** `1.35` is not valid semver.
- **The first version on the marked line wins.** `image: foo:1.2.3 # aks 1.36.4` captures
  `1.2.3`.
- **A format with no comment syntax cannot carry a marker.** ARM template JSON is the common
  case; use a path-based manager there, which needs no marker.
- **A comment cannot sit inside a shell `\` continuation.** Assign the version to a variable
  first, which is better practice anyway.
- **`npx renovate@latest` broke mid-session** with `No matching version found` for the very
  version the registry reported as `latest`. Pin a version in CI.
