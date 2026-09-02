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
--- `stripMax` IS THE SMALLEST OF THE THREE ON PURPOSE. A strip row is a
--- timestamp and a hash -- it says "it happened again" and nothing else -- so
--- the tenth one in a row carries almost no information the second did not, and
--- the thing they are all evidence of is a PATTERN rather than a list. Twenty is
--- already several times more than the vMenu behaviour this exists to catch
--- produces, and the count that was really seen is kept whatever the cap drops.
local DEFAULTS = {
    chatMax = 50,
    killMax = 30,
    stripMax = 20,
    -- Chat lines the server refused to deliver. A LIST OF ITS OWN RATHER THAN A
    -- FLAG ON THE CHAT ROWS ABOVE, and the separation is the point: `chat` is a
    -- drop-oldest window fifty lines deep, so a player who keeps talking after a
    -- refused line pushes it out of the buffer -- with their own evidence. The
    -- offender chooses that volume, which makes it exactly the wrong place to
    -- store the finding. Sized like `stripMax` because it is the same kind of
    -- fact: a small number of them says everything a large number would.
    refusedMax = 20,
}

--- What a promoted record may hold. See `promote`.
---
--- CHOSEN AGAINST THE ITEM, NOT AGAINST MEMORY. 250 kill rows is roughly 50KB
--- once marshalled onto the incident row, against DynamoDB's 400KB ceiling and
--- alongside the evidence log that is already there. It is far more than a real
--- match produces -- a dominant player in a twenty-minute round lands tens, not
--- hundreds -- so in practice this cap is never the thing that truncates.
local PROMOTED = {
    chatMax = 150,
    killMax = 250,
    -- SIXTY, AND IT IS THE NUMBER THE TIMELINE CAP IS SET FROM rather than a
    -- second opinion about it -- see MAX_TIMELINE_STRIPS in incident_build.lua,
    -- which is this value. A minute of recursive re-granting at the client's own
    -- one-a-second report rate fits inside it; anything past that is truncated
    -- and SAYS it was truncated, which is the honest end of the trade.
    stripMax = 60,
    -- SIXTY, FOR THE SAME REASON AND AGAINST THE SAME NUMBER -- see
    -- MAX_TIMELINE_CHAT in incident_build.lua, which is this value. Chat is rate
    -- limited to eight messages per ten seconds before the server starts
    -- dropping them (BR.ChatLimits), so sixty refused lines is more than seventy
    -- seconds of a player typing nothing but adverts.
    refusedMax = 60,
}

--- @param opts table|nil { chatMax, killMax }
--- @return table
function BR.EvidenceBuf.new(opts)
    opts = opts or {}
    local o = setmetatable({}, BR.EvidenceBuf)
    o.chatMax = opts.chatMax or DEFAULTS.chatMax
    o.killMax = opts.killMax or DEFAULTS.killMax
    o.stripMax = opts.stripMax or DEFAULTS.stripMax
    o.refusedMax = opts.refusedMax or DEFAULTS.refusedMax

    -- Licences whose records are kept larger, because a case has been opened
    -- about them. See `promote` -- this is what makes the promotion apply to
    -- records that do not exist yet.
    o.promoted = {}

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
---
--- `killsSeen`/`chatSeen` COUNT WHAT WAS OFFERED, NOT WHAT WAS KEPT, and they
--- are never decremented. The lists above them drop their oldest row when full,
--- which is the right trade for an evidence snippet and a silent lie for a
--- timeline: a reviewer reading "these are the kills" needs to know when it is
--- really "these are the last thirty". The difference between these counters and
--- `#kills` is exactly what was lost, and it is the only way to know.
---
--- `killMax`/`chatMax` ARE PER-RECORD OVERRIDES and are normally nil, meaning
--- "use the buffer's default". `promote` sets them for the handful of players
--- who have drawn a case. See `promote` for why the cost is shaped that way.
local function newRecord(key, meta)
    return {
        key       = key,
        license   = meta and meta.license or nil,
        name      = meta and meta.name or nil,
        matchId   = meta and meta.matchId or nil,
        squadId   = meta and meta.squadId or nil,
        openedAt  = meta and meta.now or nil,
        leftAt    = nil,
        chat      = {},
        kills     = {},
        -- Weapons this gamemode never issued, taken out of this player's hand
        -- by client/inventory.lua. `stripsSeen` counts what the server accepted,
        -- which is not the same as what the client observed -- see the throttles
        -- at both ends -- so the gap between it and `#strips` is what the CAPS
        -- dropped and nothing more.
        strips    = {},
        -- Chat lines this server accepted from the player and then delivered to
        -- nobody but them. `refusedSeen` counts what the screen refused, which
        -- is not the same as what this list kept -- the gap is what the cap
        -- dropped, exactly as it is for the three above.
        refused   = {},
        chatSeen  = 0,
        killsSeen = 0,
        stripsSeen = 0,
        refusedSeen = 0,
        chatMax   = nil,
        killMax   = nil,
        stripMax  = nil,
        refusedMax = nil,
    }
end

