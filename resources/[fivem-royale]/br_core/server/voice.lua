-- Voice authority: WHICH SQUAD RADIO EXISTS, AND WHO MAY BE ON IT.
--
-- ==========================================================================
-- WHAT THIS FILE STOPPED DOING, AND WHY THAT IS THE POINT.
--
-- It used to hand every client a Mumble PROXIMITY CHANNEL and create the room
-- with MUMBLE_CREATE_CHANNEL. It does neither now. pma-voice owns the engine
-- (see client/voice.lua for the whole argument), and pma-voice's model is that
-- every player has their OWN channel and speakers add the channels of the
-- players near them to their voice target. There is no match room to assign,
-- and creating one behind pma-voice's back would be a room nobody joins.
--
-- WHAT IS LEFT IS THE ONE THING pma-voice CANNOT KNOW: which of these
-- forty-eight people are a squad, and therefore which radio channel each player
-- is entitled to. pma-voice has a radio -- a channel audible at any distance,
-- riding MumbleAddVoiceTargetPlayerByServerId, which resolves against the
-- Mumble user list rather than the channel list and so reaches a squadmate the
-- game has not streamed in. That is exactly what squad voice has always needed.
--
-- ==========================================================================
-- HOW A PLAYER GETS ONTO A RADIO, AND WHY IT TAKES BOTH SIDES.
--
--   1. THIS FILE decides the NUMBER, from matchId and squadId, and sends it to
--      that player and to nobody else (VOICE_SET). Neither input is public --
--      matchId is excluded from roster.lua's PUBLIC_FIELDS -- so a client
--      cannot work out another squad's channel.
--   2. THE CLIENT decides whether to ASK for it, because the mode preference is
--      the player's. 'squad' asks; 'nearby' and 'off' ask for channel 0.
--   3. THIS FILE REFUSES ANYBODY WHO ASKED FOR ONE THEY WERE NOT GIVEN, using
--      pma-voice's own `addChannelCheck` hook -- which exists for precisely
--      this and is consulted inside its setPlayerRadio before anyone is added.
--
-- STEP 3 IS NOT DECORATION. Step 1's secrecy is only worth what guessing costs,
-- and the radio channel space is small integers. The check re-derives squad
-- membership from the roster at the moment of the request, so it cannot go
-- stale and there is no second copy of the answer to keep in step.
--
-- WHAT THIS COSTS, stated plainly, as the previous version of this file did:
-- proximity voice is now enforced by the SPEAKER, on the speaker's machine. A
-- modified client can therefore transmit to anyone it can see. The failure mode
-- is nuisance rather than surveillance, muting is the answer to nuisance and
-- pma-voice has a per-player mute already. The SQUAD radio is the part that
-- would actually be worth stealing, and that is the part this file gates.
--
-- ==========================================================================
-- MATCH ISOLATION, WHICH IS NOW SOMEBODY ELSE'S MECHANISM. READ THIS.
--
-- Two parallel matches stand on the same coordinates, and the old design gave
-- each match its own Mumble room because "routing buckets stop players seeing
-- each other; they are not documented to stop them HEARING each other."
--
-- THAT SENTENCE WAS ABOUT AN ENGINE SIDE EFFECT AND IT NO LONGER APPLIES.
-- pma-voice does not hear by room. It builds its voice target from the client's
-- own STREAMED player list, so a player in another match's routing bucket is
-- never a candidate to be sent to in the first place. Isolation is not being
-- inferred from an undocumented property of Mumble; it is the resource's own
-- selection loop, and buckets are the thing it selects from.
-- Config.Match.matchBucketBase gives every match its own.
--
-- THE HONEST RESIDUE, because this is the class of claim this project keeps
-- getting burned on: nobody here has watched two matches fail to hear each
-- other under pma-voice. What has changed is that the claim now rests on a
-- documented resource behaviour we have read the source of, rather than on an
-- engine behaviour nobody could find documentation for.
--
-- The SQUAD RADIO does not depend on any of that: its channel number contains
-- matchId, so two matches cannot collide on one, and the check in step 3 above
-- is a hard server-side wall regardless of buckets.
-- ==========================================================================

BR = BR or {}
BR.Voice = BR.Voice or {}

local VOICE_RES = 'pma-voice'
local V = (BR.Config.Match or {}).voice or {}

--- Is pma-voice running?
---
--- THE NATIVE ITSELF IS GUARDED, which is not paranoia about FXServer builds --
--- it is about the harnesses. This function is on the path of BR.Voice.push,
--- and push is called from the roster, from match state changes and from a 1 Hz
--- sweep; a nil global here would raise inside all three and take the roster's
--- own bookkeeping down with it. Absent reads as "no voice resource", which is
--- the correct and safe answer for anything that cannot answer the question.
local function present()
    return GetResourceState ~= nil and GetResourceState(VOICE_RES) == 'started'
end

