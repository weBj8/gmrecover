# Lua API (binary module)

```lua
require("gmrecover")
gmrecover.Save(slot, data, keep, level, function(err, path) end) -- path nil: unchanged, skipped
gmrecover.Load(slot, function(err, data, path) end)              -- data nil: no valid snapshot
gmrecover.List(slot) -- { path, ... } newest first
```

`slot`: `[A-Za-z0-9_-]`, max 64 chars.
