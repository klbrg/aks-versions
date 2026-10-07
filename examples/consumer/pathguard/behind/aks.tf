# Two minors behind the rapid head (1.36.4). AKS forbids 1.34.x -> 1.36.x, so the guard must
# block this one.
module "aks" {
  source             = "./modules/aks"
  kubernetes_version = "1.34.5"
}
