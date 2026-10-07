# Some consumers pin a minor rather than a patch, letting whatever applies the config pick the
# patch within it. The aks-minor marker reads major.minor out of the same tags, so the same
# streams serve both styles.
#
# Pinned a minor behind on purpose so a run has something to propose.

variable "kubernetes_minor" {
  type = string
  # renovate: aks-minor=stable
  default = "1.34"
}