-- ==========================================================================
-- THE CHANNEL MATHS IS PURE AND EXPOSED, DELIBERATELY.
--
-- Everything that can go wrong here is arithmetic -- two squads landing on one
-- number, a radio surviving into the next match -- and none of it is observable
-- from outside until two people who should not hear each other do. Arithmetic
-- that cannot be seen belongs somewhere it can be tested, which is the same
-- split as storm_solve and combat_solve.

--- Which proximity channel a match (or the lobby, or warmup) is.
---
--- THIS IS NO LONGER A MUMBLE CHANNEL AND NOTHING JOINS IT. pma-voice assigns
--- every player their own channel and this number is never handed to the engine
--- by anything, on either side.
---
--- It is kept because it is still the cheapest MATCH-SCOPED IDENTIFIER in the
--- system -- two players who must not hear each other still have to differ on
--- it, and it is what /brvoice prints to show that they do -- and because
--- tools/test_roster.lua has swept it since voice shipped.
--- @param matchId integer|nil
--- @param state string|nil
--- @return integer
function BR.Voice.proxChannel(matchId, state)
    if matchId then return (V.matchBase or 2000) + matchId end
    if state == BR.PlayerState.WARMUP then return V.warmupChannel or 1001 end
    return V.lobbyChannel or 1000
end

--- Which pma-voice radio channel one squad in one match is.
---
--- ==========================================================================
--- A squadId IS A STRING, NOT A NUMBER, AND THAT COST A ROUND OF THIS FILE.
---
--- server/party.lua namespaces squad ids by match and formats them as text:
---
---     local id = ('m%dsq%d'):format(m.id, i)     -- 'm3sq1'
---
--- The first version of this function did `matchId * stride + squadId` on that,
--- which is an arithmetic operation on a non-numeric string. In Lua that does
--- not evaluate to nil or to zero -- IT RAISES. The raise came out of
--- BR.Voice.push, which is called from inside BR.Roster.each by the 1 Hz sweep
--- and by pushMatch, so a single squad match aborted the sweep for every player
--- after it and left them with no voice assignment at all.
---
--- IT WOULD NEVER HAVE BEEN CAUGHT IN SOLOS, which is the part worth
--- remembering: solos have no squadId, so radio is nil, so the arithmetic never
--- runs. Exactly the shape of #150, where solo voice was broken from the day it
--- shipped because every test queued squads. tools/test_roster.lua caught this
--- one, in the squad blocks, before it reached a playtest.
---
--- SO THE INDEX IS PARSED OUT, AND A FAILURE TO PARSE IS LOUD. A silent nil
--- here would be a squad with no radio -- proximity-only squad voice, which is
--- the exact regression this whole change exists to end, and it would look like
--- "squad chat stopped working at range" with nothing in the console.
--- ==========================================================================
--- @param matchId integer|nil
--- @param squadId string|nil  as party.lua writes it, e.g. 'm3sq1'
--- @return integer|nil  nil when this player has no squad radio at all
local warnedSquadId = false
function BR.Voice.radioChannel(matchId, squadId)
    if not matchId or not squadId then return nil end

    local mid = math.tointeger(tonumber(matchId))
    if not mid then return nil end

    -- The trailing index is the squad's number within its match. The matchId is
    -- taken from the roster entry rather than from the string, so the two
    -- halves of the number come from the same place the caller got them.
    local n = tostring(squadId):match('sq(%d+)$')
    n = n and math.tointeger(tonumber(n)) or nil
    if not n then
        if not warnedSquadId then
            warnedSquadId = true
            print(('[br_core] VOICE: cannot read a squad index out of squadId '
                .. '%q -- server/party.lua has changed its format. SQUAD VOICE '
                .. 'IS PROXIMITY-ONLY until this is fixed.')
                :format(tostring(squadId)))
        end
        return nil
    end

    -- Separate number space from the proximity ids above, and far from them.
    -- The stride is per match, so squad 3 of match 7 and squad 3 of match 8 are
    -- different rooms -- which is what stops a radio surviving into the next
    -- match on a client that never asked to leave.
    --
    -- Read through V so a later round can move these into
    -- br_lib/config/match.lua (Config.Match.voice.radioBase / .radioStride)
    -- without touching this file. They are not there today.
    return (V.radioBase or 30000) + (mid * (V.radioStride or 100)) + n
end

--- @param e table roster entry
--- @return integer
local function proxChannelFor(e)
    return BR.Voice.proxChannel(e.matchId, e.state)
end

