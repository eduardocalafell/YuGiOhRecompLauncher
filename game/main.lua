-- main.lua -- ygo-recomp launcher, phase 1 (arcane redesign).
--
-- A boot-screen shell around the recompiled Yu-Gi-Oh! Forbidden Memories game
-- at C:\games\ygo-recomp\. It never touches the game/recompiler source -- it
-- only edits game.toml's [video].renderer, writes disc\YUGIOH.cue on first
-- run, backs up saves\, and launches the built exe. All logic lives in
-- core.lua; this file is the immediate-mode UI, styled per the design guide
-- (theme.lua tokens + icons.lua glyphs, all procedural -- no image assets).

local core  = require("core")
local Theme = require("theme")
local Icons = require("icons")
local utf8  = require("utf8")
local C = Theme.color

local FONT_DISPLAY, FONT_SUB, FONT_SECTION, FONT_BODY, FONT_SMALL, FONT_TINY
local Logo = nil   -- assets/logo.png (user artwork, background made transparent)

-- ------------------------------------------------------------- debug log
local DEBUG_LOG_PATH = "launcher-debug.log"
local debugLogFile = io.open(DEBUG_LOG_PATH, "w")
local function dlog(fmt, ...)
    if not debugLogFile then return end
    debugLogFile:write(string.format("[%9.3f] " .. fmt, love.timer.getTime(), ...) .. "\n")
    debugLogFile:flush()
end
local unpack = table.unpack or unpack
local function timed(label, fn)
    return function(...)
        local t0 = love.timer.getTime()
        local results = { fn(...) }
        dlog("%-24s %7.1fms", label, (love.timer.getTime() - t0) * 1000)
        return unpack(results)
    end
end

-- ------------------------------------------------------- persistent state
local DiscField = { value = "", focused = false }
local ShowDiscWizard = false
local CurrentRenderer = nil
local Log = {}                 -- { {time=, msg=, level=} , ... } newest first
local Saves = {}
local DiscSourcePath = nil
local SaveRefreshTimer = 0
local SAVE_REFRESH_INTERVAL = 2.0
local Ripples = {}             -- click feedback rings
local SmoothMode = false       -- "Smooth 60 FPS": opengl + GL frame interpolation

-- per-frame widget registries
local UI = { buttons = {}, fields = {} }
local WantHandCursor = false
local HAND_CURSOR = nil

local function resetFrame()
    UI.buttons = {}
    UI.fields = {}
    WantHandCursor = false
end

local RENDERER_META = {
    software = { icon = "chip",    label = "SOFTWARE" },
    opengl   = { icon = "hex",     label = "OPENGL"   },
    vulkan   = { icon = "chevron", label = "VULKAN"   },
}

local LEVEL_ICON = { info = "gear", success = "check", launch = "rocket",
    warn = "bang", error = "cross" }
local LEVEL_COLOR = { info = C.violet, success = C.success, launch = C.cyan,
    warn = C.warn, error = C.danger }

local function log(msg, level)
    table.insert(Log, 1, { time = os.date("%H:%M:%S"), msg = msg, level = level or "info" })
    if #Log > 6 then table.remove(Log) end
    print(msg)
end

-- --------------------------------------------------------- saves worker
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
local refreshSaves = requestSavesRefresh

local refreshDiscSourcePath = timed("refreshDiscSourcePath", function()
    DiscSourcePath = core.read_cue_source_path()
end)

local function refreshState()
    local r, err = core.get_renderer()
    CurrentRenderer = r
    if not r then log("WARNING: " .. tostring(err), "warn") end
    ShowDiscWizard = not core.cue_exists()
    if not core.exe_exists() then
        log("game exe not found in build-mingw\\", "warn")
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
        log("Renderer set to '" .. name .. "' in game.toml", "info")
    else
        log("ERROR setting renderer: " .. tostring(err), "error")
    end
end

local function trim(s)
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub('^"(.*)"$', "%1")
    return s
end

