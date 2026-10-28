-- gmrecover client: toasts for builders and the `gmrecover_menu` admin settings panel.
-- The server re-checks superadmin on every action; the client check only hides the UI.

local KINDS = { [0] = NOTIFY_GENERIC, [1] = NOTIFY_ERROR, [2] = NOTIFY_HINT, [3] = NOTIFY_GENERIC }
local SOUNDS = { [0] = "buttons/button15.wav", [1] = "buttons/button10.wav",
    [2] = "buttons/button14.wav", [3] = "buttons/blip1.wav" }

net.Receive("gmrecover.notify", function()
    local kind, text = net.ReadUInt(3), net.ReadString()
    notification.AddLegacy(text, KINDS[kind] or NOTIFY_GENERIC, kind == 3 and 12 or 6)
    surface.PlaySound(SOUNDS[kind] or SOUNDS[0])
    chat.AddText(Color(90, 170, 255), "[gmrecover] ", color_white, text)
end)

local function action(name, args)
    net.Start("gmrecover.action")
    net.WriteString(name)
    net.WriteString(util.TableToJSON(args or {}))
    net.SendToServer()
end

-- name, label, min, max, decimals; checkbox when min/max are nil
local SETTINGS = {
    { "gmrecover_enabled", "Autosave enabled" },
    { "gmrecover_interval", "Autosave interval (s)", 10, 3600, 0 },
    { "gmrecover_keep", "Snapshots kept", 1, 50, 0 },
    { "gmrecover_level", "Compression level (zstd)", 1, 19, 0 },
    { "gmrecover_budget_ms", "Lua budget per tick (ms)", 0.1, 20, 1 },
    { "gmrecover_holdoff", "Autosave pause after crash (s)", 0, 3600, 0 },
    { "gmrecover_autorestore", "Auto-restore after crash (s, 0 = off)", 0, 3600, 0 },
}

local frame -- current menu, rebuilt on every open

--- Debounced so dragging a slider sends one update, not one per frame.
local function set_later(name, value)
    timer.Create("gmrecover.set." .. name, 0.5, 1, function() action("set", { name = name, value = value }) end)
end

local function status_text(st)
    local ls = st.last_save or {}
    -- optional lines are appended only when present: table.concat rejects nil holes
    local lines = { st.recovery_pending and "CRASH RECOVERY PENDING: restore or discard the last snapshot."
        or "Running normally." }
    if (st.holdoff_left or 0) > 0 then lines[#lines + 1] = "Autosave paused for " .. st.holdoff_left .. "s more." end
    if st.busy then lines[#lines + 1] = "Busy: " .. tostring(st.busy) end
    lines[#lines + 1] = (ls.time or 0) > 0
        and string.format("Last save: %s, %d entities", os.date("%H:%M:%S", ls.time), ls.count or 0)
        or "No save this session."
    return table.concat(lines, "\n")
end

local function build(st)
    if IsValid(frame) then frame:Remove() end
    frame = vgui.Create("DFrame")
    frame:SetTitle("gmrecover - crash recovery")
    frame:SetSize(480, 560)
    frame:Center()
    frame:MakePopup()

    local status = frame:Add("DLabel")
    status:Dock(TOP)
    status:DockMargin(4, 4, 4, 8)
    status:SetWrap(true)
    status:SetAutoStretchVertical(true)
    status:SetTextColor(st.recovery_pending and Color(255, 190, 60) or color_white)
    status:SetText(status_text(st))
    frame.status = status

    local buttons = frame:Add("DPanel")
    buttons:Dock(TOP)
    buttons:SetTall(28)
    buttons:SetPaintBackground(false)
    local function button(label, tip, fn)
        local b = buttons:Add("DButton")
        b:Dock(LEFT)
        b:DockMargin(0, 0, 4, 0)
        b:SetWide(110)
        b:SetText(label)
        b:SetTooltip(tip)
        b.DoClick = fn
        return b
    end
    button("Save now", "Take a snapshot now", function() action("save") end)
    button("Restore latest", "Paste the newest valid snapshot", function()
        Derma_Query("Paste the newest snapshot? Entities are added on top of what exists now.",
            "Restore", "Restore", function() action("restore") end, "Cancel")
    end)
    frame.discard = button("Discard recovery", "Ignore the crash snapshot and resume autosave",
        function() action("discard") end)
    frame.discard:SetEnabled(st.recovery_pending)
    button("Refresh", "Reload status from server", function() action("refresh") end)

    local form = frame:Add("DForm")
    form:Dock(TOP)
    form:DockMargin(0, 8, 0, 8)
    form:SetName("Settings (saved on the server)")
    for _, s in ipairs(SETTINGS) do
        local name, label, min, max, dec = s[1], s[2], s[3], s[4], s[5]
        local value = tonumber(st.settings[name]) or 0
        if min then
            local slider = form:NumSlider(label, nil, min, max, dec)
            slider:SetValue(value)
            slider.OnValueChanged = function(_, v) set_later(name, math.Round(v, dec)) end
        else
            local cb = form:CheckBox(label)
            cb:SetValue(value ~= 0)
            cb.OnChange = function(_, v) set_later(name, v and 1 or 0) end
        end
    end

    local list = frame:Add("DListView")
    list:Dock(FILL)
    list:SetMultiSelect(false)
    list:AddColumn("Snapshots for this map (newest first)")
    frame.list = list
    frame.fill_list = function(snaps)
        list:Clear()
        for _, p in ipairs(snaps) do list:AddLine(string.GetFileFromFilename(p)) end
    end
    frame.fill_list(st.snapshots or {})
end

--- Refresh live parts only, so sliders being dragged are not reset.
local function update(st)
    if not IsValid(frame) then return build(st) end
    frame.status:SetText(status_text(st))
    frame.status:SetTextColor(st.recovery_pending and Color(255, 190, 60) or color_white)
    frame.discard:SetEnabled(st.recovery_pending)
    frame.fill_list(st.snapshots or {})
end

local want_open = false
net.Receive("gmrecover.state", function()
    local len = net.ReadUInt(16)
    local st = util.JSONToTable(util.Decompress(net.ReadData(len)) or "")
    if not st or not st.admin then return end
    if want_open or IsValid(frame) then
        want_open = false
        update(st)
    end
end)

concommand.Add("gmrecover_menu", function()
    if not LocalPlayer():IsSuperAdmin() then
        chat.AddText(Color(90, 170, 255), "[gmrecover] ", color_white, "Settings are superadmin only.")
        return
    end
    if IsValid(frame) then frame:Remove() end
    want_open = true
    action("refresh")
end, nil, "Open the gmrecover crash-recovery settings (superadmin)")
