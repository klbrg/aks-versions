# aks-versions

Publishes which Kubernetes versions AKS offers, per region, so that an AKS version can be
treated like any other dependency.

There is no Renovate datasource for AKS, and no public feed of patch-level versions per
region. The only authoritative source is the ARM call behind `az aks get-versions`, which
requires authentication. This repo runs that call daily across every AKS region and
republishes the result as annotated git tags.

Renovate itself needs no Azure credential. It reads tags over the GitHub API.

## Two ways to use this

**Point Renovate at this repo.** Nothing to set up. Copy the config from
[Consuming from Renovate](#consuming-from-renovate) and you are done. The tags here cover
every AKS region, refreshed daily.

**Run your own instance.** Fork or use the template, wire up one managed identity, and you
own the whole chain. See [Running your own instance](#running-your-own-instance).

Which to pick is a trust question, and the honest version is this: if these tags were ever
wrong, whether by a bug or by someone pushing a tag for a version that does not exist, the
result is a **failed `terraform apply`**, because AKS rejects a version it does not offer.
The blast radius is availability, not compromise. Keep `minimumReleaseAge` on and read the
PR, and using this repo directly is a reasonable risk. If you would rather not depend on a
stranger's repo for your control-plane versions, self-host. Both are supported and the
self-hosted path is not a second-class citizen.

## Running your own instance

Five steps. The first one is the one people get wrong.

**1. Find out what OIDC subject your repo actually sends.**

```bash
gh api repos/OWNER/REPO/actions/oidc/customization/sub
```

If `use_immutable_subject` is `true`, the subject embeds numeric IDs and the form in
Microsoft's docs will **not** match:

```
repo:OWNER@<ownerId>/REPO@<repoId>:ref:refs/heads/main
```

Use the `sub_claim_prefix` that command returns, plus `:ref:refs/heads/main`. Getting this
wrong gives `AADSTS700213: No matching federated identity record found` at
`azure/login`, and the federated credential is created successfully regardless, so the
error only appears at run time.

**2. Create a user-assigned managed identity and trust that subject.**

A UAMI rather than an app registration because it is an ordinary ARM resource, needs no
Entra directory role to create, and cannot have a client secret added to it later.

```bash
az group create --name rg-aks-versions --location swedencentral
az identity create --name id-aks-versions --resource-group rg-aks-versions \
  --location swedencentral --query '{clientId:clientId,principalId:principalId}'

az identity federated-credential create \
  --name github-main --identity-name id-aks-versions --resource-group rg-aks-versions \
  --issuer https://token.actions.githubusercontent.com \
  --subject '<the subject from step 1>' \
  --audiences api://AzureADTokenExchange
```

**3. Grant it read access.**

```bash
az role assignment create \
  --assignee-object-id <principalId> --assignee-principal-type ServicePrincipal \
  --role Reader --scope /subscriptions/<subscription-id> \
  --subscription <subscription-id>
```

`Reader` at subscription scope is the least privilege that works.
`az provider operation show --namespace Microsoft.ContainerService` lists no discrete action
for `locations/kubernetesVersions`, so there is nothing narrower to grant. Use
`--assignee-object-id`, not `--assignee`, which needs a Graph lookup that often fails for a
fresh UAMI.

**4. Set three repository secrets.**

| Secret | Value |
|---|---|
| `AZURE_CLIENT_ID` | the UAMI's `clientId` |
| `AZURE_TENANT_ID` | your tenant ID |
| `AZURE_SUBSCRIPTION_ID` | the subscription the Reader role was granted on |

**5. Optionally limit the scope.**

| Repository variable | Effect |
|---|---|
| `REGIONS` | space separated short names, e.g. `swedencentral northeurope`. Default is every AKS region |
| `REGION_GRACE_DAYS` | how long a newly appeared region is ignored by the regionless streams. Default 30 |
| `STANDARD_SUPPORT_ONLY` | `true` drops `patch-<minor>` streams for minors that have left standard support |

`REGIONS` is the one that matters. Every region is about 450 tags at bootstrap and roughly
4,700 new tags a year. Two regions is about 16 tags and 14 a month.

`STANDARD_SUPPORT_ONLY` looks like a size lever and mostly is not. It cuts 8 streams per
region to 5, a 37% smaller bootstrap, but it barely touches growth: AKS prunes old patches
once a minor leaves standard support, so those streams carry two entries each and are
effectively frozen. All the growth comes from the minors you would keep. It also stops
serving anyone deliberately sitting on an LTS version. Reach for `REGIONS` instead unless
you specifically do not want LTS minors mirrored.

`REGION_GRACE_DAYS` is explained under [Regionless streams](#regionless-streams).

Then run the workflow once by hand. On a bootstrap it creates every tag and, because every
tag is new and shares one date, backfills a Release for each of them too. After that it only
touches what changed.

## Tag scheme

```
<region>-<channel>-v<version>     per region
<channel>-v<version>              regionless: available in every tracked region
```

| Channel | Meaning |
|---|---|
| `rapid` | latest GA patch on the newest supported minor (N) |
| `stable` | latest GA patch on minor N-1 |
| `patch-<minor>` | latest GA patch on that specific minor |

These mirror the [AKS cluster autoupgrade channels](https://learn.microsoft.com/azure/aks/auto-upgrade-cluster).
Preview minors are never tagged, because autoupgrade only ever targets GA versions.

```
swedencentral-rapid-v1.36.4
swedencentral-stable-v1.35.8
swedencentral-patch-1.34-v1.34.11
```

56 regions times roughly 8 streams each is about 450 tags at steady state, growing only
when Azure ships a new patch somewhere.

## Regionless streams

AKS rolls patches out region by region. The release tracker exposes nine ordered rollout
groups and at the time of writing a 36-region group was `In Progress`, so at any moment
some regions can be a patch or two behind others.

That matters if several clusters in different regions share one version string, which is
the normal case for a platform repo. The only safe value is then the **lowest** of the
per-region heads, because anything higher fails to apply in the laggard. The regionless
streams publish exactly that:

```
rapid-v1.36.4          newest GA patch available in EVERY tracked region
stable-v1.35.8
patch-1.35-v1.35.8
```

Follow them with the region left out of the marker:

```hcl
# renovate: aks-stream=stable
k8s_version = "1.35.8"
```

Each release body names the binding region, the slowest tracked region to offer that
version, so a stalled stream tells you who you are waiting for.

**"Every tracked region" means the regions this instance tracks.** On an instance that
tracks all 56, it means all 56, which is far more conservative than anyone needs. Narrowing
`REGIONS` to the regions you actually run in is what makes these streams say something
useful about your estate.

### Two guards, for one failure mode

AKS adds regions. A brand new region offering an older patch would otherwise set the value
for everybody and stall the stream on a region nobody uses. One new region would poison it.

1. **A grace period.** A region is ignored by the regionless streams until it has been
   tracked for `REGION_GRACE_DAYS` (default 30), measured from its oldest tag, so a newly
   appeared region cannot bind the intersection before it has had a fair chance to catch
   up. A bootstrap is exempt, since then every region is new and excluding them all would
   publish nothing.
2. **Monotonicity.** A regionless tag is only created when the candidate is higher than the
   current stream head. A lagging region therefore cannot add a backwards tag dated today,
   which would be noise and would carry a misleading date.

A stall is still possible once a region is past its grace period and is genuinely behind.
That is the stream being honest rather than broken, and the run logs which region is
responsible:

```
regionless rapid stalls at 1.36.4: australiacentral2 only offers 1.36.2
```

A stream is also skipped entirely, rather than guessed at, when some tracked region does
not offer that minor at all.

The regionless `rapid` release is what carries GitHub's "Latest" badge. GitHub always
designates one release as latest and offers no way to opt out, and left to its own
heuristics it compares dates and semver across every region's tag namespace at once and
lands somewhere arbitrary. The newest GA version available everywhere is the one summary of
this repo that is both canonical and true.

## Why annotated tags

The tag date is the point. It is what lets Renovate's `minimumReleaseAge` hold a new
version back for a soak period, and it is also the entire history of this repo.

Azure publishes no release dates at all, not in the ARM response and not in the release
tracker, so the only timestamp available is when this job first observed the version in
that region. A lightweight tag cannot carry that: it is only a pointer to a commit and has
no date of its own, so anything reading it falls back to the date of the commit it points
at. Since this repo only ever gains tags and never new commits, every version would report
the date of the initial commit, look months old, and sail straight through
`minimumReleaseAge` with no error and no warning. Hence `git tag -a`, which is required
rather than cosmetic.

Because the dates are real, the tags are the audit trail. No separate snapshot file is
needed to answer what a region and channel pointed at over time:

```bash
# the dated series for one stream
git for-each-ref --sort=taggerdate --format='%(taggerdate:short)  %(refname:short)' \
  'refs/tags/swedencentral-stable-*'

# everything currently offered in one region
git for-each-ref --format='%(refname:short)' 'refs/tags/swedencentral-*' | sort
```

Two things the tags deliberately do not record, because nothing consumes them today: the
preview versions, and the per-patch upgrade graph, meaning the exact set of versions a
given patch may move to. The upgrade graph is the one worth archiving if a need arises, since AKS
forbids skipping minors and the graph is unrecoverable once Azure retires a version. It
would mean committing the raw ARM payload per region, about 12.7 KiB each.

## Consuming from Renovate

`renovate.json` in this repo is the worked example, exercised against the fixtures in
`examples/consumer/`. One custom manager per region and channel; `extractVersionTemplate`
is the selector that isolates one tag stream from the other 450.

**The examples use Terraform, but nothing here is Terraform-specific.** A custom manager
matches text, not HCL. The same setup works wherever a Kubernetes version is written down:
a Helm `values.yaml`, a Bicep parameter file, a Pulumi program, an ARM template, a
Kustomize overlay, a CI variable file, a shell script, even a Makefile. Point
`managerFilePatterns` at those files and put the attribute or key names you use into
`matchStrings`. The pattern below looks for `k8s_version`, `kubernetes_version` and
`orchestrator_version` purely because that is what the fixtures happen to call them.

```json
{
  "customManagers": [
    {
      "customType": "regex",
      "managerFilePatterns": ["/terraform/platform/prod/.+/aks/.+\\.tf$/"],
      "matchStrings": [
        "(?:k8s_version|kubernetes_version|orchestrator_version)\\s*=\\s*\"(?<currentValue>\\d+\\.\\d+\\.\\d+)\""
      ],
      "depNameTemplate": "aks-gwc-stable",
      "packageNameTemplate": "klbrg/aks-versions",
      "datasourceTemplate": "github-tags",
      "extractVersionTemplate": "^swedencentral-stable-v(?<version>.+)$",
      "versioningTemplate": "semver"
    }
  ],
  "packageRules": [
    {
      "matchDepNames": ["aks-gwc-stable", "aks-gwc-rapid"],
      "prBodyNotes": [
        "Upstream Kubernetes changelog: https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-{{{newMajor}}}.{{{newMinor}}}.md",
        "AKS release notes: https://github.com/Azure/AKS/releases",
        "AKS lags upstream: a patch listed in the Kubernetes changelog is not necessarily offered by AKS in this region."
      ]
    }
  ]
}
```

Point `extractVersionTemplate` at a different stream to change what an environment follows:

| Want | Pattern |
|---|---|
| newest minor | `^swedencentral-rapid-v(?<version>.+)$` |
| N-1, the AKS default | `^swedencentral-stable-v(?<version>.+)$` |
| patches only, pinned to one minor | `^swedencentral-patch-1\.35-v(?<version>.+)$` |

Because channel is chosen by `managerFilePatterns`, dev on `rapid` and prod on `stable` is
two managers that differ only in path and regex. Channel becomes a property of the
directory layout.

Add in production, left out of this repo's config so that a dry run produces output:

- `"minimumReleaseAge": "5 days"`, the soak period the annotated tag dates make possible
- `"dependencyDashboardApproval": true` on the prod rule, because the `stable` stream
  crosses minors when N moves and will arrive as a patch-looking PR that is really a
  control-plane minor upgrade

### Setting a single file to follow a channel

Selecting by path needs one manager per region and channel, which is fine when environments
map onto directories. When they do not, or when one directory mixes regions, put a marker
comment on the line above each version instead. One manager then serves every file and each
line declares its own stream:

```hcl
# renovate: aks-stream=swedencentral-rapid
k8s_version = "1.36.4"
```

The manager that reads it, already in `renovate.json`:

```json
{
  "customType": "regex",
  "managerFilePatterns": ["/\\.tf$/"],
  "matchStrings": [
    "#\\s*renovate:\\s*aks-stream=(?<depName>[a-z0-9]+-(?:rapid|stable|patch-\\d+\\.\\d+))\\s*\\n\\s*(?:k8s_version|kubernetes_version|orchestrator_version)\\s*=\\s*\"(?<currentValue>\\d+\\.\\d+\\.\\d+)\""
  ],
  "packageNameTemplate": "klbrg/aks-versions",
  "datasourceTemplate": "github-tags",
  "extractVersionTemplate": "^{{{depName}}}-v(?<version>.+)$",
  "versioningTemplate": "semver"
}
```

`depName` is captured from the comment and interpolated into `extractVersionTemplate`, so
the marker is the only thing that picks the stream. `extractVersion` is one of Renovate's
`validMatchFields`, so it can also be written out in full in the comment if you prefer.

Verified against `examples/consumer/terraform/marker/aks.tf`, where two markers in one file
resolved independently:

| Marker | Pinned | Interpolated `extractVersion` | Resolved |
|---|---|---|---|
| `swedencentral-rapid` | 1.36.0 | `^swedencentral-rapid-v(?<version>.+)$` | 1.36.4 |
| `northeurope-stable` | 1.35.0 | `^northeurope-stable-v(?<version>.+)$` | 1.35.8 |
| `swedencentral-patch-1.34` | 1.34.5 | `^swedencentral-patch-1.34-v(?<version>.+)$` | 1.34.11 |

(Resolved values are from a run on 2026-10-07 and will have moved since.)

The marker has to sit on the line immediately above the version it governs. A file with
several version attributes, such as a cluster plus its node pools, needs one marker per
line. If every version in a directory follows the same channel, the path-based manager is
less repetitive.

### Pinning to a minor so an illegal jump is impossible

AKS does not permit arbitrary minor jumps, and Renovate cannot know that: no datasource
field carries the `upgrades` graph, so Renovate offers the head of whatever stream it is
pointed at. The reachability is also not uniform. Within standard support a patch reaches
its own minor plus exactly one more, while the LTS-only minors (1.33 and below) may jump up
to three to get back into the support window:

| Pinned at | Can reach |
|---|---|
| a patch of a minor in standard support | later patches of that same minor, plus the next minor |
| the newest patch of such a minor | the next minor only, since nothing newer exists in its own |
| a minor that has left standard support (`supportPlan` is `AKSLongTermSupport` only) | several minors ahead, so it can get back inside the support window |

The exact sets move whenever Azure ships a patch, so read them from the data rather than
from this table. Each Release body prints the permitted targets for its own version, and
`az aks get-versions` is always the authority.

So a cluster that skips a channel cycle can be offered a jump AKS refuses, and the refusal
lands at `terraform apply`, after review and approval, because plan never asks AKS whether
the hop is legal.

Following `patch-<minor>` removes the possibility rather than managing it. That stream only
ever contains one minor, so the illegal version is not in the dependency's version list at
all. Verified above: pinned at 1.34.5 it resolved to the newest 1.34 patch and did not
offer the newer 1.36 one, although that tag exists.

```hcl
# renovate: aks-stream=swedencentral-patch-1.34
k8s_version = "1.34.5"
```

Moving to the next minor is then an edit to this one marker, reviewed on its own, which is
the right shape for a control-plane upgrade. The `rapid` and `stable` streams remain useful
as the signal that the channel target moved.

If you would rather keep following `stable` and accept the risk, `separateMultipleMinor:
true` raises a separate PR per minor so the legal intermediate step at least exists as its
own PR. It does not suppress the far one, so ordering stays manual.

### Release notes

`github-tags` declares `sourceUrlSupport = 'package'` and derives `sourceUrl` from
`packageName`, so Renovate looks for changelogs in **this** repo, which has none. That is
why the links go in `prBodyNotes` instead. `newMajor` and `newMinor` are standard Renovate
template fields, so `1.35.8` renders as `CHANGELOG-1.35.md`.

Putting the notes in the annotated tag message does not work, and it is worth knowing why
rather than discovering it twice. Renovate's tag GraphQL query requests only `name`, the
target `oid` and a date, and its `transform` returns `{version, gitRef, hash,
releaseTimestamp}`. The tag message is never fetched. The message this repo writes is for
`git show <tag>`, not for Renovate.

The only in-repo carrier Renovate reads is a GitHub **Release**, whose adapter fetches
`name`, `description`, `url` and `publishedAt`. The publisher creates one per new `rapid`
and `stable` tag, which is what makes a collapsible `Release Notes` section appear in the
PR. Two facts make that work, both confirmed against Renovate's source:

- The matcher is `r.tag === version || r.tag === 'v'+version || r.tag === gitRef ||
  r.tag === 'v'+gitRef`, and the tags adapter sets `gitRef` to the **raw tag name**. So a
  release on `swedencentral-stable-v1.35.8` matches on `gitRef`, before
  `extractVersion` strips the prefix. No `depName` juggling is needed.
- Renovate needs **two** versions in the stream spanning current to new, or it logs
  `Not enough valid releases` and never reaches the matcher. This is self-satisfying in
  steady state, because a consumer's pin came from the same stream. Only the very first
  adoption of a stream, where the pin was never a channel target, goes without notes.

All three stream kinds get a Release, controlled by `RELEASE_STREAMS` (default
`rapid stable patch-*`, space separated globs). `patch-<minor>` is included because a
cluster that must never make an illegal minor jump follows that stream, so it is the one
whose PRs actually get read.

Releases are normally created only for newly created tags. `BACKFILL_RELEASES` controls the
exception, and the default `auto` exists because **backfilling is only safe at a bootstrap**:

```js
// renovate/lib/modules/datasource/github-tags/index.ts
if (releaseTimestamp && (isNullOrUndefined(release.releaseTimestamp) ||
    releaseTimestamp > release.releaseTimestamp)) {
  release.releaseTimestamp = releaseTimestamp;   // the release date WINS
}
```

A Release's `publishedAt` overwrites the tag's tagger date whenever it is later. Creating a
release alongside its tag is therefore always safe, since the dates match. Backfilling a
release for a tag created weeks ago **replaces the real detection date with today**, which
makes a long-soaked version look brand new and re-arms `minimumReleaseAge` against it.

`auto` detects a fresh instance by checking that the repo has **no releases** yet. It keys
on releases rather than tags on purpose, because of what travels when someone copies this
repo:

| | Tags | Releases | History |
|---|---|---|---|
| `git clone` | yes | no | yes |
| Fork | yes | no | yes |
| Use this template | no | no | no, one fresh commit |

Releases are GitHub metadata, not git objects, so neither a clone nor a fork brings them.
Keying on tags would leave a forked instance with 450 tags, no releases, and `auto`
concluding it was not a bootstrap, so it would never produce release notes at all.

On a fork the tag dates restart at that instance's first run, since the backfilled releases
carry that date. That is honest rather than lossy: your instance genuinely first observed
those versions then, and the soak period starts from your adoption. If you want the
original dates preserved, use the template instead and let your instance build its own
history from scratch.

Backfilling later, outside a bootstrap, resets the dates of whatever you touch. Prefer
backfilling a whole stream over part of one.

The release body carries what Azure will not give you anywhere else: the anchored upstream
changelog link, the `supportPlan`, and the upgrade targets AKS permits from that version.
That last one is the `upgrades` graph, and the PR is where it is actually useful, since AKS
forbids skipping minors and Renovate has no way to know that.

No configuration will give you AKS-specific patch notes, because Azure does not publish
them per patch per region. The honest best is the upstream Kubernetes changelog for the
minor, plus the dated `Azure/AKS` release notes for the rollout wave.

### Gotchas when dry-running Renovate

Three things cost real time and are not obvious:

- Renovate reads repo config from the **default branch**. A `renovate.json` on a feature
  branch is ignored, Renovate decides the repo is not onboarded, and the onboarding config
  silently replaces your managers. `--use-base-branch-config=branch` does not change this.
- `--platform=local` reads **committed** content, not the working tree. Uncommitted
  fixtures are invisible, which looks identical to a broken regex.
- `--platform=local` never builds a PR body, so it cannot validate `prBodyNotes`. Use
  `--platform=github --dry-run=full` for that.

## Identity

A user-assigned managed identity with a federated identity credential for this repo. No
secrets. A UAMI rather than an app registration because it is a plain ARM resource, needs
no Entra directory role to create, and cannot have a client secret added to it later.

| Thing | Value |
|---|---|
| Resource group | `rg-aks-versions` (swedencentral) |
| Identity | `id-aks-versions` |
| Role | `Reader` at subscription scope |
| FIC subject | `repo:klbrg@48217039/aks-versions@1408380151:ref:refs/heads/main` |

The subject uses GitHub's **immutable** form, with numeric owner and repo IDs, because this
account has `use_immutable_subject: true`. The documented `repo:<owner>/<repo>:ref:...`
form fails with `AADSTS700213`. Check what your repo actually sends:

```bash
gh api repos/klbrg/aks-versions/actions/oidc/customization/sub
```

Keep immutable subjects on. The trust binds to numeric IDs, so it survives a rename and
cannot be hijacked by recreating a repo under the same name.

Reader at subscription scope is the least privilege that works:
`az provider operation show --namespace Microsoft.ContainerService` lists no discrete action
for `locations/kubernetesVersions`, so there is nothing narrower to grant.

Repo secrets: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`.

The FIC trusts `refs/heads/main` only, so a `workflow_dispatch` run on a feature branch
cannot authenticate. That is deliberate.

## Running it

```bash
# resolve every region and log the tags it would create, without creating any
DRY_RUN=true ./scripts/publish-versions.sh
```

The script aborts rather than publishing a partial set if region discovery returns fewer
than `MIN_REGIONS` (default 40) regions, so an ARM hiccup cannot quietly truncate the data.

It pushes tags only and never commits, so `main` is untouched by the schedule.
