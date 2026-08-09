-- Ringmaster's runtime configuration, read once at boot.
--
-- EVERYTHING HERE IS UNSET-SAFE. A server with no Ringmaster configured must
-- boot, run matches, and never mention it again beyond one line saying it is
-- off. That is the same contract br_stats has with its database, and it exists
-- for the same reason: this is an operations tool, and an operations tool that
-- can stop the game it observes has the relationship backwards.
--
-- Convars rather than a config file, because these differ per host -- the
-- endpoint is a private IP over a VPC peering link -- and because the shared
-- secret must never live in the repo. `br_lib/config/` is for values that are
-- the same everywhere and belong under review; this is not that.

BR = BR or {}
BR.Ring = BR.Ring or {}

--- Read a convar, treating empty string as absent.
---
--- GetConvar returns the default only when the convar is UNSET. A convar set to
--- "" is set, so the default never applies -- which would leave an empty ingest
--- URL looking configured and produce a push to nowhere on a timer. Collapsing
--- both to nil means "configured" has exactly one meaning downstream.
local function str(name, fallback)
    local v = GetConvar(name, '')
    if v == nil or v == '' then return fallback end
    return v
end

local function num(name, fallback)
    local v = tonumber(str(name, nil))
    if not v then return fallback end
    return v
end

--- Clamp with a named reason, because a typo'd convar should be visible rather
--- than merely survivable. A push interval of 0 would spin the scheduler; one
--- of 3600000 would look identical to "broken" from the console.
local function clamp(v, lo, hi)
    if v < lo then return lo, true end
    if v > hi then return hi, true end
    return v, false
end

local pushMs, pushClamped = clamp(num('br_ringmaster_push_ms', 2000), 250, 60000)

BR.Ring.Config = {
    -- Where the snapshots and events go. Ringmaster's ingest endpoint, reachable
    -- ONLY over the VPC peering link -- a private address, never a public one,
    -- and never through Cloudflare.
    ingestUrl = str('br_ringmaster_ingest_url', nil),

    -- Presented on every push. The endpoint is already unreachable from outside
    -- the peered CIDR, so this is defence in depth rather than the primary
    -- control -- but the primary control is a security group, and security
    -- groups get edited by tired people.
    ingestSecret = str('br_ringmaster_ingest_secret', nil),

    -- How often the snapshot goes out. 2s by default.
    --
    -- NOTE this is deliberately SLOWER than br_core's own roster digest, which
    -- runs at digestHz = 2, i.e. every 500ms. A human reading a dashboard does
    -- not need 2Hz, and the push crosses a region boundary; PLAN.md used to
    -- claim the two cadences matched, and they never did.
    pushMs = pushMs,

    -- Bounds on the EVENT queue. Small on purpose: this is a moderation feed,
    -- not a log shipper, and an unbounded queue behind a dead endpoint is a
    -- memory leak that presents as "the server got slow overnight".
    outboxCapacity = num('br_ringmaster_outbox_capacity', 512),
    outboxBatchMax = num('br_ringmaster_outbox_batch', 32),
}

--- Is there anywhere to push to?
---
--- Both halves are required. A URL with no secret would be rejected by the
--- endpoint on every attempt, which is a retry loop rather than a
--- configuration -- better to be plainly off.
--- @return boolean
function BR.Ring.Config.configured()
    local c = BR.Ring.Config
    return c.ingestUrl ~= nil and c.ingestSecret ~= nil
end

--- What to print at boot. Returns lines rather than printing them, so main.lua
--- owns the banner and this stays testable.
--- @return table lines
--- @return boolean healthy
function BR.Ring.Config.report()
    local c = BR.Ring.Config
    local lines = {}

    if c.configured() then
        -- The URL is not a secret; the secret is. Print one, never the other,
        -- and print only its length so a wrong-length paste is diagnosable
        -- without the value reaching a console log.
        lines[#lines + 1] = ('ingest    %s'):format(c.ingestUrl)
        lines[#lines + 1] = ('secret    set (%d chars)'):format(#c.ingestSecret)
        lines[#lines + 1] = ('push      every %dms'):format(c.pushMs)
    else
        lines[#lines + 1] = 'ingest    NOT CONFIGURED -- nothing is being pushed'
        if c.ingestUrl == nil then
            lines[#lines + 1] = '          set br_ringmaster_ingest_url'
        end
        if c.ingestSecret == nil then
            lines[#lines + 1] = '          set br_ringmaster_ingest_secret'
        end
    end

    if pushClamped then
        lines[#lines + 1] = ('push      br_ringmaster_push_ms was out of range; clamped to %d'):format(c.pushMs)
    end

    return lines, c.configured()
end
