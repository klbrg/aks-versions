# aks-versions

[![publish](https://github.com/klbrg/aks-versions/actions/workflows/publish-versions.yml/badge.svg)](https://github.com/klbrg/aks-versions/actions/workflows/publish-versions.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Publishes the Kubernetes versions AKS offers per region as git tags, so Renovate can track them.

`az aks get-versions` is the only authoritative source and needs authentication. This repo runs
it hourly across every AKS region and republishes the result as annotated git tags and GitHub
Releases, which Renovate reads with its built-in `github-tags` datasource and no Azure
credential of its own.

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

Nothing published here is secret. The publishing identity holds `Reader` on one subscription,
trusts one repository and one branch, and has no client secret. A wrong tag causes a failed
deployment, not a compromise, since AKS rejects a version it does not offer.

## Background

Use this to hold an exact patch version under review, with a soak and an audit trail, instead
of letting an auto-upgrade channel move it for you.

Do not use it if a minor alias such as `1.36` plus the `patch` channel will do. That combination
absorbs patch moves without drift and is Microsoft's own recommendation.

It does not replace node-image auto-upgrade, which should stay enabled. It also fails open: an
unmerged PR means an unpatched cluster, so pair it with a check comparing running versions
against the stream head.

## Install

Nothing to install to consume this repo. See [Usage](#usage).

To run your own instance, use this repository as a template, then:

1. Read the OIDC subject your repository sends:
   `gh api repos/OWNER/REPO/actions/oidc/customization/sub`. If `use_immutable_subject` is
   `true`, the subject form in Microsoft's docs will not match and auth fails at run time.
2. Create a user-assigned managed identity and a federated credential for that subject.
3. Grant it `Reader` at subscription scope.
4. Set the secrets `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`.
5. Set the repository variable `REGIONS`. See [Configuration](#configuration).

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

`Reader` at subscription scope is the least privilege that works. Use `--assignee-object-id`,
not `--assignee`, whose Graph lookup often fails for a fresh identity.

## Configuration

All optional, set as repository variables under Settings > Secrets and variables > Actions.
The defaults live in `scripts/publish-versions.sh`; an unset or empty variable falls back to
them.

| Variable | Default | Accepts | What it does |
|---|---|---|---|
| `REGIONS` | every AKS region | space separated short names, e.g. `swedencentral northeurope` | Limits what gets tagged. Set this: it controls repo size, and the regionless streams are an intersection over it. |
| `RELEASE_STREAMS` | `rapid stable patch-*` | space separated globs | Which streams also get a GitHub Release, which is what carries release notes into the PR body. |
| `BACKFILL_RELEASES` | `auto` | `auto`, `true`, `false` | `auto` creates releases for pre-existing tags only on a bootstrap. Read [Tag dates](#tag-dates) before setting `true`. |
| `REGION_GRACE_DAYS` | `30` | integer days | How long a newly seen region is ignored before it may bind a regionless stream. |
| `STANDARD_SUPPORT_ONLY` | `false` | `true`, `false` | `true` drops `patch-<minor>` streams for minors past standard support. |
| `MIN_REGIONS` | `40` | integer | Aborts if *region discovery* returns fewer regions than this. Nothing to do with version availability. Ignored when `REGIONS` is set. |
| `DRY_RUN` | `false` | `true`, `false` | Resolve everything, change nothing. Normally the `dryRun` dispatch input. |

## The publishing workflow

`.github/workflows/publish-versions.yml`:

- **Triggers.** `schedule` at `23 * * * *`, plus `workflow_dispatch` with `dryRun`, `regions`
  and `backfill`, each overriding the matching repository variable for one run.
- **Permissions.** `contents: write` for tags and releases, `id-token: write` for the OIDC
  token. `concurrency` allows one run at a time.
- **Steps.** `actions/checkout` with `fetch-depth: 0`, `azure/login`,
  `scripts/publish-versions.sh`, then a keepalive step that pushes an empty commit once the
  newest commit passes 50 days (see [Gotchas](#gotchas)). Both actions are pinned by commit SHA.

A region whose `get-versions` call fails logs a `WARN` and is skipped without failing the run.
`rapid-v<head>` is marked as the latest release. Runs are idempotent: an existing tag keeps its
date, so a re-run never re-arms a soak.

## Usage

Tags come in two shapes:

```
<region>-<channel>-v<version>     per region
<channel>-v<version>              available in every tracked region
```

Channels mirror the AKS autoupgrade channels. `rapid` is the latest patch on the newest
supported minor, `stable` the latest patch on minor N-1, `patch-<minor>` the latest patch on one
specific minor.

### Marking a version

Mark any line that holds a version. The marker is a comment, so its syntax is whatever the file
already uses, and the version must sit on the line immediately below it:

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

Renovate matches text, not a language. Verified against Terraform, Terragrunt, Bicep, Pulumi,
CDKTF, Azure Service Operator, Crossplane, Helm, Ansible, GitHub Actions, Azure Pipelines, Make,
shell, ini and `az aks create`. Adjust `managerFilePatterns` to your files. Formats without
comments and shell line continuations need a different approach, both in [Gotchas](#gotchas).

Working fixtures for every pattern below are in `examples/consumer/`.

### Picking a stream

`extractVersionTemplate` is the selector: one manager per region and channel, or one marker per
line with `aks-stream=<region>-<channel>`. Omit the region for a regionless stream. To track a
minor rather than a patch use `aks-minor=<channel>`, which reads only `major.minor` and needs
`"versioning": "loose"`, since a two-part version is not valid semver.

A path-based manager with `depNameTemplate` and no marker is the alternative where the format
has no comment syntax.

A cluster two minors behind following `rapid` can never legally reach anything in that stream,
so it gets nothing, with `updates: []` and no warning. Point it at `stable` or its own
`patch-<minor>` until it catches up.

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

`minimumReleaseAge` is the soak, read from the tag dates. The two rollback settings block
downgrades, which AKS never permits. `allowedVersions` keeps proposals inside the legal upgrade
path of one minor forward; it carries `supportsTemplating: true` and Renovate ships an `add`
helper, so the bound comes from the version in the file with nothing hardcoded.

### Release notes

`github-tags` derives `sourceUrl` from `packageName` and matches a release by raw tag name, so a
release on `swedencentral-stable-v1.35.8` matches before `extractVersion` strips the prefix.
Renovate needs two versions spanning current to new, or it logs `Not enough valid releases`, so
only the first adoption of a stream misses out.

## How it works

### Streams

`scripts/streams.jq` computes the channels from the ARM response. Preview minors are never
tagged; GA minors carry `isPreview: null` rather than `false`, so the filter is `!= true`.

### Regionless streams

A regionless tag carries the **lowest** of the per-region heads, which is the newest version
that applies in every tracked region. Two guards keep a newly added region from setting that
value for everyone:

- **A grace period.** A region is ignored until tracked for `REGION_GRACE_DAYS`, measured from
  its oldest tag, and only once the instance itself is older than the grace period.
- **Monotonicity.** A regionless tag is created only when the candidate is higher than the
  current head.

A stream stalls, visibly in the log, once a tracked region is past its grace period and is
behind, and is skipped entirely when a tracked region does not offer that minor.

### Tag dates

The tag date is the only release date available, and `minimumReleaseAge` reads it. Two
invariants follow, both of which fail silently:

- **Tags must be annotated.** A lightweight tag inherits the date of the commit it points at,
  which here is the initial commit, so every version would look months old and sail through the
  soak.
- **Releases must be created alongside their tags.** A release's `publishedAt` overwrites the
  tag's date in Renovate whenever it is later, so backfilling a release for an older tag re-arms
  the soak on a version that already soaked.

`BACKFILL_RELEASES=auto` keys on the repo having no *releases*, not no tags, because a fork
carries every tag but no releases.

## Staging

Two ways to roll a version through environments in order, both keeping the exact patch in the
config and both giving a reviewed PR per stage.

**Time-based.** Every stage tracks the same stream with a different `minimumReleaseAge`. Each
stage needs its own `depName`, or Renovate treats them as one dependency. It is a timer, not a
gate: if dev's apply failed, prod's clock runs anyway.

**Success-based.** After a stage applies, its CI pushes an annotated tag recording what it
applied, and the next stage tracks that tag. A version cannot reach prod until it ran in test,
and each stage's soak starts when that stage adopted it. Those tags must be annotated too.

Neither performs the upgrade, respects a maintenance window, touches node images or controls
surge. Those belong to whatever applies the config.

## Gotchas

- **A public repo disables its own scheduled workflow after 60 days without a commit.** Tags and
  releases do not count as activity. `workflow_dispatch` keeps working, so the feed silently
  goes stale. The keepalive step exists for this.
- **`--platform=local` reads committed content, not the working tree.** Uncommitted fixtures are
  invisible, which looks exactly like a broken regex.
- **Renovate reads repo config from the default branch.** A `renovate.json` on a feature branch
  is ignored, and the onboarding config silently replaces your managers.
  `--use-base-branch-config=branch` does not change this.
- **`--platform=local` never builds a PR body**, so it cannot validate `prBodyNotes`. Even
  `--platform=github --dry-run=full` stops before `ensurePr`, so only a real PR proves the body.
- **`allowedVersions` appears in both `exposedConfigOptions` and `supportsTemplating`.** Only the
  second means templated.
- **An arbitrary capture group reaches the templates.** `stream` is not one of Renovate's
  `validMatchFields` and still interpolates, which is what lets one manager serve every stream.
- **Two-part versions need `loose` versioning.** `1.35` is not valid semver.
- **The first version on the marked line wins.** `image: foo:1.2.3 # aks 1.36.4` captures
  `1.2.3`.
- **A format with no comment syntax cannot carry a marker.** ARM template JSON is the common
  case; use a path-based manager.
- **A comment cannot sit inside a shell `\` continuation.** Assign the version to a variable
  first.
- **`npx renovate@latest` broke mid-session** with `No matching version found` for the version
  the registry reported as `latest`. Pin a version in CI.

## Maintainers

[@klbrg](https://github.com/klbrg)

## Contributing

Issues and pull requests welcome. This repo is also a template; self-hosting is a supported
path, not a second-class one.

Two invariants to respect when changing the publisher, both under [Tag dates](#tag-dates): tags
must be annotated, and releases must be created alongside their tags. Both fail silently.

## License

MIT © Rickard Karlberg. See [LICENSE](LICENSE).
