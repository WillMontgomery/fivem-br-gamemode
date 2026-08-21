-- WHO A SPECTATOR MAY LOOK AT.
--
-- PURE, AND IN br_lib, FOR THE SAME REASON BR.FocusResolve IS (protocol.lua):
-- this is the decision that must never be got wrong, so it is the decision that
-- has to be testable outside the game. Nothing here reads a native, a clock or a
-- roster; it is handed a view and returns an ordered list.
--
-- ═══ THE RULE THIS FILE EXISTS FOR ═══
--
-- A DEAD PLAYER WITH A WORKING VOICE CHANNEL IS AN INFORMATION LEAK. Spectating
-- an enemy while squadmates are still alive is a wallhack with extra steps: the
-- dead player reads out positions and the squad plays on with a spotter. Every
-- shipped battle royale answers it the same way and so does this one --
--
--   * while any squadmate is still in the fight, the target set is YOUR OWN
--     SQUAD and nothing else;
--   * only once the squad is gone may it widen.
--
-- IT IS THE STRUCTURE OF playerTargets(), NOT A CHECK INSIDE IT, and that is
-- deliberate (#192: "a check bolted on later is a check somebody removes"). The
-- squad list is built first; the wider list is only ever reached because the
-- squad list came back EMPTY. There is no argument, no flag and no branch that
-- can widen the set while a squadmate lives, because the widening is the else of
-- "my squad is gone" and cannot be reached any other way.
--
-- IN SOLOS IT IS MOOT and falls out for free rather than needing a mode check: a
-- solo player has no squadId, so their squad list is empty on the first pass and
-- the wider branch is where they start. #192: "there is no squad and no one to
-- tell".
--
-- ═══ TWO POLICIES, ONE CAMERA ═══
--
-- Player spectate and admin spectate differ in WHO MAY BE TARGETED and in
-- nothing else -- the camera is one camera (br_core/client/spectate.lua). So the
-- two policies are two functions here, side by side, rather than one function
-- with a privilege argument. An admin watches one named person and does not
-- cycle; a player cycles a set they are entitled to see.

BR = BR or {}
BR.SpectateSolve = {}

--- Order a candidate list so every caller agrees on "next".
---
--- BY SERVER ID, because it is the only key present on every row and it does not
--- move while a player is connected. Sorting by name would re-order the wheel
--- under a rename, and sorting by nothing at all would make `next` a different
--- player on every push -- Lua's pairs() has no defined order, and this list is
--- built by walking a roster table.
local function bySrc(list)
    table.sort(list, function(a, b) return a.src < b.src end)
    return list
end

--- Who this player may spectate.
---
--- @param view table
---   mySrc    integer   the spectator
---   squadId  any|nil   their squad, or nil for a solo
---   free     boolean   may the set widen once the squad is gone?
---   players  table     array of { src, squadId, living, name }, THIS MATCH ONLY
---                      -- `living` is the caller's answer to "still in the
---                      fight" (server: BR.Server.isInMatch), so there is one
---                      definition of that and this file does not own a second.
--- @return table candidates  ordered, possibly empty
--- @return string policy     'squad' | 'free' | 'none' -- for logs and tests
function BR.SpectateSolve.playerTargets(view)
    view = view or {}
    local players = view.players or {}
    local me = view.mySrc

    -- MY SQUAD, LIVING, MINUS ME. Built first and unconditionally.
    local squad = {}
    if view.squadId ~= nil then
        for _, p in ipairs(players) do
            if p.src ~= me and p.living and p.squadId == view.squadId then
                squad[#squad + 1] = p
            end
        end
    end

    -- AND IF THERE IS ANYONE ON IT, THAT IS THE ANSWER. No flag reaches past
    -- this return. `free` is not consulted, `players` is not walked again, and
    -- an admin scope would not help -- a player spectator cannot leave their
    -- squad while one of them is standing.
    if #squad > 0 then
        return bySrc(squad), 'squad'
    end

    -- The squad is gone (or there never was one). Widening is a product
    -- decision and #192 leaves it open -- "refusing it costs little" -- so it is
    -- a config value read by the caller and passed in, not a constant here.
    if not view.free then
        return {}, 'none'
    end

    local rest = {}
    for _, p in ipairs(players) do
        if p.src ~= me and p.living then
            rest[#rest + 1] = p
        end
    end
    return bySrc(rest), #rest > 0 and 'free' or 'none'
end

--- Who this ADMIN may spectate: the one person they named, if they are here.
---
--- NO LIVENESS TEST AND NO SQUAD TEST, and both absences are the feature. A
--- moderator watching a suspected cheater is watching whoever they typed --
--- alive, downed, dead or sitting in the lobby -- and the squad rule protects
--- players from each other, not players from moderation. What it DOES test is
--- presence, because a target who is not on the list is not on this server, and
--- pointing a camera at a server id nobody is holding is the recycled-id bug
--- this project has already been bitten by.
---
--- @param view table
---   want     integer   the target's server id
---   players  table     array of { src, ... } -- EVERY connected player
--- @return table candidates  zero or one row
--- @return string policy     'admin' | 'none'
function BR.SpectateSolve.adminTargets(view)
    view = view or {}
    for _, p in ipairs(view.players or {}) do
        if p.src == view.want then
            return { p }, 'admin'
        end
    end
    return {}, 'none'
end

--- Walk a candidate list.
---
--- @param list table      from playerTargets / adminTargets
--- @param current any|nil the src being watched now
--- @param dir number      +1 next, -1 previous, 0 "hold what I have"
--- @return table|nil the row to watch
function BR.SpectateSolve.step(list, current, dir)
    local n = list and #list or 0
    if n == 0 then return nil end

    local at = nil
    for i = 1, n do
        if list[i].src == current then
            at = i
            break
        end
    end

    -- NOT ON THE LIST ANY MORE -- the target died, left, or was never eligible.
    -- Land on an end of the list rather than nowhere: this is the path a
    -- re-resolve takes every time a target is lost, and returning nil here would
    -- turn "your target died" into "spectating is over".
    if not at then
        return (dir or 0) < 0 and list[n] or list[1]
    end

    -- 0 IS HOLD, and it has to be an explicit case rather than falling out of
    -- the arithmetic. In Lua `0` is TRUTHY and `(at - 1 + 0) % n + 1 == at`
    -- would happen to be right today -- but the caller's intent is "do not
    -- move", and writing it as a modulo that coincidentally does not move is
    -- the kind of thing a later edit breaks silently.
    dir = tonumber(dir) or 0
    if dir == 0 then return list[at] end

    return list[(at - 1 + (dir > 0 and 1 or -1)) % n + 1]
end
