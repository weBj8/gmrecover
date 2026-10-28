-- gmrecover: periodic crash-recovery snapshots of player-owned builds.
-- Serialization runs in a coroutine under a per-tick time budget; compression and disk IO
-- run on DLL worker threads (gmrecover.Save / gmrecover.Load), so the main thread never waits on IO.
if not util.IsBinaryModuleInstalled("gmrecover") then
    MsgN("[gmrecover] binary module gmsv_gmrecover not installed; addon disabled")
    return
end
require("gmrecover")
-- Uses AdvDupe2's copy/paste engine (Wire, ACF/ACE and constraint alignment depend on it).

local FORMAT = 2 -- 2: AdvDupe2 tables; 1 (vanilla duplicator) is not restorable
local FLAGS = { FCVAR_ARCHIVE, FCVAR_PROTECTED }
local cv_enabled = CreateConVar("gmrecover_enabled", "1", FLAGS, "Autosave on/off", 0, 1)
local cv_interval = CreateConVar("gmrecover_interval", "60", FLAGS, "Seconds between autosaves", 10)
local cv_keep = CreateConVar("gmrecover_keep", "5", FLAGS, "Snapshots kept on disk", 1, 1000)
local cv_level = CreateConVar("gmrecover_level", "3", FLAGS, "zstd level (1-19)", 1, 19)
local cv_budget = CreateConVar("gmrecover_budget_ms", "2", FLAGS, "Max ms of Lua work per tick", 0.1, 50)
local cv_holdoff = CreateConVar("gmrecover_holdoff", "600", FLAGS,
    "After a crash, delay autosave this many seconds unless restored/discarded", 0)
local cv_autorestore = CreateConVar("gmrecover_autorestore", "5", FLAGS,
    "Restore the last snapshot this many seconds after map load, after crash/shutdown/changelevel (0 = off)", 0)

local function log(...) MsgN("[gmrecover] ", ...) end
local function slot() return (game.GetMap():gsub("[^%w_%-]", "_")) end

-- ---------- settings persistence ----------
-- FCVAR_ARCHIVE is only written on clean shutdown; a crash would lose changes, so mirror to data/.
local SETTINGS = { "gmrecover_enabled", "gmrecover_interval", "gmrecover_keep", "gmrecover_level",
    "gmrecover_budget_ms", "gmrecover_holdoff", "gmrecover_autorestore" }
local SETTINGS_FILE = "gmrecover/settings.json"
local is_setting = {}
for _, n in ipairs(SETTINGS) do is_setting[n] = true end

local function persist_settings()
    local t = {}
    for _, n in ipairs(SETTINGS) do t[n] = GetConVar(n):GetString() end
    file.CreateDir("gmrecover")
    file.Write(SETTINGS_FILE, util.TableToJSON(t, true))
end

do
    local saved = util.JSONToTable(file.Read(SETTINGS_FILE, "DATA") or "") or {}
    for n, v in pairs(saved) do
        if is_setting[n] then GetConVar(n):SetString(tostring(v)) end
    end
end

-- ---------- crash detection ----------
-- state.json = { map, clean, redirect }. Written clean=false at boot, clean=true on ShutDown
-- (fires for both quit and changelevel). clean=false at boot = last run crashed.
-- redirect: we changelevel'd away from a wrong map to recover a crash; next boot is still a crash recovery.
local STATE_FILE = "gmrecover/state.json"
local LEGACY_MARKER = "gmrecover/running.txt"
local prev = util.JSONToTable(file.Read(STATE_FILE, "DATA") or "") or {}
local legacy_crash = file.Exists(LEGACY_MARKER, "DATA")
file.Delete(LEGACY_MARKER)

--- Pure: how the previous run ended, given the previous state and current map.
local function boot_kind(p, map, legacy)
    if legacy or p.clean == false then return "crash" end
    if p.redirect then return "crash" end
    if not p.map then return "first" end
    return p.map == map and "shutdown" or "changelevel"
end

local boot = boot_kind(prev, game.GetMap(), legacy_crash)
local crashed = boot == "crash"
local crash_map = crashed and (prev.redirect or prev.map) or nil
local redirect_to -- set when this boot must changelevel to crash_map
if crashed and crash_map and crash_map ~= game.GetMap() then
    if file.Exists("maps/" .. crash_map .. ".bsp", "GAME") then
        redirect_to = crash_map
    else
        log("crashed map ", crash_map, " not installed; recovering on ", game.GetMap())
    end
