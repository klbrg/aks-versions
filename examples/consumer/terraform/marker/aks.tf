# Fixture for the marker-based manager, which is the alternative to selecting a stream by
# directory. Each version line declares its own stream, so one manager serves every file
# and a single directory can mix regions and channels.
#
# Terraform here is only an example. The managers match text, not HCL, so the same markers
# work in a Helm values.yaml, a Bicep parameter file, a Pulumi program, a CI variable file
# or anything else that spells out a version. Adjust managerFilePatterns and the attribute
# names in matchStrings to suit.
#
# The marker comment must sit on the line immediately above the version it governs.

module "aks_rapid" {
  source = "./modules/aks"

  # renovate: aks-stream=swedencentral-rapid
  k8s_version = "1.36.0"
}

# A different region in the same file, to show the marker is what selects the stream.
module "aks_other_region" {
  source = "./modules/aks"

  # renovate: aks-stream=northeurope-stable
  k8s_version = "1.35.0"
}

# A patch-pinned cluster. This stream only ever contains one minor, so Renovate cannot
# propose a minor jump that AKS would refuse at apply time. Moving to the next minor is an
# edit to this marker, which is the right shape for a control-plane upgrade.
module "aks_patch_pinned" {
  source = "./modules/aks"

  # renovate: aks-stream=swedencentral-patch-1.34
  k8s_version = "1.34.5"
}

# Omit the region to follow a regionless stream: the newest version available in EVERY
# region this instance tracks. Use this when clusters in several regions have to share one
# version string, because anything higher than the slowest region fails to apply there.
module "aks_everywhere" {
  source = "./modules/aks"

  # renovate: aks-stream=stable
  k8s_version = "1.35.0"
}

# The regionless patch stream, for a multi-region estate pinned to one minor.
module "aks_everywhere_patch_pinned" {
  source = "./modules/aks"

  # renovate: aks-stream=patch-1.34
  k8s_version = "1.34.5"
}

# Pinned ABOVE its stream head on purpose. This is the only shape that can produce a
# downgrade: a cluster already on a newer version than the stream it follows, which happens
# when you move a marker from rapid to stable, or when a lagging region binds a regionless
# stream below your current pin. AKS never permits a downgrade (all 403 upgrade edges in
# the ARM payload point strictly upward), so Renovate must not offer one.
module "aks_above_its_stream" {
  source = "./modules/aks"

  # renovate: aks-stream=stable
  k8s_version = "1.36.4"
}
