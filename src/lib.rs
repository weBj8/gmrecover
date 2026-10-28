//! gmrecover: crash-recovery snapshot storage for builder servers.
//! Lua serializes state; this DLL compresses, checksums and writes it on worker threads.
//! Callbacks run on the main thread via rsgdll's executor, so Lua is never touched off-thread.

pub mod store;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

use rsgdll::prelude::*;

rsgdll::module!(name = "gmrecover");

/// Last saved crc per snapshot dir, to skip writes when nothing changed.
static LAST_CRC: Mutex<Option<HashMap<PathBuf, u32>>> = Mutex::new(None);

/// Snapshot dir for a slot name: `garrysmod/data/gmrecover/<slot>`.
/// Slot is restricted to `[A-Za-z0-9_-]` so it cannot escape the data dir.
fn slot_dir(slot: &str) -> Result<PathBuf> {
    let ok = !slot.is_empty()
        && slot.len() <= 64
        && slot
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-');
    ok.then(|| PathBuf::from("garrysmod/data/gmrecover").join(slot))
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

/// Lua: `gmrecover.Save(slot, data, keep, level, function(err, path) end)`.
/// `path` is nil when data matched the last save (no IO done).
#[rsgdll::function]
async fn save(slot: String, data: LuaBytes, keep: i64, level: i64) -> Result<Option<String>> {
    let dir = slot_dir(&slot)?;
    let keep = usize::try_from(keep.clamp(1, 1000)).unwrap_or(1);
    let level = i32::try_from(level.clamp(1, 19)).unwrap_or(3);
    rsgdll::spawn_worker(move || save_blocking(dir, data.0, keep, level)).await
}

/// Lua: `gmrecover.Load(slot, function(err, data, path) end)`; data nil if no valid snapshot.
#[rsgdll::function]
async fn load(slot: String) -> Result<(Option<LuaBytes>, Option<String>)> {
    let dir = slot_dir(&slot)?;
    rsgdll::spawn_worker(move || {
        store::load_latest(&dir)
            .map(|o| {
                o.map_or((None, None), |(p, raw)| {
                    (Some(LuaBytes(raw)), Some(p.display().to_string()))
                })
            })
            .map_err(|e| anyhow!("load {}: {e}", dir.display()))
    })
    .await
}

/// Lua: `gmrecover.List(slot) -> {path, ...}` newest first. Directory listing only.
#[rsgdll::function]
fn list(slot: String) -> Result<Vec<String>> {
    let dir = slot_dir(&slot)?;
    store::list(&dir)
        .map(|v| v.iter().map(|p| p.display().to_string()).collect())
        .map_err(|e| anyhow!("list: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slot_validation() {
        assert!(slot_dir("gm_construct").is_ok());
        assert!(slot_dir("../etc").is_err());
        assert!(slot_dir("").is_err());
        assert!(slot_dir("a/b").is_err());
    }
}
