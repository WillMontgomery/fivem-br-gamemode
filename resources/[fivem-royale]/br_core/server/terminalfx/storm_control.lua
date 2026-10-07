-- Season 2 terminals (#396), wave B: STORM CONTROL, the server half (it has
-- no client half of its own: the circles it decides reach every client as the
-- storm's own records, phase by phase; the spot is picked on the big map by
-- the confirm box's "Set location" step, client/terminal.lua's picker).
--
--   "Storm control: we should let them actually pick exactly where they want
--    it. When they click confirm, we should open the big map for them, wait
--    for them to pick a location, then when they close the big map we run
--    it."                                                  -- owner, 2026-10-06
--
-- THE DOOR IS server/terminal.lua; this file is what happens once it has said
-- yes, and it costs 150 Volts (the registry row). The run carries the spot the
-- player picked (`spot = true` on the row: BR.Terminal.spot checks its shape,
-- and it arrives as `opts.at`). The storm's half is server/storm.lua's:
-- BR.Storm.aimCheck holds the spot to the planner's rules and BR.Storm.aim
-- hands the match it, so the storm ends EXACTLY there -- or, when it cannot,
-- the run is refused with the reason, before anything is spent (never moved
-- to a nearby spot: see server/storm.lua's STORM CONTROL block).
--
-- STORM REVEAL STAYS TRUE. A squad that ran Storm reveal earlier this match is
-- sent where the storm now ends, the same way it was sent the first answer
-- (BR.Terminal.reveal), so its mark never shows a circle that will not come.
--
-- REFUSED, SPENDING NOTHING (the door's rule for a function's own reason):
--   no_storm         the storm has not drawn its first circle
--   no_circle        the final circle is already on the map
--   storm_spot_land  the spot is over water or outside the play area
--   storm_spot_out   the spot is outside the next circle on the map
--   storm_spot_edge  the spot is too near that circle's edge to end on
-- and asked again when the load is over, so a circle drawn in those 3 to 5
-- seconds that no longer holds the spot gives everything back.

BR = BR or {}
BR.Terminal = BR.Terminal or {}

local T = BR.Terminal

--- Send every squad that ran Storm reveal in this match where the storm ends
--- now. In squad order, so the sends replay.
--- @param m table
local function reReveal(m)
    local s = m.terminals
    if not (s and s.reveals and next(s.reveals)) then return end
    local f = BR.Storm.finalCentre(m)
    if not f then return end
    local keys = {}
    for key in pairs(s.reveals) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do T.reveal(m, key, f) end
end

T.FUNCTIONS.storm_control = {
    -- Listed (no spot yet): there is a circle left to draw or there is not.
    -- With the spot: whether the storm can end exactly on it. A dev terminal
    -- outside a match is never refused.
    refuse = function(src, session, opts)
        local m = T.whereIs(src)
        if not m then return (not session.dev) and 'unavailable' or nil end
        local rec = m.storm
        if not rec or not m.stormRng then return 'no_storm' end
        if rec.phase >= #BR.Config.Storm.phases then return 'no_circle' end
        local at = opts and opts.at
        if not at then return nil end
        local _, why = BR.Storm.aimCheck(m, at.x, at.y)
        return why
    end,
    -- THE STORM ENDS ON THE SPOT: the match aimed at it, and every squad that
    -- ran Storm reveal told the new end.
    run = function(src, session, opts)
        local m = T.whereIs(src)
        if not m then
            if session.dev then
                print(('[br_core] brterminal (client %d): Storm control ran on the dev terminal '
                    .. 'with no match to steer'):format(src))
                return { ok = true, code = 'done' }
            end
            return { ok = false, code = 'unavailable' }
        end
        local at = opts and opts.at
        if not at then return { ok = false, code = 'bad_option' } end
        local spot, why = BR.Storm.aim(m, at.x, at.y)
        if not spot then return { ok = false, code = why } end
        reReveal(m)
        print(('[br_core] terminals: Storm control by %d in match %s: the storm ends at (%.1f, %.1f)')
            :format(src, tostring(m.id), spot.x, spot.y))
        return { ok = true, code = 'done' }
    end,
}
