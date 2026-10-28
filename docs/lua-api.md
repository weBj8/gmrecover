# Lua API (binary module)

```lua
require("gmrecover")
gmrecover.Save(slot, data, keep, level, tier, function(err, path) end) -- tier 1 temp, 2 data; path nil: unchanged
gmrecover.Load(slot, function(err, data, path) end)              -- newest valid of both tiers; data nil: none
gmrecover.List(slot) -- { path, ... } both tiers, newest first
```

`slot`: `[A-Za-z0-9_-]`, max 64 chars.
