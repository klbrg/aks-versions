# Given the output of `az aks get-versions` plus --arg region, emit the committed
# snapshot for that region.
#
# Deliberately contains no timestamp. The git commit date is the timestamp, so a file
# changes only when Azure's answer changes. That keeps `git log versions/<region>.json`
# a history of real version transitions rather than one empty commit per day.
def nums: split(".") | map(tonumber);
def lp($ga; $m):
  [$ga[] | select(.version == $m) | .patchVersions | keys[]]
  | map(nums) | max | if . == null then null else join(".") end;

. as $root
| [$root.values[] | select(.isPreview != true)] as $ga
| ([$ga[].version] | map(nums) | sort | map(join("."))) as $minors
| {
    region: $region,
    channels: (
      { rapid: lp($ga; $minors[-1]) }
      + (if ($minors | length) > 1 then { stable: lp($ga; $minors[-2]) } else {} end)
    ),
    patch: ([$minors[] | { key: ., value: lp($ga; .) }] | from_entries),
    preview: ([$root.values[] | select(.isPreview == true) | .patchVersions | keys[]]
              | map(nums) | sort | map(join(".")))
  }
