-- Chat routing.
--
-- Squad chat is routed SERVER-SIDE to squad members only. It would be easier to
-- broadcast everything and let the client filter by channel, and that would be
-- wrong: a client-side filter is not a privacy boundary. Anyone reading the
-- event stream would see every squad's comms, which in a competitive mode is
-- exactly the information you must not leak.
--
-- The default FiveM `chat` resource is not used -- see server.cfg, where it is
-- stopped. Two chat systems fighting over the T key is a bad time.

local RATE = {}   -- [src] = { count, windowStart }

--- Simple sliding-window rate limit. Chat is a spam vector and, because every
--- message fans out to up to 48 clients, an unbounded one is also a bandwidth
--- amplifier.
--- @param src integer
--- @return boolean allowed
local function allow(src)
    local now = GetGameTimer()
    local r = RATE[src]
    if not r or (now - r.windowStart) > BR.ChatLimits.rateWindowMs then
        RATE[src] = { count = 1, windowStart = now }
        return true
    end
    r.count = r.count + 1
    return r.count <= BR.ChatLimits.rateMax
end

--- Strip anything that could break the UI or impersonate another channel.
--- The UI renders text nodes rather than HTML, so this is defence in depth
--- rather than the only guard.
--- @param text string
--- @return string
local function sanitise(text)
    text = tostring(text or '')
    -- Collapse control characters and newlines; a multi-line message would let
    -- one player push everyone else's chat off screen.
    text = text:gsub('[%c]', ' ')
    text = text:gsub('%s+', ' ')
    text = text:gsub('^%s*(.-)%s*$', '%1')

    -- NOT `text:sub(1, max)`, WHICH COUNTS BYTES AND CUTS THROUGH CHARACTERS.
    -- That was harmless while the truncated tail only had to render -- a
    -- replacement glyph on a very long message. It stopped being harmless the
    -- moment the screen below started reading the result: half of an `é` is
    -- malformed UTF-8, malformed UTF-8 is refused, and the player who wrote two
    -- hundred bytes of accented French would be silently talking to nobody for
    -- the rest of the round. See BR.ChatScreen.clamp.
    return BR.ChatScreen.clamp(text, BR.ChatLimits.maxLength)
end

--- Deliver a message to a set of recipients.
--- @param targets table  array of server ids, or nil for everyone
--- @param msg table
local function deliver(targets, msg)
    if not targets then
        TriggerClientEvent(BR.Net.CHAT_MSG, -1, msg)
        return
    end
    for _, src in ipairs(targets) do
        TriggerClientEvent(BR.Net.CHAT_MSG, src, msg)
    end
end

