-- What a match knows about a player, held in memory until somebody needs it.
--
-- WHY THIS EXISTS. An incident is only as good as the evidence attached to it,
-- and the evidence is gone by the time anybody asks. Chat scrolls, the kill feed
-- is a client broadcast nothing persists, and a player who has caused trouble
-- tends to leave immediately afterwards -- which used to take their roster entry,
-- their name and their license with them.
--
-- So the match keeps a small, bounded record per player and throws it away when
-- the match ends. Nothing is written to a database speculatively: an incident is
-- what turns a buffer into a record (owner call, 2026-08-14), and the
-- overwhelming majority of matches produce none and therefore cost nothing.
--
-- PURE, AND `now` IS ALWAYS A PARAMETER. Same split as combat_solve and outbox:
-- the wiring -- which event fires, which native reports the time -- cannot be
-- exercised outside the game, but the bookkeeping can, and bookkeeping is where
-- the bugs that matter live. A buffer that silently stops appending, or one that
-- loses a departed player, fails a review weeks later rather than at load.
--
-- SEALED, NOT DELETED. The single most important decision in this file. When a
-- player disconnects their record moves aside rather than being freed, because:
--
--   * they are still reportable for the rest of the match -- "caused hell then
--     left" is the case players most want to report and the one a live-roster
--     lookup cannot serve;
--   * an incident filed against them still needs their chat and their kills;
--   * and server ids are RECYCLED WITHIN THE MINUTE. A record left under `src`
--     would quietly start collecting the next player's chat, and an incident
--     built from it would be a record about the wrong person.

BR = BR or {}

BR.EvidenceBuf = {}
BR.EvidenceBuf.__index = BR.EvidenceBuf

--- Caps. Bounded because 100 players times an unbounded chat log is a memory
--- leak with a nice name, and because the last fifty lines are the ones that
--- explain an incident -- the first fifty are the bus ride.
local DEFAULTS = {
    chatMax = 50,
    killMax = 30,
}

--- @param opts table|nil { chatMax, killMax }
--- @return table
function BR.EvidenceBuf.new(opts)
    opts = opts or {}
    local o = setmetatable({}, BR.EvidenceBuf)
    o.chatMax = opts.chatMax or DEFAULTS.chatMax
    o.killMax = opts.killMax or DEFAULTS.killMax

    -- [key] = record, for players still connected. `key` is the caller's --
    -- in the game it is `src`, and this file neither knows nor cares.
    o.live = {}
    -- An ARRAY, not a map keyed on license. A player who disconnects and
    -- reconnects inside one match produces two distinct sessions, and collapsing
    -- them would silently merge two sets of evidence under one heading. It also
    -- keeps a licenseless connection representable rather than unstorable.
    o.sealed = {}
    return o
end

--- The empty record. Written here so its shape is documented in one place.
local function newRecord(key, meta)
    return {
        key      = key,
        license  = meta and meta.license or nil,
        name     = meta and meta.name or nil,
        matchId  = meta and meta.matchId or nil,
        squadId  = meta and meta.squadId or nil,
        openedAt = meta and meta.now or nil,
        leftAt   = nil,
        chat     = {},
        kills    = {},
    }
end

