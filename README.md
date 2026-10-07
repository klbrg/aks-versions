# aks-versions

[![publish](https://github.com/klbrg/aks-versions/actions/workflows/publish-versions.yml/badge.svg)](https://github.com/klbrg/aks-versions/actions/workflows/publish-versions.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Publishes the Kubernetes versions AKS offers per region as git tags, so Renovate can track them.

`az aks get-versions` is the only authoritative source and needs authentication. This repo runs
it hourly across every AKS region and republishes the result as annotated git tags and GitHub
Releases, which Renovate reads with its built-in `github-tags` datasource and no Azure
credential of its own.

## Table of Contents

- [Install](#install)
- [Usage](#usage)
- [Configuration](#configuration)
- [Maintainers](#maintainers)
- [Contributing](#contributing)
- [License](#license)

## Install

Nothing to install to consume this repo. To run your own instance, use it as a template, then:

1. Read the OIDC subject your repository sends:
   `gh api repos/OWNER/REPO/actions/oidc/customization/sub`. If `use_immutable_subject` is
   `true`, the subject form in Microsoft's docs will not match and auth fails at run time.
2. Create a user-assigned managed identity and a federated credential for that subject.
3. Grant it `Reader` at subscription scope.
4. Set the secrets `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`.
5. Set the repository variable `REGIONS`.

```bash
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

Use `--assignee-object-id`, not `--assignee`, whose Graph lookup often fails for a fresh
identity.

## Usage

```
<region>-<channel>-v<version>     per region
<channel>-v<version>              available in every tracked region
```

Channels mirror the AKS autoupgrade channels: `rapid` is the latest patch on the newest
supported minor, `stable` the latest patch on minor N-1, `patch-<minor>` the latest patch on one
specific minor.

Mark any line that holds a version. The marker is a comment, so its syntax is whatever the file
already uses, and the version must sit on the line immediately below it:

```
# renovate: aks-stream=swedencentral-stable
version: 1.35.8
```

One custom manager reads every marker:

```json
{
  "minimumReleaseAge": "5 days",
  "rollbackPrs": false,
  "packageRules": [
    { "matchUpdateTypes": ["rollback"], "enabled": false },
    { "allowedVersions": "<{{{major}}}.{{add minor 2}}.0" }
  ],
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

`minimumReleaseAge` is the soak, measured from the tag dates. The two rollback settings block
downgrades, which AKS never permits. `allowedVersions` keeps proposals within one minor forward,
which is as far as AKS allows; a cluster further behind than that gets no PR at all, so point it
at `stable` or its own `patch-<minor>` until it catches up.

Renovate matches text, not a language, so adjust `managerFilePatterns` to your files. Omit the
region to follow a stream available in every tracked region. To track `major.minor` instead of a
patch, use `aks-minor=<channel>` with `"versioning": "loose"`. Config must be on your default
branch, or Renovate ignores it and the onboarding config replaces your managers.

Working fixtures are in `examples/consumer/`.

## Configuration

Repository variables for a self-hosted instance, all optional. The defaults live in
`scripts/publish-versions.sh`.

| Variable | Default | Accepts | What it does |
|---|---|---|---|
| `REGIONS` | every AKS region | space separated short names, e.g. `swedencentral northeurope` | Limits what gets tagged. Set this: it controls repo size, and the regionless streams are an intersection over it. |
| `RELEASE_STREAMS` | `rapid stable patch-*` | space separated globs | Which streams also get a GitHub Release, which is what carries release notes into the PR body. |
| `BACKFILL_RELEASES` | `auto` | `auto`, `true`, `false` | `auto` creates releases for pre-existing tags only on a bootstrap. |
| `STANDARD_SUPPORT_ONLY` | `false` | `true`, `false` | `true` drops `patch-<minor>` streams for minors past standard support. |
| `MIN_REGIONS` | `40` | integer | Aborts if region discovery returns fewer regions than this. Ignored when `REGIONS` is set. |
| `DRY_RUN` | `false` | `true`, `false` | Resolve everything, change nothing. Normally the `dryRun` dispatch input. |

## Maintainers

[@klbrg](https://github.com/klbrg)

## Contributing

Pull requests accepted. Questions and bug reports go in
[issues](https://github.com/klbrg/aks-versions/issues).

Two invariants in the publisher, both of which fail silently if broken: tags must be annotated,
since that date is the soak clock, and releases must be created alongside their tags, since a
release date overwrites the tag's.

## License

MIT © Rickard Karlberg. See [LICENSE](LICENSE).
