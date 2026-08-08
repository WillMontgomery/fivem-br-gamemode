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
    -- Parties are persistent; squads are formed from them per match. The events
    -- are named "squad" for continuity with the UI, but they operate on parties.
    SQUAD_INVITE    = 'br:squad:invite',     -- C->S  { target }
    SQUAD_RESPOND   = 'br:squad:respond',    -- C->S  { accept }
    SQUAD_JOINREQ   = 'br:squad:joinreq',    -- C->S  { leader } -- ask to join their party
    SQUAD_JOINRESP  = 'br:squad:joinresp',   -- C->S  { requester, accept } -- leader's answer
    SQUAD_JOINASK   = 'br:squad:joinask',    -- S->C  { from, name, size, max } -- to the leader
    SQUAD_LEAVE     = 'br:squad:leave',      -- C->S
    SQUAD_KICK      = 'br:squad:kick',       -- C->S  { target }
    SQUAD_UPDATE    = 'br:squad:update',     -- S->C  { id, leader, members }
    SQUAD_INVITED   = 'br:squad:invited',    -- S->C  { partyId, from, name, size, max }
    LOBBY_STATUS    = 'br:lobby:status',     -- S->C  { queued, needed, connected, mode, ids, players, wait }
    SQUAD_RESULT    = 'br:squad:result',     -- S->C  { ok, reason } -- feedback for an invite/kick
    NOTIFY          = 'br:notify',           -- S->C  { text, tone } -- one notice for the on-screen stack
    SQUAD_POS       = 'br:squad:pos',        -- S->C  squadmate positions, SQUAD MEMBERS ONLY (1Hz)
    MATCH_LEAVE     = 'br:match:leave',      -- C->S  abandon the current match, back to the lobby
    TO_LOBBY        = 'br:lobby:return',     -- S->C  respawn at the lobby pad NOW (leave-match flow)

    -- Bus / drop
    BUS_ROUTE       = 'br:bus:route',        -- S->C  { sx, sy, ex, ey, alt, tStart, tEnd }
    BUS_SPECTATE    = 'br:bus:spectate',     -- S->C  { matchId, route } -- another match's departing flight, for warmup bystanders
    BUS_JUMP        = 'br:bus:jump',         -- C->S  request to jump
    BUS_JUMP_OK     = 'br:bus:jumpOk',       -- S->C  { x, y, z, heading }
    DROP_LANDED     = 'br:drop:landed',      -- C->S  reached the ground

    -- Storm
    STORM_SYNC      = 'br:storm:sync',       -- S->C  full storm record (also mirrored to GlobalState)
    STORM_DAMAGE    = 'br:storm:damage',     -- S->C  { amount, targetHp }

    -- Player-placed map markers (one per player; squad-visible in squads)
    MARKER_SET      = 'br:marker:set',       -- C->S  { x, y }
    MARKER_CLEAR    = 'br:marker:clear',     -- C->S  remove my marker
    MARKER_SYNC     = 'br:marker:sync',      -- S->C  { op, owner, x, y, colour }

    -- Loot / inventory
    LOOT_CELL       = 'br:loot:cell',        -- C->S  { cx, cy } subscribe to a grid cell
    LOOT_ADD        = 'br:loot:add',         -- S->C  array of loot entries entering scope
    LOOT_GONE       = 'br:loot:gone',        -- S->C  array of loot ids removed
    LOOT_CLAIM      = 'br:loot:claim',       -- C->S  { id }
    -- The repair round-trip. Only a CLIENT can ground-probe or read water
    -- height, so a client that finds an entry floating in the sea or buried
    -- under the map sends back the corrected position it computed. The server
    -- bounds how far it may move (see server/loot.lua) -- this is a
    -- suggestion, not an instruction.
    LOOT_FIX        = 'br:loot:fix',         -- C->S  { id, x, y, z }
    -- C->S { item, x, y, z }. An NPC the reporter killed dropped a weapon.
    -- Client-observed by necessity: ambient peds are client-side and the
    -- server has never heard of them. Rate-limited and range-checked at the
    -- far end -- see the handler for why that is enough.
    NPC_DROP        = 'br:loot:npcdrop',
    -- DEV ONLY, refused unless the server is in dev mode. Exists so a crate
    -- can be spawned from the F8 console standing in front of you, rather
    -- than from the server console where you cannot see it land.
    LOOT_DEV        = 'br:loot:dev',         -- C->S  { item?, x, y, z }
    INV_SET         = 'br:inv:set',          -- S->C  authoritative inventory mirror
    INV_SWAP        = 'br:inv:swap',         -- C->S  { from, to }
    INV_DROP        = 'br:inv:drop',         -- C->S  { slot }
    INV_USE         = 'br:inv:use',          -- C->S  { slot }
    INV_SELECT      = 'br:inv:select',       -- C->S  { slot }
    -- The server owns the inventory but cannot write a ped: it decides the
    -- consumable landed and TELLS the client to apply it, exactly as the storm
    -- tells a client to hurt itself. Health/armour arrive in DISPLAY units.
    INV_EFFECT      = 'br:inv:effect',       -- S->C  { health, healthCap, armour, armourCap }
    -- Ammo is the one number only the client can observe before M6's shot
    -- validation exists. Reports are accepted ONLY when they LOWER the stored
    -- value, so the worst a liar can do is disarm themselves.
    INV_AMMO        = 'br:inv:ammo',         -- C->S  { pool = { light = n, ... }, clip, slot }

    -- Combat / DBNO
    HEALTH_SYNC     = 'br:health:sync',      -- S->C  { hp, armour } authoritative correction
    DAMAGE_FEED     = 'br:damage:feed',      -- S->C  { amount, dir, headshot } for hitmarkers
    -- S->C { amount, armourFirst }. The server telling a victim to apply a
    -- validated gunshot to their own ped. Same shape and same reasoning as
    -- STORM_DAMAGE: the server cannot write a ped, so it keeps the ledger and
    -- instructs the client to show it.
    HIT_DAMAGE      = 'br:hit:damage',
    -- S->C { netId, hp }. A shot was REFUSED, so the shooter's local copy of
    -- the victim is wrong -- GTA applied the damage on their machine before
    -- the server ever saw the event, and CancelEvent stops replication, not
    -- that. This tells them to put the ped back.
    HIT_RESYNC      = 'br:hit:resync',
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
    PROMPT    = 'prompt',    -- world-anchored interaction prompt + progress ring
    FEED      = 'feed',      -- kill feed + damage numbers
    STORM     = 'storm',     -- phase, radius, endsAt (4 Hz)
    DBNO      = 'dbno',
    SPECTATE  = 'spectate',
    SUMMARY   = 'summary',
    FOCUS     = 'focus',     -- tell the UI which screen owns focus
    TOAST     = 'toast',
    CHAT      = 'chat',      -- one appended message
    SCREEN    = 'screen',    -- resolution + safe zone, so the HUD can lay out
    LOBBY     = 'lobby',     -- queue progress, so waiting has a visible reason
    INVITE    = 'invite',    -- an incoming party invite
    LEAVING   = 'leaving',   -- the voluntary-leave interstitial (black + text)
}

--- NUI -> Lua callback names, namespaced. Every one of these MUST resolve on
--- every path including errors; a missing resolve hangs the CEF promise forever.
BR.NuiCb = {
    QUEUE        = 'br/lobby/queue',
    QUEUE_LEAVE  = 'br/lobby/leave',
    SQUAD_INVITE = 'br/squad/invite',
    SQUAD_RESPOND = 'br/squad/respond',
    SQUAD_JOINREQ = 'br/squad/joinreq',
    SQUAD_JOINRESP = 'br/squad/joinresp',
    SQUAD_KICK   = 'br/squad/kick',
    SQUAD_LEAVE  = 'br/squad/leave',
    INV_SWAP     = 'br/inv/swap',
    INV_DROP     = 'br/inv/drop',
    INV_USE      = 'br/inv/use',
    INV_SELECT   = 'br/inv/select',
    CLOSE        = 'br/close',
    CHAT_SEND    = 'br/chat/send',
    CHAT_FOCUS   = 'br/chat/focus',  -- UI tells Lua the input opened/closed
    PAUSE        = 'br/pause',       -- ESC in the lobby: open GTA's pause menu
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