--- Append to a bounded list, dropping the OLDEST when full.
---
--- Oldest-first, matching the outbox, and for the same reason: when a buffer is
--- full the recent rows are the ones describing what is happening now.
local function push(list, row, cap)
    list[#list + 1] = row
    while #list > cap do table.remove(list, 1) end
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
        self:applyPromotion(r)
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
    -- ON EVERY TRACK, NOT ONLY ON CREATION, BECAUSE `license` IS LAZY. A record
    -- can exist for several notes before the roster resolves who it belongs to,
    -- and a promotion registered in that window would otherwise never reach it.
    self:applyPromotion(r)
    return r
end

--- Give one record the caps its licence has been promoted to, if any.
function BR.EvidenceBuf:applyPromotion(r)
    if r.license == nil then return end
    local caps = self.promoted[r.license]
    if not caps then return end

    -- NEVER DOWNWARD. Two cases about one player must not let the second shrink
    -- what the first is holding.
    if caps.chatMax and caps.chatMax > (r.chatMax or self.chatMax) then
        r.chatMax = caps.chatMax
    end
    if caps.killMax and caps.killMax > (r.killMax or self.killMax) then
        r.killMax = caps.killMax
    end
    if caps.stripMax and caps.stripMax > (r.stripMax or self.stripMax) then
        r.stripMax = caps.stripMax
    end
    if caps.refusedMax and caps.refusedMax > (r.refusedMax or self.refusedMax) then
        r.refusedMax = caps.refusedMax
    end
end

--- Record one chat line against its sender.
--- @param key any
--- @param row table  { text, channel, at }
--- @param meta table|nil
function BR.EvidenceBuf:noteChat(key, row, meta)
    local r = self:track(key, meta)
    r.chatSeen = r.chatSeen + 1
    push(r.chat, row, r.chatMax or self.chatMax)
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
    r.killsSeen = r.killsSeen + 1
    push(r.kills, row, r.killMax or self.killMax)
end

--- Record that a weapon this gamemode does not issue was taken out of a hand.
---
--- ONE SIDE ONLY, unlike a kill. A kill has two participants and both of their
--- records want it; a strip is a fact about one player's own ped and there is
--- nobody else it is evidence about.
---
--- OVERFLOW DROPS THE OLDEST, like everything else here -- and for strips that
--- costs less than it does anywhere else in this file, because the earliest ones
--- are the entries that rode the incident's own PutItem at filing time and are
--- already durable in DynamoDB. What this buffer is holding is the tail.
--- @param key any
--- @param row table  { at, weapon }
--- @param meta table|nil
function BR.EvidenceBuf:noteStrip(key, row, meta)
    local r = self:track(key, meta)
    r.stripsSeen = r.stripsSeen + 1
    push(r.strips, row, r.stripMax or self.stripMax)
end

--- Record one chat line the server refused to deliver.
---
--- ONE SIDE ONLY, like a strip and unlike a kill: a refused line is a fact about
--- what one player tried to say and there is nobody else it is evidence about --
--- least of all the people it was never delivered to.
---
--- SEPARATE FROM `noteChat` RATHER THAN A FLAG ON IT, and the caller raises
--- BOTH for a refused line. `chat` stays the complete record of what this player
--- said this match, holes in which would be their own kind of lie; `refused` is
--- the short list a reviewer is actually reading, kept where the player's own
--- chat volume cannot evict it. See DEFAULTS.refusedMax.
--- @param key any
--- @param row table  { at, text, channel, reason }
--- @param meta table|nil
function BR.EvidenceBuf:noteRefusedChat(key, row, meta)
    local r = self:track(key, meta)
    r.refusedSeen = (r.refusedSeen or 0) + 1
    r.refused = r.refused or {}
    push(r.refused, row, r.refusedMax or self.refusedMax)
end

--- Keep more about this player, because a case has been opened about them.
---
--- WHY THIS EXISTS AT ALL. The default caps are sized for the evidence SNIPPET
--- an incident carries -- the last thirty kills explain a refusal perfectly well.
--- #30 asks for something else: EVERY kill by the offender across the whole
--- match, which at thirty rows would quietly become "the last thirty" for exactly
--- the prolific cheater the timeline exists to document.
---
--- RAISED FOR ONE LICENSE, NOT FOR EVERYONE, and that is the whole point. The
--- caps exist because a hundred players times an unbounded log is a memory leak;
--- raising them globally to serve the rare offender would pay that cost on every
--- player in every match, including the overwhelming majority of matches that
--- produce no incident at all. Promoting on FILING keeps the cost proportional to
--- incidents, which is the same rule the buffer itself is built on -- nothing is
--- spent speculatively.
---
--- RETROSPECTIVE ONLY AS FAR AS THE BUFFER STILL REACHES. Rows already dropped
--- before the promotion are gone; `killsSeen` is what says so. In practice the
--- case is filed early -- the anticheat fires on a doubling, a report comes in
--- mid-match -- so the promotion is in place for most of the round.
---
--- IT REGISTERS THE LICENCE, IT DOES NOT ONLY WALK THE RECORDS THAT EXIST NOW,
--- and that distinction is the difference between this working and this doing
--- nothing at all. The realistic case is a case filed EARLY -- the anticheat
--- trips on a player who has not killed anybody yet -- so at the moment of
--- promotion there is frequently no record to promote, and every record created
--- afterwards would be born with the default cap. Registering the licence makes
--- `track` apply the caps to records that appear later, including the one this
--- player gets when they reconnect mid-match.
---
--- @param license string
--- @param caps table|nil  { chatMax, killMax }; defaults to PROMOTED
--- @return integer  how many EXISTING records were promoted
function BR.EvidenceBuf:promote(license, caps)
    if license == nil then return 0 end
    caps = caps or PROMOTED

    local held = self.promoted[license]
    if held then
        -- Never downward, for the same reason `applyPromotion` is not.
        self.promoted[license] = {
            chatMax = math.max(held.chatMax or 0, caps.chatMax or 0),
            killMax = math.max(held.killMax or 0, caps.killMax or 0),
            stripMax = math.max(held.stripMax or 0, caps.stripMax or 0),
            refusedMax = math.max(held.refusedMax or 0, caps.refusedMax or 0),
        }
    else
        self.promoted[license] = {
            chatMax = caps.chatMax,
            killMax = caps.killMax,
            stripMax = caps.stripMax,
            refusedMax = caps.refusedMax,
        }
    end

    local n = 0
    for _, r in ipairs(self:forLicense(license)) do
        self:applyPromotion(r)
        n = n + 1
    end
    return n
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
    -- Whose records went, so their promotion can go with them.
    local touched = {}

    for key, r in pairs(self.live) do
        if matchId == nil or r.matchId == matchId then
            if r.license ~= nil then touched[r.license] = true end
            self.live[key] = nil
            n = n + 1
        end
    end
    local keep = {}
    for _, r in ipairs(self.sealed) do
        if matchId == nil or r.matchId == matchId then
            if r.license ~= nil then touched[r.license] = true end
            n = n + 1
        else
            keep[#keep + 1] = r
        end
    end
    self.sealed = keep

    -- THE PROMOTION DIES WITH THE MATCH IT WAS BOUGHT FOR. A player who drew a
    -- case last round must not go on costing a 250-row buffer in every round
    -- afterwards -- the whole reason the caps are raised per incident rather
    -- than globally is that the cost stays tied to a case. Only dropped once the
    -- licence has no records left at all, so clearing one match does not
    -- un-promote a player who is somehow live in another.
    for license in pairs(touched) do
        if #self:forLicense(license) == 0 then
            self.promoted[license] = nil
        end
    end
    if matchId == nil then self.promoted = {} end

    return n
end

--- Counters, for `brring`-style introspection and for the tests.
---
--- `killsDropped` IS THE ONE WORTH READING. It is the gap between what the match
--- offered and what the caps kept, summed across every record -- so a non-zero
--- value on a server whose incidents are meant to carry complete kill timelines
--- says the caps are too small for the way this server actually plays.
function BR.EvidenceBuf:stats()
    local liveN, chat, kills, chatSeen, killsSeen = 0, 0, 0, 0, 0
    local strips, stripsSeen = 0, 0
    local refused, refusedSeen = 0, 0
    local function count(r)
        chat      = chat + #r.chat
        kills     = kills + #r.kills
        chatSeen  = chatSeen + (r.chatSeen or 0)
        killsSeen = killsSeen + (r.killsSeen or 0)
        strips     = strips + #(r.strips or {})
        stripsSeen = stripsSeen + (r.stripsSeen or 0)
        refused     = refused + #(r.refused or {})
        refusedSeen = refusedSeen + (r.refusedSeen or 0)
    end
    for _, r in pairs(self.live) do
        liveN = liveN + 1
        count(r)
    end
    for _, r in ipairs(self.sealed) do count(r) end
    return {
        live = liveN, sealed = #self.sealed,
        chatRows = chat, killRows = kills,
        chatSeen = chatSeen, killsSeen = killsSeen,
        chatDropped  = chatSeen - chat,
        killsDropped = killsSeen - kills,
        -- `stripRows` ON A HEALTHY SERVER IS ZERO, which makes it the one
        -- counter here worth reading on its own. Chat and kills are ordinary
        -- play; a strip is not.
        stripRows = strips, stripsSeen = stripsSeen,
        stripsDropped = stripsSeen - strips,
        -- `refusedRows` IS ZERO ON A HEALTHY SERVER TOO, and it is the counter to
        -- watch while the chat screen is new: it is the only number anywhere
        -- that says how often a message was silently delivered to nobody. The
        -- sender is never told, so nothing else on this server can be read as a
        -- rate of false positives.
        refusedRows = refused, refusedSeen = refusedSeen,
        refusedDropped = refusedSeen - refused,
    }
end

--- The default and promoted caps, exposed so callers and tests name one number.
BR.EvidenceBuf.DEFAULTS = DEFAULTS
BR.EvidenceBuf.PROMOTED = PROMOTED
