# Staged soak fixture: prod tracks the same stable stream as the other stages, but with a
# different minimumReleaseAge, so a patch reaches the stages in order over time.
module "aks" {
  source = "./modules/aks"

  kubernetes_version = "1.35.0"
}
