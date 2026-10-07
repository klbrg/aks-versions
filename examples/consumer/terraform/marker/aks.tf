# Fixture for the marker-based manager, which is the alternative to selecting a channel by
# directory. Each version line declares its own stream, so one manager serves every file
# and a single directory can mix regions and channels.
#
# The marker comment must sit on the line immediately above the version it governs.

module "aks_rapid" {
  source = "./modules/aks"

  # renovate: aks-stream=germanywestcentral-rapid
  k8s_version = "1.36.0"
}

module "aks_stable_other_region" {
  source = "./modules/aks"

  # renovate: aks-stream=swedencentral-stable
  k8s_version = "1.35.0"
}
