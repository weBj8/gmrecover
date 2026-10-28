//! Native replacement for Lua `util.TableToJSON(wrap(t))`: one pass over the Lua table on the
//! calling (main) thread, emitting JSON that `util.JSONToTable` + Lua `unwrap` read back.
//! Format rules (must match lua/autorun/server/gmrecover.lua `wrap`/`unwrap`):
//! - every table is a JSON object; number keys are written as strings (JSONToTable turns them back);
//! - string keys that look numeric or start with `~s:` get a `~s:` prefix;
//! - binary strings become `{"~b": base64}`;
//! - Vector/Angle become GMod's `"[x y z]"` / `"{p y r}"` strings;
//! - values JSON can't hold (functions, entities, NaN, ...) are dropped, like TableToJSON;
//! - a table that refers back to an ancestor drops just that field (Lua `wrap` + TableToJSON never failed on these).

use core::ffi::{c_int, c_void};

use rsgdll::__rt::sys::gmod::{ILuaBase, types};
use rsgdll::__rt::sys::lua::*;
use rsgdll::{Lua, LuaTable};

const MAX_DEPTH: usize = 64;
const SKEY: &[u8] = b"~s:";

/// Same set as Lua `[%z\1-\8\11\12\14-\31\127-\255]`.
pub fn is_binary(s: &[u8]) -> bool {
    s.iter()
        .any(|&b| matches!(b, 0..=8 | 11 | 12 | 14..=31 | 127..=255))
}

/// Superset of Lua 5.1 `tonumber(k) ~= nil` (strtod: decimal, exponent, hex, inf/nan,
/// surrounding whitespace). Over-escaping is harmless: `unwrap` strips the prefix.
pub fn key_needs_prefix(k: &[u8]) -> bool {
    if k.starts_with(SKEY) {
        return true;
    }
    let s = String::from_utf8_lossy(k);
    let t = s.trim();
    let hex = t.trim_start_matches(['+', '-']);
    t.parse::<f64>().is_ok() || ((hex.starts_with("0x") || hex.starts_with("0X")) && hex.len() > 2)
}

pub fn base64(src: &[u8], out: &mut Vec<u8>) {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    src.chunks(3).for_each(|c| {
        let n = c
            .iter()
            .enumerate()
            .fold(0u32, |n, (i, &b)| n | u32::from(b) << (16 - 8 * i));
        (0..4).for_each(|i| match i <= c.len() {
            true => out.push(T[(n >> (18 - 6 * i) & 63) as usize]),
            false => out.push(b'='),
        });
    });
}

pub fn json_str(s: &[u8], out: &mut Vec<u8>) {
    out.push(b'"');
    s.iter().for_each(|&b| match b {
        b'"' => out.extend_from_slice(b"\\\""),
        b'\\' => out.extend_from_slice(b"\\\\"),
        b'\n' => out.extend_from_slice(b"\\n"),
        b'\r' => out.extend_from_slice(b"\\r"),
        b'\t' => out.extend_from_slice(b"\\t"),
        0..=31 => out.extend_from_slice(format!("\\u{b:04x}").as_bytes()),
        _ => out.push(b),
    });
    out.push(b'"');
}

/// Shortest round-trip form, never exponent (JSON-valid); `None` for NaN/inf.
pub fn num(n: f64) -> Option<String> {
    n.is_finite()
        .then(|| match n.fract() == 0.0 && n.abs() < 1e15 {
            true => format!("{}", n as i64),
            false => format!("{n}"),
        })
}

struct Enc {
    api: &'static LuaApi,
    l: *mut lua_State,
    main: *mut lua_State,
    base: *mut ILuaBase,
    out: Vec<u8>,
    path: Vec<*const c_void>,
}

impl Enc {
    unsafe fn bytes(&self, idx: c_int) -> &[u8] {
        let mut len = 0usize;
        unsafe {
            let p = (self.api.lua_tolstring)(self.l, idx, &mut len);
            core::slice::from_raw_parts(p.cast::<u8>(), len)
        }
    }

    /// Writes `"key":`-ready key; false = key type JSON can't hold (entry dropped).
    unsafe fn key(&mut self, k: c_int) -> bool {
        unsafe {
            match (self.api.lua_type)(self.l, k) {
                LUA_TSTRING => {
                    let s = self.bytes(k).to_vec();
                    match key_needs_prefix(&s) {
                        true => json_str(&[SKEY, &s].concat(), &mut self.out),
                        false => json_str(&s, &mut self.out),
                    }
                    true
                }
                LUA_TNUMBER => num((self.api.lua_tonumber)(self.l, k))
                    .map(|n| json_str(n.as_bytes(), &mut self.out))
                    .is_some(),
                LUA_TBOOLEAN => {
                    let b = (self.api.lua_toboolean)(self.l, k) != 0;
                    json_str(if b { b"true" } else { b"false" }, &mut self.out);
                    true
                }
                _ => false,
            }
        }
    }

    unsafe fn value(&mut self, v: c_int) -> Result<bool, String> {
        unsafe {
            Ok(match (self.api.lua_type)(self.l, v) {
                LUA_TBOOLEAN => {
                    let b = (self.api.lua_toboolean)(self.l, v) != 0;
                    self.out
                        .extend_from_slice(if b { b"true" } else { b"false" });
                    true
                }
                LUA_TNUMBER => num((self.api.lua_tonumber)(self.l, v))
                    .map(|n| self.out.extend_from_slice(n.as_bytes()))
                    .is_some(),
                LUA_TSTRING => {
                    let s = self.bytes(v).to_vec();
                    match is_binary(&s) {
                        true => {
                            self.out.extend_from_slice(b"{\"~b\":\"");
                            base64(&s, &mut self.out);
                            self.out.extend_from_slice(b"\"}");
                        }
                        false => json_str(&s, &mut self.out),
                    }
                    true
                }
                LUA_TTABLE => self.table(v)?,
                LUA_TUSERDATA => self.vec(v),
                _ => false,
            })
        }
    }

