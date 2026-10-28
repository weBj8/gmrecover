# Crash recovery

## Detection

At boot the server writes `data/gmrecover/running.txt` and deletes it on clean shutdown or map change. If the file is still there at boot, the last run crashed. Then:

- Joining builders get a toast + chat note that their builds can be restored.
- Superadmins get `gmrecover_menu` opened automatically, with Restore and Discard buttons.
- If `gmrecover_autorestore > 0`, restore runs that many seconds after map load.
- After restore, each owner is told how many entities came back (also on rejoin).
- `gmrecover_holdoff` holds autosave so an empty post-crash map cannot rotate good snapshots away.

Settings changed from the menu or console are mirrored to `data/gmrecover/settings.json` and reapplied at boot. `FCVAR_ARCHIVE` values are written only on clean shutdown.

## Saved data

Saved per owner, the same as an AdvDupe2 dupe: entity data, physics bones, color/material, bodygroups, network vars, all constraints (weld, axis, ballsocket, slider, rope, nocollide...) with alignment, parenting, Wire connections, ACF/ACE links, other `EntityMods`, and each bone's freeze state. Moving vehicles keep moving during autosave.

Restore pastes through the AdvDupe2 queue as the owner. It is paced by `AdvDupe2_SpawnRate`, adds an undo entry, skips spawn limits, and keeps everything frozen while placing. Once the paste finishes, parts saved unfrozen are unfrozen again; parts saved frozen stay frozen.

## Limitations

- Constraints between entities of two different owners are not saved.
- Runtime state not in dupes resets (E2 variables, ammo/fuel, live wire values).
- Owners offline at restore get their build when they join. It stays in autosaves until then.
- Format 1 snapshots (before AdvDupe2) cannot be restored.
- Uses AdvDupe2 internals `CopyEntTable`/`CopyConstraintTable`. Saving logs an error if they get renamed.
- Map-created entities, players and weapons are skipped.
