# aks-versions

[![publish](https://github.com/klbrg/aks-versions/actions/workflows/publish-versions.yml/badge.svg)](https://github.com/klbrg/aks-versions/actions/workflows/publish-versions.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Publishes the Kubernetes versions AKS offers per region as git tags, so Renovate can track them.

Renovate has no AKS datasource, and no public feed lists patch versions per region. The only
authoritative source is the ARM call behind `az aks get-versions`, which requires
authentication. This repo runs it daily across every AKS region and republishes the result as
annotated git tags and GitHub Releases. Renovate reads those with its built-in `github-tags`
datasource and needs no Azure credential of its own.

Point Renovate at this instance, or run your own from the template.

## Table of Contents

- [Security](#security)
- [Background](#background)
- [Install](#install)
- [Usage](#usage)
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
5. Set the repository variable `REGIONS` to the regions you deploy to. Strongly recommended:
   it controls repo size, makes the regionless streams meaningful, and confines stalls to
   regions you care about.

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

Other repository variables: `REGION_GRACE_DAYS` (default 30), `STANDARD_SUPPORT_ONLY`,
`RELEASE_STREAMS`, `MIN_REGIONS`. The reasoning behind the first is in
[DESIGN.md](DESIGN.md#regionless-streams).

## Usage

Tags come in two shapes:

```
<region>-<channel>-v<version>     per region
<channel>-v<version>              available in every tracked region
```

Channels mirror the AKS autoupgrade channels. `rapid` is the latest patch on the newest
supported minor, `stable` the latest patch on minor N-1, and `patch-<minor>` the latest patch
on one specific minor.

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
shell line continuations. Both are covered in [DESIGN.md](DESIGN.md#gotchas).

`rollbackPrs: false` matters. AKS never permits a downgrade, and a version pinned above its
stream would otherwise attract a rollback PR.

### Picking a stream

`extractVersionTemplate` is the selector. One manager per region and channel, or one marker per
line with `aks-stream=<region>-<channel>`. Omit the region for a regionless stream. To track a
minor rather than a patch, use `aks-minor=<channel>` instead, which reads only `major.minor`
and needs `"versioning": "loose"` because a two-part version is not valid semver.

A path-based manager, with `depNameTemplate` set and no marker, is the alternative when the
file format has no comment syntax, ARM template JSON being the common case.

### Worth setting

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
a downgrade. The `allowedVersions` rule stops Renovate proposing a minor jump AKS would refuse,
deriving the bound from the version currently in the file.

Why each of those is needed, and the traps around them:
[DESIGN.md](DESIGN.md).

## Maintainers

[@klbrg](https://github.com/klbrg)

## Contributing

Issues and pull requests welcome. This repo is also a template; self-hosting is a supported
path, not a second-class one.

Two invariants to respect when changing the publisher, both of which fail silently:

- Tags must be annotated. A lightweight tag has no date of its own, so `minimumReleaseAge`
  stops working with no error.
- Releases must be created alongside their tags. Backfilling one for an older tag overwrites
  that tag's date and re-arms the soak on a version that already soaked.

[DESIGN.md](DESIGN.md) has the reasoning behind both.

## License

MIT © Rickard Karlberg. See [LICENSE](LICENSE).
