-- Season 2 terminals (#396), wave B: STORM DELAY, the server half (it has no
-- client half: the storm record it changes is the storm every client draws).
--
--   "The storm's current hold gets longer by the time you choose.
--    If the storm is already closing, the delay is added to its next hold.
--    The next circle doesn't change."         -- its page, storm_delay_what
--
-- THE DOOR IS server/terminal.lua (the session, the key, the squad's one use,
-- the 3-5 s load, the lobby's notice, the refund); this file is what happens
-- once it has said yes. The storm's half is BR.Storm.delay in
-- server/storm.lua: the hold is the published record's own `tWait`, so a
-- longer hold is the record rebuilt and published -- every countdown, the
-- sweep after it and the circles on the map follow from that one record, as
-- they do for every hold.
--
-- THE CHOICE IS THE ROW'S OWN NUMBER: `delay` is '60' or '120', seconds, read
-- as a number here (br_lib/config/terminals.lua's registry).
--
-- REFUSED, SPENDING NOTHING (the door's rule for a function's own reason):
--   no_storm  the storm has not drawn its first circle
--   no_hold   no hold is left to lengthen: the final circle is closing or
--             closed (BR.Storm.holdLeft)
-- and asked again when the load is over, so a hold that ran out in those
-- 3 to 5 seconds gives everything back.

BR = BR or {}
BR.Terminal = BR.Terminal or {}

local T = BR.Terminal

--- The delay a run asked for, in ms: its `delay` choice, a whole number of
--- seconds the registry allows (BR.Terminal.options already checked it).
--- @param opts table|nil
--- @return integer
local function delayMs(opts)
    local s = tonumber(opts and opts.delay) or 0
    return math.max(0, math.floor(s * 1000))
end

--- Why Storm delay cannot run in this match now, or nil.
--- @param m table
--- @return string|nil
local function why(m)
    if not m.storm then return 'no_storm' end
    if BR.Storm.holdLeft(m, GetGameTimer()) == nil then return 'no_hold' end
    return nil
end

T.FUNCTIONS.storm_delay = {
    -- The same answer for every choice: a hold is left to lengthen or it is
    -- not, whatever the delay. A dev terminal outside a match is never refused
    -- for it (the app alone, typed facts).
    refuse = function(src, session)
        local m = T.whereIs(src)
        if not m then return (not session.dev) and 'unavailable' or nil end
        return why(m)
    end,
    -- THE HOLD GETS LONGER: this one while the storm holds, the next one while
    -- it closes (BR.Storm.delay). Everyone in the match sees it on the
    -- countdown, from the record.
    run = function(src, session, opts)
        local m = T.whereIs(src)
        if not m then
            if session.dev then
                print(('[br_core] brterminal (client %d): Storm delay ran on the dev terminal '
                    .. 'with no match to delay'):format(src))
                return { ok = true, code = 'done' }
            end
            return { ok = false, code = 'unavailable' }
        end
        local no = why(m)
        if no then return { ok = false, code = no } end
        local which = BR.Storm.delay(m, delayMs(opts), GetGameTimer())
        if not which then return { ok = false, code = 'no_hold' } end
        return { ok = true, code = 'done' }
    end,
}
