# agent-settings.jq — merge Claude Code settings layers, left to right
# (install.sh: base, role, identity, then the machine-local overlay).
#   jq -s -f scripts/lib/agent-settings.jq base.json overlay.json ...
def merge($base; $overlay):
    ($base * $overlay) as $m
    | $m
    # jq's "*" replaces arrays, so permission lists concatenate instead: a
    # later layer's allow/ask entries add to the earlier ones.
    | if ($m.permissions // null) != null then
        .permissions.allow = (($base.permissions.allow // []) + ($overlay.permissions.allow // []) | unique)
        | .permissions.ask = (($base.permissions.ask   // []) + ($overlay.permissions.ask   // []) | unique)
      else .
      end
    # Likewise hooks.<event>: an identity that defines an event ADDS its hooks to
    # the base ones instead of clobbering them. `unique` drops byte-identical
    # entries; distinct entries under the same matcher all run, which is what
    # Claude Code does with every matching hook.
    | if (($base.hooks // null) != null) or (($overlay.hooks // null) != null) then
        .hooks = (
          reduce (( ($base.hooks // {}) + ($overlay.hooks // {}) ) | keys_unsorted[]) as $ev
            ({}; .[$ev] = ((($base.hooks[$ev]) // []) + (($overlay.hooks[$ev]) // []) | unique))
        )
      else .
      end;
# Keep a "//" banner key first so it reads as a header. Claude Code re-serializes
# settings.json at runtime (permission grants, /config) and may move it.
reduce .[] as $layer ({}; merge(.; $layer))
| if has("//") then {"//": .["//"]} + . else . end
