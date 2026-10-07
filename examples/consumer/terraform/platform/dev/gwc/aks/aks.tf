# Fixture for dry-running the Renovate config in ../../../../../renovate.json.
# dev follows the AKS "rapid" channel: latest patch on the newest supported minor N.

module "aks" {
  source = "git::https://github.com/cvc-partners/terraform-modules.git//modules/azure/aks?ref=azure-aks-v1.0.0"

  k8s_version = "1.36.0"

  default_node_pool = {
    kubernetes_version = "1.36.0"
  }
}
