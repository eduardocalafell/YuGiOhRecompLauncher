-- main.lua -- ygo-recomp launcher, phase 1.
--
-- A boot-screen shell around the recompiled Yu-Gi-Oh! Forbidden Memories
-- game at C:\games\ygo-recomp\. It never touches the game/recompiler source
-- itself -- it only edits game.toml's [video].renderer field, writes
-- disc\YUGIOH.cue on first run, backs up saves\, and launches the built exe
-- as a subprocess. All the actual logic lives in core.lua; this file is
-- just an immediate-mode-style UI wired to it.

local core = require("core")
local utf8 = require("utf8")

local COLORS = {
    bg              = {0.10, 0.11, 0.13},
    panel           = {0.15, 0.16, 0.19},
    text            = {0.92, 0.92, 0.94},
    textDim         = {0.60, 0.62, 0.66},
    accent          = {0.55, 0.35, 0.85},
    accentText      = {1, 1, 1},
    button          = {0.22, 0.23, 0.27},
    buttonHover     = {0.28, 0.29, 0.34},
    buttonDisabled  = {0.17, 0.17, 0.19},
    buttonBorder    = {0.32, 0.33, 0.38},
    fieldBg         = {0.08, 0.09, 0.10},
    ok              = {0.35, 0.75, 0.45},
    warn            = {0.85, 0.55, 0.25},
    err             = {0.85, 0.35, 0.35},
}

local FONT_TITLE, FONT_SUB, FONT_NORMAL, FONT_SMALL

-- ------------------------------------------------------------- debug log
-- Always-on diagnostic log to a plain file next to wherever the exe/love
-- process's cwd is, so "runs fine for a few seconds then lags" can be
-- diagnosed from a file afterward even when launched via double-click
-- (no console attached). Overwritten fresh each run (mode "w").
local DEBUG_LOG_PATH = "launcher-debug.log"
local debugLogFile = io.open(DEBUG_LOG_PATH, "w")

local function dlog(fmt, ...)
    if not debugLogFile then return end
    debugLogFile:write(string.format("[%9.3f] " .. fmt, love.timer.getTime(), ...) .. "\n")
    debugLogFile:flush()
end

-- LÖVE runs on LuaJIT (Lua 5.1 semantics): the varargs-unpack function is
-- the global `unpack`, not `table.unpack` (that's a 5.2+ addition and is
-- simply absent here -- calling it throws "attempt to call a nil value").
local unpack = table.unpack or unpack

-- Wraps fn, always logs how long it took (ms) under `label`, always returns
-- fn's own results untouched.
local function timed(label, fn)
    return function(...)
        local t0 = love.timer.getTime()
        local results = { fn(...) }
        dlog("%-24s %7.1fms", label, (love.timer.getTime() - t0) * 1000)
        return unpack(results)
    end
end

-- persistent widget state (must survive across frames)
local DiscField = { value = "", focused = false }
local ShowDiscWizard = false
local CurrentRenderer = nil
local Log = {}

-- Cached filesystem reads. core.list_saves()/read_cue_source_path() shell
-- out (dir/cmd), so calling them from love.draw() (60x/sec) was spawning a
-- new process every frame -- the actual cause of sluggish UI response.
-- Refreshed on load, right after any action that could change them, and
-- otherwise on a slow timer (SAVE_REFRESH_INTERVAL) so an external change
-- (e.g. a save made by the game itself while the launcher stays open) still
-- shows up without re-shelling out every frame.
local Saves = {}
local DiscSourcePath = nil
local SaveRefreshTimer = 0
local SAVE_REFRESH_INTERVAL = 2.0

-- per-frame widget registries, rebuilt every love.draw()
local UI = { buttons = {}, fields = {} }

local function resetFrame()
    UI.buttons = {}
    UI.fields = {}
end

local function log(msg)
    table.insert(Log, 1, os.date("%H:%M:%S") .. "  " .. msg)
    if #Log > 7 then table.remove(Log) end
    print(msg)
end

-- ------------------------------------------------------------- draw utils

