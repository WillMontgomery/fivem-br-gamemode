--[[
    The in-game player list and report panel, this side of the wire.

    THIS FILE DECIDES NOTHING. It asks the server who is here, renders what
    comes back, and forwards what the player pressed. The bucket is resolved
    server-side, the categories arrive with the list, and a report is validated
    against all of it again on the far end. The remaining allowance used to
    arrive with the list too, and stopped in #142 -- the panel no longer says
    it, so nothing computes it, forwards it or declares it.

    LATCHING, NOT HELD (#95). The key is br_core's -- registered there as
    `brplayers`, rebindable in Settings like everything else -- and it is a
    `tap` because only `tap` accepts the raw-layer VK override that tilde needs.
    So this toggles rather than tracking a held key, and there is no release
    event to miss.

    IT ASKS EVERY TIME IT OPENS. A cached list would show somebody who left
    thirty seconds ago as present and, worse, hide somebody who just joined the
    match -- and the whole point of the panel is naming who is actually here.

    TWO REFUSALS LIVE HERE AND ONLY ONE OF THEM COSTS A ROUND TRIP. The lobby
    case asks the server, gets `inMatch = false` and lets go; the descent case
    (#141) never asks at all, because the client already knows which phase it is
    in and a descent is fifteen seconds long. See NO_PANEL below.

    THE PAGE CAN CLOSE THE PANEL WITH THE KEY THAT OPENED IT (#142), and it has
    to be the page that does it. Once NUI holds the cursor with keep-input off,
    the raw key layer in br_core is blind -- br_core/client/natives.lua records
    the same finding about Escape -- so the tilde that opened this panel cannot
    be seen again by anything on the Lua side. The keypress that closes it is a
    DOM keydown in PlayerList.tsx, arriving here as an ordinary PLAYERS_FOCUS
    `open = false`, which is the shape #83 used to reach GTA's pause menu from
    the lobby. Nothing in this file had to change for it: the callback that
    receives it was already the one true way in.
]]

BR = BR or {}
BR.PlayerList = {}

--- Whether the panel is currently up. Owned here because the keybind has to
--- toggle something, and RECONCILED against the focus stack at the bottom of
--- this file, because the stack is what actually knows (#121).
local open = false

--- ONE SCREEN FOR ONE PANEL, again.
---
--- It was two for a day. `players` kept game input so the roster could be read
--- on the move, and `playersReport` existed for no other reason than to NOT be
--- in BR.FocusKeepsInput -- a report HAD a text field, and with input kept
--- every keystroke in it was also a movement key, so typing a note walked you
--- off a roof. (The field itself is gone as well now, in #142. Do not go
--- looking for it: this paragraph is why the second screen existed, not a
--- description of anything that is still on the panel.)
---
--- View mode gave up keep-input too in #135 ("The player list doesn't capture
--- mouse input today. It should" -- owner, 2026-08-16), and the moment it did,
--- both modes wanted the same focus and the second screen was machinery that
--- did nothing. It is DELETED rather than left inert, here, in the resolver's
--- table and in the page's focus union: an unused branch in the one part of
--- this interface that has already been got wrong twice is not a spare part,
--- it is a thing the next reader has to disprove.
---
--- The mode is now entirely the page's business. Lua is not told about it and
--- has no reason to want to be.
local SCREEN = 'players'

--- The phases where this key does nothing (#141).
---
--- OWNER, 2026-08-16, WHILE VALIDATING #134: "we shouldn't be able to open the
--- player list while in the bus, freefall, or parachute."
---
--- It is the same argument that took GTA's weapon wheel away from those phases,
--- and it is stronger here. Aboard the bus there is nothing to say -- everybody
--- is alive, nobody has done anything yet, and the report you would file is
--- about a match that has not started. In freefall and under the canopy the
--- player is steering toward a landing spot with about fifteen seconds to
--- choose it, and a panel that takes the cursor, stops them moving and covers
--- the left third of the screen is not a feature arriving, it is the drop being
--- taken away from them.
---
--- A key that does nothing reads as a key that does not apply here. A panel
--- that opens over that reads as the game breaking.
local NO_PANEL = {
    [BR.PlayerState.BUS]      = true,
    [BR.PlayerState.FREEFALL] = true,
    [BR.PlayerState.GLIDE]    = true,
}

--- This client's own player state, as the HUD envelope last reported it.
---
--- WHY IT IS MIRRORED HERE AND NOT ASKED FOR. br_core and br_ui are separate
--- Lua states -- br_ui cannot see BR.State.me at all, and ringmaster.lua:66
--- records what happens to code that tries: "the first version of this read nil
--- forever from over there."
---
--- So this reads the fact off the wire that already carries it. br_core pushes
--- BR.Nui.HUD through `br:ui:sendLocal` whenever anything on it changes, and
--- `state` is one of the fields its change test compares -- so every transition
--- into and out of a descent phase produces one of these, by construction. It
--- is the same envelope App.tsx reads to decide the HUD is up.
---
--- IT SELF-HEALS AFTER A br_ui RESTART, which is the case a mirror usually gets
--- wrong. A restart fires `br:ui:ready`, br_core answers it by asking the
--- server for a snapshot, and the snapshot handler calls BR.PushHud(TRUE) --
--- forced, so the dedupe cannot swallow it. The gap is one round trip, and it
--- is a gap in which this reads nil.
---
--- nil MEANS "NOT KNOWN YET" AND OPENS THE PANEL. Refusing on an unknown state
--- would mean a br_ui restart in the lobby left the key dead until the player's
--- state next changed, which is a worse failure than the panel opening for a
--- moment during a descent: the server still answers, and the panel it shows is
--- correct.
local myState = nil

--- Reconcile the focus stack to the state the page asked for.
---
--- STATE, NOT TOGGLES. The page sends what it wants to be true, never "flip
--- it" -- a dropped message then costs one stale frame instead of leaving the
--- panel and the cursor permanently disagreeing, which is the failure this
--- interface has already had twice.
---
--- `open` IS WRITTEN BEFORE THE PUSH OR THE POP, and that ordering is load
--- bearing now that the handler at the bottom of this file listens to focus:
--- pushFocus/popFocus emit `br:ui:focusChanged` synchronously, so that handler
--- runs INSIDE this function. It reads `open`, and it must read the value we
--- are on our way to, not the one we are leaving.
local function apply(wantOpen)
    if wantOpen == open then return end
    open = wantOpen

    if wantOpen then
        TriggerServerEvent(BR.Net.PLAYERS_ASK)
        TriggerEvent('br:ui:pushFocus', SCREEN)
    else
        TriggerEvent('br:ui:popFocus', SCREEN)
    end
end

--- Ask the server and show the panel.
local function show()
    apply(true)
end

--- Close it, in whichever mode the page had it in. There is nothing to unwind:
--- the mode is React state on a component that unmounts with the panel, so it
--- cannot survive to be wrong the next time this opens.
local function hide()
    apply(false)
end

--- The key. One press toggles.
---
--- NOTHING IN THE LOBBY (owner, 2026-08-12). The server answers with
--- `inMatch = false` for a lobby player, and this refuses to open at all rather
--- than showing an empty panel -- an empty list reads as a broken feature,
--- where nothing happening reads as a key that does not apply here.
---
--- AND NOTHING ON THE WAY DOWN (#141). Same refusal, one phase earlier and
--- WITHOUT THE ROUND TRIP, which is the difference worth having: the lobby case
--- asks the server and declines the answer, so the panel is refused a tick
--- after the key. Here the client already knows, and a descent is exactly the
--- fifteen seconds in which a tick of stolen cursor is felt.
---
--- CLOSING IS NEVER REFUSED, only opening. A player who was reading the panel
--- during warmup and got put on the bus mid-read still has it up (the handler
--- below takes it off them, but a keypress that arrives first must not be a
--- keypress that traps them behind it).
AddEventHandler('br:ui:playersToggle', function()
    if open then hide() return end
    if NO_PANEL[myState] then return end
    show()
end)

--- The state mirror, and the one thing it does besides answer the guard above.
---
--- THE BUS TAKES THE PANEL AWAY RATHER THAN WAITING TO BE ASKED, because
--- refusing to open is only half of #141. Warmup is inside a match -- the
--- server answers `inMatch = true` there and it should, since a warmup scrapper
--- is a real thing to report -- so the panel opens legitimately on the pad, and
--- then the bus arrives. Without this the player boards it with a panel up, the
--- cursor held and their movement gone, having pressed nothing: the exact state
--- the issue is about, reached from the one direction a keypress guard cannot
--- see.
---
--- It calls hide() rather than dropping a flag, so the focus stack lets go too.
--- A panel that is merely invisible is a panel that is still holding the
--- cursor, and that is the worst bug this interface can produce.
AddEventHandler('br:ui:sendLocal', function(kind, data)
    if kind ~= BR.Nui.HUD or type(data) ~= 'table' then return end
    myState = data.state
    if open and NO_PANEL[myState] then hide() end
end)

RegisterNetEvent(BR.Net.PLAYERS_LIST)
AddEventHandler(BR.Net.PLAYERS_LIST, function(payload)
    if type(payload) ~= 'table' then return end

    if not payload.inMatch then
        -- Asked from the lobby. Release the focus we optimistically took and
        -- say nothing: there is no panel to show and no error to report.
        if open then hide() end
        return
    end

    -- `remaining` USED TO RIDE ALONG HERE and the server no longer computes it
    -- (#142). The panel stopped saying how many reports were left, so a field
    -- forwarded here would have been read by nothing at either end -- and a
    -- payload key that survives the last thing that rendered it is how a
    -- contract quietly grows a member nobody can delete.
    --
    -- AND `squadId` IS NOW STRIPPED ON ITS WAY PAST, which is the one thing this
    -- file does to the list rather than merely carrying it.
    --
    -- Owner, 2026-08-17: "I don't want players to be able to tell how many
    -- squads are left if we show them 38 players and 18 squads for example."
    --
    -- The panel drew a `squad` tag off this field and that tag is gone
    -- (PlayerList.tsx carries what it meant). Removing only the tag would have
    -- been cosmetic: `squadId` is a STABLE PER-SQUAD STRING and there is one on
    -- every row, so counting distinct values gives the exact number of squads
    -- still in the match -- no arithmetic, no inference, no modified client
    -- needed beyond reading the envelope that is already on its way to the page.
    -- The leak is the field, not the label.
    --
    -- REBUILT ROW BY ROW RATHER THAN NILLED IN PLACE, because `payload` is the
    -- table the net event handed us and mutating it would be editing somebody
    -- else's object for the benefit of ours. The four keys below are exactly
    -- what ListedPlayer declares and exactly what the panel renders; anything
    -- the server adds later has to be added here deliberately, which is the
    -- point of an allowlist over a delete.
    --
    -- THIS IS THE NARROW HALF OF THE FIX AND IT IS WORTH SAYING SO. The field is
    -- still computed and still sent over the network to this client
    -- (br_core/server/players.lua builds it into PLAYERS_LIST) -- what changes
    -- here is that it never reaches the page. Closing it at the source is a
    -- server change and is called out in the hand-over rather than done from
    -- br_ui.
    local rows = {}
    for i, p in ipairs(payload.players or {}) do
        rows[i] = {
            src   = p.src,
            name  = p.name,
            state = p.state,
            left  = p.left,
            you   = p.you,
        }
    end

    TriggerEvent('br:ui:sendLocal', BR.Nui.PLAYERS, {
        players         = rows,
        categories      = payload.categories or {},
        defaultCategory = payload.defaultCategory,
        maxTargets      = payload.maxTargets,
    })
end)

RegisterNetEvent(BR.Net.REPORT_RESULT)
AddEventHandler(BR.Net.REPORT_RESULT, function(res)
    if type(res) ~= 'table' then return end

    -- THE PANEL IS TOLD, AND SO IS THE PLAYER. The panel closes itself on a
    -- success; the toast is what survives the panel closing, and it is the
    -- thing that carries the actual promise -- that somebody will look.
    TriggerEvent('br:ui:sendLocal', BR.Nui.REPORT, {
        ok      = res.ok == true,
        filed   = tonumber(res.filed) or 0,
        refused = res.refused,
    })

    if res.ok then
        TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
            text = (tonumber(res.filed) or 0) == 1
                and 'Report sent. An admin will review it.'
                or ('%d reports sent. An admin will review them.')
                    :format(tonumber(res.filed) or 0),
            tone = 'success', key = 'report.sent', ms = 6000,
        })
        if open then hide() end
    else
        TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
            text = tostring(res.refused or 'That report could not be sent.'),
            tone = 'warn', key = 'report.refused', ms = 6000,
        })
    end
end)

RegisterNUICallback(BR.NuiCb.PLAYERS_FOCUS, function(data, cb)
    -- `report` USED TO RIDE ALONG HERE and no longer does. The page sent it so
    -- Lua could swap focus screens for the note field; with one screen there is
    -- nothing to swap, so the page stopped sending it and this stopped reading
    -- it. A field still parsed on one side and never written on the other is
    -- how a contract quietly grows a member nobody can delete.
    apply(data ~= nil and data.open == true)
    cb({ ok = true })
end)

--- Submit. FORWARDS AND NOTHING ELSE.
---
--- The client names server ids and a category string; the server resolves the
--- licenses, checks the bucket, applies the limit and refuses anything it does
--- not like. Every rule this panel appears to enforce is enforced again there,
--- because a panel is a suggestion and a server is an authority.
---
--- The callback resolves immediately: CEF promises must always resolve, and
--- the real answer arrives as REPORT_RESULT. A page that awaited the round
--- trip would hang on a dropped message.
--- `note` WENT WITH THE FIELD THAT FED IT (#142, owner: "We don't need a custom
--- text field for reports. Just the dropdown").
---
--- It is deleted rather than left optional here, and the reason is worth the
--- line: it had never reached anywhere. br_ddb writes `note: null`
--- unconditionally and has since 2026-08-14 -- so a string typed by a player
--- crossed a NUI callback, a net event, a length cap and an incident builder in
--- order to be discarded by the last thing that touched it. Leaving the
--- parameter accepted here would keep that road open for the next person who
--- assumes a field that is forwarded is a field that arrives.
RegisterNUICallback(BR.NuiCb.REPORT_SUBMIT, function(data, cb)
    TriggerServerEvent(BR.Net.REPORT_SUBMIT, {
        targets = (data and data.targets) or {},
    })
    cb({ ok = true })
end)

-- THE PANEL CAN BE TAKEN AWAY FROM UNDER US, and until now nothing here would
-- ever find out (#121).
--
-- `open` above is this file's own boolean; the focus STACK is what actually
-- decides whether the panel is on screen. Anything that empties or replaces
-- the stack without asking -- a match ending, a br_ui restart, the focus
-- watchdog, `brfocus clear`, the frontend handover in pause.lua -- left `open`
-- still saying true. The next press of the key then tried to CLOSE a panel
-- that was already gone: nothing appeared, and the player had to press twice.
--
-- br_ui/client/pause.lua carries the scar this is copied from, where the same
-- drift also stranded a stack entry nothing would ever pop (user, 2026-08-09:
-- readied up and "was brought back to the pause menu where I could not close
-- the UI"). So this calls hide() rather than just clearing the flag -- popFocus
-- is safe on a screen that does not hold focus, and letting go of both halves
-- is the whole point.
--
-- IT IS FIXABLE IN ONE LINE ONLY BECAUSE THERE IS ONE SCREEN NOW. While report
-- mode had its own, `screen` could be `playersReport` with the panel very much
-- up, so "the top is not mine" was not the same question as "am I closed" and
-- this handler would have had to know about both. Collapsing the screens is
-- what made it trivial; #135 and #121 land together for that reason.
AddEventHandler('br:ui:focusChanged', function(screen)
    if screen ~= SCREEN and open then hide() end
end)

-- A REFRESH WHILE OPEN, because a match moves. Somebody dies, somebody leaves,
-- and a panel held open through a fight would name a roster that no longer
-- exists. Two seconds matches the snapshot cadence the rest of the interface
-- already runs at.
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(2000)
        if open then TriggerServerEvent(BR.Net.PLAYERS_ASK) end
    end
end)
