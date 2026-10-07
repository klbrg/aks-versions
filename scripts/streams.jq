# Given the output of `az aks get-versions`, emit "<stream>|<version>" lines:
#   patch-<minor>  latest GA patch on that minor      (AKS "patch" channel)
#   rapid          latest GA patch on minor N         (AKS "rapid" channel)
#   stable         latest GA patch on minor N-1       (AKS "stable" channel)
#
# Preview minors are excluded: autoupgrade never targets them.
# isPreview is null (not false) on GA minors, hence `!= true`.
#
# --argjson standard_only true limits the patch-<minor> streams to minors still in standard
# support, meaning capabilities.supportPlan contains KubernetesOfficial. That drops the
# LTS-only minors: a smaller instance, at the cost of no longer serving anyone deliberately
# sitting on an LTS version. It saves little over time, because AKS prunes old patches once
# a minor leaves standard support, so those streams are nearly frozen. REGIONS is the lever
# that actually controls size.
#
# The filter derives from supportPlan rather than a hardcoded floor version on purpose. A
# floor like "1.35 and newer" is right for a few months and wrong after that.
#
# rapid and stable are unaffected by the filter: N and N-1 are defined over all GA minors,
# which is how AKS defines them.
def nums: split(".") | map(tonumber);
def lp($ga; $m):
  [$ga[] | select(.version == $m) | .patchVersions | keys[]]
  | map(nums) | max | if . == null then null else join(".") end;

[.values[] | select(.isPreview != true)] as $ga
| ([$ga[].version] | map(nums) | sort | map(join("."))) as $minors
| ([$ga[]
    | select(($standard_only | not)
             or (((.capabilities.supportPlan // []) | index("KubernetesOfficial")) != null))
    | .version] | map(nums) | sort | map(join("."))) as $patch_minors
| [
    ($patch_minors[] | {stream: "patch-\(.)", version: lp($ga; .)}),
    {stream: "rapid",  version: lp($ga; $minors[-1])},
    (if ($minors | length) > 1 then {stream: "stable", version: lp($ga; $minors[-2])} else empty end)
  ]
| map(select(.version != null))
| .[] | "\(.stream)|\(.version)"
