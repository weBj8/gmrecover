//! gmrecover: crash-recovery snapshot storage for builder servers.
//! Lua serializes state; this DLL compresses, checksums and writes it on worker threads.
//! Callbacks run on the main thread via rsgdll's executor, so Lua is never touched off-thread.

pub mod json;
pub mod store;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

use rsgdll::prelude::*;

rsgdll::module!(name = "gmrecover");

/// Last saved crc per snapshot dir, to skip writes when nothing changed.
static LAST_CRC: Mutex<Option<HashMap<PathBuf, u32>>> = Mutex::new(None);

/// Tier roots: T1 = fast scratch in the OS temp dir (lost on host reboot), T2 = `garrysmod/data`.
/// T1 is namespaced by a hash of the server's working dir so several servers on one host don't mix.
fn tier_root(tier: i64) -> PathBuf {
    match tier {
        1 => {
            let cwd = std::env::current_dir().unwrap_or_default();
            std::env::temp_dir().join(format!(
                "gmrecover-{:08x}",
                crc32fast::hash(cwd.as_os_str().as_encoded_bytes())
            ))
        }
        _ => PathBuf::from("garrysmod/data/gmrecover"),
    }
}

/// Snapshot dirs of a slot in both tiers.
fn slot_dirs(slot: &str) -> Result<[PathBuf; 2]> {
    Ok([slot_dir(slot, 1)?, slot_dir(slot, 2)?])
}

/// Snapshot dir for a slot name: `<tier root>/<slot>`.
/// Slot is restricted to `[A-Za-z0-9_-]` so it cannot escape the root.
fn slot_dir(slot: &str, tier: i64) -> Result<PathBuf> {
    let ok = !slot.is_empty()
        && slot.len() <= 64
        && slot
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-');
    ok.then(|| tier_root(tier).join(slot))
        .ok_or_else(|| anyhow!("invalid slot name {slot:?}"))
}

/// Pure decision + write; returns path written or None when unchanged.
fn save_blocking(dir: PathBuf, raw: Vec<u8>, keep: usize, level: i32) -> Result<Option<String>> {
    let crc = crc32fast::hash(&raw);
    let unchanged = LAST_CRC
        .lock()
        .map(|m| m.as_ref().and_then(|m| m.get(&dir)) == Some(&crc))
        .unwrap_or(false);
    if unchanged {
        return Ok(None);
    }
    let enc = store::encode(&raw, level).map_err(|e| anyhow!("compress: {e}"))?;
    let path =
        store::write(&dir, &enc, keep).map_err(|e| anyhow!("write {}: {e}", dir.display()))?;
    if let Ok(mut m) = LAST_CRC.lock() {
        m.get_or_insert_with(HashMap::new).insert(dir, crc);
    }
    Ok(Some(path.display().to_string()))
}

/// Lua: `gmrecover.Save(slot, data, keep, level, tier, function(err, path) end)`; tier 1 = temp, 2 = data.
/// `path` is nil when data matched the last save of that tier (no IO done).
#[rsgdll::function]
async fn save(
    slot: String,
    data: LuaBytes,
    keep: i64,
    level: i64,
    tier: i64,
) -> Result<Option<String>> {
    let dir = slot_dir(&slot, tier)?;
    let keep = usize::try_from(keep.clamp(1, 1000)).unwrap_or(1);
    let level = i32::try_from(level.clamp(1, 19)).unwrap_or(3);
    rsgdll::spawn_worker(move || save_blocking(dir, data.0, keep, level)).await
}

/// Lua: `gmrecover.Load(slot, function(err, data, path) end)`; newest valid snapshot of either tier.
#[rsgdll::function]
async fn load(slot: String) -> Result<(Option<LuaBytes>, Option<String>)> {
    let dirs = slot_dirs(&slot)?;
    rsgdll::spawn_worker(move || {
        store::load_latest(&dirs)
            .map(|o| {
                o.map_or((None, None), |(p, raw)| {
                    (Some(LuaBytes(raw)), Some(p.display().to_string()))
                })
            })
            .map_err(|e| anyhow!("load: {e}"))
    })
    .await
}

/// Lua: `gmrecover.List(slot) -> {path, ...}` newest first across both tiers. Directory listing only.
#[rsgdll::function]
fn list(slot: String) -> Result<Vec<String>> {
    let dirs = slot_dirs(&slot)?;
    store::list_all(&dirs)
        .map(|v| v.iter().map(|p| p.display().to_string()).collect())
        .map_err(|e| anyhow!("list: {e}"))
}

/// Lua: `gmrecover.EncodeJson(tab) -> json`; same output contract as `util.TableToJSON(wrap(tab))`.
/// Runs on the calling Lua thread (main-thread work, no worker).
#[rsgdll::function]
fn encode_json(lua: &Lua, tab: LuaTable) -> Result<LuaBytes> {
    json::encode(lua, &tab).map(LuaBytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slot_validation() {
        assert!(slot_dir("gm_construct", 2).is_ok());
        assert!(slot_dir("../etc", 1).is_err());
        assert!(slot_dir("", 2).is_err());
        assert!(slot_dir("a/b", 2).is_err());
        assert!(slot_dir("x", 1).unwrap().starts_with(std::env::temp_dir()));
    }
}
