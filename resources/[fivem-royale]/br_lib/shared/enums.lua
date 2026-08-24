-- Shared enumerations. Loaded first; every other br_lib file assumes BR exists.

BR = BR or {}

--- Match lifecycle. The server owns transitions; clients only ever mirror them.
BR.MatchState = {
    WAITING = 'waiting', -- not enough players, lobby open
    WARMUP  = 'warmup',  -- countdown running, players on the warmup pad
    BUS     = 'bus',     -- battle bus in flight, players may jump
    PLAYING = 'playing', -- storm active, combat live
    ENDED   = 'ended',   -- winner decided, summary showing
    CLEANUP = 'cleanup', -- tearing down for the next match
}

--- Per-player state inside a match.
BR.PlayerState = {
    LOBBY      = 'lobby',
    WARMUP     = 'warmup',
    BUS        = 'bus',        -- aboard, not yet jumped
    FREEFALL   = 'freefall',   -- jumped, chute not open
    GLIDE      = 'glide',      -- chute open
    ALIVE      = 'alive',      -- landed and fighting
    DBNO       = 'dbno',       -- downed but not out (squads only)
    DEAD       = 'dead',
    SPECTATING = 'spectating',
    LEFT       = 'left',       -- disconnected mid-match
}

--- Loot rarity. Order matters: index is used for weighted rolls and comparisons.
BR.Rarity = {
    COMMON    = 1,
    UNCOMMON  = 2,
    RARE      = 3,
    EPIC      = 4,
    LEGENDARY = 5,
}

--- Single source of truth for rarity presentation. The Lua side uses `rgb` for
--- loot glow markers; the NUI uses `hex` for inventory borders. Keeping both here
--- is what stops the two from drifting apart.
BR.RarityInfo = {
    [BR.Rarity.COMMON]    = { key = 'common',    label = 'Common',    hex = '#B0B0B0', rgb = { 176, 176, 176 }, damageMult = 1.00 },
    [BR.Rarity.UNCOMMON]  = { key = 'uncommon',  label = 'Uncommon',  hex = '#4CD964', rgb = {  76, 217, 100 }, damageMult = 1.06 },
    [BR.Rarity.RARE]      = { key = 'rare',      label = 'Rare',      hex = '#3B9BFF', rgb = {  59, 155, 255 }, damageMult = 1.12 },
    [BR.Rarity.EPIC]      = { key = 'epic',      label = 'Epic',      hex = '#B15BFF', rgb = { 177,  91, 255 }, damageMult = 1.20 },
    [BR.Rarity.LEGENDARY] = { key = 'legendary', label = 'Legendary', hex = '#FFB020', rgb = { 255, 176,  32 }, damageMult = 1.28 },
}

--- What a loot entry / inventory slot actually holds.
--- Per-SQUADMATE colour, by their stable member index.
---
--- ONE PALETTE FOR EVERYTHING THAT IDENTIFIES A TEAMMATE: their minimap blip,
--- their destination marker's blip, and the world beam of that marker. There
--- used to be two -- an index palette for blips and the SQUAD colour for
--- markers -- and the squad colour is shared by the whole squad, so every
--- teammate's destination marker came out the same colour while their blips
--- were all different (user, 2026-08-05).
---
--- NEVER PURPLE, in any slot: purple belongs to the storm alone.
--- `blip` is a GTA blip colour index; `rgb` is for DrawMarker.
BR.SquadColours = {
    { blip =  3, hex = '#60A5FA', rgb = { 96, 165, 250} },
    { blip =  2, hex = '#4ADE80', rgb = { 74, 222, 128} },
    { blip =  5, hex = '#FBBF24', rgb = {251, 191,  36} },
    { blip =  1, hex = '#F87171', rgb = {248, 113, 113} },
    { blip =  8, hex = '#F472B6', rgb = {244, 114, 182} },
    { blip = 15, hex = '#2DD4BF', rgb = { 45, 212, 191} },
    { blip = 17, hex = '#FB923C', rgb = {251, 146,  60} },
    { blip = 18, hex = '#6EE7F9', rgb = {110, 231, 249} },
}

--- The colour for a member index, wrapping. Never nil.
--- @param i integer|nil
--- @return table
function BR.SquadColour(i)
    local n = #BR.SquadColours
    local idx = ((math.tointeger(i or 1) or 1) - 1) % n + 1
    return BR.SquadColours[idx]
end

BR.ItemKind = {
    WEAPON     = 'weapon',
    AMMO       = 'ammo',
    CONSUMABLE = 'consumable',
    THROWABLE  = 'throwable',
}

--- Ammo pools. Mapped onto GTA's native ammo groups so the engine tracks counts
--- for us rather than us shadowing them.
BR.AmmoType = {
    LIGHT  = 'light',  -- pistols
    SMG    = 'smg',
    MEDIUM = 'medium', -- rifles
    SHELLS = 'shells', -- shotguns
    HEAVY  = 'heavy',  -- snipers / LMG
}

