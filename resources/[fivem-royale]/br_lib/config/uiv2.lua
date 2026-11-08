-- UI v2 (#436): the one list of redone screens, each behind a switch of its
-- own and all of them behind one.
--
-- Owner, 2026-11-07: "All this UI rework - can we make a server-side toggle
-- for it? One toggle for everything (market, locker v2, HUD, inventory, player
-- list, etc), and also a separate toggle for each component? Let's call
-- everything as a whole UI v2." UI v2 is separate from the season: the season
-- decides what content exists, UI v2 how it looks, in any season.
--
-- ═══ ONE ROW PER PIECE, AND ONLY HERE ═══
--
--   <id> = {}    a piece: lowercase letters and digits, from a letter
--
-- A door asks BR.UIv2.has('<id>') (br_lib/shared/uiv2.lua), and that is the
-- only way anything asks. br_uiv2 in server.cfg is UI v2 as a whole, off when
-- unset; br_uiv2_<id> set on or off wins either way, and unset follows it.
-- `bruiv2` on the server console flips them live.
--
-- PURE DATA: no convar is read here. tools/check_uiv2.lua (verify.sh's
-- `ui v2 gates`) loads this file in bare Lua and fails the build for a row
-- that is not an empty table, an id that is not lowercase letters and digits,
-- an id passed to has() with no row here, and a row nothing asks about.
--
-- inventory and players join as each is ported from its preview, one row and
-- its doors each. A NEW ROW FOLLOWS br_uiv2 from the deploy that adds it, and
-- shows from the one that first draws it, so a box with br_uiv2 on that should
-- not show it yet needs br_uiv2_<id> off (DEPLOY.md, before merging dev into
-- main).

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.UIv2 = {
    pieces = {
        -- #28: My Looks, the ped picker -- stock, custom freemode peds and
        -- saved looks (br_core/client/locker2.lua). Off: Season 1's locker,
        -- exactly as it was. It changes only standing in the lobby, where a
        -- character can be changed.
        locker = {},
        -- #411: the Market with the lobby character kept in view, tabs only
        -- for the kinds with real items, a buy confirm, and a Preview of a
        -- dance on the lobby character while the season has dances. Off:
        -- Season 1's Market and its grid, exactly as they were.
        market = {},
        -- #431: the in-match HUD in the Broadcast look, the squad panel
        -- included, ported from its preview. Off: today's HUD, exactly. The
        -- page is told it (br_ui/client/uiv2.lua) before any screen reads it.
        hud = {},
    },
}
