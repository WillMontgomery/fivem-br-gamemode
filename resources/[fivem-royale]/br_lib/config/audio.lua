-- Interface audio.
--
-- WHY NATIVE AND NOT NUI.
--
-- Every cue here plays through PlaySoundFrontend, not through an <audio> tag in
-- the browser. Three reasons, in order of how much they matter:
--
--   * ENGINE AUDIO DUCKS. A hitmarker fired from CEF sits on top of gunfire at
--     full volume forever; the same sound fired natively is mixed by the game
--     against everything else. There is no way to reproduce that from a browser.
--   * NO ASSETS. These are sounds GTA already ships and already has loaded.
--     Nothing to stream, nothing to add to files{}, nothing to license.
--   * NO LATENCY. The NUI bridge is throttled and asynchronous; a hit confirm
--     that arrives 80ms late is worse than no hit confirm.
--
-- The exception is menu audio, which the UI fires through the SFX callback --
-- there is nothing for it to duck against and it wants to follow a volume
-- slider some day.
--
-- EVERY NAME BELOW MUST BE AUDITIONED IN GAME.
--
-- A wrong sound-set name does not error. PlaySoundFrontend simply plays
-- nothing, exactly like a wrong native name returning nil -- and this project
-- has already lost a day to GetGroundZFor3dCoord. That is what /brsfx is for:
-- audition first, then fill the table from what actually plays.
--
-- Sets used here are the ones the base game leans on most heavily, so they are
-- the most likely to be loaded already:
--   HUD_FRONTEND_DEFAULT_SOUNDSET   menu navigation
--   HUD_MINI_GAME_SOUNDSET          short confirms
--   HUD_AWARDS                      rewards
--   GTAO_FM_EVENTS_SOUNDSET         match-scale events
--   MP_MISSION_COUNTDOWN_SOUNDSET   countdowns

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.Audio = {
    -- Master switch, for a player who wants silence without touching the game
    -- mixer. Client-side only; nothing here reaches another player.
    enabled = true,

    -- Per-cue rate limits, in ms. THE HITMARKER IS THE REASON THIS EXISTS: it
    -- fires once per bullet, and an unthrottled full-auto burst is thirty
    -- overlapping sounds. That has no visual symptom and will not be found by
    -- playing -- it just sounds broken and nobody can say why.
    minInterval = {
        ['hit']       = 60,
        ['hit.crit']  = 60,
        ['ui.hover']  = 40,
    },

    cues = {
        -- ---- interface ------------------------------------------------
        ['ui.hover']   = { set = 'HUD_FRONTEND_DEFAULT_SOUNDSET', name = 'NAV_UP_DOWN' },
        ['ui.select']  = { set = 'HUD_FRONTEND_DEFAULT_SOUNDSET', name = 'SELECT' },
        ['ui.back']    = { set = 'HUD_FRONTEND_DEFAULT_SOUNDSET', name = 'BACK' },
        ['ui.error']   = { set = 'HUD_FRONTEND_DEFAULT_SOUNDSET', name = 'ERROR' },
        ['ui.ready']   = { set = 'HUD_MINI_GAME_SOUNDSET',        name = 'CHECKPOINT_PERFECT' },

        -- ---- combat ---------------------------------------------------
        -- Deliberately dry and short. A hit confirm is information, not a
        -- reward: it fires hundreds of times a match and anything with a tail
        -- becomes noise by the second firefight.
        ['hit']        = { set = 'HUD_MINI_GAME_SOUNDSET',        name = 'CHECKPOINT_NORMAL' },
        ['hit.crit']   = { set = 'HUD_MINI_GAME_SOUNDSET',        name = 'CHECKPOINT_PERFECT' },
        -- The reward. This one IS allowed to be a moment.
        ['elim']       = { set = 'HUD_AWARDS',                    name = 'CHALLENGE_UNLOCKED' },
        ['downed']     = { set = 'GTAO_FM_EVENTS_SOUNDSET',       name = 'LOSER' },

        -- ---- match ----------------------------------------------------
        ['storm.phase'] = { set = 'MP_MISSION_COUNTDOWN_SOUNDSET', name = 'Countdown_1' },
        ['victory']     = { set = 'GTAO_FM_EVENTS_SOUNDSET',       name = 'WIN' },

        -- ---- loot -----------------------------------------------------
        -- ONE MOTIF, FIVE LEVELS. Common through Epic share a cue; Legendary
        -- gets its own, because the whole point is that you can hear what you
        -- picked up without looking at it. If the engine gives us nothing that
        -- separates the middle tiers, that is a finding, not a failure -- two
        -- distinguishable levels beats five identical ones.
        ['loot']        = { set = 'HUD_FRONTEND_DEFAULT_SOUNDSET', name = 'SELECT' },
        ['loot.rare']   = { set = 'HUD_MINI_GAME_SOUNDSET',        name = 'CHECKPOINT_UNDER_THE_BRIDGE' },
        ['loot.legendary'] = { set = 'HUD_AWARDS',                 name = 'CHALLENGE_UNLOCKED' },
    },
}

--- Which loot cue a rarity maps to.
--- @param rarity integer 1..5
--- @return string
function BR.Config.LootCue(rarity)
    if (rarity or 1) >= 5 then return 'loot.legendary' end
    if (rarity or 1) >= 3 then return 'loot.rare' end
    return 'loot'
end
