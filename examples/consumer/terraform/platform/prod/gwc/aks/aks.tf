# Fixture for dry-running the Renovate config in ../../../../../renovate.json.
# Deliberately pinned behind the current stable target so a dry run has something to find.
# prod follows the AKS "stable" channel: latest patch on minor N-1.

module "aks" {
  source = "git::https://github.com/cvc-partners/terraform-modules.git//modules/azure/aks?ref=azure-aks-v1.0.0"

  k8s_version = "1.35.8"

  default_node_pool = {
    kubernetes_version = "1.35.8"
  }
}
