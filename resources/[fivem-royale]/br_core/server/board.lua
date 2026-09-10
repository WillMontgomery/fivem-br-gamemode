-- The warmup stat board's server half, which is one value and no logic (#247).
--
-- ═══════════════════════════════════════════════════════════════════════════
-- WHY THIS FILE EXISTS AT ALL
-- ═══════════════════════════════════════════════════════════════════════════
--
-- The board is a DUI: a browser on the PLAYER'S machine, pointed at
-- https://<ringmaster>/scoreboard?id=<their license>. Building that URL needs a
-- license, and nothing in br_core/client has ever held one. A client knows its
-- server id, its name, its inventory and its squad; identifiers are a server
-- fact, read off the FiveM connection, and every consumer of them so far
-- (grants, bans, stats, evidence) has been server-side.
--
-- So this is the missing wire, and it is the whole file: on READY, tell that one
-- client its own license.
--
-- ═══ THE GAME SERVER STILL DOES NOT DEPEND ON RINGMASTER, AND THIS IS WHERE
--     THAT WOULD HAVE BEEN GIVEN AWAY ═══
--
-- The obvious wrong shape is a server that fetches the board, or checks whether
-- Ringmaster is up, or holds a URL. None of that is here. This handler reads an
-- identifier FiveM already gave us and sends it to its owner. It would run
-- identically on a box that had never heard of the console, it makes no HTTP
-- request, it has no timeout, and there is no state anywhere on this box that a
-- Ringmaster outage can change. The only thing that ever talks to Ringmaster in
-- this feature is a Chromium instance on somebody else's computer.
--
-- ═══ ON READY, WHICH IS BEFORE THE BOARD CAN POSSIBLY BE WANTED ═══
--
-- BR.Net.READY is the client saying it has finished loading and wants a
-- snapshot; server/world.lua, server/broadcast.lua, server/community.lua and
-- server/admin.lua all already hang a per-player push off it. A player cannot be
-- in the warmup state before that, so the license is in hand before
-- client/board.lua has any reason to build a browser -- which is the ordering
-- requirement, and it is met by construction rather than by a delay.
--
-- AND IT RE-FIRES ON EVERY br_ui RESTART AND EVERY br_core RESTART, because
-- client/state.lua re-sends READY on both. So a `restart br_core` mid-session
-- gets the license back rather than leaving a client that can never build a URL
-- again, which is the silent half-wiring this project keeps paying for.

--- The one push.
---
--- BARE, NOT QUALIFIED. BR.Identity.licenseOf strips the `license:` prefix, and
--- the bare hex is exactly what the owner's URL carries: `?id=b6f5a127...`. The
--- prefixed form is what br_stats keys rows on and what BR.Grants asks about;
--- re-attaching it here would put `license:` in a query string and answer 400.
---
--- NIL IS A REAL ANSWER AND IS NOT AN ERROR. FiveM does not always report a
--- license (BR.Identity.licenseOf's own note says so, and says nothing should
--- invent a fallback). A client that is never told one builds no URL, creates no
--- browser and draws no board, and /brboard on that client prints an empty
--- license -- which is a diagnosis rather than a mystery.
RegisterNetEvent(BR.Net.READY)
AddEventHandler(BR.Net.READY, function()
    -- `source` READ ONCE, INTO A LOCAL, BEFORE ANYTHING ELSE. It is a magic
    -- global that only holds the calling client for the synchronous part of the
    -- handler; every server file in this project takes the same precaution.
    local src = source

    local license = BR.Identity and BR.Identity.licenseOf(src)
    if type(license) ~= 'string' or license == '' then return end

    TriggerClientEvent(BR.Net.BOARD_ID, src, license)
end)
