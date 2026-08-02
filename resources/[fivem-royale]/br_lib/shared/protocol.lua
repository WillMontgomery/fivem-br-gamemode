-- Network event names and the NUI envelope contract.
--
-- Every event name in the project lives here. Magic strings scattered across
-- files are how client and server quietly stop agreeing with each other.

BR = BR or {}

--- Server -> client, and client -> server, net event names.
--- Prefixed so they never collide with another resource's events.
BR.Net = {
    -- Handshake / bulk sync
    READY           = 'br:ready',            -- C->S  client finished loading, request snapshot
    SNAPSHOT        = 'br:snapshot',         -- S->C  full roster + match + inventory state

    -- Match lifecycle
    STATE           = 'br:state',            -- S->C  { state, endsAt, meta }
    ROSTER_DELTA    = 'br:roster:delta',     -- S->C  array of roster changes (coalesced)
    DIGEST          = 'br:digest',           -- S->C  { alive, squadsAlive, phase, endsAt }

    -- Lobby / squads
    QUEUE_JOIN      = 'br:queue:join',       -- C->S  { mode }
    QUEUE_LEAVE     = 'br:queue:leave',      -- C->S
    SQUAD_INVITE    = 'br:squad:invite',     -- C->S  { target }
    SQUAD_RESPOND   = 'br:squad:respond',    -- C->S  { squadId, accept }
    SQUAD_LEAVE     = 'br:squad:leave',      -- C->S
    SQUAD_UPDATE    = 'br:squad:update',     -- S->C  { squad }

    -- Bus / drop
    BUS_ROUTE       = 'br:bus:route',        -- S->C  { sx, sy, ex, ey, alt, tStart, tEnd }
    BUS_JUMP        = 'br:bus:jump',         -- C->S  request to jump
    BUS_JUMP_OK     = 'br:bus:jumpOk',       -- S->C  { x, y, z, heading }
    DROP_LANDED     = 'br:drop:landed',      -- C->S  reached the ground

    -- Storm
    STORM_SYNC      = 'br:storm:sync',       -- S->C  full storm record (also mirrored to GlobalState)
    STORM_DAMAGE    = 'br:storm:damage',     -- S->C  { amount, targetHp }

    -- Loot / inventory
    LOOT_CELL       = 'br:loot:cell',        -- C->S  { cx, cy } subscribe to a grid cell
    LOOT_ADD        = 'br:loot:add',         -- S->C  array of loot entries entering scope
    LOOT_GONE       = 'br:loot:gone',        -- S->C  array of loot ids removed
    LOOT_CLAIM      = 'br:loot:claim',       -- C->S  { id }
    INV_SET         = 'br:inv:set',          -- S->C  authoritative inventory mirror
    INV_SWAP        = 'br:inv:swap',         -- C->S  { from, to }
    INV_DROP        = 'br:inv:drop',         -- C->S  { slot }
    INV_USE         = 'br:inv:use',          -- C->S  { slot }
    INV_SELECT      = 'br:inv:select',       -- C->S  { slot }

    -- Combat / DBNO
    HEALTH_SYNC     = 'br:health:sync',      -- S->C  { hp, armour } authoritative correction
    DAMAGE_FEED     = 'br:damage:feed',      -- S->C  { amount, dir, headshot } for hitmarkers
    KILL_FEED       = 'br:kill:feed',        -- S->C  { killer, victim, weapon, headshot }
    DBNO_SET        = 'br:dbno:set',         -- S->C  { downed, bleedEndsAt, byName }
    REVIVE_START    = 'br:revive:start',     -- C->S  { target }
    REVIVE_STOP     = 'br:revive:stop',      -- C->S
    REVIVE_PROGRESS = 'br:revive:progress',  -- S->C  { pct }

    -- Spectate / end
    SPECTATE_SET    = 'br:spectate:set',     -- S->C  { targetSrc, x, y, z }
    SPECTATE_CYCLE  = 'br:spectate:cycle',   -- C->S  { dir }
    SUMMARY         = 'br:summary',          -- S->C  end-of-match payload

    -- Death. The client reports; the server decides. See server/combat.lua.
    PLAYER_DIED     = 'br:player:died',      -- C->S  { cause, killer? }

    -- Chat
    CHAT_SEND       = 'br:chat:send',        -- C->S  { channel, text }
    CHAT_MSG        = 'br:chat:msg',         -- S->C  { channel, from, name, text, at }

    -- Clock synchronisation. The storm and bus are interpolated locally from a
    -- record published once, which only works if clients agree on the time.
    CLOCK_PING      = 'br:clock:ping',       -- C->S  { sentAt }
    CLOCK_PONG      = 'br:clock:pong',       -- S->C  { sentAt, serverAt }

    -- Client -> server position report (2 Hz), used for validation and spectate
    POS_REPORT      = 'br:pos',              -- C->S  { x, y, z }
}