local function onBrowseDisc()
    local script =
        "Add-Type -AssemblyName System.Windows.Forms; " ..
        "$f = New-Object System.Windows.Forms.OpenFileDialog; " ..
        "$f.Title = 'Select your Yu-Gi-Oh! Forbidden Memories disc dump'; " ..
        "$f.Filter = 'Disc images (*.img;*.bin;*.cue;*.ccd)|*.img;*.bin;*.cue;*.ccd|All files (*.*)|*.*'; " ..
        "if ($f.ShowDialog() -eq 'OK') { Write-Output $f.FileName }"
    local cmd = 'powershell -NoProfile -WindowStyle Hidden -Command "' .. script .. '"'
    local p = io.popen(cmd, "r")
    if not p then log("Native file dialog unavailable -- type the path manually.", "warn") return end
    local result = p:read("*l")
    p:close()
    if result and result ~= "" then
        DiscField.value = result
        log("Selected: " .. result, "info")
    end
end

local function onCreateCue()
    local path = trim(DiscField.value)
    local ok, err = core.create_cue(path, core.CUE_PATH)
    if ok then
        log("Created disc\\YUGIOH.cue", "success")
        ShowDiscWizard = false
        refreshDiscSourcePath()
    else
        log("ERROR creating .cue: " .. tostring(err), "error")
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
    for _, e in ipairs(errors) do log("backup error -- " .. e, "error") end
    if #backedUp > 0 then
        log("Backed up " .. #backedUp .. " file(s) to saves\\backups\\", "success")
    elseif #errors == 0 then
        log("No save files found in saves\\ to back up.", "warn")
    end
end

local function onOpenSavesFolder()
    core.open_saves_folder()
    log("Opened saves\\ folder", "info")
end

local function onPlay()
    local ok, msg = core.launch_game({ interpolation = SmoothMode, interp_fps = 60 })
    if ok then
        local how = SmoothMode and " [60 FPS smooth]" or ""
        log("Launching game..." .. how, "launch")
    else
        log("Cannot launch: " .. tostring(msg), "error")
    end
end

-- "Smooth 60 FPS": frame interpolation is GL-only, so turning it on also flips
-- the renderer to opengl. The interpolation itself is applied at launch via
-- env vars (see core.launch_game) -- game.toml only carries the renderer.
local function onToggleSmooth()
    SmoothMode = not SmoothMode
    if SmoothMode and CurrentRenderer ~= "opengl" then
        onSelectRenderer("opengl")
    end
    log(SmoothMode and "Smooth 60 FPS ON — opengl + frame interpolation"
        or "Smooth 60 FPS OFF", SmoothMode and "success" or "info")
end

onSelectRenderer = timed("onSelectRenderer", onSelectRenderer)
onBrowseDisc = timed("onBrowseDisc", onBrowseDisc)
onCreateCue = timed("onCreateCue", onCreateCue)
onBackupSaves = timed("onBackupSaves", onBackupSaves)
onPlay = timed("onPlay", onPlay)

-- ------------------------------------------------------------ draw utils
local function mouseOver(x, y, w, h)
    local mx, my = love.mouse.getPosition()
    return mx >= x and mx <= x + w and my >= y and my <= y + h
end

-- Uppercase, letter-tracked print (for the display title + section labels).
local function printTracked(text, x, y, tracking, font)
    font = font or love.graphics.getFont()
    local cx = x
    for _, cp in utf8.codes(text) do
        local ch = utf8.char(cp)
        love.graphics.print(ch, cx, y)
        cx = cx + font:getWidth(ch) + tracking
    end
    return cx - tracking
end

local function sectionLabel(text, x, y)
    love.graphics.setFont(FONT_SECTION)
    love.graphics.setColor(C.gold)
    local endx = printTracked(text:upper(), x, y, 2, FONT_SECTION)
    Theme.diamond(endx + 12, y + FONT_SECTION:getHeight() / 2, 3, C.gold, 0.8)
end

-- Generic button. opts: x,y,w,h,label,icon,iconColor,variant,active,disabled,action
-- variant: "primary" | "secondary" | "ghost" | "renderer"
local function button(opts)
    local x, y, w, h = opts.x, opts.y, opts.w, opts.h
    local hot = (not opts.disabled) and mouseOver(x, y, w, h)
    if hot then WantHandCursor = true end
    local r = Theme.radius.medium

    if opts.variant == "renderer" then
        if opts.active then
            Theme.glow(x, y, w, h, r, C.violet, 0.5, 4)
            Theme.fillRect(x, y, w, h, r, C.indigo, 0.9)
            Theme.strokeRect(x, y, w, h, r, C.violet, 1, 1.5)
        else
            Theme.fillRect(x, y, w, h, r, C.midnight, hot and 0.9 or 0.6)
            Theme.strokeRect(x, y, w, h, r, hot and C.violet or C.border, hot and 0.8 or 1, 1)
        end
    elseif opts.variant == "secondary" or opts.variant == "ghost" then
        if opts.variant == "secondary" then
            Theme.fillRect(x, y, w, h, r, C.midnight, hot and 0.9 or 0.55)
        end
        Theme.strokeRect(x, y, w, h, r, hot and C.violet or C.border, hot and 0.9 or 0.8, 1)
    end

    local ic = opts.iconColor or (opts.active and C.gold or (hot and C.gold or C.textMuted))
    local tx = x + (opts.icon and 16 or 0)
    if opts.icon then
        Icons.draw(opts.icon, x + 22, y + h / 2, 9, ic)
        tx = x + 42
    end
    if opts.label then
        love.graphics.setFont(opts.font or FONT_BODY)
        love.graphics.setColor(opts.active and C.text or (hot and C.text or C.textMuted))
        local f = opts.font or FONT_BODY
        if opts.center then
            love.graphics.printf(opts.label, x, y + (h - f:getHeight()) / 2, w, "center")
        else
            love.graphics.print(opts.label, tx, y + (h - f:getHeight()) / 2)
        end
    end

    if not opts.disabled then
        table.insert(UI.buttons, { x = x, y = y, w = w, h = h, action = opts.action })
    end
    return hot
end

-- Pill toggle switch. Registers a click that runs `action`.
local function toggleSwitch(x, y, on, action)
    local w, h = 46, 24
    local hot = mouseOver(x, y, w, h)
    if hot then WantHandCursor = true end
    if on then Theme.glow(x, y, w, h, h / 2, C.violet, 0.35, 3) end
    Theme.fillRect(x, y, w, h, h / 2, on and C.violet or C.midnight, on and 0.9 or 0.7)
    Theme.strokeRect(x, y, w, h, h / 2, on and C.violet or C.border, hot and 1 or 0.8, 1)
    local knobR = (h - 8) / 2
    local kx = on and (x + w - knobR - 4) or (x + knobR + 4)
    love.graphics.setColor(on and C.gold or C.textMuted)
    love.graphics.circle("fill", kx, y + h / 2, knobR)
    table.insert(UI.buttons, { x = x, y = y, w = w, h = h, action = action })
    return hot
end

local function statusChip(x, y, label, color)
    love.graphics.setFont(FONT_TINY)
    local tw = FONT_TINY:getWidth(label)
    local w = tw + 34
    local h = 22
    Theme.fillRect(x, y, w, h, 11, color, 0.14)
    Theme.strokeRect(x, y, w, h, 11, color, 0.6, 1)
    love.graphics.setColor(color)
    love.graphics.circle("fill", x + 13, y + h / 2, 3.5)
    love.graphics.setColor(C.text)
    love.graphics.print(label, x + 24, y + (h - FONT_TINY:getHeight()) / 2)
    return w
end

-- procedural arcane "illustration" for the left rail
local function artPanel(x, y, w, h, t)
    Theme.panel(x, y, w, h, { fill = C.obsidian, fillAlpha = 0.9, border = Theme.rgba(C.gold, 0.35) })
    love.graphics.setScissor(x + 2, y + 2, w - 4, h - 4)
    -- vertical gradient wash
    Theme.gradientRect(x + 2, y + 2, w - 4, h - 4, { 0.10, 0.08, 0.16 }, C.obsidian)
    local cx, cy = x + w / 2, y + h * 0.42
    -- glow behind the seal
    for i = 6, 1, -1 do
        love.graphics.setColor(C.violet[1], C.violet[2], C.violet[3], 0.05)
        love.graphics.circle("fill", cx, cy, 40 + i * 10)
    end
    Theme.arcaneCircle(cx, cy, w * 0.34, C.gold, 0.5, t)
    Theme.arcaneCircle(cx, cy, w * 0.22, C.violet, 0.5, -t * 1.5)
    Icons.eye(cx, cy, w * 0.12, Theme.rgba(C.gold, 0.9))
    -- temple pillars near the bottom
    love.graphics.setColor(C.gold[1], C.gold[2], C.gold[3], 0.25)
    love.graphics.setLineWidth(2)
    local by = y + h - 40
    for _, px in ipairs({ x + w * 0.28, x + w * 0.5, x + w * 0.72 }) do
        love.graphics.line(px, by, px, by - h * 0.28)
    end
    love.graphics.line(x + w * 0.2, by, x + w * 0.8, by)
    love.graphics.setScissor()
end

-- ----------------------------------------------------------- love.load
function love.load(argv)
    FONT_DISPLAY = love.graphics.newFont(30)
    FONT_SUB     = love.graphics.newFont(13)
    FONT_SECTION = love.graphics.newFont(13)
    FONT_BODY    = love.graphics.newFont(14)
    FONT_SMALL   = love.graphics.newFont(12)
    FONT_TINY    = love.graphics.newFont(11)
    love.graphics.setFont(FONT_BODY)
    if love.mouse.getSystemCursor then
        HAND_CURSOR = love.mouse.getSystemCursor("hand")
    end
    -- mipmaps = smooth downscale (the header draws this well below native size;
    -- without mipmaps a ~3x reduction aliases/"shreds" the fine gold edges).
    local okLogo, logoImg = pcall(love.graphics.newImage, "assets/logo.png", { mipmaps = true })
    Logo = okLogo and logoImg or nil
    if Logo then
        Logo:setFilter("linear", "linear")
        pcall(function() Logo:setMipmapFilter("linear") end)
    end

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
    local ok_ri, rname, rver, rvendor, rdevice = pcall(love.graphics.getRendererInfo)
    if ok_ri then
        dlog("renderer: name=%s ver=%s vendor=%s device=%s", tostring(rname), tostring(rver), tostring(rvendor), tostring(rdevice))
    end
    SavesWorker:start()
    log("ygo-recomp launcher ready.", "success")
    refreshState()
end

-- ----------------------------------------------------------- love.update
local SnapshotTimer = 0
function love.update(dt)
    pollSavesRefresh()
    if SavesWorker then
        local workerErr = SavesWorker:getError()
        if workerErr then
            dlog("SavesWorker thread error: %s", tostring(workerErr))
            SavesWorker = nil
        end
    end
    SaveRefreshTimer = SaveRefreshTimer + dt
    if SaveRefreshTimer >= SAVE_REFRESH_INTERVAL then
        SaveRefreshTimer = 0
        refreshSaves()
    end
    -- age click ripples
    local now = love.timer.getTime()
    for i = #Ripples, 1, -1 do
        if now - Ripples[i].t0 > 0.45 then table.remove(Ripples, i) end
    end
    SnapshotTimer = SnapshotTimer + dt
    if SnapshotTimer >= 2.0 then
        SnapshotTimer = 0
        dlog("snapshot fps=%d dt=%.1fms lua_mem=%.0fKB", love.timer.getFPS(), dt * 1000, collectgarbage("count"))
    end
end

function love.focus(f) dlog("window focus -> %s", tostring(f)) end
function love.quit() dlog("launcher quitting") end

-- --------------------------------------------------------- interaction
function love.mousepressed(x, y, mbutton)
    if mbutton ~= 1 then return end
    for _, f in ipairs(UI.fields) do
        f.field.focused = x >= f.x and x <= f.x + f.w and y >= f.y and y <= f.y + f.h
    end
    for _, b in ipairs(UI.buttons) do
        if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
            table.insert(Ripples, { x = x, y = y, t0 = love.timer.getTime() })
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

-- ------------------------------------------------------------ textField
local function textField(field, x, y, w, h, placeholder)
    Theme.fillRect(x, y, w, h, Theme.radius.small, C.obsidian, 0.9)
    Theme.strokeRect(x, y, w, h, Theme.radius.small, field.focused and C.violet or C.border, 1, 1)
    love.graphics.setScissor(x + 1, y + 1, w - 2, h - 2)
    love.graphics.setFont(FONT_SMALL)
    if field.value == "" then
        love.graphics.setColor(C.textMuted)
        love.graphics.print(placeholder or "", x + 10, y + (h - FONT_SMALL:getHeight()) / 2)
    else
        love.graphics.setColor(C.text)
        local shown = field.value
        while FONT_SMALL:getWidth(shown) > w - 20 and #shown > 0 do shown = shown:sub(2) end
        love.graphics.print(shown, x + 10, y + (h - FONT_SMALL:getHeight()) / 2)
    end
    love.graphics.setScissor()
    table.insert(UI.fields, { x = x, y = y, w = w, h = h, field = field })
end

-- ------------------------------------------------------------- love.draw
function love.draw()
    resetFrame()
    local W, H = love.graphics.getDimensions()
    local t = love.timer.getTime()

    -- background
    Theme.gradientRect(0, 0, W, H, C.midnight, C.obsidian)
    Theme.arcaneCircle(W * 0.82, H * 0.24, 260, C.violet, 0.04, t)
    Theme.arcaneCircle(W * 0.2, H * 0.85, 200, C.gold, 0.03, -t)

    local P = 24
    -- ---- brand strip
    Icons.eye(P + 12, 30, 11, C.gold)
    love.graphics.setFont(FONT_SMALL)
    love.graphics.setColor(C.textMuted)
    printTracked("YGO-RECOMP LAUNCHER", P + 32, 24, 2, FONT_SMALL)

    local headerY = 62
    local footerH = 40
    local artW = 250
    local colX = P + artW + P
    local colW = W - colX - P

    -- ---- left art rail
    artPanel(P, headerY, artW, H - headerY - footerH - P, t)

    -- ---- logo + status card
    if Logo then
        local lh = 120
        local ls = lh / Logo:getHeight()
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(Logo, colX - 8, headerY - 6, 0, ls, ls)
    else
        love.graphics.setFont(FONT_DISPLAY)
        love.graphics.setColor(C.gold)
        printTracked("FORBIDDEN MEMORIES", colX, headerY + 4, 1, FONT_DISPLAY)
        printTracked("RECOMPILED", colX, headerY + 42, 1, FONT_DISPLAY)
    end
    love.graphics.setFont(FONT_SUB)
    love.graphics.setColor(C.violet)
    love.graphics.print("Forbidden Memories — Phase 1", colX + 4, headerY + 118)

    -- status card (top-right of the column)
    local scW, scH = 210, 58
    local scX, scY = colX + colW - scW, headerY
    Theme.panel(scX, scY, scW, scH, { fill = C.indigo, fillAlpha = 0.6, border = Theme.rgba(C.gold, 0.3) })
    Theme.arcaneCircle(scX + 29, scY + scH / 2, 16, C.gold, 0.7, t)
    Icons.eye(scX + 29, scY + scH / 2, 9, C.gold)
    love.graphics.setFont(FONT_SMALL)
    love.graphics.setColor(C.text)
    love.graphics.print("DUELIST", scX + 52, scY + 12)
    love.graphics.setFont(FONT_TINY)
    love.graphics.setColor(C.textMuted)
    love.graphics.print(core.exe_exists() and "Ready to duel." or "Game exe missing", scX + 52, scY + 30)
    love.graphics.setColor(core.exe_exists() and C.success or C.danger)
    love.graphics.circle("fill", scX + 55, scY + 45, 3)
    love.graphics.setColor(C.textMuted)
    love.graphics.print(core.exe_exists() and "Online" or "Offline", scX + 64, scY + 39)

    local y = headerY + 146

    -- ---- renderer
    sectionLabel("Renderer", colX, y)
    y = y + 26
    local rw, rh, gap = 158, 44, 12
    for i, name in ipairs({ "software", "opengl", "vulkan" }) do
        local meta = RENDERER_META[name]
        button({ x = colX + (i - 1) * (rw + gap), y = y, w = rw, h = rh,
            label = meta.label, icon = meta.icon, variant = "renderer",
            active = (CurrentRenderer == name), font = FONT_SMALL,
            action = function() onSelectRenderer(name) end })
    end
    -- Smooth 60 FPS (frame interpolation) toggle, to the right of the buttons.
    local sx = colX + 3 * (rw + gap) + 16
    love.graphics.setFont(FONT_SMALL)
    love.graphics.setColor(SmoothMode and C.gold or C.text)
    love.graphics.print("Smooth 60 FPS", sx, y + 3)
    love.graphics.setFont(FONT_TINY)
    love.graphics.setColor(C.textMuted)
    love.graphics.print("frame interpolation", sx, y + 24)
    toggleSwitch(sx + 150, y + 10, SmoothMode, onToggleSmooth)
    y = y + rh + 22

    -- ---- disc image
    sectionLabel("Disc image", colX, y)
    y = y + 26
    if ShowDiscWizard then
        local boxH = 116
        Theme.panel(colX, y, colW, boxH)
        love.graphics.setFont(FONT_TINY)
        love.graphics.setColor(C.textMuted)
        love.graphics.printf("Point to your own legal disc dump (.img/.bin, raw 2352-byte-sector).\n" ..
            "Writes disc\\YUGIOH.cue referencing it in place — the ~518 MB file is never copied.",
            colX + 16, y + 12, colW - 32, "left")
        textField(DiscField, colX + 16, y + 46, colW - 300, 34, "C:\\path\\to\\your\\YUGIOH.img")
        button({ x = colX + colW - 272, y = y + 46, w = 120, h = 34, label = "BROWSE",
            icon = "folder", variant = "secondary", font = FONT_SMALL, action = onBrowseDisc })
        button({ x = colX + colW - 140, y = y + 46, w = 124, h = 34, label = "CREATE .CUE",
            icon = "check", variant = "secondary", font = FONT_SMALL, action = onCreateCue })
        if core.cue_exists() then
            button({ x = colX + 16, y = y + 86, w = 90, h = 22, label = "CANCEL",
                variant = "ghost", font = FONT_TINY, center = true, action = onCancelWizard })
        end
        y = y + boxH + 22
    else
        local boxH = 76
        Theme.panel(colX, y, colW, boxH)
        Theme.arcaneCircle(colX + 42, y + boxH / 2, 22, C.violet, 0.5, t)
        Icons.disc(colX + 42, y + boxH / 2, 15, C.cyan)
        statusChip(colX + 76, y + 14, "CONFIGURED", C.success)
        love.graphics.setFont(FONT_TINY)
        love.graphics.setColor(C.textMuted)
        local path = DiscSourcePath or core.CUE_PATH
        love.graphics.printf(path, colX + 76, y + 42, colW - 280, "left")
        button({ x = colX + colW - 172, y = y + 21, w = 156, h = 34, label = "CHANGE IMAGE",
            icon = "folder", variant = "secondary", font = FONT_SMALL, action = onReconfigureDisc })
        y = y + boxH + 22
    end

    -- ---- saves
    sectionLabel("Saves", colX, y)
    love.graphics.setFont(FONT_TINY)
    love.graphics.setColor(C.textMuted)
    love.graphics.print(core.SAVES_DIR, colX + 108, y + 3)
    button({ x = colX + colW - 300, y = y - 6, w = 140, h = 30, label = "OPEN FOLDER",
        icon = "folder", variant = "secondary", font = FONT_TINY, action = onOpenSavesFolder })
    button({ x = colX + colW - 148, y = y - 6, w = 148, h = 30, label = "BACKUP ALL",
        icon = "cloud", variant = "secondary", font = FONT_TINY, action = onBackupSaves })
    y = y + 30

    local rowH = 52
    local nSaves = math.max(#Saves, 1)
    Theme.panel(colX, y, colW, nSaves * rowH + 8, { fill = C.midnight, fillAlpha = 0.5 })
    if #Saves == 0 then
        love.graphics.setFont(FONT_SMALL)
        love.graphics.setColor(C.textMuted)
        love.graphics.print("(no save files found)", colX + 16, y + 16)
    else
        for i, entry in ipairs(Saves) do
            local ry = y + 4 + (i - 1) * rowH
            if i > 1 then
                Theme.strokeRect(colX + 12, ry, colW - 24, 0, 0, C.border, 0.5, 1)
            end
            Theme.fillRect(colX + 14, ry + 10, 30, 32, 4, C.indigo, 0.7)
            Icons.memcard(colX + 29, ry + 26, 9, C.violet)
            love.graphics.setFont(FONT_BODY)
            love.graphics.setColor(C.text)
            love.graphics.print(entry.name, colX + 58, ry + 9)
            love.graphics.setFont(FONT_TINY)
            love.graphics.setColor(C.textMuted)
            love.graphics.print("Memory Card " .. i, colX + 58, ry + 28)
            love.graphics.setColor(C.textMuted)
            love.graphics.setFont(FONT_SMALL)
            local sizeStr = entry.size and string.format("%.1f KB", entry.size / 1024) or "?"
            love.graphics.print(sizeStr, colX + 300, ry + 18)
            button({ x = colX + colW - 130, y = ry + 10, w = 116, h = 32, label = "BACKUP",
                icon = "download", variant = "secondary", font = FONT_TINY, action = onBackupSaves })
        end
    end
    y = y + nSaves * rowH + 8 + 22

    -- ---- PLAY
    local playDisabled = not (core.exe_exists() and core.cue_exists())
    local pw, ph = colW, 72
    if not playDisabled then
        local pulse = 0.35 + 0.15 * math.sin(t * 2.2)
        Theme.glow(colX, y, pw, ph, Theme.radius.large, C.violet, pulse, 7)
    end
    Theme.gradientRect(colX + 3, y + 3, pw - 6, ph - 6, C.indigo, { 0.10, 0.08, 0.20 })
    Theme.fillRect(colX, y, pw, ph, Theme.radius.large, C.violet, playDisabled and 0.05 or 0.12)
    Theme.strokeRect(colX, y, pw, ph, Theme.radius.large, playDisabled and C.border or C.gold, 1, 2)
    local phot = (not playDisabled) and mouseOver(colX, y, pw, ph)
    if phot then WantHandCursor = true end
    Icons.eye(colX + pw / 2 - 70, y + ph / 2, 15, playDisabled and C.textMuted or C.gold)
    love.graphics.setFont(FONT_DISPLAY)
    love.graphics.setColor(playDisabled and C.textMuted or C.gold)
    printTracked("PLAY", colX + pw / 2 - 42, y + ph / 2 - 20, 4, FONT_DISPLAY)
    if not playDisabled then
        table.insert(UI.buttons, { x = colX, y = y, w = pw, h = ph, action = onPlay })
    end
    if playDisabled then
        love.graphics.setFont(FONT_TINY)
        love.graphics.setColor(C.warn)
        local why = not core.exe_exists() and "game exe not found in build-mingw\\" or "finish disc setup above first"
        love.graphics.printf("Disabled: " .. why, colX, y + ph + 6, pw, "center")
    end
    y = y + ph + 22

    -- ---- activity log
    sectionLabel("Activity log", colX, y)
    button({ x = colX + colW - 120, y = y - 6, w = 120, h = 28, label = "CLEAR LOG",
        variant = "ghost", font = FONT_TINY, center = true, action = function() Log = {} end })
    y = y + 30
    local logH = H - footerH - y - 4
    Theme.panel(colX, y, colW, logH, { fill = C.obsidian, fillAlpha = 0.6 })
    love.graphics.setFont(FONT_SMALL)
    for i, entry in ipairs(Log) do
        local ly = y + 12 + (i - 1) * 22
        if ly + 18 > y + logH then break end
        local col = LEVEL_COLOR[entry.level] or C.violet
        Icons.draw(LEVEL_ICON[entry.level] or "gear", colX + 24, ly + 7, 7, col)
        love.graphics.setColor(C.textMuted)
        love.graphics.print(entry.time, colX + 42, ly)
        love.graphics.setColor(C.text)
        love.graphics.print(entry.msg, colX + 118, ly)
    end

    -- ---- footer
    love.graphics.setFont(FONT_TINY)
    love.graphics.setColor(C.textMuted)
    love.graphics.print("v1.0.0  ·  Forbidden Memories Recompiled", P, H - 26)
    local hx = W - P - 120
    love.graphics.print("Need help?", hx, H - 26)
    Icons.book(hx + 78, H - 20, 8, C.textMuted)
    Icons.chat(hx + 104, H - 20, 8, C.textMuted)

    -- ---- click ripples (drawn on top)
    for _, rp in ipairs(Ripples) do
        local age = (t - rp.t0) / 0.45
        local rad = 6 + age * 40
        love.graphics.setColor(C.gold[1], C.gold[2], C.gold[3], (1 - age) * 0.4)
        love.graphics.setLineWidth(2)
        love.graphics.circle("line", rp.x, rp.y, rad)
    end

    -- cursor
    if HAND_CURSOR then
        love.mouse.setCursor(WantHandCursor and HAND_CURSOR or nil)
    end
end
