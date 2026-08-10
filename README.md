# YuGiOhRecompLauncher

A small LÖVE2D (Lua) launcher/front-end for [YuGiOhForbiddenMemoriesRecomp](https://github.com/eduardocalafell/YuGiOhForbiddenMemoriesRecomp) — a static recompilation of *Yu-Gi-Oh! Forbidden Memories* (PS1, SLUS-01411) built on the [psxrecomp](https://github.com/mstan/psxrecomp) framework.

This is a convenience shell around the already-built recompiled game. It does not touch the game's code or the recompiled binary itself — it only edits config and launches the process. The UI is a fully procedural "arcane gold / obsidian" theme (drawn in LÖVE, no external art beyond the project logo) — see `game/theme.lua` and `game/icons.lua`.

## What it does

- **Renderer picker** — switches `[video] renderer` (`software` / `opengl` / `vulkan`) in the game's `game.toml` with a single-line, byte-preserving edit.
- **Smooth 60 FPS mode** — one toggle selects OpenGL and enables the runtime's frame interpolation at launch (interpolated presentation up to the host refresh; guest timing stays stock), for smooth motion even though the game logic ticks below 60. Applied via `PSX_FRAME_INTERPOLATION*` env vars on the launched process — no `game.toml` edit.
- **First-run disc setup wizard** — if no `disc/YUGIOH.cue` exists yet, prompts for the path to your own legally-dumped disc image and writes a minimal `.cue` pointing at it. Never copies the disc image itself.
- **Save management** — lists memory card saves and makes one-click timestamped backups.
- **Play** — launches the recompiled game as a detached process with the right working directory/config.

## Status

Phase 1 (this shell) is done and tested (see `game/selftest.lua`, a headless harness covering the same logic the UI calls). Phase 2 — a Lua modding API hooking into the recompiled game code itself (e.g. intercepting card-stat/fusion functions) — is not started; this launcher never touches `generated/`, `psxrecomp/`, or any recompiler output.

## Requirements

- A working build of [YuGiOhForbiddenMemoriesRecomp](https://github.com/eduardocalafell/YuGiOhForbiddenMemoriesRecomp) (MinGW build — see that repo; the MSVC build is currently broken, see its README).
- Your own legally-dumped copy of the Yu-Gi-Oh! Forbidden Memories disc (SLUS-01411, NTSC-U). Nothing here (or in the game repo) includes or requires any copyrighted disc/game data — you bring your own dump.
- Windows. LÖVE 11.5 (win64) as the runtime — either grab the fused `.exe` from this repo's [Releases](../../releases) (bundles LÖVE, no separate install needed), or run from source with your own LÖVE install (see below).

## Running

**From a release**: download the latest zip from [Releases](../../releases), extract, run `YuGiOhRecompLauncher.exe`. It expects to sit two directories away from the game repo the same way this source tree does — see the layout below, or edit the paths at the top of `game/core.lua`.

**From source**:
```
runtime\love.exe game
```
(or double-click `Run-Launcher.bat` / `Run-Launcher-Debug.bat` for a console window with logs, once you've placed a LÖVE 11.5 win64 distribution in `runtime\`).

## Expected layout

```
C:\games\
  ygo-recomp\                          <- YuGiOhForbiddenMemoriesRecomp checkout/build
    build-mingw\Yu_Gi_Oh__Forbidden_Memories_Recompiled.exe
    game.toml
    disc\YUGIOH.cue
    saves\
  ygo-recomp-launcher\                 <- this repo
    game\
    runtime\                           <- LÖVE 11.5 win64 (not committed, see .gitignore)
```

## Known simplifications (candidates for a future pass)

- The first-run Browse… file-picker still shells out to a one-shot PowerShell `OpenFileDialog` and blocks the UI thread while open. It's the last remaining subprocess in the launcher (everything else — directory listing, mkdir, launching the game — now goes straight through the Win32 API via LuaJIT's FFI, so nothing flashes a console during normal use). Low priority since it only fires once, during disc setup.
- No validation of the chosen disc dump's contents (track count/sector mode) beyond "the file exists".
- No launcher-side settings persistence beyond what's already in `game.toml`.

## Legal

No game or disc data is included in this repository or its releases — only the launcher's own Lua source and the LÖVE runtime (zlib-licensed, redistributable). You need your own build of the game and your own legal disc dump for any of this to do anything.
