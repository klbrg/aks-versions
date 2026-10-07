# aks-versions

[![publish](https://github.com/klbrg/aks-versions/actions/workflows/publish-versions.yml/badge.svg)](https://github.com/klbrg/aks-versions/actions/workflows/publish-versions.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Publishes the Kubernetes versions AKS offers per region as git tags, so Renovate can track them.

Renovate has no AKS datasource, and no public feed lists patch versions per region. The only
authoritative source is the ARM call behind `az aks get-versions`, which requires
authentication. This repo runs it hourly across every AKS region and republishes the result as
annotated git tags and GitHub Releases. Renovate reads those with its built-in `github-tags`
datasource and needs no Azure credential of its own.

Point Renovate at this instance, or run your own from the template.

## Table of Contents

- [Security](#security)
- [Background](#background)
- [Install](#install)
- [Configuration](#configuration)
- [The publishing workflow](#the-publishing-workflow)
- [Usage](#usage)
- [How it works](#how-it-works)
- [Staging](#staging)
- [Gotchas](#gotchas)
- [Maintainers](#maintainers)
- [Contributing](#contributing)
- [License](#license)

## Security

A wrong tag causes a failed deployment, not a compromise. AKS rejects a version it does not
offer, so the blast radius is availability.

Nothing published here is secret. Tags and releases contain only version numbers that
`az aks get-versions` returns to any authenticated caller. The publishing identity holds
`Reader` on one subscription, trusts one repository and one branch, and has no client secret
to leak.

Keep `minimumReleaseAge` set and read the PR. If you would rather not depend on someone
else's repo for your control-plane versions, self-host.

## Background

AKS auto-upgrade channels patch clusters for you. What they do not give you is control over
when a patch lands, a soak period before it does, a review step, or a record of what moved.
Tracking the version as a dependency gives all four, and costs you a pipeline that has to
actually run.

A channel also rewrites the version your declarative config pinned, which appears as drift on
the next plan. The exception is a minor alias such as `1.36` combined with the `patch`
channel: the alias absorbs patch moves, the running patch is reported separately, and nothing
drifts. That combination is Microsoft's own recommendation and needs none of this.

This is not a complete patching strategy on its own:

- Keep node-image auto-upgrade (`NodeImage`) enabled. Most CVE exposure is in the node image,
  and Renovate cannot see it.
- It fails open. An unmerged PR means an unpatched cluster while every dashboard looks green.
  Pair it with a check that compares running versions against the stream head.

## Install

Nothing to install to consume this repo. See [Usage](#usage).

To run your own instance, use this repository as a template, then:

1. Read the OIDC subject your repository sends:
   `gh api repos/OWNER/REPO/actions/oidc/customization/sub`. If `use_immutable_subject` is
   `true`, the subject form in Microsoft's docs will not match, and auth fails at run time
   with no hint at setup time.
2. Create a user-assigned managed identity and a federated credential for that subject.
3. Grant it `Reader` at subscription scope.
4. Set the secrets `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`.
5. Set the repository variable `REGIONS`. See [Configuration](#configuration).

```bash
# 2 and 3: a managed identity, trust for that subject, and read access
az group create -n rg-aks-versions -l swedencentral
az identity create -n id-aks-versions -g rg-aks-versions \
  --query '{clientId:clientId,principalId:principalId}'
az identity federated-credential create --name github-main \
  --identity-name id-aks-versions -g rg-aks-versions \
  --issuer https://token.actions.githubusercontent.com \
  --subject '<the subject from step 1>' --audiences api://AzureADTokenExchange
az role assignment create --assignee-object-id <principalId> \
  --assignee-principal-type ServicePrincipal --role Reader \
  --scope /subscriptions/<sub> --subscription <sub>
```

`Reader` at subscription scope is the least privilege that works:
`az provider operation show --namespace Microsoft.ContainerService` lists no discrete action
for `locations/kubernetesVersions`. Use `--assignee-object-id`, not `--assignee`, whose Graph
lookup often fails for a fresh identity.

## Configuration

Everything is optional. Set these as repository variables under
Settings > Secrets and variables > Actions > Variables. The defaults live in
`scripts/publish-versions.sh`, and an unset or empty variable falls back to them.

| Variable | Default | Accepts | What it does |
|---|---|---|---|
| `REGIONS` | every AKS region | space separated short names, e.g. `swedencentral northeurope` | Limits what gets tagged. The main lever on repo size, and what gives the regionless streams a useful meaning. Strongly recommended. |
| `RELEASE_STREAMS` | `rapid stable patch-*` | space separated globs | Which streams also get a GitHub Release. Releases are what carry release notes into the PR body. |
| `BACKFILL_RELEASES` | `auto` | `auto`, `true`, `false` | `auto` creates releases for pre-existing tags only on a bootstrap, keyed on the repo having no releases. See [Why the tag dates matter](#why-the-tag-dates-matter) before setting `true`. |
| `REGION_GRACE_DAYS` | `30` | integer days | How long a newly seen region is ignored before it may bind a regionless stream. |
| `STANDARD_SUPPORT_ONLY` | `false` | `true`, `false` | `true` drops `patch-<minor>` streams for minors that have left standard support. |
| `MIN_REGIONS` | `40` | integer | Sanity floor on region discovery. Below it the run fails rather than publish a partial set. Ignored when `REGIONS` is set. |
| `DRY_RUN` | `false` | `true`, `false` | Resolve everything and change nothing. Normally used as the `dryRun` dispatch input. |

`REGIONS` is worth setting for three reasons: 56 regions times roughly 8 streams is about 450
tags at steady state, growing near 4,700 a year at the observed cadence of 1.3 patches per
supported minor per month; the regionless streams are an intersection, so they only mean
something over regions you actually deploy to; and a stalled region then only affects you if
you care about it.

## The publishing workflow

`.github/workflows/publish-versions.yml` is the whole moving part.

**Triggers.** `schedule` at `23 * * * *`, so hourly, plus `workflow_dispatch` with three
inputs: `dryRun`, `regions` and `backfill`. A dispatch input overrides the matching repository
variable for that one run, which is the intended way to test a change before it runs
unattended.

Hourly because the publish interval is the one setting a consumer cannot tune. Everything else
about consumption is theirs to choose, but pointing Renovate at an hourly schedule against a
feed that updates once a day gains them nothing, so the interval has to suit the consumer who
runs no soak and wants a patch as soon as it exists. A soak of days makes the interval
irrelevant, which is an argument for the shorter one, not the longer.

It is cheap enough to stop thinking about: a steady-state run is about 95 seconds and 56 ARM
reads, and Actions minutes are free on a public repository. The run is idempotent, so the
hours that find nothing create nothing and leave existing tag dates untouched.

Minute 23 rather than the hour because GitHub's scheduled queue is best effort and the top of
the hour is its busiest slot. Running hourly also makes that unreliability self-healing: a
dropped run costs an hour, where a dropped daily run costs a day.

Self-hosting for one estate is a different problem from serving a shared feed. If every
consumer is yours and soaks for days, once or twice a day is plenty, and the comment in the
workflow says so.

**Permissions.** `contents: write` to push tags and create releases, `id-token: write` to mint
the OIDC token for `azure/login`. No other scope, and no long-lived credential. `concurrency`
pins the job to one run at a time with `cancel-in-progress: false`, so a dispatch during the
nightly run queues instead of leaving tags half pushed.

**Steps.** `actions/checkout` with `fetch-depth: 0`, because the script compares against
existing tags. Then `azure/login` by OIDC. Then one `run` of `scripts/publish-versions.sh`,
with the configuration above passed as environment variables. Both actions are pinned by
commit SHA with the version in a trailing comment.

A fourth step keeps the schedule alive. GitHub disables scheduled workflows in a public
repository after 60 days with no repository activity, and only commits count as activity: the
tags and releases this job creates do not. A repo that only ever gains tags therefore switches
its own schedule off about two months after the last human commit, and the only warning is an
email. The step pushes an empty commit once the newest commit passes 50 days, which resets the
clock with 10 days to spare. It runs only on the `schedule` event, since a dispatch already
means someone is active, and a failed push is logged rather than fatal, because hundreds of
hourly attempts remain and a successful publish should not be marked failed. One caveat: this
assumes a `GITHUB_TOKEN` commit counts as activity, which is how the widely used keepalive
actions work but is not something this repo has yet observed across a full 60 day window.

What the script does, in the order the log shows it:

1. **Regions.** Use `REGIONS` if set. Otherwise discover them from
   `az provider show --namespace Microsoft.ContainerService`, map the provider's display names
   to short names via `az account list-locations`, and fail if fewer than `MIN_REGIONS` come
   back.
2. **Existing state.** Count tags and releases, fetch remote tags once, and decide whether this
   run is a bootstrap for the purposes of `BACKFILL_RELEASES=auto`.
3. **Collect.** Call `az aks get-versions` per region and reduce each response to
   `<stream>|<version>` lines with `scripts/streams.jq`. A region that fails logs a `WARN` and
   is skipped; it does not fail the run.
4. **Regionless streams.** Intersect the per-region heads, apply the grace period and the
   monotonicity check, and log which region binds or stalls each stream.
5. **Publish.** Push the new annotated tags, create releases for `RELEASE_STREAMS`, and mark
   `rapid-v<head>` as the latest release. `DRY_RUN=true` stops before this and logs what it
   would have done.

The run is idempotent. A tag that already exists is left alone, including its date, so a
re-run never re-arms a soak.

## Usage

Tags come in two shapes:

```
<region>-<channel>-v<version>     per region
<channel>-v<version>              available in every tracked region
```

Channels mirror the AKS autoupgrade channels. `rapid` is the latest patch on the newest
supported minor, `stable` the latest patch on minor N-1, and `patch-<minor>` the latest patch
on one specific minor.

### Marking a version

Mark any line that holds a version. The marker is a comment, so its syntax is whatever the
file already uses:

```
# renovate: aks-stream=swedencentral-stable
version: 1.35.8
```

One custom manager reads every marker:

```json
{
  "rollbackPrs": false,
  "customManagers": [
    {
      "customType": "regex",
      "managerFilePatterns": ["/\\.(tf|ya?ml|bicep)$/"],
      "matchStrings": [
        "(?:#|//|;)\\s*renovate:\\s*aks-stream=(?<depName>(?:[a-z0-9]+-)?(?:rapid|stable|patch-\\d+\\.\\d+))[ \\t]*\\n[^\\n]*?(?<currentValue>\\d+\\.\\d+\\.\\d+)"
      ],
      "packageNameTemplate": "klbrg/aks-versions",
      "datasourceTemplate": "github-tags",
      "extractVersionTemplate": "^{{{depName}}}-v(?<version>.+)$",
      "versioningTemplate": "semver"
    }
  ]
}
```

Renovate matches text, not a particular language. The rule is just that the version sits on
the line below the marker, which has been verified against Terraform, Terragrunt, Bicep,
Pulumi, CDKTF, Azure Service Operator, Crossplane, Helm, Ansible, GitHub Actions, Azure
Pipelines, Make, shell, ini and `az aks create`. Adjust `managerFilePatterns` to your files.

Two cases need a different approach: formats without comments, such as ARM template JSON, and
shell line continuations. Both are in [Gotchas](#gotchas).

Working fixtures for every pattern below live in `examples/consumer/`.

### Picking a stream

`extractVersionTemplate` is the selector. One manager per region and channel, or one marker per
line with `aks-stream=<region>-<channel>`. Omit the region for a regionless stream. To track a
minor rather than a patch, use `aks-minor=<channel>` instead, which reads only `major.minor`
and needs `"versioning": "loose"` because a two-part version is not valid semver.

A path-based manager, with `depNameTemplate` set and no marker, is the alternative when the
file format has no comment syntax, ARM template JSON being the common case.

### Rules worth setting

```json
{
  "minimumReleaseAge": "5 days",
  "rollbackPrs": false,
  "packageRules": [
    { "matchUpdateTypes": ["rollback"], "enabled": false },
    { "allowedVersions": "<{{{major}}}.{{add minor 2}}.0" }
  ]
}
```

The soak is what the tag dates exist for. The rollback block matters because AKS never permits
a downgrade, and a version pinned above its stream would otherwise attract a rollback PR.
The `allowedVersions` rule stops Renovate proposing a minor jump AKS would refuse.

### Legal upgrade paths

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

Downgrades are blocked outright by the two rules above. AKS never permits one: across all 403
upgrade edges in the payload, every target is strictly higher than its source. The cost is
silence, since a dependency pinned above its stream then produces no PR and no warning.

### Release notes

`github-tags` derives `sourceUrl` from `packageName`, so Renovate looks for changelogs in this
repo. It matches a release by `r.tag === gitRef`, and the tags adapter sets `gitRef` to the raw
tag name, so a release on `swedencentral-stable-v1.35.8` matches before `extractVersion` strips
the prefix.

Renovate also needs **two** versions spanning current to new, or it logs
`Not enough valid releases` and never reaches the matcher. That is self-satisfying in steady
state, because a consumer's pin came from the same stream; only the first adoption misses out.

## How it works

### Streams

Channels mirror the AKS autoupgrade channels, computed from the ARM response by
`scripts/streams.jq`. Preview minors are never tagged, because autoupgrade never targets them.
GA minors carry `isPreview: null` rather than `false`, so the filter is `!= true`.

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

### Why the tag dates matter

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
- **A public repo disables its own scheduled workflow after 60 days without a commit.** Tags
  and releases do not count as activity, which is exactly all this repo produces in steady
  state. The schedule stops, `workflow_dispatch` keeps working, and the feed silently goes
  stale. The keepalive step above exists for this.
- **`npx renovate@latest` broke mid-session** with `No matching version found` for the very
  version the registry reported as `latest`. Pin a version in CI.

## Maintainers

[@klbrg](https://github.com/klbrg)

## Contributing

Issues and pull requests welcome. This repo is also a template; self-hosting is a supported
path, not a second-class one.

Two invariants to respect when changing the publisher, both of which fail silently, and both
explained under [Why the tag dates matter](#why-the-tag-dates-matter):

- Tags must be annotated. A lightweight tag has no date of its own, so `minimumReleaseAge`
  stops working with no error.
- Releases must be created alongside their tags. Backfilling one for an older tag overwrites
  that tag's date and re-arms the soak on a version that already soaked.

## License

MIT © Rickard Karlberg. See [LICENSE](LICENSE).
