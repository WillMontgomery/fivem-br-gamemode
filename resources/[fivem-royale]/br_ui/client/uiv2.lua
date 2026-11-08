-- UI v2 (#436) on the page: which of its pieces this machine holds.
--
-- The page draws each piece from what it is told here, and every piece is off
-- until it is told (ui-src/src/bridge/uiv2.ts): a piece off draws today's
-- screen, exactly. The answer is br_ui's MIRROR of the one br_core's client
-- holds (br_lib/shared/uiv2.lua), which moves standing in the lobby or as a
-- match starts, and mid-match only as a FIRST ANSWER, which a holder takes at
-- once in any state: a `restart br_core` makes a fresh holder, which takes the
-- server's answer then, mid-match too, and this sends it on.
--
-- SENT TWO WAYS, EACH COVERING WHAT THE OTHER CANNOT:
--
--   * AS THE PAGE REPORTS ITS ENVIRONMENT: client/nui.lua's ENV callback calls
--     BR.Ui.pushUiv2() just before br:ui:ready, ahead of every replay. That is
--     a page load, a reload and a br_ui restart -- and a restart moves the
--     mirror while the module loads, before this file is there to follow it.
--   * ON EVERY MOVE (BR.UIv2.onChange): the first answer, a br_core restart,
--     a lobby move, a match starting.
--
-- ONE LITERAL has() PER PIECE THE PAGE DRAWS. Each is its row's door
-- (tools/check_uiv2.lua U1, U2), and the keys are ui-src's UIv2Piece
-- (tools/test_uiv2.lua holds the two lists equal). The Market and the Locker
-- are not here: each rides its own envelope (client/market.lua's `v2`, and
-- br_core's LOCKER2 `on`).
--
-- NIL-SAFE like client/market.lua's market2On: tools/test_client.lua loads
-- br_ui without the UI v2 module.
--
-- LISTED AFTER client/nui.lua in the manifest, whose BR.Ui.send it uses.

BR = BR or {}
BR.Ui = BR.Ui or {}

--- Every piece the page draws, as this machine holds it now.
--- @return table
local function pieces()
    return {
        -- The in-match HUD, the squad panel included (#431).
        hud = BR.UIv2 ~= nil and BR.UIv2.has ~= nil and BR.UIv2.has('hud') == true,
    }
end

--- Tell the page which pieces this machine holds.
function BR.Ui.pushUiv2()
    BR.Ui.send(BR.Nui.UIV2, pieces())
end

if BR.UIv2 and BR.UIv2.onChange then
    BR.UIv2.onChange(function() BR.Ui.pushUiv2() end)
end
