# aks-versions

Publishes which Kubernetes versions AKS offers, per region, so that an AKS version can be
treated like any other dependency.

There is no Renovate datasource for AKS, and no public feed of patch-level versions per
region. The only authoritative source is the ARM call behind `az aks get-versions`, which
requires authentication. This repo runs that call daily across every AKS region and
republishes the result two ways: as annotated git tags for Renovate, and as committed JSON
snapshots for history.

Renovate itself needs no Azure credential. It reads tags over the GitHub API.

## Tag scheme

```
<region>-<channel>-v<version>
```

| Channel | Meaning |
|---|---|
| `rapid` | latest GA patch on the newest supported minor (N) |
| `stable` | latest GA patch on minor N-1 |
| `patch-<minor>` | latest GA patch on that specific minor |

These mirror the [AKS cluster autoupgrade channels](https://learn.microsoft.com/azure/aks/auto-upgrade-cluster).
Preview minors are never tagged, because autoupgrade only ever targets GA versions.

```
germanywestcentral-rapid-v1.36.4
germanywestcentral-stable-v1.35.8
germanywestcentral-patch-1.34-v1.34.11
```

56 regions times roughly 8 streams each is about 450 tags at steady state, growing only
when Azure ships a new patch somewhere.

## Version snapshots

`versions/<region>.json` holds the current state for each region:

```json
{
  "channels": { "rapid": "1.36.4", "stable": "1.35.8" },
  "patch": {
    "1.31": "1.31.100",
    "1.35": "1.35.8",
    "1.36": "1.36.4"
  },
  "preview": ["1.37.0"],
  "region": "germanywestcentral"
}
```

These files deliberately contain **no timestamp**. The commit date is the timestamp, so a
file changes only when Azure's answer changes. That makes the history meaningful:

```bash
git log --follow -p versions/germanywestcentral.json   # every transition, with dates
git log --oneline versions/                            # days on which anything moved
```

A timestamp field would produce one commit per day regardless, and the signal would be
buried. Keys are sorted (`jq -S`) so diffs stay minimal.

Snapshots are committed before tags are created, so each tag points at the commit that
recorded the data it describes.

## Why annotated tags

The tag date is the point: it is what lets Renovate's `minimumReleaseAge` hold a new
version back for a soak period. Azure publishes no release dates at all, not in the ARM
response and not in the release tracker, so the only timestamp available is when this job
first observed the version in that region.

A lightweight tag cannot carry that. It is only a pointer to a commit and has no date of
its own, so anything reading it falls back to the date of the commit it points at. Every
version would report the wrong date, look months old, and sail straight through
`minimumReleaseAge` with no error and no warning. Hence `git tag -a`, which is required
rather than cosmetic.

## Consuming from Renovate

`renovate.json` in this repo is the worked example, exercised against the fixtures in
`examples/consumer/`. One custom manager per region and channel; `extractVersionTemplate`
is the selector that isolates one tag stream from the other 450.

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
      "extractVersionTemplate": "^germanywestcentral-stable-v(?<version>.+)$",
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

| Want | Pattern | Resolves to |
|---|---|---|
| newest minor | `^germanywestcentral-rapid-v(?<version>.+)$` | 1.36.4 |
| N-1, the AKS default | `^germanywestcentral-stable-v(?<version>.+)$` | 1.35.8 |
| patches only, pinned to 1.35 | `^germanywestcentral-patch-1\.35-v(?<version>.+)$` | 1.35.8 |

Because channel is chosen by `managerFilePatterns`, dev on `rapid` and prod on `stable` is
two managers that differ only in path and regex. Channel becomes a property of the
directory layout.

Add in production, left out of this repo's config so that a dry run produces output:

- `"minimumReleaseAge": "5 days"`, the soak period the annotated tag dates make possible
- `"dependencyDashboardApproval": true` on the prod rule, because the `stable` stream
  crosses minors when N moves and will arrive as a patch-looking PR that is really a
  control-plane minor upgrade

### Release notes

`github-tags` declares `sourceUrlSupport = 'package'` and derives `sourceUrl` from
`packageName`, so Renovate looks for changelogs in **this** repo, which has none. That is
why the links go in `prBodyNotes` instead. `newMajor` and `newMinor` are standard Renovate
template fields, so `1.35.8` renders as `CHANGELOG-1.35.md`.

No configuration will give you AKS-specific patch notes, because Azure does not publish
them per patch per region. The honest best is the upstream Kubernetes changelog for the
minor, plus the dated `Azure/AKS` release notes for the rollout wave.

### Gotchas when dry-running Renovate

Three things cost time and are not obvious:

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

## Running it

```bash
# resolve everything, write snapshots, commit and tag nothing
DRY_RUN=true ./scripts/publish-versions.sh
```

The script aborts rather than publishing a partial set if region discovery returns fewer
than `MIN_REGIONS` (default 40) regions, so an ARM hiccup cannot quietly truncate the data.

The workflow pushes to `main` using `GITHUB_TOKEN`, which by design does not retrigger
workflows, so the snapshot commit cannot cause a loop.