--- Match modes.
---
--- `dbno` IS THE MODE'S DEFAULT ANSWER, NOT THE WHOLE RULE, and it is worth being
--- exact because this comment used to claim `squadSize` drove DBNO, which was
--- never true and is now doubly misleading. `squadSize` is read by nothing but a
--- test; `dbno` is read in exactly one place, BR.Combat.canBeDowned.
---
--- Solo carries `false` because a solo player has nobody who could revive them,
--- so a knock would be a slower death and a worse one. #191's CPR kit makes that
--- CONDITIONAL ON INVENTORY rather than flipping it: a solo carrying a kit goes
--- down instead of dying, because they can call an ambulance. THE FLAG STAYS
--- FALSE -- flipping it would knock down every solo in every match, including
--- the overwhelming majority holding no kit. See the block in canBeDowned.
BR.Mode = {
    SOLO  = { key = 'solo',  label = 'Solo',  squadSize = 1, dbno = false },
    SQUAD = { key = 'squad', label = 'Squad', squadSize = 4, dbno = true  },
}

--- Modes are referenced by their string key across the wire and in config
--- (queue requests, Config.Match.defaultMode), so a key -> mode lookup is needed.
--- Without this every call site invents its own if/else chain.
BR.ModeByKey = {}
for _, m in pairs(BR.Mode) do
    BR.ModeByKey[m.key] = m
end

--- Resolve a mode from an untrusted string. Never returns nil: an unknown key
--- from a client falls back to solo rather than crashing the queue handler.
--- @param key string|nil
--- @return table
function BR.ResolveMode(key)
    return BR.ModeByKey[key] or BR.Mode.SOLO
end

--- Storm phase sub-state, returned by BR.StormAt().
BR.StormPhase = {
    PRE       = 'pre',       -- initial hold, before phase 1
    HOLDING   = 'holding',   -- circle static, next circle already revealed
    SHRINKING = 'shrinking', -- interpolating toward the next circle
    FINISHED  = 'finished',  -- final circle collapsed
}

-- ==========================================================================
-- VOICE: THE THREE MODES, WHAT EACH ONE ROUTES, AND THE DEFAULT.
--
-- THIS BLOCK IS HERE RATHER THAN IN br_core BECAUSE TWO RESOURCES OWN HALVES
-- OF THE SAME DECISION AND THEY KEPT DISAGREEING. br_ui/client/settings.lua
-- stores the player's choice; br_core/client/voice.lua acts on it. Both used
-- to spell the vocabulary and the default out by hand, and they spelled the
-- default DIFFERENTLY -- settings said 'nearby', voice.lua said 'squad' -- for
-- long enough that "what happens to a player who never opens the settings
-- screen" depended on which file you read. Settings won in practice, by the
-- accident of firing a push on br:ui:ready. Nothing enforced it.
--
-- So there is now one definition and everybody READS it. enums.lua is the one
-- br_lib file both resources already load (see both fxmanifests), which is why
-- it lands here and not in config/match.lua -- br_ui deliberately does not
-- pull the match config in.
--
-- ==========================================================================
-- THE MODES ARE MUTUALLY EXCLUSIVE. THIS IS THE OWNER'S SPEC, VERBATIM:
--
--   "Nearby should only be nearby, different from squads and not additional to
--    it. It means a player could hear anyone nearby within their bucket, and
--    likewise others will hear them nearby. Squads should be set to no
--    distance/fade/etc and only talk/listen within a given squad."
--
-- It has been restated more than once, so it is worth being blunt about what
-- it rules out: SQUAD IS NOT PROXIMITY PLUS A RADIO. A squad player does not
-- hear the stranger standing next to them, and a nearby player does not hear
-- their squadmate across the island. Each mode is ONE channel of audio, never
-- two layered.
--
-- THE SHAPE OF BR.VoiceRouting IS WHAT ENFORCES THAT, and it is deliberately
-- the smallest thing that can: two booleans per mode, never both true. Every
-- consumer -- the transmit gag, the radio join, the listen refusal, the
-- talking indicator and the /brvoice readout -- is derived from these two
-- columns rather than re-deciding from the mode string. So "make squad hear
-- non-squad again" is not a change somebody can make in one place by accident:
-- it means setting proximity = true on the squad row, which turns that row
-- into a mode with both columns set, and both the suite and tools/verify.sh
-- fail on exactly that.
-- ==========================================================================

--- The vocabulary. These strings cross the br_ui -> br_core boundary on
--- `br:settings:changed` and are persisted in this machine's KVP, so they are
--- a stored format and not merely an internal name.
BR.VoiceMode = {
    NEARBY = 'nearby',
    SQUAD  = 'squad',
    OFF    = 'off',
}