    /// Vector/Angle via ILuaBase. Inside a coroutine ILuaBase acts on the running thread's stack,
    /// not main's (its pop once ate lua_next's key: "invalid key to 'next'", crash). So the value
    /// goes on top of both stacks, ILuaBase never pops, and both tops are restored afterwards.
    unsafe fn vec(&mut self, v: c_int) -> bool {
        unsafe {
            let (b, vt) = (self.base.cast::<c_void>(), (*self.base).vt());
            let (tl, tm) = ((self.api.lua_gettop)(self.l), (self.api.lua_gettop)(self.main));
            (self.api.lua_pushvalue)(self.l, v);
            if self.l != self.main {
                (self.api.lua_pushvalue)(self.l, v);
                (self.api.lua_xmove)(self.l, self.main, 1);
            }
            let r = match (vt.get_type)(b, -1) {
                types::VECTOR => Some((b'[', b']', *(vt.get_vector)(b, -1))),
                types::ANGLE => Some((b'{', b'}', *(vt.get_angle)(b, -1))),
                _ => None,
            };
            (self.api.lua_settop)(self.l, tl);
            if self.l != self.main {
                (self.api.lua_settop)(self.main, tm);
            }
            r.map(|(open, close, [x, y, z])| {
                // f32 Display: shortest round-trip, never exponent
                let f = |n: f32| {
                    if n.is_finite() {
                        format!("{n}")
                    } else {
                        "0".into()
                    }
                };
                let s = format!("{} {} {}", f(x), f(y), f(z));
                json_str(&[&[open], s.as_bytes(), &[close]].concat(), &mut self.out);
            })
            .is_some()
        }
    }

    /// false = back-reference to an ancestor (entry dropped; dupe tables like Wire/ACF data link back).
    unsafe fn table(&mut self, t: c_int) -> Result<bool, String> {
        unsafe {
            let p = (self.api.lua_topointer)(self.l, t);
            if self.path.contains(&p) {
                return Ok(false);
            }
            if self.path.len() >= MAX_DEPTH || (self.api.lua_checkstack)(self.l, 4) == 0 {
                return Err("table nested too deep".into());
            }
            self.path.push(p);
            self.out.push(b'{');
            let mut first = true;
            (self.api.lua_pushnil)(self.l);
            while (self.api.lua_next)(self.l, t) != 0 {
                let top = (self.api.lua_gettop)(self.l);
                let mark = self.out.len();
                if !first {
                    self.out.push(b',');
                }
                let kept = self.key(top - 1) && {
                    self.out.push(b':');
                    self.value(top)?
                };
                match kept {
                    true => first = false,
                    false => self.out.truncate(mark),
                }
                (self.api.lua_settop)(self.l, -2); // pop value, keep key for lua_next
            }
            self.path.pop();
            self.out.push(b'}');
            Ok(true)
        }
    }
}

/// Encodes `tab`. Must run on the Lua thread that called (main thread or its coroutine).
pub fn encode(lua: &Lua, tab: &LuaTable) -> rsgdll::Result<Vec<u8>> {
    let base = lua.base()?;
    let g = lua.guard();
    tab.0.push(lua)?;
    let mut e = Enc {
        api: lua.api(),
        l: lua.raw(),
        main: lua.main_thread(),
        base,
        out: Vec::with_capacity(4096),
        path: Vec::new(),
    };
    // SAFETY: plain stack ops on a table without metamethod use (lua_next/rawlike reads);
    // stack space is reserved per level, the main stack gets 2 slots for Vector reads,
    // and the guard restores the stack top on every exit path.
    let r = unsafe {
        match (e.api.lua_checkstack)(e.main, 2) {
            0 => Err("main stack full".to_string()),
            _ => e.table((e.api.lua_gettop)(e.l)),
        }
    };
    drop(g);
    r.map(|_| e.out).map_err(rsgdll::Error::msg)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn helpers() {
        let b64 = |s: &[u8]| {
            let mut o = Vec::new();
            base64(s, &mut o);
            String::from_utf8(o).unwrap()
        };
        assert_eq!(b64(b""), "");
        assert_eq!(b64(b"f"), "Zg==");
        assert_eq!(b64(b"fo"), "Zm8=");
        assert_eq!(b64(b"foo"), "Zm9v");
        assert_eq!(b64(b"\0\xffx\n"), "AP94Cg==");
        assert!(is_binary(b"\0") && is_binary("é".as_bytes()) && !is_binary(b"a\tb\r\n"));
        [
            "123", " 5 ", "1e3", "0x1F", "-0X2", ".5", "inf", "nan", "~s:x",
        ]
        .iter()
        .for_each(|k| assert!(key_needs_prefix(k.as_bytes()), "{k}"));
        ["Pos", "x1", "0x", "", "~sx"]
            .iter()
            .for_each(|k| assert!(!key_needs_prefix(k.as_bytes()), "{k}"));
        assert_eq!(num(3.0).unwrap(), "3");
        assert_eq!(num(-0.5).unwrap(), "-0.5");
        assert_eq!(num(1e20).unwrap(), "100000000000000000000");
        assert!(num(f64::NAN).is_none() && num(f64::INFINITY).is_none());
        let mut o = Vec::new();
        json_str(b"a\"\\\n\x01", &mut o);
        assert_eq!(o, b"\"a\\\"\\\\\\n\\u0001\"");
    }
}
