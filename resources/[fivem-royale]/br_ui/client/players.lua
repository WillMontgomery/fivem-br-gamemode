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

--- The key this panel is CURRENTLY on, as a readable label, or '' when it is
--- on none.
---
--- MIRRORED FOR THE SAME REASON `myState` IS, off the same wire. The bindings
--- live in br_core/client/keybinds.lua and this is a different Lua state, so
--- BR.Keys.labelFor -- the authority every world prompt asks -- is not callable
--- from here. What IS available is the table that function feeds: BR.Keys.push
--- builds a row per binding with the key that actually works on this client and
--- sends it as BR.Nui.KEYBINDS, and it re-sends on `br:ui:ready`, on a rebind
--- and on a reset. So this follows a rebind by construction rather than by a
--- cache that has to be invalidated.
---
--- IT IS THE SAME SOURCE THE PANEL ALREADY USES. PlayerList.tsx reads the
--- `brplayers` row out of this exact envelope to know which key closes it. Two
--- readers of one table beats a second answer to the same question -- this
--- project has already shipped a prompt naming a key nothing was listening to
--- (#129), and the fix was to stop having two places that knew.
---
--- EMPTY MEANS UNBOUND AND IS NOT A GAP. `BR.Keys.push` sends '' for a binding
--- with no key, and the prompts below name the panel instead of naming a key.
--- A prompt that says "press F2" when nothing is listening on F2 turns "this
--- feature is unavailable" into "this feature is broken", and the player cannot
--- tell those apart from a chair.
local myKey = ''

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
---
--- THREE ENVELOPES ARE READ HERE, all of them ones br_core was already sending
--- to the page. This file adds no channel of its own; it listens to the wire
--- that runs past it.
AddEventHandler('br:ui:sendLocal', function(kind, data)
    if type(data) ~= 'table' then return end

    if kind == BR.Nui.HUD then
        myState = data.state
        if open and NO_PANEL[myState] then hide() end
        return
    end

    -- The key this panel is on, so the two prompts below can name it. See
    -- `myKey`: this is the same row PlayerList.tsx reads to know what closes it.
    if kind == BR.Nui.KEYBINDS then
        for _, row in ipairs(data.actions or {}) do
            if row.command == 'brplayers' then
                myKey = type(row.key) == 'string' and row.key or ''
                break
            end
        end
        return
    end

    -- THE VERDICT SCREEN IS ARRIVING, SO THE PANEL GOES (#169).
    --
    -- Owner: "the player list should be auto-dismissed when the verdict screen
    -- is shown in-game". Two full-screen surfaces at once, one of which is the
    -- end of the match -- and this one is holding the cursor, so the player is
    -- reading their placement through a roster they cannot dismiss without
    -- finding the key again.
    --
    -- HERE RATHER THAN IN React, and rather than in the state machine that
    -- ends the match. The page cannot do it: closing this panel means letting
    -- go of the FOCUS STACK, which is Lua's, and a component that merely stops
    -- rendering is a component that is still holding the mouse -- the worst bug
    -- this interface can produce, and one it has produced twice.
    --
    -- The end-of-match focus sweep in br_core/client/state.lua does pop
    -- `settings`, `locker` and `lobby`, but not this one -- and it could not
    -- have rescued us anyway: popFocus only emits `br:ui:focusChanged` when the
    -- TOP of the stack changes, so popping three screens from UNDER an open
    -- player list fires nothing and the reconciler at the bottom of this file
    -- never hears about it.
    --
    -- SUMMARY IS THE RIGHT SIGNAL, not the ENDED state. `hud.state` reaching
    -- `ended` is the match being decided; this envelope is the verdict screen
    -- actually having something to draw, and br_core only sends it to players
    -- who were in the round. A bystander watching from the lobby has no verdict
    -- screen and keeps their panel.
    if kind == BR.Nui.SUMMARY then
        if open then hide() end
        return
    end
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
    -- `src` IS GONE FROM THE ROW AND `id` HAS TAKEN ITS PLACE (#172). The row
    -- now carries an opaque per-match token the server minted; the panel ticks
    -- it and hands it straight back, and only the server can turn it into a
    -- person. Two things fall out of that and both are improvements here:
    --
    --   * a player who has LEFT is still on this list and still reportable. A
    --     server id could not have carried them -- theirs was freed the moment
    --     they dropped and is being handed to the next connection.
    --   * the panel keys its rows and its ticks on this. Server ids are
    --     recycled INSIDE one match, so a departed row and a live row could
    --     have collided on `src`: React would have seen two children with one
    --     key and ticking one name would have ticked the other.
    --
    -- The allowlist is still a REBUILD rather than a delete, so `squadId` is
    -- still dropped on the way past (the note above), and anything the server
    -- adds later still has to be added here deliberately.
    local rows = {}
    for i, p in ipairs(payload.players or {}) do
        rows[i] = {
            id    = p.id,
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

--[[
    THE TWO PROMPTS, AND THE SENTENCES ARE WRITTEN HERE (#168, #169).

    THE SERVER SENDS AN OCCASION, NEVER TEXT. Both lines name the key this panel
    is on and only this side knows which key that is -- it is rebindable, the
    engine and the raw layer can disagree about it, and a hint naming a key
    nothing is listening to is worse than no hint at all. So the wire carries
    `kind` (and, for the nudge, a display name the kill feed has already shown
    this player) and the prose is assembled against `myKey`.

    WHO GETS THEM IS NOT DECIDED HERE AND MUST NOT BE. The server withholds the
    first from the player the incident is about, and answers the second only for
    somebody who was actually killed by somebody with a case open. A client that
    decided either for itself would be a client that knows who is under
    suspicion, which is the whole thing this feature is not allowed to leak.

    THEY RENDER AS NOTICES, which is where every other server-originated line in
    this game appears, bottom of the screen beside the radar. Not the DUI prompt
    -- that is a world-anchored interaction ring for a key being HELD, and this
    is a piece of news.
]]

--- "press F2", or a way to say it that names no key at all.
local function pressPhrase()
    if myKey ~= '' then return ('pressing %s'):format(myKey) end
    -- No binding. Name the surface rather than a key, and the player can bind
    -- one in Settings -- where the same table this reads is what the screen
    -- lists.
    return 'opening the player list'
end

RegisterNetEvent(BR.Net.REPORT_HINT)
AddEventHandler(BR.Net.REPORT_HINT, function(d)
    if type(d) ~= 'table' then return end

    if d.kind == 'exists' then
        TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
            text = ('See something suspicious? You can report players by %s. '
                .. 'As a bonus, all accurate reports are rewarded with Volts.')
                :format(pressPhrase()),
            tone = 'info', key = 'report.exists', ms = 12000,
        })
        return
    end

    if d.kind == 'killer' then
        local name = type(d.name) == 'string' and d.name ~= '' and d.name or 'them'
        TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
            text = myKey ~= ''
                and ('Suspect cheating? Press %s to report %s.'):format(myKey, name)
                or ('Suspect cheating? Open the player list to report %s.'):format(name),
            tone = 'warn', key = 'report.nudge', ms = 10000,
        })
    end
end)

--- Ask whether the player who just killed us already has a case open.
---
--- THE ASK CARRIES NOTHING. Not the killer's id, not their name, not our own --
--- the server resolves the asker from `source` and their killer from its own
--- damage records. That is deliberate and it is the anti-enumeration design:
--- there is no field a modified client could put a name in, so there is nothing
--- to walk the roster WITH. See the handler in br_core/server/players.lua.
---
--- FIRED OFF THE KILL FEED because that is the message this client already gets
--- when it dies, and it is the one that carries `victimSrc`. br_core's own
--- state.lua reads the same envelope for the verdict screen's slam text; this
--- is a second reader of a broadcast, not a new channel.
---
--- ONLY FOR A PLAYER KILL. `killerSrc` is nil for the storm, a fall or a fire,
--- and there is nobody to report for those.
---
--- ONE ANSWER PER KILLER PER MATCH, and the latch is the SERVER's -- a client
--- that spams this gets the same single reply, because the rate limit cannot be
--- ours to keep.
RegisterNetEvent(BR.Net.KILL_FEED)
AddEventHandler(BR.Net.KILL_FEED, function(d)
    if type(d) ~= 'table' then return end
    if d.killerSrc == nil then return end
    if d.victimSrc ~= GetPlayerServerId(PlayerId()) then return end
    TriggerServerEvent(BR.Net.REPORT_KILLED)
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
--- The client names ROW TOKENS and a category string; the server resolves the
--- licenses, checks the bucket, applies the limit and refuses anything it does
--- not like. Every rule this panel appears to enforce is enforced again there,
--- because a panel is a suggestion and a server is an authority.
---
--- IT NAMES A TOKEN RATHER THAN A SERVER ID SINCE #172, and this side is not
--- told what a token means -- which is the point. It is the string that arrived
--- on the row, echoed back unread; the server minted it, keeps the mapping, and
--- throws it away when the match ends.
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
