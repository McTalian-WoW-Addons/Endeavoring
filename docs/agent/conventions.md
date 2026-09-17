# Endeavoring conventions

## Structure

- Start every file `local addonName = select(1, ...)` then `local ns = select(2, ...)` (`---@class Ndvrng_NS`).
- End every module file `ns.X = X`; no `return` statement.
- `Bootstrap.lua` loads first per the `.toc` and populates `ns.Constants`, `ns.MSG_TYPE`, `ns.SK`, `ns.state`, `ns.DebugPrint`.
- Layered dirs: `Data/` (SavedVariables), `Cache/`, `Services/` (API wrappers), `Sync/` (addon-comm protocol), `Features/` (UI tabs), `Integrations/` (Blizzard frame hooks).

## WoW API

- Most `C_*` calls live in `Services/*.lua` (`NeighborhoodAPI`, `PlayerInfo`, `QuestRewards`), but `Features/*.lua` may call Blizzard `C_*` APIs directly too (e.g. `Tasks.lua` calls `C_NeighborhoodInitiative` for tracked tasks) — there is no single adapter seam to route through.
- Retail-only addon (`## Interface: 120100`); no flavor branching needed.
- Confirm API signatures, events, and enums against `wow-ui-source` (`live` branch) before using one.

## Strings

- User-facing text goes through `ns.L["Key"]`, with the key added to `Endeavoring/locale/enUS.lua` under the current `--#region`/`--#endregion` version block.
- `print()` is used directly for user errors/info, prefixed with `ns.Constants.PREFIX_ERROR`/`PREFIX_INFO`/`PREFIX_WARN`.
- `ns.DebugPrint` is gated by `ns.DB.IsVerboseDebug()`; use it for debug-only output instead of a bare `print()`.
- `make hardcode_string_check` flags literal strings that should route through `L[]`.

## Testing

- Specs build a namespace with `Endeavoring_spec/_mocks/nsMocks.CreateNS()` rather than `loadfile`-per-module against a hand-built `ns`.
- `Endeavoring_spec/LoadOrder_spec.lua` parses `Endeavoring.toc` and `loadfile()`s every module in TOC order into a fresh `ns`, to catch load-time errors normal specs never exercise.
- Run tests only through `make test*` targets; `busted`/`luacov` are not on `$PATH` (they live in `~/.luarocks/bin`).

## Packaging

- Only `Endeavoring/` ships; `Endeavoring_spec/`, `.github/`, `docs/`, and root config files are dev-only.
- `wow-build-tools` skips untracked files silently, and this repo has no `check_untracked_files` guard target — `git add` new `.lua` files yourself before `make dev`/`make build`.
- Type commits by whether they touch the packaged `Endeavoring/` dir; see `/wow-dev:git-workflow`.
