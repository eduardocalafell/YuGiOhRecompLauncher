-- core.lua
--
-- Pure file/process logic for the ygo-recomp launcher: no love.graphics /
-- love.* calls in here on purpose, so it can be unit-exercised headlessly
-- (see selftest.lua) and reused later without dragging the UI along.
--
-- All paths below point at the *game* project (a sibling checkout, not this
-- launcher's own folder): C:\games\ygo-recomp\. This launcher never edits
-- anything under psxrecomp\ or the generated/ C sources -- it only ever
-- touches game.toml's [video].renderer field, disc\YUGIOH.cue, and files
-- inside saves\.

local core = {}

core.ROOT       = "C:\\games\\ygo-recomp\\"
core.TOML_PATH  = core.ROOT .. "game.toml"
core.DISC_DIR   = core.ROOT .. "disc\\"
core.CUE_PATH   = core.DISC_DIR .. "YUGIOH.cue"
core.SAVES_DIR  = core.ROOT .. "saves\\"
core.BACKUP_DIR = core.SAVES_DIR .. "backups\\"
core.EXE_DIR    = core.ROOT .. "build-mingw\\"
core.EXE_PATH   = core.EXE_DIR .. "Yu_Gi_Oh__Forbidden_Memories_Recompiled.exe"

local VALID_RENDERERS = { software = true, opengl = true, vulkan = true }
core.VALID_RENDERERS = VALID_RENDERERS

-- ---------------------------------------------------------------- fs utils

function core.file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

function core.file_size(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end")
    f:close()
    return size
end

-- Every shell-out below goes through hidden PowerShell (-WindowStyle Hidden)
-- rather than `cmd /c ...`: love.exe/lovec.exe have no console of their own
-- (see conf.lua's t.console = false), so a plain cmd.exe child briefly flashes
-- a visible console window every time -- very noticeable for list_saves(),
-- which a background thread calls every ~2s (see main.lua's SavesWorker).
-- PowerShell single-quoted strings don't need backslash-escaping, so Windows
-- paths pass through as-is; embedded single quotes (unlikely in these
-- controlled paths, but cheap to handle) are escaped by doubling.
local function ps_quote(s)
    return "'" .. s:gsub("'", "''") .. "'"
end

local function run_hidden_ps(script, mode)
    return io.popen('powershell -NoProfile -WindowStyle Hidden -Command "' .. script .. '"', mode)
end

function core.dir_exists(path)
    local clean = path:gsub("[\\/]+$", "")
    local p = run_hidden_ps("if (Test-Path -LiteralPath " .. ps_quote(clean) ..
        " -PathType Container) { 'YES' } else { 'NO' }")
    if not p then return false end
    local out = p:read("*l")
    p:close()
    return out == "YES"
end

function core.ensure_dir(path)
    local clean = path:gsub("[\\/]+$", "")
    if core.dir_exists(clean) then return true end
    local p = run_hidden_ps("New-Item -ItemType Directory -Force -Path " .. ps_quote(clean) .. " | Out-Null")
    if p then p:close() end
    return core.dir_exists(clean)
end

function core.read_all(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local data = f:read("*a")
    f:close()
    return data
end

function core.write_all(path, data)
    local f, err = io.open(path, "wb")
    if not f then return false, err end
    f:write(data)
    f:close()
    return true
end

-- Split text into lines without losing the original line-ending style, so a
-- surgical single-line edit can be written back byte-identical apart from
-- that one line.
function core.split_lines(data)
    local nl = data:find("\r\n", 1, true) and "\r\n" or "\n"
    local hadTrailing = #data >= #nl and data:sub(-#nl) == nl
    local body = hadTrailing and data:sub(1, -#nl - 1) or data
    local lines = {}
    local start = 1
    while true do
        local s, e = body:find(nl, start, true)
        if not s then
            table.insert(lines, body:sub(start))
            break
        end
        table.insert(lines, body:sub(start, s - 1))
        start = e + 1
    end
    return lines, nl, hadTrailing
end

function core.join_lines(lines, nl, hadTrailing)
    local body = table.concat(lines, nl)
    if hadTrailing then body = body .. nl end
    return body
end

-- --------------------------------------------------------- game.toml edits

-- Returns the current [video] renderer value, or nil+err.
function core.get_renderer()
    local data, err = core.read_all(core.TOML_PATH)
    if not data then return nil, "cannot read game.toml: " .. tostring(err) end
    local lines = core.split_lines(data)
    for _, line in ipairs(lines) do
        local val = line:match('^%s*renderer%s*=%s*"([^"]*)"%s*$')
        if val then return val end
    end
    return nil, "renderer field not found in game.toml"
end

-- Surgically rewrites ONLY the `renderer = "..."` line in game.toml,
-- preserving indentation, every comment, and every other byte of the file.
function core.set_renderer(newVal)
    if not VALID_RENDERERS[newVal] then
        return false, "invalid renderer: " .. tostring(newVal)
    end
    local data, err = core.read_all(core.TOML_PATH)
    if not data then return false, "cannot read game.toml: " .. tostring(err) end
    local lines, nl, trail = core.split_lines(data)
    local found = false
    for i, line in ipairs(lines) do
        local indent = line:match('^(%s*)renderer%s*=%s*"[^"]*"%s*$')
        if indent then
            lines[i] = indent .. 'renderer = "' .. newVal .. '"'
            found = true
            break
        end
    end
    if not found then
        return false, "renderer field not found in game.toml (no changes made)"
    end
    local ok, werr = core.write_all(core.TOML_PATH, core.join_lines(lines, nl, trail))
    if not ok then return false, "cannot write game.toml: " .. tostring(werr) end
    return true
end

-- ------------------------------------------------------------- disc setup

function core.cue_exists()
    return core.file_exists(core.CUE_PATH)
end

-- Best-effort parse of an existing .cue's FILE "..." line, for display only.
function core.read_cue_source_path()
    local data = core.read_all(core.CUE_PATH)
    if not data then return nil end
    return data:match('FILE%s+"([^"]+)"')
end

-- Writes a minimal single-track .cue pointing at imgPath (the user's own
-- disc dump, referenced in place -- never copied). Matches the format
-- already used by disc\YUGIOH.cue: raw 2352-byte-sector MODE2 track.
function core.create_cue(imgPath, cuePathOverride)
    local cuePath = cuePathOverride or core.CUE_PATH
    if not imgPath or imgPath == "" then
        return false, "no disc image path given"
    end
    if not core.file_exists(imgPath) then
        return false, "file not found: " .. imgPath
    end
    local dir = cuePath:match("^(.*)[\\/][^\\/]+$")
    if dir and not core.ensure_dir(dir) then
        return false, "could not create directory: " .. dir
    end
    local content = string.format(
        'FILE "%s" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n',
        imgPath)
    local ok, err = core.write_all(cuePath, content)
    if not ok then return false, "cannot write " .. cuePath .. ": " .. tostring(err) end
    return true
end

-- -------------------------------------------------------------- save mgmt

-- Lists files (not subfolders) directly inside saves\ -- i.e. the .mcd
-- memory card images, excluding the backups\ subfolder itself.
function core.list_saves()
    local results = {}
    local clean = core.SAVES_DIR:gsub("[\\/]+$", "")
    local p = run_hidden_ps("Get-ChildItem -LiteralPath " .. ps_quote(clean) ..
        " -File -ErrorAction SilentlyContinue | ForEach-Object Name")
    if not p then return results end
    for name in p:lines() do
        if name ~= "" then table.insert(results, name) end
    end
    p:close()
    return results
end

-- Copies every file in saves\ into saves\backups\<name>.backup-<timestamp>.
-- Purely additive -- never touches/overwrites the originals.
-- Returns: array of backup filenames created, array of "name: error" strings.
function core.backup_saves()
    local backedUp, errors = {}, {}
    if not core.ensure_dir(core.BACKUP_DIR) then
        table.insert(errors, "(backups dir): could not create " .. core.BACKUP_DIR)
        return backedUp, errors
    end
    local files = core.list_saves()
    local timestamp = os.date("%Y%m%d-%H%M%S")
    for _, name in ipairs(files) do
        local src = core.SAVES_DIR .. name
        local dot = name:find("%.[^.]*$")
        local base = dot and name:sub(1, dot - 1) or name
        local ext = dot and name:sub(dot) or ""
        local destName = base .. ".backup-" .. timestamp .. ext
        local dest = core.BACKUP_DIR .. destName
        local data, rerr = core.read_all(src)
        if not data then
            table.insert(errors, name .. ": " .. tostring(rerr))
        else
            local ok, werr = core.write_all(dest, data)
            if ok then
                table.insert(backedUp, destName)
            else
                table.insert(errors, name .. ": " .. tostring(werr))
            end
        end
    end
    return backedUp, errors
end

-- ------------------------------------------------------------------ play

function core.exe_exists()
    return core.file_exists(core.EXE_PATH)
end

-- Launches the recompiled game as a detached subprocess, matching the
-- README's documented invocation (`--game game.toml`, run with the project
-- root as the working directory), via PowerShell's Start-Process -- which
-- both sets the child's working directory and returns immediately instead
-- of blocking this launcher's UI thread until the game exits. Wrapped in a
-- hidden PowerShell host the same way as the other shell-outs in this file
-- (see run_hidden_ps above) so only the launcher's own invocation is
-- invisible; Start-Process itself does NOT hide the child, so the game's
-- own window still opens normally.
--
-- core.ROOT ends in a trailing backslash (by design, so ROOT .. "x.toml"
-- reads cleanly) -- but a trailing backslash immediately before a closing
-- quote is a classic Windows command-line footgun (cmd/CRT argv parsing
-- treats \" as an escaped literal quote, not "backslash then close-quote",
-- silently corrupting everything after it). Previously this used `start`
-- with core.ROOT quoted as-is and it broke exactly that way -- launching a
-- garbled command that manifested as DLL-not-found dialogs instead of the
-- game. Stripped here before quoting, same as every other path in this file.
function core.launch_game()
    if not core.exe_exists() then
        return false, "game executable not found: " .. core.EXE_PATH
    end
    if not core.cue_exists() then
        return false, "disc\\YUGIOH.cue not found yet -- finish the disc setup step first"
    end
    local rootClean = core.ROOT:gsub("[\\/]+$", "")
    local script = string.format(
        "Start-Process -FilePath %s -ArgumentList '--game',%s -WorkingDirectory %s",
        ps_quote(core.EXE_PATH), ps_quote(core.TOML_PATH), ps_quote(rootClean))
    local p = run_hidden_ps(script)
    if not p then return false, "could not launch (io.popen failed)" end
    local ok, exitReason, code = p:close()
    return true, string.format("launch command issued (ok=%s, %s, code=%s)",
        tostring(ok), tostring(exitReason), tostring(code))
end

return core
