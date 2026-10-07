# One minor behind the rapid head. AKS permits 1.35.x -> 1.36.x, so the same guard must let
# this one through. That is what makes the rule generic rather than a blanket block.
module "aks" {
  source             = "./modules/aks"
  kubernetes_version = "1.35.0"
}
