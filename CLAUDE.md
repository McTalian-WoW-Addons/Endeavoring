# Endeavoring

WoW addon (Lua): enhances the Endeavors neighborhood UI — contributor breakdown, leaderboard, activity log, profile sync. Shared workflow: `wow-dev` plugin skills.

## Commands

`make help` lists targets. Checks: `/wow-dev:run-checks`. Notable: `make test-file FILE=…`, `make test-pattern PATTERN="…"`, `make boot_sim` (client load-order sim), `make hardcode_string_check`, `make i18n_fmt`.
In-game: `/endeavoring` or `/ndvr`.

## Conventions

- Every file starts `local addonName = select(1, ...)` then `local ns = select(2, ...)`; modules end `ns.X = X` (no `return`).
- Strings via `ns.L["Key"]`, key added to `Endeavoring/locale/enUS.lua` under the current `--#region` block.
- Specs build `ns` with `Endeavoring_spec/_mocks/nsMocks.CreateNS()`; `LoadOrder_spec.lua` `loadfile()`s every `.toc` module in order to catch load errors.
Full list: `docs/agent/conventions.md`.

## Docs

- `.github/docs/architecture.md` — file layout, module responsibilities.
- `.github/docs/sync-protocol.md` — addon-comm sync protocol, message limits.
- `.github/docs/message-codec.md` — CBOR encode/decode, compression.
- `.github/docs/database-schema.md` — `EndeavoringDB` SavedVariables shape.
- `.github/docs/glossary.md` — WoW/Endeavoring terminology.
- `.github/docs/resources.md` — dev reference links.
- `docs/pr-title-rules.md` — PR titles; merge labels.
