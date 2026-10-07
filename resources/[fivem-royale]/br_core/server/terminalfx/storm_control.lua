-- Season 2 terminals (#396), wave B: STORM CONTROL, the server half (it has
-- no client half of its own: the circles it decides reach every client as the
-- storm's own records, phase by phase, and the mark it leaves is Storm
-- reveal's; the spot is picked on the big map by the confirm box's "Set
-- location" step, client/terminal.lua's picker).
--
--   "I select a marker of where I want the storm to FINISH that match. Then,
--    once that's applied, I have a persistent marker that I can see and my
--    teammates can see, which shows us that location. As the match progresses,
--    each storm will incrementally move closer to that point - breakouts will
--    be much more common if the point is far away, and that breaks our
--    traditional rules."                                   -- owner, 2026-10-07
--
-- THE DOOR IS server/terminal.lua; this file is what happens once it has said
-- yes, and it costs 150 Volts (the registry row). The run carries the spot the
-- player picked (`spot = true` on the row: BR.Terminal.spot checks its shape,
-- and it arrives as `opts.at`). The storm's half is server/storm.lua's:
-- BR.Storm.aim plans the rest of the match toward the spot and hands the match
-- the plan, so every circle the storm draws from now on moves an equal share of
-- the way toward it and the final circle is centered on it. No spot is
-- refused: one over water or off the map is aimed as the nearest land to it.
--
-- THE MARK, ON THE SQUAD'S MAPS (2026-10-07). Where the storm finishes is
-- exactly what Storm reveal shows, so it is Storm reveal's mark
-- (BR.Terminal.reveal): sent to the runner's squad -- its dead and spectating
-- members too, or the runner alone in a solo match -- kept for the match, and
-- sent again by BR.Net.READY to a client that restarts. A squad has one
-- terminal use a match, so it never holds both marks.
--
-- STORM REVEAL STAYS TRUE. Every other squad that ran Storm reveal earlier
-- this match is sent where the storm now finishes, the same way it was sent
-- the first answer, so its mark never shows a circle that will not come.
--
-- REFUSED, SPENDING NOTHING (the door's rule for a function's own reason):
--   no_storm         the storm has not drawn its first circle
--   storm_aimed      a Storm control already picked this match's spot: one
--                    spot a match (round 4's review), so the first runner's
--                    storm finishes on their spot
--   no_circle        the final circle (BR.StormFinalPhase, circle 7) is
--                    already on the map, and a circle on the map never moves
-- and asked again when the load is over, so the final circle drawn in those 3
-- to 5 seconds -- or another squad's Storm control landing first -- gives
-- everything back.

BR = BR or {}
BR.Terminal = BR.Terminal or {}

local T = BR.Terminal

--- Send every squad that ran Storm reveal in this match, but `skip`, where the
--- storm finishes now. In squad order, so the sends replay.
--- @param m table
--- @param f table     BR.Storm.finalCentre's answer
--- @param skip string|nil  the squad already sent it
local function reReveal(m, f, skip)
    local s = m.terminals
    if not (s and s.reveals and next(s.reveals)) then return end
    local keys = {}
    for key in pairs(s.reveals) do
        if key ~= skip then keys[#keys + 1] = key end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do T.reveal(m, key, f) end
end

T.FUNCTIONS.storm_control = {
    -- Listed or run: the storm is not aimed yet, and the final circle is not
    -- on the map yet, or not. Wherever the spot is, the storm can finish on
    -- it, so the spot itself is never a reason. A dev terminal outside a match
    -- is never refused.
    refuse = function(src, session)
        local m = T.whereIs(src)
        if not m then return (not session.dev) and 'unavailable' or nil end
        local rec = m.storm
        if not rec or not m.stormRng then return 'no_storm' end
        if BR.Storm.aimed(m) then return 'storm_aimed' end
        if rec.phase >= BR.StormFinalPhase() then return 'no_circle' end
        return nil
    end,
    -- THE STORM FINISHES ON THE SPOT: the match aimed at it, the runner's
    -- squad shown it, and every squad that ran Storm reveal told the new end.
    run = function(src, session, opts)
        local m, _, key = T.whereIs(src)
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
        -- Who aimed the storm that stands, and their squad: spared its
        -- persistent notice, since the squad has the mark.
        local fx = T.fxOf(m)
        fx.stormBy, fx.stormSquad = src, key
        local f = BR.Storm.finalCentre(m)
        if f then
            T.reveal(m, key, f)
            reReveal(m, f, key)
        end
        print(('[br_core] terminals: Storm control by %d in match %s at (%.1f, %.1f): the storm finishes at (%.1f, %.1f)')
            :format(src, tostring(m.id), plan.x, plan.y, plan.ex, plan.ey))
        return { ok = true, code = 'done' }
    end,
}

-- THE PERSISTENT NOTICE (round 4), for the rest of the match: everyone in the
-- fight but the squad that aimed the storm, which has the mark instead ("you
-- and your squad see it on the map ... Everyone else only gets the usual
-- notice", 2026-10-07). One spot a match, so it never changes hands.
T.impactSource(function(m, now, add)
    local fx = m.stormAim ~= nil and m.terminalFx or nil
    if not (fx and fx.stormBy) then return end
    BR.Roster.each(function(e) return e.matchId == m.id end, function(src, e)
        if src ~= fx.stormBy and BR.TerminalSolve.squadKey(e, src) ~= fx.stormSquad then
            add(src, 'impact_storm', nil)
        end
    end)
end)
