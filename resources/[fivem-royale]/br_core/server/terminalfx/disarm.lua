-- Season 2 terminals (#396), wave A: DISARM, the server half.
--
-- THE PAGE (br_lib/config/terminals.lua, `disarm_*`; the owner's "take away
-- everyone's most powerful weapon", 2026-10-04, and ROUND 4, 2026-10-06: "The
-- disarm tool should not apply to the user or their squad"): "Every player
-- still in the match outside your squad loses the most powerful weapon they
-- carry. Your squad keeps its weapons. Most powerful means the highest rarity,
-- then the most damage. The weapons are gone. They aren't dropped." Instant;
-- 200 Volts (the registry row's `cost`). Refused, spending nothing, when
-- nobody outside the runner's squad carries a weapon.
--
--   STILL IN THE MATCH   still in the fight (BR.Server.isInMatch, the panel's
--                        and the HUD's count): standing, downed, in the air.
--   NOT THE SQUAD        the runner and everyone in their squad
--                        (BR.TerminalSolve.squadKey, the key the squad's one
--                        use is spent under) keep every weapon they carry. A
--                        solo player is a squad of one: only they are spared.
--   A WEAPON             a slot of kind `weapon`: every gun and every melee
--                        weapon. Throwables are their own kind and are not.
--   THE MOST POWERFUL    the stack's rarity, then its weapon row's damage; a tie
--                        on both goes to the lower slot (BR.Terminal.disarmPick,
--                        the one ranking -- tools/test_terminalfx.lua holds it).
--   GONE                 BR.Inv.revoke: the slot emptied through the
--                        inventory's own API (never a client native), one
--                        INV_SET, and the weapon remembered for fx.disarmGraceMs
--                        so the hits of the round trip before the INV_SET
--                        lands (a launcher's round still in the air among
--                        them, whatever they are refused for) and the strip
--                        report accuse nobody.
--
-- No client half: the INV_SET is client/inventory.lua's, which takes the gun
-- out of the hand. Nothing is kept after the run.

BR = BR or {}
BR.Terminal = BR.Terminal or {}

local T = BR.Terminal
local TS = BR.TerminalSolve

local function fx() return BR.Config.Terminals.fx or {} end

--- A stack's place in the ranking, or nil for anything that is not a weapon.
--- @param s any  an inventory slot
--- @return number|nil rarity, number|nil damage
local function rankOf(s)
    if type(s) ~= 'table' or s.kind ~= BR.ItemKind.WEAPON then return nil, nil end
    local w = BR.Config.WeaponById and BR.Config.WeaponById[s.item] or nil
    if not w then return nil, nil end
    return tonumber(s.rarity) or tonumber(w.rarity) or 0, tonumber(w.damage) or 0
end

--- THE ONE RANKING: the slot holding the most powerful weapon in `slots` --
--- the highest rarity, then the most damage, then the lowest slot -- or nil
--- when there is no weapon in them.
--- @param slots table  [slot] = stack | false
--- @return integer|nil
function T.disarmPick(slots)
    local order = {}
    for i in pairs(type(slots) == 'table' and slots or {}) do
        if math.type(i) == 'integer' then order[#order + 1] = i end
    end
    table.sort(order)
    local best, bestR, bestD = nil, nil, nil
    for _, i in ipairs(order) do
        local r, d = rankOf(slots[i])
        if r ~= nil and (best == nil or r > bestR or (r == bestR and d > bestD)) then
            best, bestR, bestD = i, r, d
        end
    end
    return best
end

--- Still in the fight, by the one answer the panel and the HUD use.
--- @param state string|nil
--- @return boolean
local function inFight(state)
    if BR.Server and BR.Server.isInMatch then return BR.Server.isInMatch(state) == true end
    return T.marked(state)
end

--- Everyone in this match still in the fight OUTSIDE squad `key`, with the
--- slot Disarm takes from each who carries a weapon.
--- @param m table
--- @param key string  the runner's squad, spared
--- @return table[] { { src, slot } }
local function targets(m, key)
    local out = {}
    BR.Roster.each(function(e) return e.matchId == m.id end, function(src, e)
        if inFight(e.state) and TS.squadKey(e, src) ~= key then
            local inv = BR.Inv.of(src)
            local slot = inv and T.disarmPick(inv.slots) or nil
            if slot then out[#out + 1] = { src = src, slot = slot } end
        end
    end)
    return out
end

T.FUNCTIONS.disarm = {
    -- NOBODY ARMED OUTSIDE THE SQUAD IS REFUSED, SPENDING NOTHING -- the 200
    -- Volts included, since the door asks this before the price. Asked again
    -- when the loading is over, so a match that dropped its last weapon
    -- meanwhile is refunded.
    refuse = function(src, session)
        local m, _, key = T.whereIs(src)
        if not m then return (not session.dev) and 'unavailable' or nil end
        if #targets(m, key) == 0 then return 'no_weapons' end
        return nil
    end,
    -- EVERY PLAYER STILL IN THE MATCH OUTSIDE THE RUNNER'S SQUAD LOSES THEIR
    -- MOST POWERFUL WEAPON.
    run = function(src, session)
        local m, _, key = T.whereIs(src)
        if not m then
            if session.dev then
                print(('[br_core] brterminal (client %d): Disarm ran on the dev terminal '
                    .. 'with no match to disarm'):format(src))
                return { ok = true, code = 'done' }
            end
            return { ok = false, code = 'unavailable' }
        end
        local grace = tonumber(fx().disarmGraceMs) or 10000
        local taken = {}
        for _, t in ipairs(targets(m, key)) do
            local stack = BR.Inv.revoke(t.src, t.slot, grace)
            if stack then taken[#taken + 1] = ('%d:%s'):format(t.src, tostring(stack.item)) end
        end
        if #taken == 0 then return { ok = false, code = 'no_weapons' } end
        print(('[br_core] terminals: Disarm by %s in match %s took %d weapon(s): %s')
            :format(tostring(key), tostring(m.id), #taken, table.concat(taken, ' ')))
        return { ok = true, code = 'done' }
    end,
}