end

local function write_state(clean)
    file.CreateDir("gmrecover")
    file.Write(STATE_FILE, util.TableToJSON({ map = game.GetMap(), clean = clean, redirect = redirect_to }))
end
write_state(false)
log("previous run ended by ", boot, "; last map ", tostring(prev.map), "; current map ", game.GetMap())
hook.Add("ShutDown", "gmrecover.marker", function()
    write_state(true)
    log("clean shutdown/changelevel; latest map ", game.GetMap())
end)

-- ---------- networking ----------
util.AddNetworkString("gmrecover.notify") -- S->C: kind(uint3), text
util.AddNetworkString("gmrecover.state")  -- S->C: json state for the admin menu
util.AddNetworkString("gmrecover.action") -- C->S: action string, json args

local NOTIFY = { info = 0, error = 1, success = 2, warn = 3 }
--- Toast on clients; `target` nil = everyone.
local function notify(target, kind, text)
    net.Start("gmrecover.notify")
    net.WriteUInt(NOTIFY[kind] or 0, 3)
    net.WriteString(text)
    if target then net.Send(target) else net.Broadcast() end
end

local function admins()
    local t = {}
    for _, p in player.Iterator() do if p:IsSuperAdmin() then t[#t + 1] = p end end
    return t
end

-- ---------- time-budgeted job runner (one job at a time) ----------
local job -- { co = coroutine, name = string }
local deadline = 0
local function yield_if_spent()
    if SysTime() > deadline then coroutine.yield() end
end

local function start_job(name, fn)
    if job then log("busy: ", job.name, " still running") return false end
    job = { name = name, co = coroutine.create(fn) }
    return true
end

hook.Add("Think", "gmrecover.job", function()
    if not job then return end
    deadline = SysTime() + cv_budget:GetFloat() / 1000
    local ok, err = coroutine.resume(job.co)
    if not ok then log(job.name, " failed: ", tostring(err)) end
    if not ok or coroutine.status(job.co) == "dead" then job = nil end
end)

-- ---------- ownership ----------
local function owner_sid(ent)
    if not ent.CPPIGetOwner then return nil end
    local ply = ent:CPPIGetOwner()
    return IsValid(ply) and ply:IsPlayer() and ply:SteamID64() or nil
end

local function savable(ent)
    return IsValid(ent) and not ent:IsPlayer() and not ent:IsWeapon() and not ent:IsWorld()
        and not ent:CreatedByMap() and not ent:IsConstraint()
end

-- ---------- AdvDupe2 bridge ----------
-- AD2's copy functions are file-locals; reach them through AreaCopy's upvalues so entities are
-- copied one at a time (spread across ticks) in exactly AD2's format. That format carries Wire
-- links (WireDupeInfo), ACF/ACE links (EntityMods + PostEntityPaste), and constraint pose data
-- (BuildDupeInfo) that axis/ballsocket/slider need to come back aligned.
local ZERO_V, ZERO_A = Vector(0, 0, 0), Angle(0, 0, 0)
local ad2
local function ad2_api()
    if ad2 then return ad2 end
    local dup = AdvDupe2 and AdvDupe2.duplicator
    if not (dup and dup.AreaCopy and AdvDupe2.InitPastingQueue) then return nil, "AdvDupe2 is not loaded" end
    local found = {}
    for i = 1, 64 do
        local name, value = debug.getupvalue(dup.AreaCopy, i)
        if not name then break end
        found[name] = value
    end
    if not (isfunction(found.CopyEntTable) and isfunction(found.CopyConstraintTable)) then
        return nil, "AdvDupe2 internals changed (CopyEntTable/CopyConstraintTable not found)"
    end
    ad2 = { copy_ent = found.CopyEntTable, copy_con = found.CopyConstraintTable }
    return ad2
end

-- AD2's CopyEntTable freezes every bone while copying. Record motion, sleep and velocity first
-- and put them back, so an autosave never stops a moving vehicle.
local function copy_entity(api, ent)
    local bones, frozen = {}, {}
    for b = 0, ent:GetPhysicsObjectCount() - 1 do
        local phys = ent:GetPhysicsObjectNum(b)
        if IsValid(phys) then
            local moving = phys:IsMoveable()
            bones[b] = { phys = phys, moving = moving, asleep = phys:IsAsleep(),
                vel = phys:GetVelocity(), angvel = phys:GetAngleVelocity() }
            frozen[b] = not moving
        end
    end
    local ok, tab = pcall(api.copy_ent, ent, ZERO_V)
    for _, s in pairs(bones) do
        if IsValid(s.phys) then
            s.phys:EnableMotion(s.moving)
            if s.moving and s.asleep then
                s.phys:Sleep()
            elseif s.moving then
                s.phys:Wake()
                s.phys:SetVelocityInstantaneous(s.vel)
                s.phys:SetAngleVelocityInstantaneous(s.angvel)
            end
        end
    end
    if not ok then return nil, tab end
    return tab, frozen
end

local CON_KEYS = { "Ent", "Ent1", "Ent2", "Ent3", "Ent4" }
--- Owner of a constraint when every non-world entity in it has that same owner, else nil.
local function constraint_owner(con, owner_of)
    local sid
    for _, key in ipairs(CON_KEYS) do
        local e = con[key]
        if e ~= nil and not (isentity(e) and e:IsWorld()) then
            local s = IsValid(e) and owner_of[e]
            -- shortcut: constraints between two owners' builds are dropped (each owner pastes separately); merge groups if builders share contraptions
            if not s or (sid and s ~= sid) then return nil end
            sid = s
        end
    end
    return sid
end

-- ---------- serialization ----------
-- One record per line, so save and restore can both be spread across ticks:
--   H\t<json header>
--   E\t<sid64>\t<entindex>\t<json AD2 entity table>\t<json {bone = frozen}>
--   C\t<sid64>\t<json AD2 constraint table>
local function serialize(carry)
    local api, err = ad2_api()
    if not api then error(err) end
    local lines = { "H\t" .. util.TableToJSON({ format = FORMAT, map = game.GetMap() }) }
    local owner_of, list = {}, {}
    for _, ent in ents.Iterator() do
        if savable(ent) then
            local sid = owner_sid(ent)
            if sid then owner_of[ent] = sid; list[#list + 1] = ent end
        end
    end
    yield_if_spent()
    local seen, count = {}, 0
    for _, ent in ipairs(list) do
        if IsValid(ent) then
            -- tab nil + info nil: AD2 says not copyable (DoNotDuplicate etc.), skip silently
            local tab, info = copy_entity(api, ent)
            local ok, json = tab ~= nil, nil
            if tab then ok, json = pcall(util.TableToJSON, tab) end
            if ok and json then
                lines[#lines + 1] = table.concat({ "E", owner_of[ent], ent:EntIndex(), json,
                    util.TableToJSON(info) }, "\t")
                count = count + 1
            elseif isstring(info) or isstring(json) then
                log("skipped ", tostring(ent), ": ", tostring(isstring(info) and info or json))
            end
            for _, c in pairs(ent.Constraints or {}) do
                if IsValid(c) and not seen[c] and not c.DoNotDuplicate then
                    seen[c] = true
                    local sid = constraint_owner(c:GetTable(), owner_of)
                    local okc, ct = false, nil
                    if sid then okc, ct = pcall(api.copy_con, table.Copy(c:GetTable()), ZERO_V) end
                    local okj, cj = false, nil
                    if okc and ct then okj, cj = pcall(util.TableToJSON, ct) end
                    if okj and cj then lines[#lines + 1] = "C\t" .. sid .. "\t" .. cj end
                end
            end
        end
        yield_if_spent()
    end
    -- builds of owners still offline since the last restore are not on the map; keep them
    for _, block in ipairs(carry) do
        for _, l in ipairs(block) do lines[#lines + 1] = l end
    end
    return table.concat(lines, "\n"), count
end

local function parse(data)
    local header, groups, order = nil, {}, {}
    local function group(sid)
        local g = groups[sid]
        if not g then
            g = { Entities = {}, Constraints = {}, frozen = {}, lines = {}, count = 0 }
            groups[sid] = g
            order[#order + 1] = sid
        end
        return g
    end
    for line in data:gmatch("[^\n]+") do
        local kind = line:sub(1, 1)
        if kind == "H" then
            header = util.JSONToTable(line:sub(3))
        elseif kind == "E" then
            local sid, idx, json, fz = line:match("^E\t(%d+)\t(%d+)\t([^\t]*)\t([^\t]*)$")
            local tab = json and util.JSONToTable(json)
            if tab then
                local g, i = group(sid), tonumber(idx)
                g.Entities[i] = tab
                g.frozen[i] = util.JSONToTable(fz) or {}
                g.lines[#g.lines + 1] = line
                g.count = g.count + 1
            end
        elseif kind == "C" then
            local sid, json = line:match("^C\t(%d+)\t(.*)$")
            local tab = json and util.JSONToTable(json)
            if tab then
                local g = group(sid)
                g.Constraints[#g.Constraints + 1] = tab
                g.lines[#g.lines + 1] = line
            end
        end
        yield_if_spent()
    end
    return header, groups, order
end

-- ---------- restore ----------
-- Each owner's build goes through AdvDupe2's paste queue as that owner: real entity factories
-- (ACE needs a player), AD2_SpawnRate pacing, an undo entry, progress bar. Offline owners
-- wait in `pending` until they join, and are kept in every autosave meanwhile.
local pending = {} -- sid64 -> group
local active = {}  -- AD2 Queue.EntityList -> { ply, group }
local bypass = {}  -- ply -> true while their restore queue runs
local capturing

-- The build was already within limits before the crash; don't let limits cut it in half.
-- shortcut: the owner also skips limits for anything they spawn while their restore queue runs; track restored entities if abused
local function allow(ply) if bypass[ply] then return true end end
for _, h in ipairs({ "PlayerCheckLimit", "PlayerSpawnProp", "PlayerSpawnSENT", "PlayerSpawnVehicle",
    "PlayerSpawnEffect", "PlayerSpawnRagdoll", "PlayerSpawnNPC", "PlayerSpawnSWEP", "PlayerSpawnObject" }) do
    hook.Add(h, "gmrecover.bypass", allow)
end

hook.Add("AdvDupe_InitPastingQueue", "gmrecover.capture", function(_, queue)
    if capturing and queue then active[queue.EntityList] = capturing end
end)

local function queue_paste(ply, g)
    if not ad2_api() or not IsValid(ply) then return false end
    local ad = ply.AdvDupe2 or {}
    ply.AdvDupe2 = ad
    local keep = { ad.Entities, ad.Constraints, ad.Name, ad.Revision }
    ad.Entities, ad.Constraints, ad.Name = g.Entities, g.Constraints, "gmrecover"
    ad.Revision = AdvDupe2.CodecRevision or 5
    capturing = { ply = ply, group = g }
    bypass[ply] = true
    -- absolute positions: copied with offset 0, pasted at OrigPos 0; parenting restored
    local ok, err = pcall(AdvDupe2.InitPastingQueue, ply, ZERO_V, ZERO_A, Vector(0, 0, 0), true, true, false, false)
    capturing = nil
    ad.Entities, ad.Constraints, ad.Name, ad.Revision = keep[1], keep[2], keep[3], keep[4]
    if not ok then
        bypass[ply] = nil
        log("paste for ", ply:Nick(), " failed: ", tostring(err))
        return false
    end
    notify(ply, "info", "Restoring " .. g.count .. " of your entities...")
    return true
end

hook.Add("AdvDupe_FinishPasting", "gmrecover.finish", function(data)
    local d = data and data[1]
    local info = d and active[d.EntityList]
    if not info then return end
    active[d.EntityList] = nil
    bypass[info.ply] = nil
    local n = 0
    for _, ent in pairs(d.CreatedEntities or {}) do
        if IsValid(ent) then
            n = n + 1
            if IsValid(info.ply) and ent.CPPISetOwner and ent:CPPIGetOwner() ~= info.ply then
                ent:CPPISetOwner(info.ply)
            end
            -- restored builds stay frozen; owners unfreeze what they need
            for b = 0, ent:GetPhysicsObjectCount() - 1 do
                local phys = ent:GetPhysicsObjectNum(b)
                if IsValid(phys) then phys:EnableMotion(false) end
            end
        end
    end
    log("restored ", n, "/", info.group.count, " entities for ", IsValid(info.ply) and info.ply:Nick() or "?")
    if IsValid(info.ply) then
        notify(info.ply, "success", ("%d of %d entities restored (frozen) with welds and wiring.")
            :format(n, info.group.count))
    end
end)

-- AD2 drops a queue without FinishPasting on error or undo; release its bypass too.
timer.Create("gmrecover.queuewatch", 5, 0, function()
    if not next(active) then return end
    local live = {}
    for _, q in ipairs(AdvDupe2 and AdvDupe2.JobManager and AdvDupe2.JobManager.Queue or {}) do
        live[q.EntityList] = true
    end
    for list, info in pairs(active) do
        if not live[list] then
            active[list] = nil
            bypass[info.ply] = nil
            log("restore queue for ", IsValid(info.ply) and info.ply:Nick() or "?", " was cancelled")
        end
    end
end)

hook.Add("PlayerInitialSpawn", "gmrecover.owner", function(ply)
    -- delay: AD2 sets up ply.AdvDupe2 and client net receivers are not ready yet
    timer.Simple(10, function()
        if not IsValid(ply) then return end
        local sid = ply:SteamID64()
        local g = pending[sid]
        if not g then return end
        pending[sid] = nil
        if not queue_paste(ply, g) then pending[sid] = g end
    end)
end)
hook.Add("PlayerDisconnected", "gmrecover.bypass", function(ply) bypass[ply] = nil end)

local function restore(data, path)
    local header, groups, order = parse(data)
    if not header or header.format ~= FORMAT then
        log("unsupported snapshot format in ", path)
        notify(admins(), "error", "Snapshot was written by an older gmrecover version and cannot be restored.")
        return
    end
    if header.map ~= game.GetMap() then log("snapshot is for map ", tostring(header.map)) return end
    local now, later = 0, 0
    for _, sid in ipairs(order) do
        local g = groups[sid]
        if queue_paste(player.GetBySteamID64(sid), g) then
            now = now + 1
        else
            pending[sid] = g
            later = later + 1
        end
        coroutine.yield() -- one owner per tick
    end
    log("restore from ", path, ": ", now, " owners pasting, ", later, " waiting to join")
    notify(nil, "success", ("Restore started for %d builders. %d offline builders get theirs when they join.")
        :format(now, later))
end

-- ---------- save / scheduling ----------
local holdoff_until = 0
local last_save = { time = 0, path = "", count = 0 }
local function save(reason)
    -- mid-restore the map is half pasted; a snapshot now would rotate out the good ones
    if next(active) then log("save skipped (", reason, "): restore in progress") return false end
    return start_job("save", function()
        local carry = {}
        for _, g in pairs(pending) do carry[#carry + 1] = g.lines end
        local data, count = serialize(carry)
        count = count + #carry
        if count == 0 then log("nothing to save (", reason, ")") return end
        gmrecover.Save(slot(), data, cv_keep:GetInt(), cv_level:GetInt(), function(err, path)
            if err then log("save failed: ", err)
            elseif path then
                last_save = { time = os.time(), path = path, count = count }
                log("saved ", count, " entities (", reason, ") -> ", path)
            end
        end)
    end)
end

timer.Create("gmrecover.autosave", cv_interval:GetFloat(), 0, function()
    if cv_enabled:GetBool() and CurTime() >= holdoff_until then save("auto") end
end)
cvars.AddChangeCallback("gmrecover_interval", function(_, _, new)
    timer.Adjust("gmrecover.autosave", math.max(tonumber(new) or 60, 10))
end, "gmrecover")
for _, n in ipairs(SETTINGS) do cvars.AddChangeCallback(n, persist_settings, "gmrecover.persist") end

-- Crash recovery stays "pending" until an admin restores or discards (or autorestore fires).
local recovery_pending = false

local function do_restore()
    if next(active) or job then
        log("restore refused: a save/restore is already running")
        notify(admins(), "error", "A save or restore is already running.")
        return
    end
    holdoff_until = 0
    recovery_pending = false
    timer.Remove("gmrecover.autorestore")
    gmrecover.Load(slot(), function(err, data, path)
        if err then log("load failed: ", err) notify(admins(), "error", "Load failed: " .. err) return end
        if not data then log("no valid snapshot for ", slot()) notify(admins(), "error", "No valid snapshot") return end
        if start_job("restore", function() restore(data, path) end) then
            log("restore started from ", path)
            notify(nil, "info", "Restoring builds from the last snapshot...")
        end
    end)
end

local function do_discard()
    holdoff_until = 0
    recovery_pending = false
    timer.Remove("gmrecover.autorestore")
    log("holdoff cleared; autosave resumes")
end

hook.Add("InitPostEntity", "gmrecover.holdoff", function()
    if redirect_to then
        log("crash detected on ", redirect_to, "; changing level to restore it")
        -- no autosave here: this map is not the one being recovered
        holdoff_until = math.huge
        timer.Simple(1, function() RunConsoleCommand("changelevel", redirect_to) end)
        return
    end
    if #gmrecover.List(slot()) == 0 then return end
    if crashed then
        recovery_pending = true
        if cv_holdoff:GetFloat() > 0 then holdoff_until = CurTime() + cv_holdoff:GetFloat() end
        log("crash detected; snapshot available. Run gmrecover_restore or gmrecover_discard")
    else
        log(boot, " detected; snapshot available for ", game.GetMap())
    end
    local delay = cv_autorestore:GetFloat()
    if delay > 0 then
        timer.Create("gmrecover.autorestore", delay, 1, do_restore)
        log("autorestore in ", delay, "s")
    end
end)

local function state_for(ply)
    return {
        settings = (function()
            local t = {}
            for _, n in ipairs(SETTINGS) do t[n] = GetConVar(n):GetString() end
            return t
        end)(),
        snapshots = gmrecover.List(slot()),
        last_save = last_save,
        recovery_pending = recovery_pending,
        holdoff_left = math.max(0, math.floor(holdoff_until - CurTime())),
        busy = job and job.name or nil,
        restoring = table.Count(active),
        waiting = table.Count(pending),
        admin = ply:IsSuperAdmin(),
    }
end

local function send_state(ply)
    local json = util.Compress(util.TableToJSON(state_for(ply)))
    net.Start("gmrecover.state")
    net.WriteUInt(#json, 16)
    net.WriteData(json, #json)
    net.Send(ply)
end

-- Builders learn about the crash on join; admins also get the recovery menu opened.
hook.Add("PlayerInitialSpawn", "gmrecover.crashnotice", function(ply)
    timer.Simple(5, function()
        if not IsValid(ply) or not recovery_pending then return end
        notify(ply, "warn", "The server restarted after a crash. Your builds can be restored by an admin.")
        if ply:IsSuperAdmin() then ply:ConCommand("gmrecover_menu") end
    end)
end)

local ACTIONS = {
    refresh = function() end,
    save = function(ply) if save("manual by " .. ply:Nick()) then notify(ply, "info", "Save started") end end,
    restore = function(ply) log(ply:Nick(), " requested restore") do_restore() end,
    discard = function(ply) do_discard() notify(ply, "info", "Recovery discarded; autosave resumed") end,
    set = function(ply, args)
        local name, value = args and args.name, args and args.value
        if not is_setting[name] or not tonumber(value) then return end
        GetConVar(name):SetString(tostring(tonumber(value)))
        log(ply:Nick(), " set ", name, " = ", value)
    end,
}

local next_action = {}
net.Receive("gmrecover.action", function(_, ply)
    if not IsValid(ply) or not ply:IsSuperAdmin() then return end -- trust boundary
    if (next_action[ply] or 0) > CurTime() then return end
    next_action[ply] = CurTime() + 0.25
    local act = ACTIONS[net.ReadString()]
    local args = util.JSONToTable(net.ReadString()) -- nil on bad JSON
    if not act then return end
    act(ply, args)
    send_state(ply)
end)
hook.Add("PlayerDisconnected", "gmrecover.ratelimit", function(ply) next_action[ply] = nil end)

-- ---------- commands (server console / superadmin) ----------
local function allowed(ply) return not IsValid(ply) or ply:IsSuperAdmin() end

concommand.Add("gmrecover_save", function(ply)
    if allowed(ply) and save("manual") then log("save started") end
end)

concommand.Add("gmrecover_restore", function(ply)
    if allowed(ply) then do_restore() end
end)

concommand.Add("gmrecover_discard", function(ply)
    if allowed(ply) then do_discard() end
end)

concommand.Add("gmrecover_list", function(ply)
    if not allowed(ply) then return end
    for i, p in ipairs(gmrecover.List(slot())) do log(i, ": ", p) end
end)