--- Who else is on this player's squad, by server id.
---
--- Sorted so the payload is stable and the dedup below can compare two pushes
--- as strings rather than re-deriving set equality every second for every
--- player. Departed players are excluded: a squadmate who has left is not
--- somebody to keep a radio open to.
--- @param src integer  the player being pushed; never in their own list
--- @param e table
--- @return table array of server ids, possibly empty
local function squadmatesOf(src, e)
    local out = {}
    if V.squadIsGlobal == false then return out end
    if not e.matchId or not e.squadId then return out end
    BR.Roster.each(
        function(o) return o.squadId == e.squadId
            and o.matchId == e.matchId
            and o.state ~= BR.PlayerState.LEFT end,
        function(other)
            if other ~= src then out[#out + 1] = other end
        end)
    table.sort(out)
    return out
end

--- @param list table
--- @return string
local function key(list)
    return table.concat(list, ',')
end

-- ------------------------------------------------------- the server-side wall ---

--- MAY THIS PLAYER JOIN THIS RADIO CHANNEL?
---
--- Handed to pma-voice as a per-channel check. It re-derives the answer from
--- the roster every time it is asked -- there is no cached membership here to
--- go stale, which matters because the interesting moment is exactly when a
--- player's squad has just changed.
--- @param src integer
--- @param channel integer
--- @return boolean
function BR.Voice.mayJoin(src, channel)
    local e = BR.Roster.get(src)
    if not e or e.state == BR.PlayerState.LEFT then return false end
    return BR.Voice.radioChannel(e.matchId, e.squadId) == channel
end

--- Channels we have already registered a check on, so we register once each.
--- Cleared when pma-voice restarts, because it drops every check it holds when
--- the resource that gave it one goes away -- and it drops ours when br_core
--- restarts, which is why registration is lazy rather than done at start.
local checked = {}

-- ------------------------------------------------- the spectator's microphone ---

--- Did a native declared BOOL actually say yes?
---
--- `MumbleIsPlayerMuted` is declared BOOL and a FiveM native declared BOOL may
--- hand Lua a NUMBER on some builds -- and IN LUA `0` IS TRUTHY, so
--- `if MumbleIsPlayerMuted(src) then` reads "muted" for a player who is not.
--- This repo has shipped that exact bug four times; client/spectate.lua carries
--- the same normaliser under the name `didHit`. Getting it wrong here would
--- mean never taking the mute (every player looks already-muted) and never
--- giving it back, so it is worth six lines.
--- @param v any
--- @return boolean
local function isYes(v)
    return v == 1 or v == true
end

--- Players WE are holding a transmit mute on, and nobody else.
---
--- THE SET EXISTS SO THE MUTE CAN BE GIVEN BACK WITHOUT STEALING SOMEBODY
--- ELSE'S. pma-voice's own `/muteply` writes the same native, so "unmute on
--- stop" as an unconditional call would quietly lift a moderator's mute the
--- moment a muted player died and started spectating their squad.
--- @type table<integer, boolean>
local specMuted = {}

--- Take or return a spectator's microphone. Server-side, and transmit only.
---
--- ═══ WHY THE SERVER AND NOT ONLY THE CLIENT ═══
---
--- "whoever is the spectator should NEVER be able to talk, only listen" -- the
--- owner, and `NEVER` is why this is not left to client/voice.lua's gag alone.
--- Under pma-voice the transmit decision genuinely is the speaker's, on the
--- speaker's machine (the argument is at the top of this file), so a client-side
--- gag is a rule a modified client simply declines to follow. `MumbleSetPlayerMuted`
--- is applied by the Mumble server to the connection itself, so it is the half
--- that holds when the client is hostile.
---
--- THE CLIENT GAG IS STILL THERE AND IS NOT REDUNDANT. It stops the honest
--- client transmitting on the frame the session opens rather than on the round
--- trip, it keeps `/brvoice` telling the truth, and it closes the radio key that
--- may already be held. Two halves, different failure modes.
---
--- ═══ THIS HALF IS STILL ONLY A MUTE, AND THAT IS STILL DELIBERATE ═══
---
--- Mumble separates muted from deafened and only the first is taken here.
---
--- WHAT CHANGED ABOVE IT. The owner's 2026-08-21 word -- "let's set voice to
--- OFF while in spectate, and return it to their preferred setting once
--- spectate is over" -- means a spectator no longer hears anything either. That
--- is implemented as a MODE, on the client, in br_core/client/voice.lua's
--- BR.Voice.mode(): it leaves the radio channel and holds a mute on everybody,
--- exactly as it does for a player who picks Off on the settings screen.
---
--- WHY IT IS NOT ALSO DONE FROM HERE, now that the rule wants both halves.
---
---   THE THREAT MODEL IS ASYMMETRIC, and it is the only reason this file has a
---   half at all. A modified client that TRANSMITS while spectating is talking
---   into a match it can see and is being fed the position of; that is why the
---   microphone is taken at the Mumble server, which is the one place a client
---   cannot argue with. A modified client that declines to go DEAF hears audio
---   its own machine was already being sent. There is nothing to win there, and
---   the server has no lever that fits anyway: this is a receive-side volume
---   override on the listener's own mixer.
---
---   AND THE OBVIOUS SERVER LEVER IS STILL THE WRONG ONE. Evicting a spectator
---   from their squad's radio channel from here would be a SECOND authority
---   over a channel the client is already leaving on its own -- two owners of
---   one membership, which is how a player comes back from a session onto no
---   channel at all. The client leaves it because its mode says to, and rejoins
---   it because its mode says to; there is one clock and it is that one.
---   tools/check_spectator_mic.lua holds this function to that.
---
--- @param src integer
--- @param on boolean  true to take the microphone, false to give it back
function BR.Voice.setSpectatorMuted(src, on)
    src = math.tointeger(tonumber(src))
    if not src then return end
    if MumbleSetPlayerMuted == nil then return end

    if on then
        if specMuted[src] then return end
        -- ALREADY MUTED BY SOMEBODY ELSE: leave it entirely alone. We neither
        -- take it nor record it, so the stop below will not hand back a mute we
        -- were never holding.
        if MumbleIsPlayerMuted ~= nil then
            local ok, already = pcall(MumbleIsPlayerMuted, src)
            if ok and isYes(already) then return end
        end
        local ok = pcall(MumbleSetPlayerMuted, src, true)
        if not ok then
            -- LOUD, because this is the security half failing open. The client
            -- gag still applies, so an honest client is still silent; what is
            -- lost is the guarantee against a modified one.
            print(('[br_core] VOICE: could not mute spectator %d at the Mumble '
                .. 'server. A modified client could transmit while spectating.')
                :format(src))
            return
        end
        specMuted[src] = true
        -- pma-voice mirrors this native into a statebag its own client reads;
        -- writing both is what keeps its UI from showing an open microphone.
        pcall(function() Player(src).state.muted = true end)
        return
    end

    if not specMuted[src] then return end
    specMuted[src] = nil
    pcall(MumbleSetPlayerMuted, src, false)
    pcall(function() Player(src).state.muted = false end)
end

--- Drop our bookkeeping for a departed player.
---
--- The native call is pointless for a connection that is gone and the src will
--- be handed to somebody else within the minute -- a stale `true` here would
--- make the next holder of that id unmutable by this file.
--- @param src integer
function BR.Voice.forgetSpectatorMute(src)
    src = math.tointeger(tonumber(src))
    if src then specMuted[src] = nil end
end

local function guard(channel)
    if not channel or checked[channel] then return end
    if not present() then return end
    local okc, err = pcall(function()
        exports[VOICE_RES]:addChannelCheck(channel, function(src)
            return BR.Voice.mayJoin(src, channel)
        end)
    end)
    -- MARKED EITHER WAY, so a failing export cannot be retried once a second
    -- for the life of the match. A failure here is the wall coming down, so it
    -- says so in those words rather than as a stack trace.
    checked[channel] = true
    if not okc then
        print(('[br_core] VOICE: could not register the squad-radio guard on '
            .. 'channel %s (%s). That channel is now joinable by any client '
            .. 'that guesses it.'):format(tostring(channel), tostring(err)))
    end
end

-- ------------------------------------------------ the two convars ---
--
-- THE CONFIGURATION pma-voice NEEDS, SET FROM HERE RATHER THAN ASKED FOR.
--
-- #165 IS WHAT ASKING LOOKS LIKE. Both convars below were added to
-- server.cfg.example last round and both were reported broken again the same
-- week, because server.cfg.example is documentation, not configuration:
-- .gitignore keeps the real server.cfg out of this repository and
-- tools/deploy.sh rsyncs resources/[fivem-royale]/ and nothing else. A convar
-- written into the example reaches the box only if somebody retypes it into a
-- file no deploy will ever touch. Two rounds of "it is in the config" have now
-- been two rounds of it not being on the server.
--
-- SO br_core SETS THEM, and only when the operator has not. GetConvar with an
-- empty sentinel distinguishes "never set" from "set to the default", so an
-- operator who deliberately wants the other value keeps it and gets told what
-- it costs instead of being silently overridden.
--
-- WHAT EACH ONE IS FOR is argued at length in client/voice.lua; the short of it:
--
--   voice_disableAutomaticListenerOnCamera 1
--     pma-voice enters SPECTATOR LISTENING whenever a scripted camera is
--     rendering. This gamemode renders one in the lobby, ON THE BUS and while
--     downed. Left at 0, every bus rider silently starts listening to every
--     streamed player's Mumble channel at unlimited range -- and because
--     the listens are taken over the WARMUP bucket's player list and dropped
--     over the MATCH bucket's one flight later, the difference is never
--     removed. That residue is a hole through the match isolation this file
--     spends forty lines arguing for, so this convar is load-bearing HERE, not
--     just on the client.
--
--     IT WAS NEVER THE WHOLE OF #165, and two versions of this comment have now
--     been wrong about what the rest was. The MumbleAddVoiceChannelListen spam
--     that #165 was opened for was vMenu's own voice chat, which ships enabled
--     and which nobody had enumerated (#185); pma-voice v7.0.1+ resolves every
--     channel before listening to it and cannot raise that warning. The
--     version-detection code that used to sit further down this file existed
--     only to blame pma-voice for it, and is gone. THIS CONVAR IS NOT PART OF
--     THAT and stays: the unlimited-range listens it prevents are pma-voice's
--     own setSpectatorMode, they are real in the version we run, and they leak
--     across the drop whether or not anything was warning about them.
--
--   voice_enableUi 0
--     pma-voice's own bottom-right overlay ("Custom [Range]", "[Call]",
--     "N Mhz [Radio]"), which the gamemode duplicates and the owner has now
--     asked about twice.
--
-- IF SPECTATOR VOICE IS EVER WANTED for dead players, it has to be built
-- deliberately -- BR.Native.spectate's free-cam path would otherwise hand a
-- dead player every conversation in the match, which is a different feature
-- from "the downed camera happens to be up".
local CONVARS = {
    { name = 'voice_disableAutomaticListenerOnCamera', want = '1',
      cost = 'every rider on the drop bus, every player in the lobby and every '
          .. 'downed player will listen to every streamed player at unlimited '
          .. 'range, and will keep some of those listens after the drop' },
    { name = 'voice_enableUi', want = '0',
      cost = 'pma-voice draws its own talking/range overlay bottom-right, on '
          .. 'top of the one br_ui draws' },
    -- THE MECHANISM, NOT THE COSTUME. This is the only pma-voice radio control
    -- we are able to turn off without turning the radio off, and it is worth
    -- knowing exactly which is which.
    --
    -- The radio ANIMATION is cosmetic: +radiotalk does TaskPlayAnim(ped,
    -- 'random@arrests', 'generic_radio_enter') on the talker for as long as
    -- the key is held. That is a fine default for a roleplay server and it is
    -- wrong here twice over -- it re-poses a player who is aiming a rifle, and
    -- it is a visible tell to every enemy in sight that this person is on
    -- comms. Nothing about audio goes with it.
    --
    -- WHAT WE DELIBERATELY DO NOT TOUCH, because it would take squad voice
    -- with it: voice_enableRadios (0 makes setPlayerRadio a no-op on both
    -- halves) and the +radiotalk KEY itself. The key is not a player-facing
    -- extra we happen to inherit -- it is the ONLY thing that ever puts a
    -- squadmate in the Mumble voice target (pma-voice client/module/radio.lua,
    -- addVoiceTargets on press, MumbleClearVoiceTargetPlayers on release).
    -- Suppress it and squad voice is silent by construction. See #157.
    { name = 'voice_enableRadioAnim', want = '0',
      cost = 'every player using squad voice visibly plays a hold-a-radio '
          .. 'animation while they talk -- through aiming, and in full view '
          .. 'of anyone watching them' },
    -- THE BUTTON CHIRP. Owner, from the playtest: "It still makes a radio
    -- chirp sound when pressing and releasing the button ... the button chirp
    -- needs to go."
    --
    -- THESE ARE VOLUMES, NOT SWITCHES, BECAUSE THERE IS NO SWITCH. pma-voice
    -- keeps the on/off for its mic clicks in a per-client KVP and exposes only
    -- the `setVoiceProperty` export over it -- br_core/client/voice.lua calls
    -- that, and this pair is the belt to it. Both go straight to `click.volume`
    -- on an <audio> element in pma-voice's own NUI (voice-ui/src/App.vue), so
    -- zero is silence.
    --
    -- WHAT IS DELIBERATELY NOT HERE: voice_enableSubmix. That is the RADIO
    -- EFFECT -- the processed, over-the-air sound a squadmate's voice gets --
    -- and the owner asked to keep it: "I don't hate the radio sound effect".
    -- It is a different feature from the chirp and it stays at its default.
    { name = 'voice_onClickVolume', want = '0',
      cost = 'a radio chirp plays every time a player presses push-to-talk' },
    { name = 'voice_offClickVolume', want = '0',
      cost = 'a radio chirp plays every time a player releases push-to-talk' },
}

--- Put the convars in force, or say why they are not. Idempotent.
---
--- Guarded on both natives: the unit suites run this file without the Cfx
--- runtime, and a nil global here would raise inside onResourceStart and take
--- the radio guards down with it.
local function applyConvars()
    if not GetConvar or not SetConvarReplicated then return end
    for _, c in ipairs(CONVARS) do
        local cur = GetConvar(c.name, '')
        if cur == '' then
            -- REPLICATED, because both of these are read on the CLIENT.
            SetConvarReplicated(c.name, c.want)
            print(('[br_core] VOICE: set %s %s (unset in server.cfg -- br_core '
                .. 'requires it).'):format(c.name, c.want))
        elseif cur ~= c.want then
            print(('[br_core] VOICE: server.cfg sets %s to %q and br_core needs '
                .. '%s. LEAVING YOURS. The cost: %s.')
                :format(c.name, cur, c.want, c.cost))
        end
    end
end

-- --------------------------------------------- WHO ELSE IS DOING VOICE HERE ---
--
-- THE ASSERTION THIS PROJECT DID NOT HAVE, AND THE ONE THAT WOULD HAVE SAVED
-- THREE ISSUES.
--
-- #185: vMenu ships its own voice chat, enabled by default, and it ran
-- alongside pma-voice for the entire life of #150, #157 and #165. Every
-- measurement taken in that time describes the COMBINATION. The audit that
-- eventually proved our own resources were clean was run over br_* only -- it
-- answered "are we doing this" and never "who is doing this", which is a
-- different question and the only one that mattered.
--
-- IT KEEPS HAPPENING. Three times in one day: vMenu's voice chat, pma-voice's
-- proximity cycle key, pma-voice's radio controls. The shape is always the
-- same -- two implementations of one subsystem with nothing anywhere asserting
-- that only one is live -- and the reason it keeps happening is that finding
-- out has always required somebody to think of looking.
--
-- SO THE BOX SAYS WHAT IS ON IT, AT BOOT, WITHOUT BEING ASKED. This is not
-- clever and it does not need to be: a name match over the started resource
-- list would have printed "vMenu" on day one of #150, and one line in a
-- console beats a week of playtests. It is deliberately a REPORT rather than a
-- refusal -- br_core has no business stopping somebody's server because it
-- recognised a resource name -- and it names what it found rather than
-- claiming a conflict, because "this also does voice" and "this is breaking
-- voice" are different claims and merging them is how this project got here.
--
-- ADDING A NAME IS THE WHOLE MAINTENANCE STORY. If a fourth voice resource
-- turns up, it goes in this table.
local VOICE_SUSPECTS = {
    ['vMenu'] = 'ships its own voice chat, ON BY DEFAULT -- this is #185. '
             .. 'Turn it off in vMenu\'s permissions/config',
    ['mumble-voip'] = 'a second Mumble voice implementation',
    ['saltychat'] = 'a second voice implementation',
    ['tokovoip_script'] = 'a second voice implementation',
    ['pma-voice'] = nil,   -- ours; named here so the intent is explicit
}

--- Every started resource that is known to touch voice, ours excluded.
---
--- SPLIT OUT AND PURE-ISH so the report and /brvoice read the same answer, and
--- so a name-matching rule can be tested without a running server.
--- @return table array of { name, why }
function BR.Voice.otherVoiceResources()
    local out = {}
    if not GetNumResources or not GetResourceByFindIndex then return out end
    local n = GetNumResources()
    for i = 0, (tonumber(n) or 0) - 1 do
        local res = GetResourceByFindIndex(i)
        if res and res ~= VOICE_RES and res ~= GetCurrentResourceName() then
            local why = VOICE_SUSPECTS[res]
            -- The name match is a SUPERSET of the table: anything calling
            -- itself voice is worth naming even if nobody has met it before,
            -- which is the half that catches the next one rather than the last.
            if not why and res:lower():find('voice') then
                why = 'name suggests a voice resource'
            end
            if why and GetResourceState and GetResourceState(res) == 'started' then
                out[#out + 1] = { name = res, why = why }
            end
        end
    end
    return out
end

--- Said once, at boot, on the console the operator actually reads.
local function reportOtherVoice()
    local others = BR.Voice.otherVoiceResources()
    if #others == 0 then return end
    print('[br_core] VOICE: ANOTHER RESOURCE ON THIS BOX ALSO DOES VOICE.')
    for _, o in ipairs(others) do
        print(('[br_core] VOICE:   %s -- %s'):format(o.name, o.why))
    end
    print('[br_core] VOICE: br_core drives pma-voice and nothing else. Two')
    print('[br_core] VOICE: voice implementations running at once is #185, and')
    print('[br_core] VOICE: every voice measurement taken while both are up')
    print('[br_core] VOICE: describes the pair rather than either one.')
end


AddEventHandler('onResourceStart', function(name)
    if name == GetCurrentResourceName() then
        applyConvars()
        reportOtherVoice()
    end
    if name == VOICE_RES then
        -- pma-voice came back holding nothing of ours. Every guard has to be
        -- re-registered, and forgetting each player's cached assignment is what
        -- makes the sweep below re-push -- and therefore re-guard -- within the
        -- second.
        checked = {}
        BR.Roster.each(
            function(e) return e.state ~= BR.PlayerState.LEFT end,
            function(src) BR.Voice.forget(src) end)
    elseif name == GetCurrentResourceName() and not present() then
        print('[br_core] VOICE: ' .. VOICE_RES .. ' is not running. There is '
            .. 'no voice chat -- no proximity, no squad radio. The gamemode '
            .. 'runs without it. See server.cfg.example for the install.')
    end
end)

-- ------------------------------------------------------------------- the push ---

--- Send one player their squad radio and their squad, if either has changed.
---
--- Deduplicated on the roster entry, because every caller fires on a state
--- change and several of them fire on the SAME state change -- a squad forming
--- is also a state change is also a match join.
--- @param src integer
function BR.Voice.push(src)
    if V.enabled == false then return end

    local e = BR.Roster.get(src)
    if not e then return end

    local prox  = proxChannelFor(e)
    -- ONE GUARD FOR BOTH HALVES. squadmatesOf() already honours squadIsGlobal;
    -- the radio number did not, so `squadIsGlobal = false` produced a player
    -- holding a radio channel with an empty squad list -- and now that the
    -- client REFUSES everybody outside that list, that combination is a player
    -- transmitting into a channel while muting every human being in the match.
    -- The two answers come off the same switch.
    local radio = (V.squadIsGlobal ~= false)
        and BR.Voice.radioChannel(e.matchId, e.squadId) or nil
    local mates = squadmatesOf(src, e)
    local mk    = key(mates)

    if e.voiceProx == prox and e.voiceMates == mk and e.voiceRadio == radio then
        return
    end

    -- EVICT BEFORE REASSIGNING, but only when they should be on NO channel.
    --
    -- pma-voice's own setPlayerRadio removes a player from their previous
    -- channel before adding them to a new one, so a player moving from one
    -- squad to another cleans up on the way in and needs nothing here. The case
    -- that does NOT clean up is the player who should now be on nothing -- back
    -- to the lobby, squad dissolved, match over -- because nobody is going to
    -- issue a join that displaces the old one. Left alone they would keep
    -- talking to their last squad from the lobby.
    if radio == nil and e.voiceRadio ~= nil and present() then
        pcall(function() exports[VOICE_RES]:setPlayerRadio(src, 0) end)
    end

    e.voiceProx, e.voiceMates, e.voiceRadio = prox, mk, radio

    -- THE WALL BEFORE THE INVITATION. The check has to be registered before the
    -- client is told the number, or the first join races past an unguarded
    -- channel.
    guard(radio)

    local R = V.range or {}
    TriggerClientEvent(BR.Net.VOICE_SET, src, {
        radio       = radio,
        mates       = mates,
        nearbyRange = R.nearby or 25.0,

        -- ==================================================================
        -- THE TWO FIELDS BELOW ARE NOT READ BY br_core/client/voice.lua.
        --
        -- `prox` was the match's Mumble room and there is no such room now;
        -- `squadRange` was the distance at which the client stopped opening a
        -- squadmate's volume override, and the pma-voice radio has no range at
        -- all -- it is a channel, and a channel does not attenuate.
        --
        -- THEY ARE STILL SENT BECAUSE tools/test_roster.lua ASSERTS ON THEM --
        -- see its 'voice.channels -- solos' block, which checks that a solo is
        -- told the proximity room the roster says they are in and that the
        -- squad range is the longer of the two. That suite is owned elsewhere
        -- and a contract change is not something to land underneath it.
        --
        -- REMOVING THEM IS A TWO-MINUTE JOB once that block is updated, and it
        -- should be done rather than left: fields nobody reads are exactly how
        -- this project accumulates subsystems with no callers. This comment is
        -- the marker for that follow-up, deliberately named so a grep for
        -- 'squadRange' lands on it.
        -- ==================================================================
        prox        = prox,
        squadRange  = R.squad or 16000.0,
    })
end

--- Re-push everybody in a match. Used when squads are formed, which changes
--- every member's squad roster at once.
--- @param m table
function BR.Voice.pushMatch(m)
    if V.enabled == false or not m then return end
    BR.Roster.each(
        function(e) return e.matchId == m.id end,
        function(src) BR.Voice.push(src) end)
end

--- Forget a player's cached assignment so their next push always sends.
---
--- Called on disconnect: a reconnecting player inherits the src, and a stale
--- cache would leave them silently on whatever radio the last holder had.
--- @param src integer
function BR.Voice.forget(src)
    local e = BR.Roster.get(src)
    if e then e.voiceProx, e.voiceMates, e.voiceRadio = nil, nil, nil end
end

-- THE SAFETY NET. Every path that changes a player's match or squad is supposed
-- to push, and the ones that exist do. This catches the ones that do not exist
-- yet: a subsystem added later that moves somebody between matches without
-- knowing this file is here would otherwise leave them on their old squad's
-- radio. It sends nothing when nothing has changed.
BR.Sched.every(1000, 'voice.sweep', function()
    if V.enabled == false then return end
    BR.Roster.each(
        function(e) return e.state ~= BR.PlayerState.LEFT end,
        function(src) BR.Voice.push(src) end)
end)

-- ------------------------------------------------------------------ readout ---

RegisterCommand('brvoice', function()
    local R = V.range or {}
    print('=== voice ===')

    -- FIRST LINE, FOR THE SAME REASON AS THE CLIENT'S. The previous version of
    -- this command opened with the range and the channel arithmetic and read as
    -- healthy through a total outage, because the arithmetic was fine and there
    -- was no voice resource running to act on it.
    print(('  engine       %s'):format(present()
        and (VOICE_RES .. ' -- running')
        or (VOICE_RES .. ' IS NOT RUNNING. There is no voice chat on this '
            .. 'server at all.')))
    -- THE CONVARS, SECOND. A pma-voice that is running and misconfigured is the
    -- shape #165 arrived in the first two times, and nothing else on this
    -- readout can show it.
    if GetConvar then
        for _, c in ipairs(CONVARS) do
            local cur = GetConvar(c.name, '')
            print(('  convar       %s = %s%s'):format(c.name,
                cur == '' and '(unset)' or cur,
                cur == c.want and '' or ('   <-- MUST BE ' .. c.want)))
        end
    end

    -- WHO ELSE IS DOING VOICE, THIRD, because it is the question nobody asked
    -- for three issues and it is invisible from every other line here.
    do
        local others = BR.Voice.otherVoiceResources()
        if #others == 0 then
            print('  others       none -- pma-voice is the only voice resource '
                .. 'started')
        else
            for _, o in ipairs(others) do
                print(('  others       %s IS ALSO RUNNING -- %s'):format(
                    o.name, o.why))
            end
        end
    end

    print(('  enabled      %s   nearby %.0fm (falloff, speaker-side)   squad-global %s')
        :format(tostring(V.enabled ~= false), R.nearby or 25.0,
                tostring(V.squadIsGlobal ~= false)))

    local guards = 0
    for _ in pairs(checked) do guards = guards + 1 end
    print(('  radio guards %d channel(s) gated to their own squad'):format(guards))

    BR.Roster.each(
        function(e) return e.state ~= BR.PlayerState.LEFT end,
        function(src, e)
            -- THE MODE IS PRINTED BECAUSE #150 WAS A MODE-SHAPED BUG. A solo
            -- match and a squad match are indistinguishable in every other
            -- column: both have a matchId, and solos simply have no squadId.
            -- It is also the column that separates "no radio because solo"
            -- from "no radio because something is wrong".
            local m = BR.Server.matchById(e.matchId)
            print(('  %-20s (%d)  match %-5s %-6s squad %-10s -> radio %s, mates [%s]')
                :format(e.name, src, tostring(e.matchId or '-'),
                        m and tostring(m.mode) or '-',
                        tostring(e.squadId or '-'),
                        tostring(e.voiceRadio or 'none'),
                        e.voiceMates ~= nil and e.voiceMates ~= '' and e.voiceMates
                            or 'nobody'))
        end)

    -- WHAT THIS READOUT PROVES, AND -- MORE USEFULLY -- WHAT IT DOES NOT.
    --
    -- #150 was a week of a correct server readout over a total client-side
    -- outage. That trap is bigger now, not smaller: proximity does not appear
    -- on this side AT ALL any more. There is no assignment to print, because
    -- there is nothing for this file to assign.
    print('')
    print('  This lists the SQUAD RADIO only. Proximity voice is not assigned')
    print('  by this server -- pma-voice decides it on each client, from that')
    print('  client\'s own streamed player list, so there is nothing here that')
    print('  can confirm or deny it. Run /brvoice in a player\'s F8 console.')
    print('  A squad player showing "radio none" is a BUG; a solo showing it is')
    print('  correct. Two squads that must not hear each other differ on radio.')
    print('')
    -- AND THE THING A CORRECT COLUMN ON THIS PAGE STILL DOES NOT BUY YOU. #157
    -- round seven was every number here being right while no audio moved,
    -- because a granted radio is not a radio anybody is TALKING on: pma-voice's
    -- radio has its own push-to-talk and the ordinary voice key does not reach
    -- it. Nothing on this server can see whether a player is holding it, so it
    -- is said here rather than measured.
    print('  A RADIO IS NOT A MICROPHONE. pma-voice\'s radio transmits only')
    print('  while +radiotalk is HELD. THE KEY THAT HOLDS IT IS OURS NOW --')
    print('  `brptt`, "Royale: Push to talk", default N, registered in')
    print('  br_core/client/keybinds.lua and rebindable on the gamemode\'s own')
    print('  settings screen. It was pma-voice\'s "Talk over Radio" on Left')
    print('  Alt, which was a default nobody had ever chosen and which no')
    print('  screen of ours could name or move. That, plus nobody being told')
    print('  the radio had a key at all, is what "squads don\'t work" turned')
    print('  out to be. This server cannot see whether anyone is holding it;')
    print('  /brvoice on the CLIENT names the binding and what it drives.')
end, true)
