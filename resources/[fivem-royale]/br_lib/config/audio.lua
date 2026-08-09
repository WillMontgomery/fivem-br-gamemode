-- COMBAT audio. Not interface audio -- that lives in the browser.
--
-- WHAT IS AND IS NOT HERE.
--
-- Everything the player hears from the INTERFACE is synthesised in
-- ui-src/src/audio/cues.ts: menus, verdicts, the storm, loot tiers. GTA's
-- frontend sounds are instantly recognisable as GTA Online's menus, which is
-- the one association a standalone game mode should not be making, and they
-- cannot be varied or put behind a volume slider.
--
-- What remains here is the handful of cues that fire DURING SHOOTING, where
-- PlaySoundFrontend earns its keep for one reason that cannot be reproduced
-- from a browser: THE ENGINE MIXES IT. A hitmarker fired from CEF sits on top
-- of a firefight at full volume forever.
--
-- EVERY NAME HERE MUST BE AUDITIONED. A wrong sound-set name does not error --
-- PlaySoundFrontend simply plays nothing, exactly like a misspelled native
-- returning nil. /brsfx exists for that, and it has already caught two: WIN
-- and LOSER live in HUD_AWARDS, not GTAO_FM_EVENTS_SOUNDSET, which is why
-- those two were silent.

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
        -- NATIVE IS COMBAT ONLY.
        --
        -- Everything the player hears from the INTERFACE -- menus, verdicts,
        -- pickups, the storm -- is synthesised in the browser
        -- (ui-src/src/audio/cues.ts). GTA's frontend sounds are instantly
        -- recognisable as GTA Online's menus, which is the one association a
        -- standalone mode should not be making, and they cannot be varied or
        -- volume-controlled.
        --
        -- What stays here is the handful of cues that fire DURING SHOOTING,
        -- where PlaySoundFrontend earns its place: the engine mixes it, so it
        -- ducks against gunfire. A hitmarker fired from CEF sits on top of a
        -- firefight at full volume forever.
        ['hit']      = { set = 'HUD_MINI_GAME_SOUNDSET', name = 'CHECKPOINT_NORMAL' },
        ['hit.crit'] = { set = 'HUD_MINI_GAME_SOUNDSET', name = 'CHECKPOINT_PERFECT' },
    },
}

-- NOTE: the loot cue moved to the browser with the rest of the interface
-- audio, and the pickup sound itself went back to GTA's own PICK_UP at the
-- user's call -- it is a world event, it fires while shooting, and the engine
-- one was right. See client/inventory.lua.
