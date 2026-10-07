-- Season 2 terminals (#396), wave C: REBOOT, the server half.
--
-- THE PAGE (br_lib/config/terminals.lua, `reboot_*`): "Every eliminated player
-- in your squad comes back with full health, by parachute over you or the
-- teammate you pick. They come back with an empty inventory. Players who left
-- the match don't come back." 150 Volts (its row). Squad-only: the door hides
-- it and refuses it outside a squad match (round 2).
--
-- ═══ OVER THE RUNNER OR A TEAMMATE, NEVER "THIS TERMINAL" (round 6) ═══
--
--   "Any use of "near this terminal" is like, not useful for this gamemode."
--                                                   -- owner, 2026-10-07
--
-- It came back over the terminal it was run at. Now option `to` says over
-- whom, as Vehicle drop's does (server/terminalfx/vehicle_drop.lua, the same
-- rule to the letter): 'self', the runner, who must be STANDING when it runs
-- (`reboot_target` otherwise), or 'mate' with option `mate`, a standing
-- teammate the state listed (BR.Terminal.mates) -- `drop_no_mate` when that
-- teammate is no longer one as it runs, everything given back. Asked as the
-- run is asked, as it is accepted and as the load ends; the point is where
-- that player stands then, by the server's own 4 Hz sample.
--
-- ═══ THE GAMEMODE'S ONE WAY BACK INTO A MATCH ═══
--
-- Not a second respawn. BR.ReviveKey.bringBackAt (server/revivekey.lua) is
-- the revive key's own return with no key, no hold and nobody credited: the
-- screen goes black and the streaming focus moves to the point, the spectate
-- camera comes down, and a fade later the player is resurrected 150 m over
-- it with the parachute (client/revivekey.lua's REVIVEKEY_PLACE and
-- skydive.lua's drop), at full health (the display bar's 100, this page's
-- promise, whatever the key's reviveHp says), ALIVE -- over the player picked,
-- as a key's is over its ambulance.
--
--   WHO          every member of the runner's squad who is OUT, in this match
--                and still connected, and not already on the way back (a key
--                arrival that has committed lands on its own) -- the runner
--                too, if they were eliminated while it loaded and it comes
--                back over a teammate (over themselves, they must be
--                standing). A player who
--                walked out or disconnected is no longer in the match's
--                roster, so "players who left the match don't come back" holds
--                by construction.
--   NOBODY       to bring back: refused, spending nothing (`reboot_none`), and
--                asked again when the load ends -- a squad whose eliminated
--                mates came back by key meanwhile gets everything back.
--   NOBODY LEFT  in the fight: refused (`unavailable`), everything back. A
--                squad whose last member fell during the load is out of the
--                match -- placed, and perhaps the match decided by it -- and
--                nothing in this gamemode brings a squad back from that
--                (reviveAllowed needs a living squadmate at the ambulance for
--                the same reason).
--
-- ═══ WHAT IT DOES TO THE RECORDS (the key's return does all of it) ═══
--
--   PLACEMENT    retracted on every client (BR.Roster.clearFields), and
--                written again at their next elimination or the match's end.
--   DEATH        `diedAt` cleared, so a rebooted player who survives is not
--                counted as having died; eliminated again, it is written
--                again, and they are placed again by the squads then left.
--   KILLS        the kill that eliminated them stays credited to its killer.
--   REVIVES      nobody's `revives` grows: nobody performed one.
--   THE KEY      a revive key for them, held or not, bought or not, is spent:
--                they are back (the page's risks say so).
--   THE SQUADS   still standing: unchanged -- only a squad with somebody in
--                the fight is rebooted, so BR.Server.squadsAlive, the match's
--                end check (`<= 1`), is exactly what it was. The players left
--                (the HUD's count) grows by the number brought back.
--
-- Its lines name nobody: the squad's done line, and the lobby's notice. No
-- client half of its own.

BR = BR or {}
BR.Terminal = BR.Terminal or {}

local T = BR.Terminal
local TS = BR.TerminalSolve

--- The display bar's top: health travels in display units (0..100).
local FULL_HP = 100.0

--- Everyone in squad `key` a Reboot brings back now: OUT, in this match,
--- connected, and not already on the way back.
--- @param m table
--- @param key string
--- @return integer[]
function T.rebootable(m, key)
    local out = {}
    for _, s in ipairs(T.squadOf(m, key)) do
        local e = BR.Roster.get(s)
        if e and e.state == BR.PlayerState.OUT and GetPlayerName(s) ~= nil
           and not (BR.ReviveKey and BR.ReviveKey.returning and BR.ReviveKey.returning(s)) then
            out[#out + 1] = s
        end
    end
    return out
end

--- Is anybody in squad `key` still in the fight (standing, downed, in the air)?
--- @param m table
--- @param key string
--- @return boolean
local function standing(m, key)
    for _, s in ipairs(T.squadOf(m, key)) do
        local e = BR.Roster.get(s)
        if e and T.marked(e.state) then return true end
    end
    return false
end

--- Why a Reboot cannot run for this squad now, or nil.
local function refusal(m, key)
    if not (BR.ReviveKey and BR.ReviveKey.bringBackAt) then return 'unavailable' end
    if #T.rebootable(m, key) == 0 then return 'reboot_none' end
    if not standing(m, key) then return 'unavailable' end
    return nil
end

--- Who the squad comes back over, or nil and why: Vehicle drop's rule
--- (server/terminalfx/vehicle_drop.lua targetOf), to the letter -- the runner,
--- standing, or the standing teammate picked, in a squad match.
--- @param src integer  the runner
--- @param opts table|nil
--- @return integer|nil target, string|nil why
local function targetOf(src, opts)
    local to = opts and opts.to or 'self'
    if to == 'self' then
        local e = BR.Roster.get(src)
        if not (e and e.state == BR.PlayerState.ALIVE) then return nil, 'reboot_target' end
        return src, nil
    end
    if to ~= 'mate' or not T.squadMatch(src) then return nil, 'bad_option' end
    local want = tonumber(opts.mate)
    for _, row in ipairs(T.mates(src)) do
        if tonumber(row.id) == want then return want, nil end
    end
    return nil, 'drop_no_mate'
end
T.rebootTargetOf = targetOf

--- Where that player stands, with its height: the server's own sample.
--- @return table|nil { x, y, z }
local function point(target)
    local e = BR.Roster.get(target)
    local p = e and e.pos
    if not (p and TS.finite(p.x) and TS.finite(p.y) and TS.finite(p.z)) then return nil end
    return { x = p.x + 0.0, y = p.y + 0.0, z = p.z + 0.0 }
end

T.FUNCTIONS.reboot = {
    -- NOBODY TO BRING BACK IS REFUSED, SPENDING NOTHING -- the 150 Volts
    -- included -- and asked again when the loading is over; and so is
    -- nobody standing to come back over (round 6). Listed, who it is over is
    -- a choice the card has not made yet.
    refuse = function(src, session, opts)
        local m, _, key = T.whereIs(src)
        if not m then return (not session.dev) and 'unavailable' or nil end
        local why = refusal(m, key)
        if why or opts == nil then return why end
        local _, whyTarget = targetOf(src, opts)
        return whyTarget
    end,
    run = function(src, session, opts)
        local m, _, key = T.whereIs(src)
        if not m then
            if session.dev then
                print(('[br_core] brterminal (client %d): Reboot ran on the dev terminal '
                    .. 'with no squad to bring back'):format(src))
                return { ok = true, code = 'done' }
            end
            return { ok = false, code = 'unavailable' }
        end
        local why = refusal(m, key)
        if why then return { ok = false, code = why } end
        local target, whyTarget = targetOf(src, opts or {})
        if not target then return { ok = false, code = whyTarget } end
        local at = point(target)
        if not at then return { ok = false, code = 'unavailable' } end
        local back = 0
        for _, s in ipairs(T.rebootable(m, key)) do
            if BR.ReviveKey.bringBackAt(s, at, FULL_HP) then back = back + 1 end
        end
        if back == 0 then return { ok = false, code = 'reboot_none' } end
        print(('[br_core] terminals: Reboot for %s in match %s: %d player(s) coming back over %d at (%.0f, %.0f)')
            :format(key, tostring(m.id), back, target, at.x, at.y))
        return { ok = true, code = 'done' }
    end,
}
