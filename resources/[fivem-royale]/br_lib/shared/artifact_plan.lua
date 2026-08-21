-- How many frames an incident gets, when, and under what number.
--
-- WHY THIS EXISTS SEPARATELY FROM server/artifacts.lua. Same split as
-- evidence_buf/evidence and combat_solve/damage: the wiring -- which event
-- fires, which resource takes the picture, what the clock says -- cannot be
-- exercised outside the game, but the bookkeeping can, and the bookkeeping is
-- where the rules live. "Three timed frames, then one per corroboration but
-- only after the first ten seconds, and never more than nine" is four rules
-- that are trivially testable and, left inline, would be verifiable only by
-- playing the game nine times.
--
-- PURE, AND `now` IS ALWAYS A PARAMETER. Nothing here reads a clock, calls a
-- native, or knows what a screenshot is. It hands out numbers.
--
-- ═══ THE RULES, AS THE OWNER SETTLED THEM (2026-08-20, #34) ═══
--
--   * On an incident being filed, capture the offending player IMMEDIATELY,
--     at +5s and at +10s. Three frames.
--   * On each corroboration, ONE more frame immediately -- but only if the
--     first ten seconds have already elapsed, because that window is already
--     covered by the three above.
--   * Up to SIX corroboration frames, so NINE per incident in total.
--   * AT THE CAP, STOP. No rolling window and nothing discarded: existing
--     evidence is never thrown away to make room, storage is bounded, and an
--     admin always sees the earliest part of the case -- which is the part
--     closest to what was reported. A seventh corroborator adds no frame, and
--     THAT IS NOT A FAILURE. The caller must be able to tell it apart from a
--     capture that went wrong, which is why `claim` answers with a reason.
--
-- ═══ A SLOT IS SPENT WHEN A FRAME IS ASKED FOR, NOT WHEN ONE ARRIVES ═══
--
-- This is the decision most likely to be revisited, so it is written down.
-- Counting only the frames that SUCCEED would mean a subject who is offline,
-- loading, or running without the capture resource lets an unlimited number of
-- corroborators each trigger an attempt -- the cap exists to bound work as well
-- as storage, and work is what an attempt costs. So a claim is spent on the
-- attempt.
--
-- The visible consequence is gaps: frame 04 may simply not exist in the bucket
-- while 05 does. That is correct and is the same property the incident record
-- already carries -- an incident with no frames is normal and is not evidence
-- of anything.

BR = BR or {}

BR.ArtifactPlan = {}
BR.ArtifactPlan.__index = BR.ArtifactPlan

--- When the three timed frames are taken, as offsets from the moment the
--- incident was filed.
---
--- AN ARRAY RATHER THAN A COUNT AND AN INTERVAL, because they are not evenly
--- spaced in principle -- the first one is "now" and exists to catch what is on
--- screen at the moment the report lands, and the other two exist to catch
--- whether it is still happening. A caller schedules one timer per entry.
local TIMED_OFFSETS_MS = { 0, 5000, 10000 }

--- The window the three timed frames cover.
---
--- DERIVED FROM THE OFFSETS RATHER THAN WRITTEN TWICE. The rule is "only if the
--- first ten seconds have already elapsed, since that window is covered", so
--- the number IS the last timed offset -- and moving a timed frame without
--- moving this would silently either double-cover or leave a hole.
local COVERED_MS = TIMED_OFFSETS_MS[#TIMED_OFFSETS_MS]

local DEFAULTS = {
    timedMax        = #TIMED_OFFSETS_MS,   -- 3
    corroborationMax = 6,
    -- 9. Stated rather than computed, because the owner settled it as a number
    -- and a reader should be able to find that number here. The constructor
    -- asserts the two halves add up to it.
    totalMax        = 9,
    -- How many incidents may be capturing at once. See `open`.
    incidentMax     = 64,
}

--- @param opts table|nil { timedMax, corroborationMax, totalMax, incidentMax }
--- @return table
function BR.ArtifactPlan.new(opts)
    opts = opts or {}
    local o = setmetatable({}, BR.ArtifactPlan)
    o.timedMax         = opts.timedMax or DEFAULTS.timedMax
    o.corroborationMax = opts.corroborationMax or DEFAULTS.corroborationMax
    o.totalMax         = opts.totalMax or DEFAULTS.totalMax
    o.incidentMax      = opts.incidentMax or DEFAULTS.incidentMax

    -- [incidentId] = { at, serial, timed, corroboration, used }
    o.cases = {}
    -- Insertion order, as { id, serial } pairs, so the bound below evicts the
    -- OLDEST case rather than an arbitrary one out of `pairs` -- and so an
    -- eviction can tell the case it queued from a later one under the same id.
    o.order = {}
    o.nextOrder = 0

    -- Counters for introspection. `refused` is deliberately not called
    -- `failures`: every refusal here is a rule working.
    o.stat = { opened = 0, claimed = 0, refusedCap = 0, refusedCovered = 0,
               refusedUnknown = 0, evicted = 0 }
    return o
end

--- The offsets a caller should schedule after `open`.
--- @return number[]
function BR.ArtifactPlan.timedOffsets()
    local out = {}
    for i, ms in ipairs(TIMED_OFFSETS_MS) do out[i] = ms end
    return out
end

--- How long the timed frames cover, in milliseconds.
--- @return number
function BR.ArtifactPlan.coveredMs()
    return COVERED_MS
end

--- Drop the oldest case once too many are open.
---
--- BOUNDED BECAUSE NOTHING ELSE FREES THIS. A corroboration can arrive against
--- a case filed in a previous match -- server/players.lua reads
--- `BR.Incident.openFor`, which is deliberately NOT dropped at match teardown --
--- so scoping this map to a match would throw away the state of exactly the
--- cases that are still being corroborated. The bound is the number of cases
--- that have drawn a filing since the last restart, capped.
---
--- An evicted case stops capturing, which is the same outcome as reaching the
--- cap and is handled by the caller the same way. Sixty-four is far more than a
--- server sees in a session; a server that sees more has a bigger problem than
--- a missing frame.
local function evict(self)
    while #self.order > self.incidentMax do
        local slot = table.remove(self.order, 1)
        local c = self.cases[slot.id]
        -- THE SERIAL IS COMPARED, NOT JUST THE ID. An id can reach `order`
        -- twice -- evicted once and then opened again by a repeated
        -- acknowledgement -- and dropping it on the FIRST of those entries would
        -- delete the LIVE case while a stale entry sat in the queue waiting to
        -- do it again. Two lines, and the reader no longer has to work out
        -- whether that sequence is reachable.
        if c and c.serial == slot.serial then
            self.cases[slot.id] = nil
            self.stat.evicted = self.stat.evicted + 1
        end
    end
end

--- Begin capturing for one incident.
---
--- IDEMPOTENT, AND THE SECOND CALL IS REFUSED RATHER THAN IGNORED. The
--- acknowledgement this hangs off (`br:incident:filed`) can in principle arrive
--- twice for one case -- br_ddb reports a duplicate write as a success, which is
--- what makes the retry safe -- and re-opening would reset the clock, restart
--- the numbering at 01, and overwrite frames already in the bucket with newer
--- ones. Overwriting evidence is the one outcome this whole feature must not
--- have.
---
--- @param incidentId string
--- @param now number  milliseconds, any monotonic source the caller also passes to `claim`
--- @return boolean opened
function BR.ArtifactPlan:open(incidentId, now)
    if type(incidentId) ~= 'string' or incidentId == '' then return false end
    if self.cases[incidentId] then return false end

    self.nextOrder = self.nextOrder + 1
    self.cases[incidentId] = {
        at            = now,
        timed         = 0,
        corroboration = 0,
        used          = 0,
        serial        = self.nextOrder,
    }
    self.order[#self.order + 1] = { id = incidentId, serial = self.nextOrder }
    self.stat.opened = self.stat.opened + 1
    evict(self)
    return true
end

--- Is this case being captured for?
--- @param incidentId string
--- @return boolean
function BR.ArtifactPlan:isOpen(incidentId)
    return self.cases[incidentId] ~= nil
end

--- Claim the next frame number for one incident.
---
--- ONE FUNCTION FOR BOTH KINDS, because they share the numbering and the total
--- and there must be exactly one place that spends them. Two functions would be
--- two places to forget `totalMax`.
---
--- THE NUMBER IS SHARED AND SEQUENTIAL, so 01..09 is capture order. That is what
--- lets a reader with nothing but the keys put the frames in the order they were
--- taken, and it is why the number is not "corroboration 3" or "timed 2".
---
--- @param incidentId string
--- @param kind string   'timed' | 'corroboration'
--- @param now number
--- @return integer|nil index  1..totalMax, or nil
--- @return string|nil reason  when index is nil: 'unknown' | 'covered' | 'cap'
function BR.ArtifactPlan:claim(incidentId, kind, now)
    local c = self.cases[incidentId]
    if not c then
        -- NOT AN ERROR, AND THE COMMONEST REASON IS A RESTART. A corroboration
        -- can name a case filed days ago; this process has no state for it, and
        -- guessing a frame number would risk writing over a frame that already
        -- exists under that number. A missing frame beats a destroyed one.
        self.stat.refusedUnknown = self.stat.refusedUnknown + 1
        return nil, 'unknown'
    end

    if kind == 'corroboration' then
        -- THE TEN-SECOND RULE. Comparing elapsed against the window the timed
        -- frames cover, so a corroboration inside it adds nothing that is not
        -- already being taken. `>=` rather than `>`: the frame at exactly +10s
        -- is the third timed one, and a corroboration landing in the same
        -- millisecond is the first one outside the covered window.
        if (now - c.at) < COVERED_MS then
            self.stat.refusedCovered = self.stat.refusedCovered + 1
            return nil, 'covered'
        end
        if c.corroboration >= self.corroborationMax then
            self.stat.refusedCap = self.stat.refusedCap + 1
            return nil, 'cap'
        end
    elseif kind == 'timed' then
        if c.timed >= self.timedMax then
            self.stat.refusedCap = self.stat.refusedCap + 1
            return nil, 'cap'
        end
    else
        return nil, 'unknown'
    end

    -- THE TOTAL IS CHECKED LAST AND SEPARATELY. With the defaults it cannot
    -- fire -- 3 + 6 is 9 -- and that is exactly why it is here: the day
    -- somebody raises `corroborationMax` without raising `totalMax`, the number
    -- the owner actually settled is the one that holds.
    if c.used >= self.totalMax then
        self.stat.refusedCap = self.stat.refusedCap + 1
        return nil, 'cap'
    end

    c.used = c.used + 1
    if kind == 'timed' then
        c.timed = c.timed + 1
    else
        c.corroboration = c.corroboration + 1
    end
    self.stat.claimed = self.stat.claimed + 1
    return c.used, nil
end

--- What has been spent on one case.
--- @param incidentId string
--- @return table|nil { used, timed, corroboration, at }
function BR.ArtifactPlan:usage(incidentId)
    local c = self.cases[incidentId]
    if not c then return nil end
    return { used = c.used, timed = c.timed, corroboration = c.corroboration, at = c.at }
end

--- Counters, for brdebug-style introspection.
function BR.ArtifactPlan:stats()
    local open = 0
    for _ in pairs(self.cases) do open = open + 1 end
    return {
        open           = open,
        opened         = self.stat.opened,
        claimed        = self.stat.claimed,
        refusedCap     = self.stat.refusedCap,
        refusedCovered = self.stat.refusedCovered,
        refusedUnknown = self.stat.refusedUnknown,
        evicted        = self.stat.evicted,
    }
end

--- Forget everything. For a resource restart.
function BR.ArtifactPlan:reset()
    self.cases = {}
    self.order = {}
    self.nextOrder = 0
end