local function button(x, y, w, h, label, opts)
    opts = opts or {}
    local mx, my = love.mouse.getPosition()
    local hot = (not opts.disabled) and mx >= x and mx <= x + w and my >= y and my <= y + h

    local bg = COLORS.button
    if opts.disabled then
        bg = COLORS.buttonDisabled
    elseif opts.active then
        bg = COLORS.accent
    elseif hot then
        bg = COLORS.buttonHover
    end

    love.graphics.setColor(bg)
    love.graphics.rectangle("fill", x, y, w, h, 6, 6)
    love.graphics.setColor(COLORS.buttonBorder)
    love.graphics.rectangle("line", x, y, w, h, 6, 6)

    love.graphics.setColor(opts.disabled and COLORS.textDim or (opts.active and COLORS.accentText or COLORS.text))
    local font = love.graphics.getFont()
    local tw, th = font:getWidth(label), font:getHeight()
    love.graphics.print(label, math.floor(x + (w - tw) / 2), math.floor(y + (h - th) / 2))

    if not opts.disabled then
        table.insert(UI.buttons, { x = x, y = y, w = w, h = h, action = opts.action })
    end
    return hot
end

local function textField(field, x, y, w, h, placeholder)
    love.graphics.setColor(COLORS.fieldBg)
    love.graphics.rectangle("fill", x, y, w, h, 4, 4)
    love.graphics.setColor(field.focused and COLORS.accent or COLORS.buttonBorder)
    love.graphics.rectangle("line", x, y, w, h, 4, 4)

    love.graphics.setScissor(x + 1, y + 1, w - 2, h - 2)
    local font = love.graphics.getFont()
    if field.value == "" then
        love.graphics.setColor(COLORS.textDim)
        love.graphics.print(placeholder or "", x + 8, y + (h - font:getHeight()) / 2)
    else
        love.graphics.setColor(COLORS.text)
        local shown = field.value
        local avail = w - 16
        -- left-clip long paths so the tail (the interesting/most recently
        -- typed part) stays visible instead of scrolling off to the right
        while font:getWidth(shown) > avail and #shown > 0 do
            shown = shown:sub(2)
        end
        love.graphics.print(shown, x + 8, y + (h - font:getHeight()) / 2)
    end
    love.graphics.setScissor()

    table.insert(UI.fields, { x = x, y = y, w = w, h = h, field = field })
end

local function sectionLabel(text, x, y)
    love.graphics.setFont(FONT_SUB)
    love.graphics.setColor(COLORS.text)
    love.graphics.print(text, x, y)
    love.graphics.setFont(FONT_NORMAL)
end

-- ------------------------------------------------------------------ state

-- core.list_saves() now enumerates saves\ in-process via the Win32 FFI
-- (FindFirstFile) rather than shelling out, so it's microseconds and never
-- flashes a console. SavesWorker keeps the enumeration off the main thread
-- anyway (cheap insurance against a pathologically large/network saves\
-- folder): requestSavesRefresh() just posts a request and returns
-- immediately; pollSavesRefresh(), called every love.update(), picks up the
-- result whenever it's ready without ever blocking.
local SavesWorker = love.thread.newThread("saves_worker.lua")
local SavesRequestChannel = love.thread.getChannel("saves_refresh_request")
local SavesResultChannel = love.thread.getChannel("saves_refresh_result")
local SavesRefreshInFlight = false
local SavesRefreshStartedAt = 0

local function requestSavesRefresh()
    if SavesRefreshInFlight then return end
    SavesRefreshInFlight = true
    SavesRefreshStartedAt = love.timer.getTime()
    SavesRequestChannel:push(true)
end

local function pollSavesRefresh()
    local result = SavesResultChannel:pop()
    if result then
        Saves = result
        SavesRefreshInFlight = false
        dlog("refreshSaves (threaded)   %7.1fms", (love.timer.getTime() - SavesRefreshStartedAt) * 1000)
    end
end

-- Same name used everywhere a refresh is wanted (initial load, post-backup,
-- the periodic timer) -- always just posts the request, never blocks. The
-- very first frame or two after love.load() will show an empty save list
-- until the worker's first result comes back; deliberate trade for a UI
-- thread that never stalls.
local refreshSaves = requestSavesRefresh

local refreshDiscSourcePath = timed("refreshDiscSourcePath", function()
    DiscSourcePath = core.read_cue_source_path()
end)