--- WHAT A PLAYER WHO HAS NEVER OPENED THE SETTINGS SCREEN GETS.
---
--- 'nearby', and the reason is that it is the only mode that works for
--- everybody: a solo has no squad, so a default of 'squad' is a default of
--- silence for every player in every solo match. That is #150's exact symptom
--- and it must not be reachable by doing nothing.
BR.VoiceModeDefault = BR.VoiceMode.NEARBY

--- WHAT EACH MODE ROUTES. Two columns, and no row may have both.
---
---   proximity  our audio goes to players within Config.Match.voice.range
---              .nearby, and we refuse nobody's audio. pma-voice enforces the
---              distance on the SPEAKER's machine.
---   radio      our audio goes to the squad radio channel the server assigned,
---              at any distance and with no falloff, and we refuse everybody
---              who is not a squadmate.
---
--- 'off' is both false: it transmits to nobody and refuses everybody.
BR.VoiceRouting = {
    [BR.VoiceMode.NEARBY] = { proximity = true,  radio = false },
    [BR.VoiceMode.SQUAD]  = { proximity = false, radio = true  },
    [BR.VoiceMode.OFF]    = { proximity = false, radio = false },
}

--- Coerce an untrusted mode string. Never returns nil: the value arrives from
--- a KVP blob and from a NUI payload, either of which can be an old build's.
--- @param mode string|nil
--- @return string  one of BR.VoiceMode
function BR.ToVoiceMode(mode)
    return BR.VoiceRouting[mode] and mode or BR.VoiceModeDefault
end

--- The routing row for a mode, coerced. Never nil, so no caller needs a guard.
--- @param mode string|nil
--- @return table  { proximity = boolean, radio = boolean }
function BR.VoiceRoutingFor(mode)
    return BR.VoiceRouting[BR.ToVoiceMode(mode)]
end

-- ==========================================================================
-- TWO SAVED PREFERENCES, ONE MODE IN FORCE.
--
-- Owner, from the playtest: "make it so that a player can save a different
-- preference (nearby/squad/off) for squads and solos."
--
-- WHY THIS IS A REAL PROBLEM AND NOT A CONVENIENCE. There is exactly one
-- stored voice mode today, and it is the same one in both kinds of match. A
-- player who picks Squad for a squad match and then queues a solo carries
-- Squad into a match that has no squads -- which is total silence, by design,
-- and indistinguishable from a fault. That is #157's second half, and the
-- settings screen's own comment records the round that was spent on it. Two
-- slots removes the state that cannot be right for both.
--
-- THE RESOLUTION LIVES HERE, NEXT TO THE VOCABULARY, for the same reason the
-- default does: br_ui stores the pair and br_core acts on it, and every
-- previous time those two answered the same question separately they answered
-- it differently (see the block above BR.VoiceMode).
--
-- 'squad' IS NOT OFFERED IN THE SOLOS ROW AT ALL, and that is a decision worth
-- writing down rather than a gap. A squad radio in a solo match is not a
-- degraded choice, it is a choice with no referent -- the server mints no
-- channel, so the mode is silence with extra steps. The settings screen
-- therefore shows two buttons in that row rather than three greyed ones: a
-- disabled control still has to be read, reasoned about and dismissed, and the
-- existing three-button row already spent a round teaching players that a dim
-- button means "your setting is broken". BR.ToSoloVoiceMode is the enforcement
-- -- a 'squad' that reaches the solo slot by any route (an old KVP blob
-- migrated from the single setting, a hand-fired event, a stale build's NUI
-- payload) becomes the default rather than silence.
-- ==========================================================================

--- Coerce a mode for the SOLO slot, where 'squad' has no meaning.
--- @param mode string|nil
--- @return string  one of BR.VoiceMode, never BR.VoiceMode.SQUAD
function BR.ToSoloVoiceMode(mode)
    mode = BR.ToVoiceMode(mode)
    if mode == BR.VoiceMode.SQUAD then return BR.VoiceModeDefault end
    return mode
end

--- WHICH OF THE TWO SAVED PREFERENCES IS IN FORCE.
---
--- PURE, AND IT TAKES ITS INPUTS, so both resources and the suite can drive it
--- without a match. The match mode is BR.Mode's `key` -- 'solo' or 'squad' --
--- and ANYTHING ELSE RESOLVES TO THE SOLO PREFERENCE, deliberately: the lobby,
--- a client that has not been told yet, and a nil all mean "no squad has been
--- formed around me", and the solo slot is the one that cannot be silence.
--- @param prefs table|nil  { solo = string|nil, squad = string|nil }
--- @param matchMode string|nil  a BR.Mode key
--- @return string  one of BR.VoiceMode
function BR.VoiceModeFor(prefs, matchMode)
    prefs = type(prefs) == 'table' and prefs or {}
    if matchMode == BR.Mode.SQUAD.key then
        return BR.ToVoiceMode(prefs.squad)
    end
    return BR.ToSoloVoiceMode(prefs.solo)
end