--- Chat channels. `squad` is routed server-side to squad members only -- the
--- client never filters, because a client-side filter is not a privacy boundary.
BR.ChatChannel = {
    GLOBAL = 'global',
    SQUAD  = 'squad',
    SYSTEM = 'system',  -- server-generated: storm warnings, eliminations
}

BR.ChatLimits = {
    maxLength     = 200,
    rateWindowMs  = 10000,
    rateMax       = 8,     -- messages per window before the server starts dropping
    historyKept   = 60,    -- messages the client keeps for the scrollback
}

--- NUI envelope kinds. Lua -> NUI always sends exactly one shape:
---   { t = 'br', v = 1, k = <kind>, d = <payload>, s = <seq> }
--- `s` is monotonic so React can drop stale or out-of-order messages.
BR.Nui = {
    SNAPSHOT  = 'snapshot',  -- full state, sent on load and after a br_ui restart
    STATE     = 'state',     -- match state transition
    HUD       = 'hud',       -- vitals, alive count, kills (10 Hz, deltas)
    SQUAD     = 'squad',
    INV       = 'inv',
    FEED      = 'feed',      -- kill feed + damage numbers
    STORM     = 'storm',     -- phase, radius, endsAt (4 Hz)
    DBNO      = 'dbno',
    SPECTATE  = 'spectate',
    SUMMARY   = 'summary',
    FOCUS     = 'focus',     -- tell the UI which screen owns focus
    TOAST     = 'toast',
    CHAT      = 'chat',      -- one appended message
    SCREEN    = 'screen',    -- resolution + safe zone, so the HUD can lay out
}

--- NUI -> Lua callback names, namespaced. Every one of these MUST resolve on
--- every path including errors; a missing resolve hangs the CEF promise forever.
BR.NuiCb = {
    QUEUE        = 'br/lobby/queue',
    QUEUE_LEAVE  = 'br/lobby/leave',
    SQUAD_INVITE = 'br/squad/invite',
    SQUAD_LEAVE  = 'br/squad/leave',
    INV_SWAP     = 'br/inv/swap',
    INV_DROP     = 'br/inv/drop',
    INV_USE      = 'br/inv/use',
    INV_SELECT   = 'br/inv/select',
    CLOSE        = 'br/close',
    CHAT_SEND    = 'br/chat/send',
    CHAT_FOCUS   = 'br/chat/focus',  -- UI tells Lua the input opened/closed
    ERROR        = 'br/err',  -- CEF exception sink; without this a crash is a blank screen
    ENV          = 'br/ui/env',  -- CEF capability report, printed at startup
}

BR.NUI_ENVELOPE_VERSION = 1

--- Lua 5.4 distinguishes integer 5 from float 5.0 and they serialise differently
--- through SendNUIMessage. Normalise every numeric payload field once, here, at
--- the boundary -- not in twelve places downstream.
---@param v any
---@return any
function BR.NuiNumber(v)
    if type(v) == 'number' then
        return v + 0.0
    end
    return v
end

--- Recursively coerce all numbers in a payload to floats. Call this on the
--- envelope's `d` field before SendNUIMessage.
---@param tbl any
---@return any
function BR.NuiNormalise(tbl)
    if type(tbl) ~= 'table' then
        return BR.NuiNumber(tbl)
    end
    local out = {}
    for k, v in pairs(tbl) do
        out[k] = BR.NuiNormalise(v)
    end
    return out
end
