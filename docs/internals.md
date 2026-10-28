# Internals

- Lua addon serializes in a coroutine. It yields once the `gmrecover_budget_ms` tick budget is spent, so big builds are spread over many ticks.
- Binary module `gmsv_gmrecover` (Rust, [rsgdll](https://github.com/weBj8/rsgdll)) does zstd compression, CRC32 and disk IO on worker threads. Results return to the main thread via rsgdll's executor, polled each tick. Lua is never touched off-thread.
- Same CRC32 as the last save: nothing is written.
- Atomic writes: temp file, fsync, rename. A corrupt or partial newest file is skipped on load, and the previous one is used.