--- Everyone who should hear "global" chat from this sender.
---
--- GLOBAL IS PER MATCH, NOT PER SERVER, and it was not. This used to deliver
--- with a nil target list, which is TriggerClientEvent(-1) -- every connected
--- client, across every concurrent match and the lobby (user asked directly,
--- 2026-08-08: "can you confirm the chat events are contained within the
--- bucket?" -- they were not).
---
--- Two matches run in separate routing buckets precisely so they cannot see or
--- affect each other, and a chat channel that spans them undoes that: it leaks
--- callouts between matches, lets a dead player in match 2 narrate match 1,
--- and scales the message fan-out with the whole server instead of with one
--- lobby. Players in NO match hear each other, which is the lobby.
--- @param src integer
--- @return table
local function globalTargets(src)
    local m = BR.Server.matchOf(src)
    if m then return BR.Server.audience(m) end

    local out = {}
    for other, p in pairs(BR.Server.roster) do
        if not p.matchId then out[#out + 1] = other end
    end
    return out
end

--- Everyone in the sender's squad, including the sender. Solo players get a
--- squad channel that reaches only themselves rather than an error.
--- @param src integer
--- @return table
local function squadTargets(src)
    local me = BR.Server.roster[src]
    if not me or not me.squadId then return { src } end

    local out = {}
    for other, p in pairs(BR.Server.roster) do
        if p.squadId == me.squadId then
            out[#out + 1] = other
        end
    end
    return out
end

RegisterNetEvent(BR.Net.CHAT_SEND)
AddEventHandler(BR.Net.CHAT_SEND, function(data)
    local src = source
    local p = BR.Server.roster[src]

    -- No roster entry means they are not in this gamemode's world yet.
    if not p then return end

    local text = sanitise(data and data.text)
    if #text == 0 then return end

    -- NOTHING STARTING WITH A SLASH GOES OUT.
    --
    -- This gamemode has no chat commands. A message beginning with `/` is
    -- therefore one of two things and neither should be broadcast: somebody
    -- probing for an admin command they hope exists, or a new player typing
    -- what worked on another server. Today both were relayed verbatim to the
    -- lobby, which publishes the probe to everyone and makes the newcomer look
    -- foolish (user call, 2026-08-08).
    --
    -- Refused with a reply rather than in silence -- the honest half of that
    -- audience is trying to do something and deserves to know why nothing
    -- happened.
    if text:sub(1, 1) == '/' then
        TriggerClientEvent(BR.Net.CHAT_MSG, src, {
            channel = BR.ChatChannel.SYSTEM,
            from = 0, name = 'System',
            text = 'This gamemode has no chat commands, and messages starting '
                .. 'with "/" are not sent.',
            at = GetGameTimer(),
        })
        return
    end

    if not allow(src) then
        TriggerClientEvent(BR.Net.CHAT_MSG, src, {
            channel = BR.ChatChannel.SYSTEM,
            from = 0, name = 'System',
            text = 'You are sending messages too quickly.',
            at = GetGameTimer(),
        })
        return
    end

    local channel = data and data.channel or BR.ChatChannel.GLOBAL
    -- Never trust a client-supplied channel: system is server-only, and anything
    -- unrecognised falls back to global rather than being routed somewhere odd.
    if channel ~= BR.ChatChannel.SQUAD then
        channel = BR.ChatChannel.GLOBAL
    end

    local msg = {
        channel = channel,
        from    = src,
        name    = p.name or GetPlayerName(src) or 'Unknown',
        text    = text,
        at      = GetGameTimer(),
    }

    -- ═══ A LINK OR A NON-LATIN SCRIPT IS SHADOWED, NOT REFUSED ═══
    --
    -- The owner, 2026-08-29: a post containing a link is refused and opens an
    -- incident; so is any non-Latin script. And then, superseding what "refused"
    -- means: "the experience to the sender should look like it posted just
    -- fine".
    --
    -- SO THE SENDER STILL RECEIVES THEIR OWN MESSAGE AND NOBODY ELSE DOES. The
    -- echo has to be indistinguishable from the real thing or it is a tell, and
    -- the only way to be sure of that is not to build a second one: `msg` below
    -- is the exact table the honest path delivers, sent on the exact event, so
    -- the sender's client cannot tell the difference because there is none. Same
    -- name, same channel, same colour, same ordering.
    --
    -- NOTHING IS SAID TO ANYBODY. No refusal sentence, no toast, no console
    -- line for the player -- this feature adds no player-facing text at all,
    -- which is both what the owner asked for and the standing rule. It is also
    -- what server/incident.lua's header already promises: "the offender learns
    -- nothing at any point".
    --
    -- WHY IT SITS HERE AND NOT HIGHER UP. Both refusals above -- the slash
    -- prefix and the rate limit -- answer the sender with a System line and
    -- deliver nothing. Screening before them would have to either suppress those
    -- replies (a tell, and a worse one because it is a change in behaviour the
    -- player has seen before) or file a case about a message that never went
    -- anywhere. A `/`-prefixed link is therefore refused by the existing rule
    -- and files nothing, which is the honest outcome: it was not posted.
    local refusal = BR.ChatScreen and BR.ChatScreen.screen(text) or nil
    if refusal then
        deliver({ src }, msg)

        -- BOTH NOTES, AND THE ORDER MATTERS. `noteChat` keeps the chat log a
        -- complete record of what this player said; `noteRefusedChat` is the
        -- short list the timeline is built from. Both happen BEFORE the incident
        -- is announced, so the line that opened the case is on the timeline the
        -- case is created with -- the same ordering server/strip.lua depends on.
        if BR.Evidence then
            BR.Evidence.noteChat(src, msg)
            if BR.Evidence.noteRefusedChat then
                BR.Evidence.noteRefusedChat(src, msg, refusal)
            end
        end

        -- HANDED OVER, NOT FILED HERE, exactly as server/strip.lua hands over.
        -- server/incident.lua is the file that knows what has already been filed
        -- this match, so it is the one that decides between opening a case and
        -- corroborating one. Fire-and-forget: if nothing is listening the
        -- message still went nowhere, which is the half that protects the match.
        -- THE LINE ITSELF IS NOT ON THIS EVENT, AND THAT IS DELIBERATE. It went
        -- into the evidence buffer two lines above, which is where the timeline
        -- is built from; putting a second copy on the wire would be a second
        -- place for one string to live and to rot -- and this repository has the
        -- scar for that already, in the `note` field that was carried through
        -- five layers of plumbing to a hard-coded null. Every key below is read
        -- by server/incident.lua. Nothing here is sent speculatively.
        TriggerEvent('br:core:chatrefused', {
            name    = msg.name,
            license = BR.Roster and BR.Roster.licenseOf
                and BR.Roster.licenseOf(src) or nil,
            matchId = p.matchId,
            reason  = refusal,
            at      = msg.at,
        })
        return
    end

    if channel == BR.ChatChannel.SQUAD then
        deliver(squadTargets(src), msg)
    else
        -- NEVER nil, which would be TriggerClientEvent(-1) and would cross
        -- every match on the server. See globalTargets.
        deliver(globalTargets(src), msg)
    end

    -- Keep it, in case an incident needs it later.
    --
    -- AFTER delivery and with the DELIVERED message, not the typed one. What a
    -- reviewer has to judge is what other players actually saw -- a record of
    -- the raw input would include control characters this refused to broadcast,
    -- and would prove something different from what happened. BR.Evidence
    -- ignores this outside a live match, so lobby small talk is never held.
    if BR.Evidence then BR.Evidence.noteChat(src, msg) end
end)

--- Server-generated announcements. Used by the storm, match state and
--- elimination systems rather than having each of them build a message.
--- @param text string
--- @param targets table|nil  nil for everyone
function BR.Server.systemMessage(text, targets)
    deliver(targets, {
        channel = BR.ChatChannel.SYSTEM,
        from    = 0,
        name    = 'System',
        text    = sanitise(text),
        at      = GetGameTimer(),
    })
end

AddEventHandler('playerDropped', function()
    RATE[source] = nil
end)

RegisterCommand('brsay', function(_, args)
    local text = table.concat(args, ' ')
    if #text == 0 then
        print('  usage: brsay <message>   (broadcasts as System)')
        return
    end
    BR.Server.systemMessage(text)
    print(('[br_core] system message sent: %s'):format(text))
end, true)
