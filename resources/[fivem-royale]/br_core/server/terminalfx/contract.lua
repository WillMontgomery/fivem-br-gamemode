-- Season 2 terminals (#396), wave A: CONTRACT, the server half.
--
-- THE PAGE (br_lib/config/terminals.lua, `contract_*`): "The player outside
-- your squad with the most eliminations gets a bounty for 5 minutes. Their
-- position shows on every player's map while it lasts. A tie goes to the
-- player who got there first." The target is told a contract is on them.
--
--   THE TARGET   BR.Terminal.contractPick, the one rule: every player in the
--                match outside the runner's squad, still in the fight, with
--                at least one elimination; the most eliminations; a tie to
--                whoever REACHED that count first (`killsAt`, stamped by
--                server/combat.lua as each kill is credited); a tie on that
--                too -- the same millisecond -- to the lower server id.
--   NOBODY       outside the squad has an elimination: refused, spending
--                nothing (`no_target`). A contract on a player with none would
--                be a bounty on a name picked at random, which is not what
--                the page says.
--   THE BOUNTY   Scan's (BR.Terminal.startBounty), with its own clock,
--                fx.contractMs (5 min), and its own words: the owner's
--                `bounty_new` to the lobby, verbatim -- it names no length --
--                but `contract_protect` to the target's squad instead of his
--                `bounty_protect`, whose "for the next 10 minutes" is Scan's,
--                and `contract_target` to the target. The same blip 58 in his
--                colours, the same pushes, ended the same ways (elimination,
--                leaving, the match ending), hidden the same way by Ghost; a
--                bounty already on the target keeps whichever clock is longer.
--
-- After the lobby's notice, like Scan's bounty. No client half: the bounty's
-- marks are client/terminalfx.lua's and client/squadmates.lua's.

BR = BR or {}
BR.Terminal = BR.Terminal or {}

local T = BR.Terminal
local TS = BR.TerminalSolve

local function fx() return BR.Config.Terminals.fx or {} end

--- THE ONE RULE: who a Contract run by squad `key` puts the bounty on, or nil.
--- @param m table
--- @param key string  the runner's squad
--- @return integer|nil src
function T.contractPick(m, key)
    local best, bestK, bestAt = nil, 0, nil
    BR.Roster.each(function(e) return e.matchId == m.id end, function(src, e)
        local k = math.floor(tonumber(e.kills) or 0)
        if k < 1 or not T.marked(e.state) or TS.squadKey(e, src) == key then return end
        local at = tonumber(e.killsAt) or math.huge
        if best == nil or k > bestK
           or (k == bestK and (at < bestAt or (at == bestAt and src < best))) then
            best, bestK, bestAt = src, k, at
        end
    end)
    return best
end

T.FUNCTIONS.contract = {
    -- NOBODY OUTSIDE THE SQUAD WITH AN ELIMINATION IS REFUSED, SPENDING
    -- NOTHING -- and asked again when the loading is over, so a target
    -- eliminated meanwhile with nobody to take their place gives everything
    -- back.
    refuse = function(src, session)
        local m, _, key = T.whereIs(src)
        if not m then return (not session.dev) and 'unavailable' or nil end
        if T.contractPick(m, key) == nil then return 'no_target' end
        return nil
    end,
    run = function(src, session)
        local m, _, key = T.whereIs(src)
        if not m then
            if session.dev then
                print(('[br_core] brterminal (client %d): Contract ran on the dev terminal '
                    .. 'with no match to put a contract out in'):format(src))
                return { ok = true, code = 'done' }
            end
            return { ok = false, code = 'unavailable' }
        end
        local target = T.contractPick(m, key)
        if not target then return { ok = false, code = 'no_target' } end
        local now = GetGameTimer()
        local e = BR.Roster.get(target)
        print(('[br_core] terminals: Contract by %s on %s (%d), %d elimination(s)')
            :format(key, e and e.name or '?', target, e and e.kills or 0))
        -- THE BOUNTY AND ITS TOASTS AFTER "has redeemed their special power:
        -- Contract...", the order Scan's bounty keeps.
        return { ok = true, code = 'done', after = function()
            T.startBounty(m, target, now, {
                ms = tonumber(fx().contractMs) or 300000,
                protect = 'contract_protect',
                target = 'contract_target',
            })
        end }
    end,
}
