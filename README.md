# gmrecover

Crash-recovery snapshots for Garry's Mod builder servers (ACF/ACE, Wiremod, sandbox). Autosaves every player-owned entity and constraint in AdvDupe2 format. After a crash, `gmrecover_restore` pastes the last good snapshot back to each owner.

## Install

1. Get `gmsv_gmrecover_<branch>.dll` from CI artifacts/release. Use `linux`/`win32` on the default 32-bit server and `linux64`/`win64` on the `x86-64` beta. Put it in `garrysmod/lua/bin/`.
2. Copy `lua/` to `garrysmod/addons/gmrecover/lua/`.
3. Needs AdvDupe2 and a CPPI prop protection addon (FPP, NADMOD, SPP...). Entities without a CPPI owner are not saved.

## Use

Server console or superadmin:

| Command | Effect |
|---|---|
| `gmrecover_restore` | Paste newest valid snapshot for the current map |
| `gmrecover_save` | Save now |
| `gmrecover_list` | List snapshots, newest first |
| `gmrecover_discard` | Skip restore, resume autosave |
| `gmrecover_menu` (client) | Settings + recovery panel |

| ConVar | Default | Meaning |
|---|---|---|
| `gmrecover_enabled` | 1 | Autosave on/off |
| `gmrecover_t1_interval` | 15 | T1 seconds between saves (OS temp dir, 0 = off) |
| `gmrecover_t1_keep` | 3 | T1 snapshots kept per map |
| `gmrecover_interval` | 60 | T2 seconds between saves (`data/`, min 10) |
| `gmrecover_keep` | 5 | T2 snapshots kept per map |
| `gmrecover_max_speed` | 50 | Skip contraptions faster than N units/s (0 = save all) |
| `gmrecover_level` | 3 | zstd level 1-19 |
| `gmrecover_budget_ms` | 0 | Lua work per tick (ms); 0 = auto, 20% of tick interval |
| `gmrecover_autorestore` | 0 | Auto-restore N s after a crash (0 = manual) |
| `gmrecover_holdoff` | 600 | Autosave delay at startup when snapshots exist |

Snapshots: T1 `<tmp>/gmrecover-<hash>/<map>/`, T2 `garrysmod/data/gmrecover/<map>/`, files `snapshot_<unix-ms>.gmr`. Restore takes the newest valid one of either tier. T1 is lost on host reboot.

## Build

```sh
cargo test
cargo clippy --all-targets -- -D warnings
RUSTFLAGS= cargo zigbuild --release --target i686-unknown-linux-gnu.2.17      # linux
RUSTFLAGS= cargo zigbuild --release --target x86_64-unknown-linux-gnu.2.17    # linux64
RUSTFLAGS= XWIN_ARCH=x86,x86_64 cargo xwin build --release --target i686-pc-windows-msvc    # win32
RUSTFLAGS= XWIN_ARCH=x86,x86_64 cargo xwin build --release --target x86_64-pc-windows-msvc  # win64
```

Rename the output to `gmsv_gmrecover_<branch>.dll`. Keep `RUSTFLAGS` empty. Global linker flags break the cross linkers.

## Docs

- [Crash recovery, saved data, limitations](docs/recovery.md)
- [Performance and storage internals](docs/internals.md)
- [Lua API of the binary module](docs/lua-api.md)