local function refreshState()
    local r, err = core.get_renderer()
    CurrentRenderer = r
    if not r then log("WARNING: " .. tostring(err)) end
    ShowDiscWizard = not core.cue_exists()
    if not core.exe_exists() then
        log("WARNING: game exe not found at " .. core.EXE_PATH)
    end
    refreshSaves()
    refreshDiscSourcePath()
end

-- ------------------------------------------------------------- callbacks

local function onSelectRenderer(name)
    if CurrentRenderer == name then return end
    local ok, err = core.set_renderer(name)
    if ok then
        CurrentRenderer = name
        log("Renderer set to '" .. name .. "' in game.toml")
    else
        log("ERROR setting renderer: " .. tostring(err))
    end
end

local function trim(s)
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub('^"(.*)"$', "%1") -- drop a pasted pair of wrapping quotes
    return s
end

local function onBrowseDisc()
    -- Best-effort native Open File dialog via a throwaway PowerShell process.
    -- NOTE: this blocks the launcher's UI thread until the dialog closes
    -- (io.popen waits for the child) -- acceptable for a first-run wizard
    -- click, called out as a known simplification for a future pass.
    local script =
        "Add-Type -AssemblyName System.Windows.Forms; " ..
        "$f = New-Object System.Windows.Forms.OpenFileDialog; " ..
        "$f.Title = 'Select your Yu-Gi-Oh! Forbidden Memories disc dump'; " ..
        "$f.Filter = 'Disc images (*.img;*.bin;*.cue;*.ccd)|*.img;*.bin;*.cue;*.ccd|All files (*.*)|*.*'; " ..
        "if ($f.ShowDialog() -eq 'OK') { Write-Output $f.FileName }"
    local cmd = 'powershell -NoProfile -WindowStyle Hidden -Command "' .. script .. '"'
    local p = io.popen(cmd, "r")
    if not p then
        log("Native file dialog unavailable -- type the path manually.")
        return
    end
    local result = p:read("*l")
    p:close()
    if result and result ~= "" then
        DiscField.value = result
        log("Selected: " .. result)
    end
end

local function onCreateCue()
    local path = trim(DiscField.value)
    local ok, err = core.create_cue(path, core.CUE_PATH)
    if ok then
        log("Created disc\\YUGIOH.cue -> " .. path)
        ShowDiscWizard = false
        refreshDiscSourcePath()
    else
        log("ERROR creating .cue: " .. tostring(err))
    end
end

local function onReconfigureDisc()
    DiscField.value = core.read_cue_source_path() or ""
    ShowDiscWizard = true
end

local function onCancelWizard()
    if core.cue_exists() then ShowDiscWizard = false end
end

