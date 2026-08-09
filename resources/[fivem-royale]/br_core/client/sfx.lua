-- Interface audio.
--
-- One entry point, one table, one rate limiter. Everything that wants a sound
-- calls BR.Sfx.play('elim') and nothing else knows a sound-set name -- which is
-- what stops a wrong name being pasted into six files and fixed in five.
--
-- WHY THIS IS THIN ON PURPOSE. PlaySoundFrontend does the work; the value here
-- is the table, the throttle and the audition command. There is no mixing, no
-- queueing and no state, because a cue that needs any of those has stopped
-- being a cue and should be a music track.
--
-- FAILURE IS SILENT, WHICH IS WHY /brsfx EXISTS. A wrong sound-set name does
-- not error and does not warn: PlaySoundFrontend simply plays nothing, exactly
-- the way a misspelled native returns nil. Audition names with /brsfx and fill
-- the config from what actually plays, never from a wiki.

BR = BR or {}
BR.Sfx = {}

local lastPlayed = {}   -- cue -> GetGameTimer() of the last play
local muted = false

--- Play an interface cue.
---
--- Safe to call from anywhere, including per-frame paths: unknown cues are
--- ignored and rate-limited cues are dropped rather than queued. Dropping is
--- deliberate -- a queued hitmarker arrives after the moment it describes.
---
--- @param cue string   a key in BR.Config.Audio.cues
function BR.Sfx.play(cue)
    if muted or not BR.Config.Audio.enabled then return end

    local def = BR.Config.Audio.cues[cue]
    if not def then
        -- Once per cue, not once per call: a typo inside a frame loop would
        -- otherwise bury the console it is trying to warn in.
        if lastPlayed['?' .. cue] == nil then
            lastPlayed['?' .. cue] = 1
            print(('[br_core] sfx: unknown cue "%s"'):format(tostring(cue)))
        end
        return
    end

    local gap = BR.Config.Audio.minInterval[cue]
    if gap then
        local now = GetGameTimer()
        if (now - (lastPlayed[cue] or -math.huge)) < gap then return end
        lastPlayed[cue] = now
    end

    -- -1 = no specific sound id, we never need to stop these.
    -- false = not a network sound; every cue here is for THIS client only.
    PlaySoundFrontend(-1, def.name, def.set, false)
end

--- Silence every cue. Client-side only.
--- @param on boolean
function BR.Sfx.setMuted(on)
    muted = on and true or false
end

-- ------------------------------------------------------------- the UI ------
--
-- Menu cues come from React, because React is what knows a button was pressed.
-- Routed through here rather than played in the browser so there is ONE cue
-- table and one throttle, and so the UI never learns a sound-set name.
AddEventHandler('br:ui:sfx', function(cue)
    BR.Sfx.play(cue)
end)

-- ----------------------------------------------------------- auditioning ---
--
-- The whole reason this command exists: every name in the config is a guess
-- until it has been heard. A wrong one is indistinguishable from a working one
-- that happens to be quiet.
--
--   /brsfx                            -- play every cue in the table, in order
--   /brsfx elim                       -- play one cue by name
--   /brsfx HUD_AWARDS CHALLENGE_UNLOCKED  -- audition a raw set/name pair
RegisterCommand('brsfx', function(_, args)
    if #args == 0 then
        print('[br_core] sfx: playing every cue, 700ms apart')
        Citizen.CreateThread(function()
            for cue, def in pairs(BR.Config.Audio.cues) do
                print(('  %-16s %s / %s'):format(cue, def.set, def.name))
                -- Bypass the throttle: auditioning is exactly when you want to
                -- hear the ones that are normally rate-limited.
                PlaySoundFrontend(-1, def.name, def.set, false)
                Citizen.Wait(700)
            end
            print('[br_core] sfx: done. Anything you did not hear is a wrong name.')
        end)
        return
    end

    if #args >= 2 then
        print(('[br_core] sfx: raw %s / %s'):format(args[1], args[2]))
        PlaySoundFrontend(-1, args[2], args[1], false)
        return
    end

    local def = BR.Config.Audio.cues[args[1]]
    if not def then
        print(('[br_core] sfx: no cue "%s". Known:'):format(args[1]))
        for cue in pairs(BR.Config.Audio.cues) do print('  ' .. cue) end
        return
    end
    print(('[br_core] sfx: %s -> %s / %s'):format(args[1], def.set, def.name))
    PlaySoundFrontend(-1, def.name, def.set, false)
end, false)

RegisterCommand('brmute', function()
    muted = not muted
    print(('[br_core] sfx: %s'):format(muted and 'muted' or 'unmuted'))
end, false)
