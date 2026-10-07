# Fixture for dry-running the Renovate config in ../../../../../renovate.json.
# dev follows the AKS "rapid" channel: latest patch on the newest supported minor N.
#
# The module source is a local path on purpose. This file exists only to be matched by the
# custom manager, and a real remote source would make Renovate's terraform manager resolve
# an unrelated dependency on every run.

module "aks" {
  source = "./modules/aks"

  k8s_version = "1.36.0"

  default_node_pool = {
    kubernetes_version = "1.36.0"
  }
}