local function onBackupSaves()
    local backedUp, errors = core.backup_saves()
    refreshSaves()
    for _, e in ipairs(errors) do log("backup error -- " .. e) end
    if #backedUp > 0 then
        log("Backed up " .. #backedUp .. " file(s) to saves\\backups\\")
    elseif #errors == 0 then
        log("No save files found in saves\\ to back up.")
    end
end

local function onPlay()
    local ok, msg = core.launch_game()
    if ok then
        log("Launching game... (" .. tostring(msg) .. ")")
    else
        log("Cannot launch: " .. tostring(msg))
    end
end

-- Wrap the click handlers that can shell out / touch disk so their duration
-- always lands in the debug log too (Lua closures capture these locals by
-- reference, so reassigning here still reaches every button action already
-- wired to them in love.draw()).
onSelectRenderer = timed("onSelectRenderer", onSelectRenderer)
onBrowseDisc = timed("onBrowseDisc", onBrowseDisc)
onCreateCue = timed("onCreateCue", onCreateCue)
onBackupSaves = timed("onBackupSaves", onBackupSaves)
onPlay = timed("onPlay", onPlay)

-- --------------------------------------------------------------- love.*

function love.load(argv)
    FONT_TITLE  = love.graphics.newFont(28)
    FONT_SUB    = love.graphics.newFont(18)
    FONT_NORMAL = love.graphics.newFont(15)
    FONT_SMALL  = love.graphics.newFont(13)
    love.graphics.setFont(FONT_NORMAL)

    for _, a in ipairs(argv or {}) do
        if a == "--selftest" then
            local selftest = require("selftest")
            selftest.run()
            love.event.quit()
            return
        end
    end

    local major, minor, revision, codename = love.getVersion()
    dlog("launcher started -- LOVE %d.%d.%d (%s), OS=%s", major, minor, revision, codename, love.system.getOS())
    SavesWorker:start()
    log("ygo-recomp launcher ready.")
    refreshState()
end

-- Periodic fps/frame-time/memory snapshot, always logged (not just on
-- trouble) so a slow-onset pattern like "fine for a few seconds, then
-- starts to lag" shows up as a visible trend in launcher-debug.log rather
-- than needing to be caught live. SLOW FRAME lines flag individual frames
-- worse than 20fps (dt > 50ms) as they happen, with whatever was hot in the
-- previous ~1s of snapshots giving context for what was running at the time.
local SnapshotTimer = 0
local SNAPSHOT_INTERVAL = 1.0

function love.update(dt)
    pollSavesRefresh()

    if SavesWorker then
        local workerErr = SavesWorker:getError()
        if workerErr then
            dlog("SavesWorker thread error: %s", tostring(workerErr))
            log("ERROR: save-list background thread died -- " .. tostring(workerErr))
            SavesWorker = nil -- stop checking; avoid spamming the log every frame
        end
    end

    SaveRefreshTimer = SaveRefreshTimer + dt
    if SaveRefreshTimer >= SAVE_REFRESH_INTERVAL then
        SaveRefreshTimer = 0
        refreshSaves()
    end

    if dt > 0.05 then
        dlog("SLOW FRAME dt=%.1fms (%.1f fps-equivalent)", dt * 1000, 1 / dt)
    end

    SnapshotTimer = SnapshotTimer + dt
    if SnapshotTimer >= SNAPSHOT_INTERVAL then
        SnapshotTimer = 0
        dlog("snapshot fps=%d dt=%.1fms lua_mem=%.1fKB buttons=%d fields=%d",
            love.timer.getFPS(), dt * 1000, collectgarbage("count"),
            #UI.buttons, #UI.fields)
    end
end

function love.focus(focused)
    dlog("window focus -> %s", tostring(focused))
end

function love.quit()
    dlog("launcher quitting")
end

function love.mousepressed(x, y, mbutton)
    if mbutton ~= 1 then return end
    for _, f in ipairs(UI.fields) do
        f.field.focused = x >= f.x and x <= f.x + f.w and y >= f.y and y <= f.y + f.h
    end
    for _, b in ipairs(UI.buttons) do
        if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
            if b.action then b.action() end
            break
        end
    end
end

function love.textinput(t)
    for _, f in ipairs(UI.fields) do
        if f.field.focused then f.field.value = f.field.value .. t end
    end
end

function love.keypressed(key)
    for _, f in ipairs(UI.fields) do
        if f.field.focused then
            if key == "backspace" then
                local v = f.field.value
                local offset = utf8.offset(v, -1)
                if offset then f.field.value = v:sub(1, offset - 1) end
            elseif key == "v" and (love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl")) then
                local clip = love.system.getClipboardText()
                if clip and clip ~= "" then f.field.value = f.field.value .. clip end
            elseif key == "escape" then
                f.field.focused = false
            end
        end
    end
end

function love.draw()
    resetFrame()
    love.graphics.clear(COLORS.bg)

    -- header
    love.graphics.setFont(FONT_TITLE)
    love.graphics.setColor(COLORS.text)
    love.graphics.print("Yu-Gi-Oh! Forbidden Memories Recompiled", 28, 22)
    love.graphics.setFont(FONT_SMALL)
    love.graphics.setColor(COLORS.textDim)
    love.graphics.print("Launcher -- phase 1", 28, 58)
    love.graphics.setFont(FONT_NORMAL)

    local y = 96

    -- ---------------------------------------------------------- renderer
    sectionLabel("Renderer", 28, y)
    y = y + 28
    local rx = 28
    for _, name in ipairs({ "software", "opengl", "vulkan" }) do
        button(rx, y, 120, 34, name, {
            active = (CurrentRenderer == name),
            action = function() onSelectRenderer(name) end,
        })
        rx = rx + 130
    end
    love.graphics.setColor(COLORS.textDim)
    love.graphics.setFont(FONT_SMALL)
    love.graphics.print("Edits [video].renderer in game.toml directly -- no rebuild needed.", rx + 10, y + 10)
    love.graphics.setFont(FONT_NORMAL)
    y = y + 60

    -- -------------------------------------------------------------- disc
    sectionLabel("Disc image", 28, y)
    y = y + 28

    love.graphics.setColor(COLORS.panel)
    local discBoxH = ShowDiscWizard and 118 or 66
    love.graphics.rectangle("fill", 28, y, 944, discBoxH, 6, 6)

    if ShowDiscWizard then
        love.graphics.setColor(COLORS.textDim)
        love.graphics.setFont(FONT_SMALL)
        love.graphics.print(
            "Point to your own legal disc dump (.img/.bin, single-track raw 2352-byte-sector CloneCD-style).\n" ..
            "This writes disc\\YUGIOH.cue referencing it in place -- the ~518 MB file is never copied.",
            40, y + 10)
        love.graphics.setFont(FONT_NORMAL)
        textField(DiscField, 40, y + 46, 660, 34, "C:\\path\\to\\your\\YUGIOH.img")
        button(712, y + 46, 110, 34, "Browse...", { action = onBrowseDisc })
        button(834, y + 46, 122, 34, "Create .cue", { action = onCreateCue })
        if core.cue_exists() then
            button(40, y + 88, 110, 24, "Cancel", { action = onCancelWizard })
        end
    else
        love.graphics.setColor(COLORS.ok)
        love.graphics.circle("fill", 46, y + 33, 5)
        love.graphics.setColor(COLORS.text)
        love.graphics.print("Configured:", 60, y + 14)
        love.graphics.setFont(FONT_SMALL)
        love.graphics.setColor(COLORS.textDim)
        love.graphics.print(DiscSourcePath or core.CUE_PATH, 60, y + 36)
        love.graphics.setFont(FONT_NORMAL)
        button(800, y + 16, 156, 34, "Change disc image...", { action = onReconfigureDisc })
    end
    y = y + discBoxH + 24

    -- ------------------------------------------------------------- saves
    sectionLabel("Saves  (" .. core.SAVES_DIR .. ")", 28, y)
    y = y + 28

    love.graphics.setColor(COLORS.panel)
    local saves = Saves
    local listH = math.max(1, #saves) * 22 + 16
    love.graphics.rectangle("fill", 28, y, 944, listH, 6, 6)
    love.graphics.setFont(FONT_SMALL)
    if #saves == 0 then
        love.graphics.setColor(COLORS.textDim)
        love.graphics.print("(no save files found)", 40, y + 10)
    else
        for i, entry in ipairs(saves) do
            local sizeStr = entry.size and string.format("%.1f KB", entry.size / 1024) or "?"
            love.graphics.setColor(COLORS.text)
            love.graphics.print(entry.name, 40, y + 10 + (i - 1) * 22)
            love.graphics.setColor(COLORS.textDim)
            love.graphics.print(sizeStr, 300, y + 10 + (i - 1) * 22)
        end
    end
    love.graphics.setFont(FONT_NORMAL)
    button(800, y + (listH - 34) / 2, 156, 34, "Backup saves now", { action = onBackupSaves })
    y = y + listH + 28

    -- -------------------------------------------------------------- play
    local playDisabled = not (core.exe_exists() and core.cue_exists())
    love.graphics.setFont(FONT_SUB)
    button(28, y, 944, 56, "PLAY", { disabled = playDisabled, action = onPlay })
    love.graphics.setFont(FONT_SMALL)
    if playDisabled then
        love.graphics.setColor(COLORS.warn)
        local why = not core.exe_exists() and "game exe not found in build-mingw\\"
            or "finish disc setup above first"
        love.graphics.print("Disabled: " .. why, 28, y + 60)
    end
    love.graphics.setFont(FONT_NORMAL)
    y = y + 90

    -- --------------------------------------------------------------- log
    love.graphics.setFont(FONT_SMALL)
    love.graphics.setColor(COLORS.textDim)
    for i, line in ipairs(Log) do
        love.graphics.print(line, 28, y + (i - 1) * 16)
    end
    love.graphics.setFont(FONT_NORMAL)
end
