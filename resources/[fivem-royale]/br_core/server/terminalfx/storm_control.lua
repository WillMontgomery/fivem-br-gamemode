-- Season 2 terminals (#396), wave B: STORM CONTROL, the server half (it has
-- no client half: the circles it decides reach every client as the storm's own
-- records, phase by phase).
--
--   "The server works out three possible final circles.
--    You pick one, and the storm closes toward it for the rest of the match.
--    Circles already on the map don't move. The change starts with the next
--    circle the storm draws."                  -- its page, storm_control_what
--
-- THE DOOR IS server/terminal.lua; this file is what happens once it has said
-- yes, and it costs 150 Volts (the registry row). The storm's half is
-- server/storm.lua's: BR.Storm.futures works out the possible ends -- the
-- storm's own planner run forward on streams of their own, so each one obeys
-- every rule a match's storm does -- and BR.Storm.steer hands the match the
-- chosen one's stream. The record on the map and the seed every shape comes
-- from are not touched.
--
-- THE THREE (BR.TerminalSolve.threeEnds over fx.stormControlFutures ends):
--   near    the end nearest THIS terminal
--   far     of the others, the end farthest from it
--   center  of the rest, the end nearest the next circle's center -- the
--           circle the storm is closing toward, the newest on the map, as
--           Supply drop's "next circle" is
-- "This terminal" is the session's terminal, or the player at the dev
-- terminal (Supply drop's rule).
--
-- STORM REVEAL STAYS TRUE. A squad that ran Storm reveal earlier this match is
-- sent where the storm now ends, the same way it was sent the first answer
-- (BR.Terminal.reveal), so its mark never shows a circle that will not come.
--
-- REFUSED, SPENDING NOTHING (the door's rule for a function's own reason):
--   no_storm   the storm has not drawn its first circle
--   no_circle  the final circle is already on the map: nothing is left to draw
-- and asked again when the load is over, so a final circle drawn in those 3
-- to 5 seconds gives everything back.

BR = BR or {}
BR.Terminal = BR.Terminal or {}

local T = BR.Terminal
local TS = BR.TerminalSolve

local function fx() return BR.Config.Terminals.fx or {} end

--- Where "this terminal" is: the session's terminal, or, for a terminal the
--- server does not know (the dev terminal), the player.
--- @return number|nil x, number|nil y
local function anchorOf(src, session)
    local t = T.site(session.terminalId)
    if t then return t.x, t.y end
    local e = BR.Roster.get(src)
    if e and e.pos then return e.pos.x, e.pos.y end
    return nil, nil
end

--- Why Storm control cannot run in this match now, or nil.
--- @param m table
--- @return string|nil
local function why(m)
    local rec = m.storm
    if not rec or not m.stormRng then return 'no_storm' end
    if rec.phase >= #BR.Config.Storm.phases then return 'no_circle' end
    return nil
end

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
    -- The same answer for every choice: there is a circle left to draw or there
    -- is not. A dev terminal outside a match is never refused for it.
    refuse = function(src, session)
        local m = T.whereIs(src)
        if not m then return (not session.dev) and 'unavailable' or nil end
        return why(m)
    end,
    -- THE STORM ENDS WHERE THE PLAYER CHOSE: the possible ends worked out now,
    -- the chosen one's stream handed to the match, and every squad that ran
    -- Storm reveal told the new end.
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
        local no = why(m)
        if no then return { ok = false, code = no } end
        local ax, ay = anchorOf(src, session)
        if not ax then return { ok = false, code = 'unavailable' } end
        local now = GetGameTimer()
        local ends, bad = BR.Storm.futures(m, fx().stormControlFutures or 8, now)
        if not ends then return { ok = false, code = bad or 'no_storm' } end
        local rec = m.storm
        local three = TS.threeEnds(ends, ax, ay, rec.cx1, rec.cy1)
        local zone = opts and opts.zone or 'near'
        local chosen = ends[three[zone] or three.near]
        BR.Storm.steer(m, chosen)
        reReveal(m)
        print(('[br_core] terminals: Storm control (%s) by %d in match %s: the storm ends at (%.0f, %.0f)')
            :format(zone, src, tostring(m.id), chosen.x, chosen.y))
        return { ok = true, code = 'done' }
    end,
}
