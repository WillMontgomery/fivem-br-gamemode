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
-- BR.Storm.aim plans the rest of the match toward the spot and hands the match
-- the plan, so every circle the storm draws from now on moves an equal share of
-- the way toward it and the final circle is centered on it (owner, 2026-10-07:
-- "I select a marker of where I want the storm to FINISH that match"). No spot
-- is refused: one over water or off the map is aimed as the nearest land to it.
--
-- STORM REVEAL STAYS TRUE. A squad that ran Storm reveal earlier this match is
-- sent where the storm now ends, the same way it was sent the first answer
-- (BR.Terminal.reveal), so its mark never shows a circle that will not come.
--
-- REFUSED, SPENDING NOTHING (the door's rule for a function's own reason):
--   no_storm         the storm has not drawn its first circle
--   storm_aimed      a Storm control already picked this match's spot: one
--                    spot a match (round 4's review), so the first runner's
--                    storm closes on their spot for the rest of the match
--   no_circle        the final circle (BR.StormFinalPhase, circle 7) is
--                    already on the map, and a circle on the map never moves
-- and asked again when the load is over, so the final circle drawn in those 3
-- to 5 seconds -- or another squad's Storm control landing first -- gives
-- everything back.

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
    -- Listed or run: the storm is not aimed yet, and there is a circle left to
    -- draw, or not. Wherever the spot is, the storm can close toward it, so the
    -- spot itself is never a reason. A dev terminal outside a match is never
    -- refused.
    refuse = function(src, session)
        local m = T.whereIs(src)
        if not m then return (not session.dev) and 'unavailable' or nil end
        local rec = m.storm
        if not rec or not m.stormRng then return 'no_storm' end
        if BR.Storm.aimed(m) then return 'storm_aimed' end
        if rec.phase >= BR.StormFinalPhase() then return 'no_circle' end
        return nil
    end,
    -- THE STORM CLOSES TOWARD THE SPOT: the match aimed at it, and every squad
    -- that ran Storm reveal told the new end.
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
        local plan, why = BR.Storm.aim(m, at.x, at.y)
        if not plan then return { ok = false, code = why } end
        -- Who aimed the storm that stands, spared its persistent notice.
        T.fxOf(m).stormBy = src
        reReveal(m)
        print(('[br_core] terminals: Storm control by %d in match %s at (%.1f, %.1f): the storm ends at (%.1f, %.1f)')
            :format(src, tostring(m.id), plan.x, plan.y, plan.ex, plan.ey))
        return { ok = true, code = 'done' }
    end,
}

-- THE PERSISTENT NOTICE (round 4), for the rest of the match: everyone in the
-- fight but the player who aimed the storm. One spot a match, so it never
-- changes hands.
T.impactSource(function(m, now, add)
    local by = m.stormAim ~= nil and m.terminalFx and m.terminalFx.stormBy or nil
    if not by then return end
    BR.Roster.each(function(e) return e.matchId == m.id end, function(src)
        if src ~= by then add(src, 'impact_storm', nil) end
    end)
end)
