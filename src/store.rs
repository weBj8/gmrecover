//! Snapshot file format, atomic write, rotation and corruption-tolerant load.
//! Plain `std::io`; runs on worker threads only, never touches Lua.

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const MAGIC: &[u8; 4] = b"GMRC";
const VERSION: u8 = 1;
/// magic + version + crc32(raw) + raw len.
const HEADER_LEN: usize = 4 + 1 + 4 + 8;
const EXT: &str = "gmr";

/// Encodes `raw` as header + zstd frame.
pub fn encode(raw: &[u8], level: i32) -> io::Result<Vec<u8>> {
    let body = zstd::bulk::compress(raw, level)?;
    Ok([
        MAGIC.as_slice(),
        &[VERSION],
        &crc32fast::hash(raw).to_le_bytes(),
        &(raw.len() as u64).to_le_bytes(),
        &body,
    ]
    .concat())
}

/// Decodes and verifies a snapshot file. Any mismatch is `InvalidData`.
pub fn decode(file: &[u8]) -> io::Result<Vec<u8>> {
    let bad = |m: &str| io::Error::new(io::ErrorKind::InvalidData, m.to_owned());
    let header = file
        .get(..HEADER_LEN)
        .ok_or_else(|| bad("truncated header"))?;
    (&header[..4] == MAGIC && header[4] == VERSION)
        .then_some(())
        .ok_or_else(|| bad("bad magic/version"))?;
    let crc = u32::from_le_bytes(header[5..9].try_into().map_err(|_| bad("crc"))?);
    let len = u64::from_le_bytes(header[9..17].try_into().map_err(|_| bad("len"))?);
    let len = usize::try_from(len).map_err(|_| bad("len overflow"))?;
    let raw = zstd::bulk::decompress(&file[HEADER_LEN..], len)?;
    (raw.len() == len && crc32fast::hash(&raw) == crc)
        .then_some(raw)
        .ok_or_else(|| bad("checksum mismatch"))
}

/// Snapshot files in `dir`, newest first (names sort by timestamp).
pub fn list(dir: &Path) -> io::Result<Vec<PathBuf>> {
    let mut v: Vec<PathBuf> = match fs::read_dir(dir) {
        Ok(rd) => rd
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().is_some_and(|e| e == EXT))
            .collect(),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Vec::new(),
        Err(e) => return Err(e),
    };
    v.sort_unstable_by(|a, b| b.cmp(a));
    Ok(v)
}

fn now_millis() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis())
}

/// Writes `data` atomically (tmp + fsync + rename) and keeps the newest `keep` snapshots.
/// Returns the written path.
pub fn write(dir: &Path, data: &[u8], keep: usize) -> io::Result<PathBuf> {
    fs::create_dir_all(dir)?;
    // Same-millisecond saves get a bumped name so they never overwrite each other.
    let newest = list(dir)?.into_iter().next();
    let stamp = (0..)
        .map(|i| now_millis() + i)
        .map(|t| dir.join(format!("snapshot_{t:020}.{EXT}")))
        .find(|p| newest.as_ref().is_none_or(|n| p > n))
        .unwrap_or_else(|| dir.join(format!("snapshot_{:020}.{EXT}", now_millis())));
    let tmp = stamp.with_extension("tmp");
    {
        let mut f = fs::File::create(&tmp)?;
        f.write_all(data)?;
        f.sync_all()?;
    }
    fs::rename(&tmp, &stamp)?;
    list(dir)?
        .iter()
        .skip(keep.max(1))
        .for_each(|old| drop(fs::remove_file(old)));
    Ok(stamp)
}

/// Newest snapshot that decodes cleanly; corrupt ones are skipped.
pub fn load_latest(dir: &Path) -> io::Result<Option<(PathBuf, Vec<u8>)>> {
    Ok(list(dir)?.into_iter().find_map(|p| {
        fs::read(&p)
            .and_then(|b| decode(&b))
            .ok()
            .map(|raw| (p, raw))
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_and_corruption() {
        let raw = b"hello world ".repeat(100);
        let enc = encode(&raw, 3).unwrap();
        assert_eq!(decode(&enc).unwrap(), raw);
        let mut flipped = enc.clone();
        *flipped.last_mut().unwrap() ^= 0xff;
        assert!(decode(&flipped).is_err());
        assert!(decode(&enc[..10]).is_err());
    }

    #[test]
    fn rotation_and_fallback() {
        let dir = tempfile::tempdir().unwrap();
        let paths: Vec<_> = (0..5u8)
            .map(|i| write(dir.path(), &encode(&[i; 64], 3).unwrap(), 3).unwrap())
            .collect();
        let left = list(dir.path()).unwrap();
        assert_eq!(left, paths[2..].iter().rev().cloned().collect::<Vec<_>>());
        assert!(
            fs::read_dir(dir.path())
                .unwrap()
                .all(|e| { e.unwrap().path().extension().is_some_and(|x| x == EXT) })
        );
        // corrupt newest -> falls back to previous
        fs::write(&paths[4], b"garbage").unwrap();
        let (p, raw) = load_latest(dir.path()).unwrap().unwrap();
        assert_eq!(p, paths[3]);
        assert_eq!(raw, vec![3u8; 64]);
    }

    #[test]
    fn empty_dir() {
        let dir = tempfile::tempdir().unwrap();
        assert!(load_latest(&dir.path().join("missing")).unwrap().is_none());
    }
}
