-- Season 2 terminals (#396), wave A: FIELD MEDIC, the server half.
--
-- THE PAGE (br_lib/config/terminals.lua, `field_medic_*`): "Every player in
-- your squad who is still standing gets full health and full armor. Downed
-- players aren't revived." Instant. Refused, spending nothing, when everyone
-- standing is already full.
--
--   STANDING   ALIVE, and nothing else. A downed squadmate's health is a bleed
--              countdown the server keeps, not a bar (server/roster.lua's
--              sampler leaves it alone), and the page says they are not
--              revived; a squadmate still in the air is not standing either --
--              their bar is not sampled into the ledger until they land, so a
--              grant to them would open its window and close it again with
--              nothing to follow.
--   FULL       the display bar's 100 and BR.Config.Match.maxArmour, through
--              BR.Inv.grantEffect: the window and the ceiling a med kit's
--              landing authorizes, and the same INV_EFFECT, so the ledger
--              follows the ped up and never snaps it back.
--
-- No client half: INV_EFFECT is client/inventory.lua's, applied upward only.
-- Nothing is kept after the run, so there is nothing to end at the match's end.

BR = BR or {}
BR.Terminal = BR.Terminal or {}

local T = BR.Terminal

--- The display bar's top: health travels in display units (0..100).
local FULL_HP = 100.0

--- A bar within this of full is full: the ledger holds fractions (a partial
--- heal's 64.8125), and a player half a point short has nothing to gain.
local SLACK = 0.5

--- @return number
local function fullArmour()
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
        or (tonumber(e.armour) or 0) < fullArmour() - SLACK
end

T.FUNCTIONS.field_medic = {
    -- NOTHING TO HEAL IS REFUSED, SPENDING NOTHING: every squadmate standing is
    -- already full (or none is standing). Asked again when the loading is
    -- over, so a squad that healed itself meanwhile gets everything back.
    refuse = function(src, session)
        local m, _, key = T.whereIs(src)
        if not m then return (not session.dev) and 'unavailable' or nil end
        for _, s in ipairs(standing(m, key)) do
            if short(BR.Roster.get(s)) then return nil end
        end
        return 'health_full'
    end,
    -- FULL HEALTH AND FULL ARMOR, for everyone standing who is short of either.
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
        local armour = fullArmour()
        local healed = 0
        for _, s in ipairs(standing(m, key)) do
            local e = BR.Roster.get(s)
            if e and short(e) and BR.Inv.grantEffect(s, {
                health = FULL_HP, healthCap = FULL_HP,
                armour = armour, armourCap = armour,
            }) then
                healed = healed + 1
            end
        end
        if healed == 0 then return { ok = false, code = 'health_full' } end
        print(('[br_core] terminals: Field medic for %s: %d player(s) to full health and armor')
            :format(key, healed))
        return { ok = true, code = 'done' }
    end,
}
