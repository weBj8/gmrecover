# Internals

- Lua addon serializes in a coroutine. It yields once the `gmrecover_budget_ms` tick budget is spent, so big builds are spread over many ticks.
- Binary module `gmsv_gmrecover` (Rust, [rsgdll](https://github.com/weBj8/rsgdll)) does zstd compression, CRC32 and disk IO on worker threads. Results return to the main thread via rsgdll's executor, polled each tick. Lua is never touched off-thread.
- Same CRC32 as the last save: nothing is written.
- Atomic writes: temp file, fsync, rename. A corrupt or partial newest file is skipped on load, and the previous one is used.
- Each moving contraption (constrained + parented entities, any part > 1 u/s) has its entity and bone poses read inside one tick (positions only, cheap); the AD2 copies are then made across ticks under the budget and get those poses written in, so the stored contraption is at one consistent pose. JSON encoding is then spread across ticks. An autosave that comes due while a save is still running is skipped. Contraptions faster than `gmrecover_max_speed` are skipped.
- Binary strings (e.g. Prop2Mesh partlists) are stored base64-wrapped, and numeric string keys are escaped, because GMod JSON corrupts both.
- T2 autosave reuses the latest T1 serialization when it is newer than `gmrecover_interval`, so it adds only IO.
