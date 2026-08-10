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

-- Filesystem/process helpers below call the Win32 API directly through
-- LuaJIT's FFI instead of shelling out to cmd/PowerShell. This is THE fix for
-- the "launcher won't open, there's just a cmd flashing" report: love.exe has
-- no console of its own (conf.lua's t.console = false), and under that
-- condition `-WindowStyle Hidden` does NOT stop Windows from briefly creating
-- (and flashing, and focus-stealing) a conhost window for every child
-- process. list_saves() runs every ~2s (main.lua's SavesWorker), so a console
-- popped twice a second -- masking the real launcher window. FFI calls run
-- in-process: no child, no console, no flash, and microseconds instead of a
-- ~40ms+ process spawn. ANSI ("A") entry points are used deliberately: every
-- path this module touches is plain ASCII (C:\games\...), so there is no
-- UTF-16 marshaling to get wrong. The __stdcall annotations are no-ops on the
-- x64 build (single calling convention) but keep this correct if ever run on
-- a 32-bit LÖVE.
local ffi = require("ffi")
local bit = require("bit")

local win = {}
do
    local okdef = pcall(ffi.cdef, [[
        typedef struct _FILETIME { uint32_t dwLowDateTime; uint32_t dwHighDateTime; } FILETIME;
        typedef struct _WIN32_FIND_DATAA {
            uint32_t dwFileAttributes;
            FILETIME ftCreationTime;
            FILETIME ftLastAccessTime;
            FILETIME ftLastWriteTime;
            uint32_t nFileSizeHigh;
            uint32_t nFileSizeLow;
            uint32_t dwReserved0;
            uint32_t dwReserved1;
            char     cFileName[260];
            char     cAlternateFileName[14];
        } WIN32_FIND_DATAA;

        uint32_t __stdcall GetFileAttributesA(const char* lpFileName);
        int      __stdcall CreateDirectoryA(const char* lpPathName, void* lpSecurityAttributes);
        void*    __stdcall FindFirstFileA(const char* lpFileName, WIN32_FIND_DATAA* lpFindFileData);
        int      __stdcall FindNextFileA(void* hFindFile, WIN32_FIND_DATAA* lpFindFileData);
        int      __stdcall FindClose(void* hFindFile);

        void* __stdcall ShellExecuteA(void* hwnd, const char* lpOperation,
            const char* lpFile, const char* lpParameters,
            const char* lpDirectory, int nShowCmd);
    ]])
    if okdef then
        local okk, kernel32 = pcall(ffi.load, "kernel32")
        local oks, shell32  = pcall(ffi.load, "shell32")
        win.k = okk and kernel32 or ffi.C   -- kernel32 exports also resolve via ffi.C
        win.shell32 = oks and shell32 or nil
    end
end

local INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF
local FILE_ATTRIBUTE_DIRECTORY = 0x10
local INVALID_HANDLE_VALUE = ffi.cast("void*", -1)

function core.dir_exists(path)
    if not win.k then return false end
    local clean = path:gsub("[\\/]+$", "")
    local attr = win.k.GetFileAttributesA(clean)
    if attr == INVALID_FILE_ATTRIBUTES then return false end
    return bit.band(attr, FILE_ATTRIBUTE_DIRECTORY) ~= 0
end

-- CreateDirectoryA only makes a single level, so walk up and create any
-- missing parents first. Stops at a drive root ("C:") or the empty string.
function core.ensure_dir(path)
    if not win.k then return false end
    local clean = path:gsub("[\\/]+$", "")
    if clean == "" or clean:match("^%a:$") then return true end
    if core.dir_exists(clean) then return true end
    local parent = clean:match("^(.*)[\\/][^\\/]+$")
    if parent and parent ~= clean then core.ensure_dir(parent) end
    win.k.CreateDirectoryA(clean, nil)
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
    if not win.k then return results end
    local clean = core.SAVES_DIR:gsub("[\\/]+$", "")
    local fd = ffi.new("WIN32_FIND_DATAA")
    local h = win.k.FindFirstFileA(clean .. "\\*", fd)
    if h == INVALID_HANDLE_VALUE then return results end
    repeat
        if bit.band(fd.dwFileAttributes, FILE_ATTRIBUTE_DIRECTORY) == 0 then
            local name = ffi.string(fd.cFileName)
            if name ~= "" then results[#results + 1] = name end
        end
    until win.k.FindNextFileA(h, fd) == 0
    win.k.FindClose(h)
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

-- Launches the recompiled game exactly the way double-clicking it in Explorer
-- would: ShellExecuteA with the "open" verb. It returns immediately (never
-- blocks this launcher's UI thread), creates no console of its own, and --
-- crucially -- takes an explicit working directory. game.toml references the
-- exe and disc with paths relative to the project root (exe = "ygo/...",
-- disc = "disc/..."), so the child MUST run with core.ROOT as its cwd, which
-- lpDirectory sets. The --game argument is passed as an absolute path so the
-- .toml itself is found regardless of cwd.
--
-- This replaces an earlier PowerShell `Start-Process` shell-out. That version
-- flashed a console (love.exe has no console, so even a hidden PS host popped
-- a conhost window) and had a history of argv-quoting corruption around
-- core.ROOT's trailing backslash -- which is what surfaced to the user as "a
-- bunch of DLL errors" instead of the game window. A direct ShellExecuteA
-- call has no command line to mis-quote at all.
function core.launch_game()
    if not core.exe_exists() then
        return false, "game executable not found: " .. core.EXE_PATH
    end
    if not core.cue_exists() then
        return false, "disc\\YUGIOH.cue not found yet -- finish the disc setup step first"
    end
    if not win.shell32 then
        return false, "cannot launch: Win32 ShellExecute unavailable (FFI failed to load shell32)"
    end
    local rootClean = core.ROOT:gsub("[\\/]+$", "")
    local params = '--game "' .. core.TOML_PATH .. '"'
    local SW_SHOWNORMAL = 1
    local hinst = win.shell32.ShellExecuteA(nil, "open", core.EXE_PATH, params, rootClean, SW_SHOWNORMAL)
    -- ShellExecuteA returns a pseudo-HINSTANCE; > 32 means success, <= 32 is
    -- an SE_ERR_* code (2 = file not found, 8 = out of memory, 31 = no assoc).
    local code = tonumber(ffi.cast("intptr_t", hinst))
    if code > 32 then
        return true, "game launched (ShellExecute ok)"
    end
    return false, "ShellExecute failed (SE_ERR code " .. tostring(code) .. ")"
end

return core
