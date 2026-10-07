# aks-versions

Publishes which Kubernetes versions AKS offers, per region, as annotated git tags, so
that Renovate can treat an AKS version like any other dependency.

There is no Renovate datasource for AKS, and no public feed of patch-level versions per
region. The only authoritative source is the ARM call behind `az aks get-versions`, which
requires authentication. This repo runs that call on a schedule and republishes the result
as tags, which Renovate reads with its built-in `github-tags` datasource. Renovate itself
needs no Azure credential.

## Tag scheme

```
<region>-<channel>-v<version>
```

| Channel | Meaning |
|---|---|
| `rapid` | latest GA patch on the newest supported minor (N) |
| `stable` | latest GA patch on minor N-1 |
| `patch-<minor>` | latest GA patch on that specific minor |

These mirror the AKS cluster autoupgrade channels. Preview minors are never tagged, because
autoupgrade only ever targets GA versions.

Examples:

```
germanywestcentral-rapid-v1.36.4
germanywestcentral-stable-v1.35.8
germanywestcentral-patch-1.34-v1.34.11
```

## Why annotated tags

The tag date is the whole point: it is what lets Renovate's `minimumReleaseAge` hold a new
version back for a soak period. Azure publishes no release dates at all, not in the ARM
response and not in the release tracker, so the only timestamp available is when this job
first observed the version in that region.

A lightweight tag cannot carry that. It is just a pointer to a commit and has no date of
its own, so anything reading it falls back to the date of the commit it points at. Since
this repo only ever gains tags and never new commits, every version would report the date
of the initial commit, look months old, and sail straight through `minimumReleaseAge`
with no error and no warning. Annotated tags carry their own tagger date, so
`git tag -a` is required, not cosmetic.

## Consuming from Renovate

```json
{
  "customManagers": [
    {
      "customType": "regex",
      "managerFilePatterns": ["/terraform/.+/aks/.+\\.tf$/"],
      "matchStrings": [
        "(?:k8s_version|kubernetes_version|orchestrator_version)\\s*=\\s*\"(?<currentValue>\\d+\\.\\d+\\.\\d+)\""
      ],
      "depNameTemplate": "aks-germanywestcentral-stable",
      "packageNameTemplate": "klbrg/aks-versions",
      "datasourceTemplate": "github-tags",
      "extractVersionTemplate": "^germanywestcentral-stable-v(?<version>.+)$",
      "versioningTemplate": "semver"
    }
  ]
}
```

Point a different `extractVersionTemplate` at `rapid` for environments that should track the
newest minor, and at `patch-<minor>` for clusters pinned to a minor that should only take
patches.

## Identity

A user-assigned managed identity with a federated identity credential for this repo. No
secrets. A UAMI rather than an app registration because it is a plain ARM resource,
needs no Entra directory role to create, and cannot have a client secret added to it later.

| Thing | Value |
|---|---|
| Resource group | `rg-aks-versions` (swedencentral) |
| Identity | `id-aks-versions` |
| Role | `Reader` at subscription scope |
| FIC subject | `repo:klbrg/aks-versions:ref:refs/heads/main` |

Reader at subscription scope is the least privilege that works:
`az provider operation show --namespace Microsoft.ContainerService` lists no discrete action
for `locations/kubernetesVersions`, so there is nothing narrower to grant.

Repo secrets: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`.

## Running it

```bash
# resolve everything, create no tags
DRY_RUN=true ./scripts/publish-versions.sh
```

The script aborts rather than publishing a partial set if region discovery returns fewer
than `MIN_REGIONS` (default 40) regions, so an ARM hiccup cannot quietly truncate the data.
