-- selftest.lua
--
-- Headless functional check of core.lua, run via:
--   runtime\lovec.exe game --selftest
-- Exercises the exact same functions the UI buttons call. Careful about
-- side effects on the REAL project:
--   * game.toml is snapshotted byte-for-byte and restored at the end.
--   * disc\YUGIOH.cue is never touched -- cue creation is tested against a
--     throwaway scratch path that is deleted afterwards.
--   * backup_saves() is allowed to run for real (it's purely additive) but
--     the backup copies it makes are deleted afterwards to leave no residue.
--   * launch_game() really spawns the game exe; the caller (whoever invoked
--     --selftest) is expected to verify the process externally and close it.

local core = require("core")

local M = {}

local function ok(cond, msg)
    print((cond and "PASS " or "FAIL ") .. msg)
    return cond
end

function M.run()
    print("=== ygo-recomp-launcher selftest ===")
    local allPass = true

    -- 1. renderer round trip -- must restore game.toml byte-exact.
    local originalToml = core.read_all(core.TOML_PATH)
    allPass = ok(originalToml ~= nil, "read game.toml") and allPass

    local orig, gerr = core.get_renderer()
    allPass = ok(orig ~= nil, "get_renderer() -> " .. tostring(orig) .. " (" .. tostring(gerr) .. ")") and allPass

    if orig then
        local testVal = (orig == "software") and "opengl" or "software"
        local setOk, setErr = core.set_renderer(testVal)
        allPass = ok(setOk, "set_renderer('" .. testVal .. "') -> " .. tostring(setErr)) and allPass
        local readBack = core.get_renderer()
        allPass = ok(readBack == testVal, "renderer reads back as '" .. tostring(readBack) .. "'") and allPass

        local badOk, badErr = core.set_renderer("not_a_real_renderer")
        allPass = ok(badOk == false, "set_renderer() rejects invalid value (" .. tostring(badErr) .. ")") and allPass

        local restoreOk = core.write_all(core.TOML_PATH, originalToml)
        allPass = ok(restoreOk, "restored game.toml from snapshot") and allPass
        local finalData = core.read_all(core.TOML_PATH)
        allPass = ok(finalData == originalToml, "game.toml byte-identical to pre-test snapshot") and allPass
    end

    -- 2. cue creation logic against a scratch path -- never touch the real cue.
    local scratchCue = core.DISC_DIR .. "_selftest_scratch.cue"
    local scratchImg = core.TOML_PATH -- any file guaranteed to exist
    local cueOk, cueErr = core.create_cue(scratchImg, scratchCue)
    allPass = ok(cueOk, "create_cue() wrote scratch cue -> " .. tostring(cueErr)) and allPass
    if cueOk then
        local content = core.read_all(scratchCue)
        allPass = ok(content ~= nil and content:find(scratchImg, 1, true) ~= nil,
            "scratch cue contains expected FILE path") and allPass
        os.remove(scratchCue)
        allPass = ok(not core.file_exists(scratchCue), "scratch cue cleaned up") and allPass
    end
    allPass = ok(core.cue_exists(), "real disc\\YUGIOH.cue untouched and still present") and allPass

    local missingOk, missingErr = core.create_cue("C:\\this\\path\\does\\not\\exist.img", scratchCue)
    allPass = ok(missingOk == false, "create_cue() rejects a missing source file (" .. tostring(missingErr) .. ")") and allPass

    -- 3. list_saves
    local saves = core.list_saves()
    local found1, found2 = false, false
    for _, n in ipairs(saves) do
        if n == "card1.mcd" then found1 = true end
        if n == "card2.mcd" then found2 = true end
    end
    allPass = ok(found1 and found2,
        "list_saves() found card1.mcd and card2.mcd (got: " .. table.concat(saves, ", ") .. ")") and allPass

    -- 4. backup_saves -- real, additive, then clean up the copies it makes.
    local backedUp, errors = core.backup_saves()
    allPass = ok(#errors == 0, "backup_saves() had no errors") and allPass
    allPass = ok(#backedUp == #saves,
        "backup_saves() produced one backup per save file (" .. #backedUp .. "/" .. #saves .. ")") and allPass
    for _, name in ipairs(backedUp) do
        local p = core.BACKUP_DIR .. name
        allPass = ok(core.file_exists(p), "backup file exists: " .. name) and allPass
        os.remove(p)
    end

    -- 5. launch_game -- spawns the REAL exe. Preconditions are checked here;
    --    process presence is verified externally by whoever runs this.
    allPass = ok(core.exe_exists(), "game exe found at " .. core.EXE_PATH) and allPass
    local launchOk, launchMsg = core.launch_game()
    print("launch_game() -> " .. tostring(launchOk) .. " / " .. tostring(launchMsg))
    allPass = ok(launchOk, "launch_game() issued the launch command") and allPass

    print(allPass and "=== SELFTEST OVERALL: PASS ===" or "=== SELFTEST OVERALL: FAIL ===")
end

return M