--- Append to a bounded list, dropping the OLDEST when full.
---
--- Oldest-first, matching the outbox, and for the same reason: when a buffer is
--- full the recent rows are the ones describing what is happening now.
local function push(list, row, cap)
    list[#list + 1] = row
    if #list > cap then table.remove(list, 1) end
end

--- Start tracking a player, or refresh what we know about them.
---
--- IDEMPOTENT AND CALLED OFTEN, on purpose. `license` is filled lazily by the
--- roster (it is nil until br_stats or the ringmaster projection resolves it),
--- and `squadId` changes when squads form. Rather than racing those, every note
--- carries the current metadata and the record keeps the best answer it has
--- seen -- so a buffer that started before the license was known still ends up
--- with one.
--- @param key any
--- @param meta table|nil { license, name, matchId, squadId, now }
--- @return table the record
function BR.EvidenceBuf:track(key, meta)
    local r = self.live[key]
    if not r then
        r = newRecord(key, meta)
        self.live[key] = r
        return r
    end
    if meta then
        -- Never overwrite a known value with nil: the lazy fields would flicker
        -- back to unknown on the next note that happens not to carry them.
        if meta.license ~= nil then r.license = meta.license end
        if meta.name    ~= nil then r.name    = meta.name    end
        if meta.matchId ~= nil then r.matchId = meta.matchId end
        if meta.squadId ~= nil then r.squadId = meta.squadId end
        if r.openedAt == nil then r.openedAt = meta.now end
    end
    return r
end

--- Record one chat line against its sender.
--- @param key any
--- @param row table  { text, channel, at }
--- @param meta table|nil
function BR.EvidenceBuf:noteChat(key, row, meta)
    local r = self:track(key, meta)
    push(r.chat, row, self.chatMax)
end

--- Record one kill against a participant.
---
--- Called for BOTH sides of a kill. A player's own deaths are context a reviewer
--- needs as much as their kills: "reported for teaming" reads very differently
--- when the record shows they died to the person they are accused of helping.
--- @param key any
--- @param row table  { killer, victim, cause, weapon, headshot, at }
--- @param meta table|nil
function BR.EvidenceBuf:noteKill(key, row, meta)
    local r = self:track(key, meta)
    push(r.kills, row, self.killMax)
end

--- Move a player's record aside, keeping it readable for the rest of the match.
--- @param key any
--- @param now number
--- @return table|nil the sealed record, or nil if there was nothing to seal
function BR.EvidenceBuf:seal(key, now)
    local r = self.live[key]
    if not r then return nil end
    self.live[key] = nil
    r.leftAt = now
    self.sealed[#self.sealed + 1] = r
    return r
end

--- Every record for one license, live or sealed, newest session last.
---
--- Returns a LIST because a reconnect inside one match is two sessions. A caller
--- filing an incident wants all of them: the evidence does not stop counting
--- because somebody bounced their client.
--- @param license string
--- @return table[]
function BR.EvidenceBuf:forLicense(license)
    local out = {}
    if license == nil then return out end
    for _, r in pairs(self.live) do
        if r.license == license then out[#out + 1] = r end
    end
    for _, r in ipairs(self.sealed) do
        if r.license == license then out[#out + 1] = r end
    end
    return out
end

--- One record by key, live only. The hot path for a note.
function BR.EvidenceBuf:get(key)
    return self.live[key]
end

--- Players this match has a record for who are no longer connected.
---
--- This is what makes a departed player reportable: the report list is built
--- from the live roster PLUS this, so somebody who left ten seconds ago is still
--- on screen with a license attached.
--- @param matchId any|nil  restrict to one match, or nil for all
--- @return table[]
function BR.EvidenceBuf:departed(matchId)
    local out = {}
    for _, r in ipairs(self.sealed) do
        if matchId == nil or r.matchId == matchId then out[#out + 1] = r end
    end
    return out
end

--- Forget everything about one match.
---
--- Called when the match ends. THE DISCARD IS THE COST CONTROL: a match that
--- produced no incident wrote nothing and now costs nothing, which is the
--- overwhelmingly common case and the reason this is a buffer rather than a
--- table.
--- @param matchId any|nil  nil forgets everything, for a resource restart
--- @return integer how many records were dropped
function BR.EvidenceBuf:clearMatch(matchId)
    local n = 0
    for key, r in pairs(self.live) do
        if matchId == nil or r.matchId == matchId then
            self.live[key] = nil
            n = n + 1
        end
    end
    local keep = {}
    for _, r in ipairs(self.sealed) do
        if matchId == nil or r.matchId == matchId then
            n = n + 1
        else
            keep[#keep + 1] = r
        end
    end
    self.sealed = keep
    return n
end

--- Counters, for `brring`-style introspection and for the tests.
function BR.EvidenceBuf:stats()
    local liveN, chat, kills = 0, 0, 0
    for _, r in pairs(self.live) do
        liveN = liveN + 1
        chat  = chat + #r.chat
        kills = kills + #r.kills
    end
    for _, r in ipairs(self.sealed) do
        chat  = chat + #r.chat
        kills = kills + #r.kills
    end
    return {
        live = liveN, sealed = #self.sealed,
        chatRows = chat, killRows = kills,
    }
end
