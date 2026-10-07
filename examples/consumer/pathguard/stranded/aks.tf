# Same 1.34.5 pin as behind/, but following the stable stream (head 1.35.8) instead of rapid.
# 1.34 -> 1.35 is a legal hop, so the same generic guard must allow it. This is the fix for a
# cluster the guard would otherwise leave stranded.
module "aks" {
  source             = "./modules/aks"
  kubernetes_version = "1.34.5"
}
