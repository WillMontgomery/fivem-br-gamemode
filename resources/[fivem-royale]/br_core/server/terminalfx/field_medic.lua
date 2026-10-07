-- Season 2 terminals (#396), wave A: FIELD MEDIC, the server half.
--
-- ROUND 4 (owner, 2026-10-06): "Field medic should heal everyone on the squad
-- to full, and their shield, and remove 20 health from everyone else in the
-- match who has at least 50 health", and "Field medic should not notify
-- everyone".
--
-- THE PAGE (br_lib/config/terminals.lua, `field_medic_*`): "Every player in
-- your squad who is still standing gets full health and full armor. Downed
-- players aren't revived. Every other player in the match who is standing with
-- at least 50 health loses 20 health." Instant. Refused, spending nothing,
-- only when nothing at all would change.
--
--   STANDING   ALIVE, and nothing else, both ways. A downed player's health is
--              a bleed countdown the server keeps, not a bar (server/roster.lua's
--              sampler leaves it alone), and the page says they are not
--              revived; a player still in the air is not standing either --
--              their bar is not sampled into the ledger until they land, so a
--              grant to them would open its window and close it again with
--              nothing to follow, and a drain would have nothing to hold.
--   FULL       the display bar's 100 and BR.Config.Match.maxArmour, through
--              BR.Inv.grantEffect: the window and the ceiling a med kit's
--              landing authorizes, and the same INV_EFFECT, so the ledger
--              follows the ped up and never snaps it back.
--   THE DRAIN  everyone standing outside the runner's squad whose health is
--              fx.medicDrainFromHp (50) or more loses fx.medicDrainHp (20),
--              through BR.Damage.drain: off the server's ledger first, the
--              sampler and the health audit told it is in flight, then the
--              ped told to follow -- never a knock (50 less 20 is 30), never
--              their armor, never credited to anyone.
--   QUIET      `quiet` on the registry row: no notice_action to the lobby
--              (BR.Terminal.finish skips it), and no `field_medic_description`
--              for one to carry. Opening the terminal with a key still tells
--              the lobby (notice_access), the owner's own rule.
--
-- No client half: INV_EFFECT is client/inventory.lua's, applied upward only,
-- and HIT_DAMAGE is client/state.lua's. Nothing is kept after the run, so
-- there is nothing to end at the match's end.

BR = BR or {}
BR.Terminal = BR.Terminal or {}

local T = BR.Terminal
local TS = BR.TerminalSolve

local function fx() return BR.Config.Terminals.fx or {} end

--- The display bar's top: health travels in display units (0..100).
local FULL_HP = 100.0

--- A bar within this of full is full: the ledger holds fractions (a partial
--- heal's 64.8125), and a player half a point short has nothing to gain.
local SLACK = 0.5

--- @return number
local function fullArmor()
    return (BR.Config.Match and BR.Config.Match.maxArmour) or 100
end

--- Everyone in this squad who is standing right now.
--- @param m table
--- @param key string
--- @return integer[]
local function standing(m, key)
    local out = {}
    for _, s in ipairs(T.squadOf(m, key)) do
        local e = BR.Roster.get(s)
        if e and e.state == BR.PlayerState.ALIVE then out[#out + 1] = s end
    end
    return out
end

--- Is this player short of full health or full armor?
--- @param e table  a roster entry
--- @return boolean
local function short(e)
    return (tonumber(e.hp) or 0) < FULL_HP - SLACK
        or (tonumber(e.armour) or 0) < fullArmor() - SLACK
end

--- Everyone standing in this match OUTSIDE squad `key` whose health is at
--- least the drain's floor: who the drain takes from. Sorted, by server id.
--- @param m table
--- @param key string
--- @return integer[]
local function drainable(m, key)
    local from = tonumber(fx().medicDrainFromHp) or 50.0
    local out = {}
    BR.Roster.each(function(e) return e.matchId == m.id end, function(src, e)
        if e.state == BR.PlayerState.ALIVE and TS.squadKey(e, src) ~= key
            and (tonumber(e.hp) or 0) >= from then
            out[#out + 1] = src
        end
    end)
    table.sort(out)
    return out
end

T.FUNCTIONS.field_medic = {
    -- NOTHING AT ALL TO CHANGE IS REFUSED, SPENDING NOTHING: every squadmate
    -- standing is already full (or none is standing) AND nobody outside the
    -- squad stands at 50 or more. Asked again when the loading is over, so a
    -- run whose last reason went away meanwhile gets everything back.
    refuse = function(src, session)
        local m, _, key = T.whereIs(src)
        if not m then return (not session.dev) and 'unavailable' or nil end
        for _, s in ipairs(standing(m, key)) do
            if short(BR.Roster.get(s)) then return nil end
        end
        if #drainable(m, key) > 0 then return nil end
        return 'health_full'
    end,
    -- FULL HEALTH AND FULL ARMOR, for everyone standing in the squad who is
    -- short of either; then the drain on everyone else at 50 or more.
    run = function(src, session)
        local m, _, key = T.whereIs(src)
        if not m then
            if session.dev then
                print(('[br_core] brterminal (client %d): Field medic ran on the dev terminal '
                    .. 'with no squad to heal'):format(src))
                return { ok = true, code = 'done' }
            end
            return { ok = false, code = 'unavailable' }
        end
        local armor = fullArmor()
        local healed = 0
        for _, s in ipairs(standing(m, key)) do
            local e = BR.Roster.get(s)
            if e and short(e) and BR.Inv.grantEffect(s, {
                health = FULL_HP, healthCap = FULL_HP,
                armour = armor, armourCap = armor,
            }) then
                healed = healed + 1
            end
        end
        local amount = tonumber(fx().medicDrainHp) or 20.0
        local drained = 0
        for _, s in ipairs(drainable(m, key)) do
            if BR.Damage.drain(s, amount) > 0 then drained = drained + 1 end
        end
        if healed == 0 and drained == 0 then return { ok = false, code = 'health_full' } end
        print(('[br_core] terminals: Field medic for %s: %d player(s) to full health and armor, '
            .. '%d other player(s) drained %.0f'):format(key, healed, drained, amount))
        return { ok = true, code = 'done' }
    end,
}
