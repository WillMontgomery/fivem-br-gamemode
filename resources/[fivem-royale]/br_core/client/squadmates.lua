-- Squadmate presence: minimap blips and overhead names, SQUAD ONLY.
--
-- Fortnite's rule, enforced end to end: you see your squad, and nobody else.
-- Solos see no one. Other squads see nothing of yours. The privacy boundary is
-- the SERVER's -- br:squad:pos is only ever addressed to squad members, so a
-- modified client cannot widen it; everything in this file is presentation.
--
-- Blips are drawn from SERVER coordinates (AddBlipForCoord), not from entities,
-- so a squadmate 3km away still has a blip -- the 424m scope ceiling does not
-- apply to data the server sends. Overhead names DO need the ped, so they
-- exist only while the mate is in scope: exactly the range where you can see
-- the ped to hang a name over.

BR = BR or {}

-- Colours live in BR.SquadColours (br_lib/shared/enums.lua), keyed on the
-- member index the server assigns -- stable because it sorts by server id, so
-- every client colours the squad identically. The local table this replaced
-- disagreed with the one markers.lua used, which is why a teammate's dot and
-- their destination marker were different colours (and included purple, which
-- belongs to the storm).

BR.Squadmates = BR.Squadmates or {}

local blips    = {}   -- [src] = blip handle
local tags     = {}   -- [src] = { tag = gamerTagId, ped = pedHandle }
local mates    = {}   -- [src] = latest server record for that squadmate
local peds     = {}   -- [src] = local ped handle, or absent when out of scope
local lastPush = 0
-- Mates whose name is drawn BY US rather than by the engine, because they are
-- on the floor and a gamer tag cannot be lowered onto them.
-- [src] = { ped = handle, text = 'Alice [DOWN]', dim = boolean, downed = boolean }
local low      = {}

-- THE PLAYER'S INTERFACE SIZE, FOR THE NAMES THIS FILE DRAWS ITSELF.
--
-- Owner, 2026-08-17: "can you make the playernames font size respect our
-- player's preference too?" -- the same preference the HUD and the DUI prompts
-- already follow.
--
-- BOTH HALVES, MULTIPLIED TOGETHER, because that is what the other two
-- surfaces actually do:
--
--   the HUD's uiScale multiplies the ROOT font size (index.css), so HUD prose
--   grows with it, and textScale is a further multiplier that `.tscale` applies
--   on top. HUD prose is therefore ui * text.
--   a DUI prompt's sprite is multiplied by uiScale in Lua (client/dui.lua), and
--   the page multiplies its label by textScale inside a texture that is then
--   drawn at that sprite size -- so DUI prose is ui * text as well.
--
-- An overhead name has no plate to break and no layout to push off screen: its
-- size IS its text size, so following only one half would make it the one piece
-- of prose in the game that disagrees with the other two.
--
-- THE SAME CHANNEL client/dui.lua USES, deliberately -- br_ui owns the value
-- and fires `br:settings:changed` on every push and save, and answers
-- `br:settings:request`. See the settings block at the bottom of this file.
local prefs = { ui = 1.0, text = 1.0 }

--- A squadmate's LOCAL ped handle, or 0 when they are not streamed in.
---
--- ONE RESOLVER FOR THE WHOLE CLIENT, and that is the point of it existing at
--- all. Resolving a player ped needs the two scope-limited natives the verify
--- gate bans, so every file that wanted one would need its own marked
--- exception -- and a marked exception per feature is how an allowlist rots
--- into a permission. The single marked use is the tick below; everybody else
--- asks here.
---
--- A zero is never "not in the squad". It means "further away than the engine
--- streams peds", which for the one caller that matters -- reviving somebody
--- at arm's length -- is simply an answer of no.
--- @param src integer
--- @return integer
function BR.Squadmates.pedOf(src)
    local ped = peds[src]
    if not ped or ped == 0 or not DoesEntityExist(ped) then return 0 end
    return ped
end

--- The last squad beacon received for this mate, or nil.
---
--- THE BEACON IS SQUAD-ONLY AND THAT IS WHY IT CARRIES THE BLEED CLOCK. A
--- downed player's expiry is not in `PUBLIC_FIELDS` and must not be: broadcast
--- there it would tell their ENEMIES exactly how long to wait them out. It
--- arrives here instead, on the channel the server already limits to their own
--- squad, and `state.lua` folds it into the panel row.
---
--- `mates` EXCLUDES SELF, so your own row gets no clock from here. It does not
--- need one -- your own countdown is the DBNO overlay, which reads the value
--- the server sends you directly on DBNO_SET.
--- @param src integer
--- @return table|nil
function BR.Squadmates.beaconOf(src)
    return mates[src]
end

-- SKEL_Head. The BONE ID, which is what GET_PED_BONE_COORDS takes -- not the
-- bone INDEX that GetPedBoneIndex hands back, which is a different number and
-- a different native.
local HEAD_BONE = 31086

--- WHERE A LABEL BELONGS OVER A PED, WHICH IS NOT WHERE THE PED'S ORIGIN IS.
---
--- THE BUG (owner, 2026-08-17): "DUIs and playernames (on their heads) show
--- too high for DBNO players (drawing above a ped's standing height vs.
--- near-ground-level for their crawling position). The playernames thing is
--- also true for dead players."
---
--- Both labels were anchored to something that does not know which way the ped
--- is lying. A fake MP gamer tag is placed by the ENGINE at a fixed lift off
--- the ped's origin -- there is no native that moves it, which is why a downed
--- mate's name has to stop being a gamer tag entirely (see the tick below) --
--- and the revive prompt in client/dbno.lua was drawn at the origin plus a
--- constant. A crawling ped's origin is still its standing capsule's, so both
--- ended up over a head that was not there.
---
--- The head BONE is the one thing on a ped that moves with the animation, so
--- it is what both labels hang off now. For a body on the floor it is a few
--- centimetres of ground clearance; standing, it is where it always was.
--- @param ped integer
--- @return number x, number y, number z
function BR.Squadmates.headAnchor(ped)
    local c = GetEntityCoords(ped)

    if GetPedBoneCoords then
        local b = GetPedBoneCoords(ped, HEAD_BONE, 0.0, 0.0, 0.0)
        -- A bone the model does not carry answers with the entity's own
        -- position, and a ped that has gone out of scope answers with the
        -- world origin. Neither is a head, and the second one is a name
        -- floating over Los Santos harbour.
        if b and b.z and (b.x ~= 0.0 or b.y ~= 0.0) then
            return b.x, b.y, b.z
        end
    end

    -- No bone native on this build: the origin, plus a compromise between a
    -- head that is standing and one that is on the floor. Wrong in both
    -- postures rather than right in one, which is the honest degrade -- there
    -- is nothing else on a ped that knows which way it is lying.
    return c.x, c.y, c.z + 0.6
end

local PLAYER_GROUP = GetHashKey('PLAYER')

-- Every ped we have ever moved into BR_ALLY, so leaving the squad (or the
-- squad dissolving) can hand ALL of them back -- the group is no longer
-- tied to tag lifetime (see the loop below).
local allied = {}

local function dropTag(src)
    local t = tags[src]
    if t then
        RemoveMpGamerTag(t.tag)
        tags[src] = nil
    end
end

--- Hand ONE ped back: default relationship group, and damageable again.
---
--- BOTH HALVES, and the second one is the one that bites. A ped that keeps the
--- damage shield after leaving the squad is invulnerable to this client for the
--- rest of the match -- a strictly worse bug than the teamkill the shield
--- exists to stop, because it is silent and it never self-corrects. Every path
--- that stops considering a ped an ally goes through here.
local function releaseAlly(ped)
    if DoesEntityExist(ped) then
        SetPedRelationshipGroupHash(ped, PLAYER_GROUP)
        SetEntityCanBeDamaged(ped, true)
    end
    allied[ped] = nil
end

--- Hand every allied ped back. Called when the squad stops being a squad --
--- an EX-squadmate must not stay unshootable.
local function disbandAllies()
    for ped in pairs(allied) do releaseAlly(ped) end
    allied = {}
end

local function dropMate(src)
    local b = blips[src]
    if b then
        if DoesBlipExist(b) then RemoveBlip(b) end
        blips[src] = nil
    end
    dropTag(src)
    low[src]   = nil
    mates[src] = nil
    peds[src]  = nil
end

local function clearAll()
    for src in pairs(mates) do dropMate(src) end
    -- Emptied outright rather than left to dropMate: a drawn name is the one
    -- piece of squad presence with no engine handle behind it, so nothing
    -- reclaims it if an entry ever outlives its mate record.
    low = {}
    disbandAllies()
end

RegisterNetEvent(BR.Net.SQUAD_POS)
AddEventHandler(BR.Net.SQUAD_POS, function(list)
    lastPush = GetGameTimer()

    local seen = {}
    for _, m in ipairs(list or {}) do
        if m.src ~= BR.State.me.src then
            seen[m.src] = true
            mates[m.src] = m

            local b = blips[m.src]
            if not b or not DoesBlipExist(b) then
                b = AddBlipForCoord(m.x + 0.0, m.y + 0.0, 0.0)
                SetBlipSprite(b, 1)
                SetBlipScale(b, 0.85)
                SetBlipColour(b, BR.SquadColour(m.i).blip)
                SetBlipAsShortRange(b, false)   -- squadmates matter at any range
                BeginTextCommandSetBlipName('STRING')
                AddTextComponentSubstringPlayerName(m.name)
                EndTextCommandSetBlipName(b)
                blips[m.src] = b
            else
                SetBlipCoords(b, m.x + 0.0, m.y + 0.0, 0.0)
            end

            -- A dead mate's blip STAYS, dimmed. Where they went down is the
            -- whole reason to keep it; a full-brightness dot would read as a
            -- live teammate to rotate to. Set unconditionally rather than on
            -- the state edge -- four native calls a second is nothing, and an
            -- edge test cannot cover the blip that was born dead (a mate who
            -- died while this client was out of the squad push).
            local dead = m.state == BR.PlayerState.DEAD
                or m.state == BR.PlayerState.SPECTATING
            SetBlipAlpha(blips[m.src], dead and 120 or 255)
        end
    end

    -- Anyone the server stopped sending is out -- died, left, next match's
    -- squads reshuffled. The push IS the membership list.
    for src in pairs(mates) do
        if not seen[src] then dropMate(src) end
    end
end)

-- Overhead names, ally grouping, and staleness.
--
-- The server goes quiet instead of sending an empty list when a squad stops
-- being a squad (last mate died, match ended while the job was between
-- pushes), so silence longer than a few pushes means "no squad" -- without
-- the staleness check the last blip of a dead squadmate would outlive them
-- indefinitely.
--
-- TICK, not SLOW: this loop is also what moves a freshly streamed-in
-- squadmate into the BR_ALLY group, and until that happens they are
-- shootable -- at 10Hz that window is a bullet or two, at 1Hz a burst.
BR.Loop.register(BR.Loop.TICK, 'squadmates.tags', function()
    if next(mates) and (GetGameTimer() - lastPush) > 3500 then
        clearAll()
        return
    end

    -- OVER A SCOPE, A NAME IS THE SAME PROBLEM THE HUD WAS.
    --
    -- Owner, 2026-08-17: "the playernames text still shows while zoomed in with
    -- a sniper. Good thing is our HUD is hidden (great! keep this!) but
    -- playernames text should not be shown during that time."
    --
    -- Read from BR.Screen.scoped rather than asking the engine again, which is
    -- the point of that flag existing: client/screen.lua owns the one answer to
    -- "is a scope scaleform up", it is deliberately narrower than "is the player
    -- aiming" (a pistol must not blank anything), and client/natives.lua already
    -- reads it the same way for the radar. Nothing about the HUD is touched
    -- here -- this only adds the overhead names to what that flag already hides.
    --
    -- Guarded, because screen.lua may not have run yet on a cold start; a nil
    -- flag means "not scoped", which is the safe default for a name.
    local scoped = (BR.Screen and BR.Screen.scoped) and true or false

    -- Who is allied THIS tick. Anything in `allied` that is missing from this
    -- set by the end of the loop has stopped being a squadmate -- left the
    -- squad, left scope, or had their ped handle replaced -- and is released
    -- below. Membership is rebuilt whole every tick rather than patched on the
    -- edges, because dropMate() alone never covered a handle change.
    local stillAllied = {}

    for src, m in pairs(mates) do
        -- Presentation-only use of scope: a name can only hang over a ped
        -- that is streamed in, and no game state is derived from whether it
        -- is. Out of scope, the coord blip above still shows where they are.
        local player = GetPlayerFromServerId(src) -- scope-ok: overhead name + local relationship group need the local ped; absence just means neither applies yet
        local ped = (player ~= -1) and GetPlayerPed(player) or 0 -- scope-ok: same presentation-only use

        -- Published for BR.Squadmates.pedOf. Written every tick rather than on
        -- the edge, because a handle changes whenever a mate respawns or
        -- re-enters scope and a cached stale one is worse than none.
        peds[src] = (ped ~= 0) and ped or nil

        -- SQUAD-LEVEL PEACE IS NOT PRESENTATION -- and it is re-asserted
        -- EVERY tick, for every streamed-in mate, in every state. The old
        -- version set the group once, inside the tag path, only after the
        -- mate had jumped -- so a handle change (or any engine-side group
        -- reset) silently made a teammate shootable again ("in squads I
        -- can kill my own teammates", live report). Ten hash-writes a
        -- second is free; a teamkill is not.
        --
        -- SET_ENTITY_CAN_BE_DAMAGED IS THE HALF THAT ACTUALLY STOPS A BULLET,
        -- AND IT IS THE WHOLE OF #115 (the false corpse).
        --
        -- The relationship group alone does NOT stop one player's bullets from
        -- damaging another player's ped -- measured here three times over
        -- (2026-08-05), which is why the undo-net further down this file
        -- exists. The undo-net repairs health AFTER the fact, and that is
        -- precisely what cannot fix a false corpse: the shooter's engine has
        -- already applied a local death, the server answers a refused
        -- weaponDamageEvent with CancelEvent(), and CancelEvent() suppresses
        -- replication while sending NO negative acknowledgement back to the
        -- firing client (citizenfx/fivem#2343, open and unimplemented). There
        -- is no message to correct with. Six rounds of correction proved that
        -- from the other end (#115).
        --
        -- So the damage must never be computed. nta (Cfx.re) on this exact
        -- symptom: "the game will generally assume that any entity NOT MARKED
        -- AS 'UNABLE TO BE DAMAGED' will have damage accepted by the remote
        -- side". This is that mark, and it is the only lever in the quote we
        -- can actually pull -- the other one, a synthesized damage reply, is
        -- the unimplemented feature above.
        --
        -- LOCAL, LIKE EVERY OTHER HALF OF THIS SCHEME. This client shields
        -- only the peds the server told it are ITS OWN squadmates. An enemy
        -- shooting the same player computes that shot on THEIR machine, where
        -- this player is nobody's teammate and carries no shield -- so enemy
        -- PvP is untouched, and a downed mate can still be finished by the
        -- people who downed them.
        --
        -- WHAT THIS DELIBERATELY DOES NOT TOUCH: NetworkSetFriendlyFireOption
        -- in client/natives.lua. See the note there before flipping it.
        if ped ~= 0 then
            SetPedRelationshipGroupHash(ped, BR.Native.ALLY_GROUP)
            SetEntityCanBeDamaged(ped, false)
            allied[ped]      = true
            stillAllied[ped] = true
        end

        -- NO NAME UNTIL THEY HAVE JUMPED: everyone shares the plane during
        -- the flight, and a tag on an invisible rider rendered as a name
        -- floating over the fuselage. Pre-drop there is nothing to label.
        --
        -- DEAD AND DOWNED MATES ARE STILL LABELLED. Nothing hides faster in a
        -- firefight than the question "where did my teammate go down", and the
        -- corpse is the answer. The state is written into the tag so it reads
        -- at a glance rather than being a name that mysteriously stopped
        -- moving (user report, 2026-08-05: could not see dead squadmates).
        local e = BR.State.roster[src]
        local st = e and e.state
        local jumped = st == BR.PlayerState.FREEFALL
            or st == BR.PlayerState.GLIDE
            or st == BR.PlayerState.ALIVE
            or st == BR.PlayerState.DBNO
            or st == BR.PlayerState.DEAD
            or st == BR.PlayerState.SPECTATING

        local mark = ''
        if st == BR.PlayerState.DBNO then mark = ' [DOWN]'
        elseif st == BR.PlayerState.DEAD or st == BR.PlayerState.SPECTATING then
            mark = ' [DEAD]'
        end

        -- A GAMER TAG CANNOT BE LOWERED, SO A BODY ON THE FLOOR DOES NOT GET
        -- ONE (owner, 2026-08-17: names "drawing above a ped's standing height
        -- vs. near-ground-level for their crawling position... also true for
        -- dead players").
        --
        -- CREATE_FAKE_MP_GAMER_TAG hands the label to the engine, and the
        -- engine hangs it off the ped's ORIGIN at a lift of its own choosing --
        -- there is no SET_MP_GAMER_TAG_HEIGHT and there never was. A downed
        -- ped's origin is its standing capsule's, because the crawl is an
        -- animation rather than a posture the engine knows about, so the tag
        -- floats where the head would be if they stood up.
        --
        -- So the two upright states keep the engine's tag -- it is the proven
        -- path, it fades and occludes the way every other name in the game
        -- does -- and the two floor states get a name this file draws itself,
        -- at the head bone, in the loop below. The seam is deliberate: the
        -- common case is not being rewritten to fix the uncommon one.
        local onFloor = st == BR.PlayerState.DBNO
            or st == BR.PlayerState.DEAD
            or st == BR.PlayerState.SPECTATING

        if ped ~= 0 and jumped and not onFloor then
            low[src] = nil
            local t = tags[src]
            -- Re-tag when the ped handle changes (respawn or re-entering
            -- scope hands the mate a new ped, and the old tag dies with the
            -- old handle) OR when the mark changes -- a gamer tag's text is
            -- fixed at creation, so "Alice" becoming "Alice [DEAD]" is a new
            -- tag or it is nothing.
            if not t or t.ped ~= ped or t.mark ~= mark then
                dropTag(src)
                local tag = CreateFakeMpGamerTag(ped, m.name .. mark,
                    false, false, '', 0)
                t = { tag = tag, ped = ped, mark = mark }
                tags[src] = t
            end

            -- Component 0 is the name, and its visibility is now written EVERY
            -- tick rather than once at creation -- the same reasoning the blip
            -- alpha above is set unconditionally. An edge test cannot cover the
            -- tag that is BORN while the player is already scoped (a mate who
            -- streams in mid-shot), and one native write per mate per tick is
            -- nothing next to a name drawn across a scope.
            --
            -- 10Hz is the same clock screen.lua toggles the HUD and the radar
            -- on, so the name leaves and returns with them rather than a beat
            -- apart.
            SetMpGamerTagVisibility(t.tag, 0, not scoped)
        elseif ped ~= 0 and jumped then
            dropTag(src)
            low[src] = {
                ped  = ped,
                text = m.name .. mark,
                -- Dimmed for the same reason their blip is: a body is a place
                -- to go, not a teammate to rotate to.
                dim  = st ~= BR.PlayerState.DBNO,
                -- STATED RATHER THAN INFERRED FROM `dim`. The draw loop needs
                -- to know whether this body can be picked up (see the revive
                -- clash there), and `not e.dim` happens to answer that today
                -- only because dim is currently defined as "not downed". Two
                -- facts sharing one field is how the next edit to the dimming
                -- rule silently changes the suppression rule.
                downed = st == BR.PlayerState.DBNO,
            }
        else
            dropTag(src)
            low[src] = nil
        end
    end

    -- ANYONE WHO STOPPED BEING AN ALLY GETS THEIR BODY BACK.
    --
    -- dropMate() cannot do this on its own: it fires on the src, and by then
    -- the ped handle it would need may already have been replaced (respawn,
    -- re-stream) -- so the shielded handle would be orphaned, still shielded,
    -- with nothing left pointing at it. Reconciling handles against the set
    -- built this tick catches all four exits: left the squad, squad dissolved,
    -- left scope, handle changed.
    --
    -- The re-stream case costs one tick of a shootable teammate, which is the
    -- same window the relationship group has always had and the reason this
    -- loop is TICK rather than SLOW.
    for ped in pairs(allied) do
        if not stillAllied[ped] then releaseAlly(ped) end
    end
end)

-- THE NAMES THE ENGINE WILL NOT DRAW LOW ENOUGH.
--
-- One line of text pinned to the head bone of every downed or dead mate in
-- scope. SetDrawOrigin is the same projection client/dui.lua draws the crate
-- prompt through -- the position is a world point and the renderer does the
-- rest -- so this adds no maths that can be got wrong, only a Z that follows
-- the body instead of the capsule.
--
-- FRAME, and it has to be: a draw call lasts exactly one frame, and this is
-- welded to a ped that is being dragged along the ground by the player it
-- belongs to.
--
-- SetDrawOrigin is documented as good for 32 different origins per frame, and
-- this loop can want at most three of them -- a squad is four people and one of
-- them is you. The loot prompt and the revive prompt are two more. There is no
-- budget problem here and there cannot be one, because the squad size is the
-- ceiling.
local NAME_LIFT = 0.30    -- clearance above the head bone, in metres
local NAME_FAR  = 120.0   -- past this a body is a blip, not a label

--- @param x number
--- @param y number
--- @param z number
--- @param s string
--- @param scale number
--- @param alpha integer
local function worldName(x, y, z, s, scale, alpha)
    SetDrawOrigin(x, y, z, 0)
    SetTextFont(4)
    SetTextScale(0.0, scale)
    SetTextColour(255, 255, 255, alpha)
    SetTextCentre(true)
    SetTextDropshadow(0, 0, 0, 0, 255)
    SetTextEdge(1, 0, 0, 0, 205)
    SetTextDropShadow()
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(s)
    EndTextCommandDisplayText(0.0, 0.0)
    ClearDrawOrigin()
end

BR.Loop.register(BR.Loop.FRAME, 'squadmates.lownames', function()
    if not next(low) then return end

    -- SCOPED: NOTHING OVERHEAD, the same rule the engine tags follow in the
    -- tick above and the HUD follows in screen.lua. Checked per FRAME here
    -- rather than inherited from the tick because this loop is per frame: a
    -- flag sampled at 10Hz and drawn at 60 would leave up to six frames of name
    -- across the scope every time the player raises it.
    if BR.Screen and BR.Screen.scoped then return end

    local me = GetEntityCoords(PlayerPedId())

    -- THE NAME AND THE REVIVE PROMPT ARE THE SAME POINT ON THE SCREEN, AND ONE
    -- OF THEM HAS TO GO (owner, 2026-08-17: "when going in for the revive, the
    -- playernames text is shown at the exact same position as the DUI,
    -- resulting in an overlap effect").
    --
    -- It is the cost of the previous fix, not a new fault. Both labels used to
    -- hang off the ped's ORIGIN and were moved to the head bone the same round,
    -- because a crawling ped's origin is still its standing capsule's and both
    -- were drawing above a head that was not there. They now agree about where
    -- the head is -- to within five centimetres, NAME_LIFT 0.30 against
    -- client/dbno.lua's dbnoPromptLift 0.35 -- and the prompt is a DUI sprite
    -- roughly 16% of the screen's height tall, centred on that point. Five
    -- centimetres of world does not separate them at revive range: the name
    -- lands inside the plate.
    --
    -- SUPPRESSED RATHER THAN OFFSET, for two reasons. The prompt's own label IS
    -- this player's name (dbno.lua sets `label = e.name`), so nothing is lost --
    -- the name is still on screen, in a box, in the place the eye is already
    -- looking. And an offset would have to be a WORLD lift converted through a
    -- SCREEN-space sprite whose size does not change with distance, so the
    -- clearance that works at arm's length is a name in the sky at twenty
    -- metres. There is no constant that is right at both.
    --
    -- THE TEST MIRRORS dbno.lua's nearestDowned RATHER THAN GUESSING AT IT: I am
    -- ALIVE and in a squad, the body is DOWNED, and it is within dbnoReviveDist
    -- of my ped -- the same two positions, differenced the same way, against the
    -- same config number, so the name leaves on the frame the prompt arrives.
    -- What is deliberately NOT copied is the nearest-of test: with two mates
    -- down inside one and a half metres of each other only one is prompted for,
    -- and hiding both names is better than drawing one of them through a plate.
    --
    -- It cannot suppress a name for a prompt that is not there: every clause is
    -- a precondition of dbno.lua drawing one, so a false positive here is
    -- impossible in the direction that costs information.
    local mine = BR.State.me
    local canRevive = mine.state == BR.PlayerState.ALIVE and mine.squadId ~= nil
    local reach = (BR.Config.Match and BR.Config.Match.dbnoReviveDist) or 1.5

    for src, e in pairs(low) do
        if not DoesEntityExist(e.ped) then
            -- The mate walked out of scope between the tick and this frame.
            -- The tick will drop the entry; drawing at a dead handle would
            -- put the name at the world origin in the meantime.
            low[src] = nil
        else
            local x, y, z = BR.Squadmates.headAnchor(e.ped)
            z = z + NAME_LIFT
            local d = #(GetEntityCoords(e.ped) - me)

            -- BEHIND THE CAMERA IS NOT A PLACE TO DRAW. SetDrawOrigin projects
            -- whatever it is given, including points behind the viewer, which
            -- come out smeared across the edge of the screen. The gamer tag
            -- this replaces was culled by the engine; this is that cull, done
            -- by hand, and it is guarded because a build without the native
            -- should show names rather than throw on every frame.
            local onScreen = (not IsSphereVisible)
                or IsSphereVisible(x, y, z, 0.5)

            -- The revive prompt owns this spot while it is up. See the block
            -- above the loop.
            local promptHasIt = canRevive and e.downed and d <= reach

            if d <= NAME_FAR and onScreen and not promptHasIt then
                -- ...AND THEN THE PLAYER'S OWN PREFERENCE, LAST -- after the
                -- distance clamp, not inside it, exactly as client/dui.lua
                -- applies it to a sprite. Inside, the clamp would eat it: a
                -- mate at 10m is already sitting on the 0.34 ceiling, so a
                -- player who asked for larger text would get nothing at every
                -- distance that matters. Outside, a name at 1.15 is 15% larger
                -- than the same name at 1.00 whatever the distance term did.
                worldName(x, y, z, e.text,
                    BR.Clamp(0.34 * (10.0 / math.max(d, 4.0)), 0.16, 0.34)
                        * prefs.ui * prefs.text,
                    e.dim and 150 or 235)
            end
        end
    end
end)

-- FRIENDLY FIRE IS UNDONE, BECAUSE IT CANNOT BE PREVENTED HERE.
--
-- The relationship-group scheme (BR_ALLY + SetCanAttackFriendly) governs AI
-- aggression and melee, and it does NOT stop one player's bullets from
-- damaging another's ped -- which is why teamkilling survived being "fixed"
-- twice (user, 2026-08-05, third report). GTA's own answer is the team system,
-- which this gamemode does not use, so the honest fix at this stage is to
-- notice the damage and put the health back.
--
-- This is a CLIENT-SIDE net and it is temporary: M6 moves damage behind
-- server-side validation, where a shot at a squadmate is simply never applied.
-- Until then, restoring is the difference between a squad that works and one
-- that does not.
--
-- FRAME, not TICK: at 10Hz an automatic weapon lands several rounds between
-- samples, and restoring to a health value that was already three bullets old
-- would leak damage. The per-mate scan only runs on a frame where health
-- actually dropped, so the ordinary cost is two native reads.
local lastHp, lastArmour = nil, nil

BR.Loop.register(BR.Loop.FRAME, 'squadmates.noff', function()
    local st = BR.State.me.state
    if st ~= BR.PlayerState.ALIVE and st ~= BR.PlayerState.WARMUP then
        lastHp, lastArmour = nil, nil
        return
    end

    local ped     = PlayerPedId()
    local hp      = GetEntityHealth(ped)
    local armour  = GetPedArmour(ped)
    local prevHp, prevArmour = lastHp, lastArmour
    lastHp, lastArmour = hp, armour

    if not prevHp then return end

    -- HasEntityBeenDamagedByEntity IS A STICKY FLAG, not "was I hit this
    -- frame". It stays true until the damage record is cleared, so a
    -- squadmate who bumped you in a car thirty seconds ago would still read
    -- as your attacker when an ENEMY finally shoots you -- and their damage
    -- would be undone.
    --
    -- So the record is cleared EVERY frame a mate flag is set, not only when
    -- something was restored. That narrows the window to a single frame: for
    -- a false positive an enemy's bullet and a teammate's would have to land
    -- inside the same frame. It is not zero, and it is the honest limit of
    -- doing this client-side -- M6's server-side validation replaces the
    -- whole approach with never applying the shot in the first place.
    local byMate = false
    for src in pairs(mates) do
        local player = GetPlayerFromServerId(src) -- scope-ok: undoing damage needs the attacker's local ped; out of scope they cannot have shot us
        local matePed = (player ~= -1) and GetPlayerPed(player) or 0 -- scope-ok: same
        if matePed ~= 0 and HasEntityBeenDamagedByEntity(ped, matePed, true) then
            byMate = true
        end
    end

    if byMate then ClearEntityLastDamageEntity(ped) end
    if not byMate then return end
    if hp >= prevHp and armour >= prevArmour then return end

    if hp < prevHp then SetEntityHealth(ped, prevHp) end
    if armour < prevArmour then SetPedArmour(ped, math.floor(prevArmour)) end
    lastHp, lastArmour = prevHp, prevArmour
end)

-- IN THE LOBBY YOU SEE EXACTLY ONE PERSON: YOURSELF.
--
-- The lobby is one shared routing bucket standing on one mark, so every other
-- lobby player's ped streams in on top of yours. Three attempts to hide them
-- failed, and the reason each failed is worth writing down, because they are
-- all the same mistake in different clothes:
--
--   1. The OWNER hides itself with SetEntityVisible. Visibility is a
--      NETWORKED property, so it also hides them from themselves -- and the
--      lobby is now a character shot, so that is the one thing we cannot do.
--   2. Each client hides the OTHERS with SetEntityVisible, at 10Hz. Also a
--      networked write, and the owner asserts its own visibility every FRAME
--      -- so the owner wins 6 times out of 7 and everyone flickers or simply
--      stays visible.
--   3. The owner calls _NETWORK_SET_ENTITY_INVISIBLE_TO_NETWORK on itself.
--      The native that describes exactly what we want, and widely reported
--      not to work under OneSync (cfx forum, 2024-2025). It did not.
--
-- SET_ENTITY_LOCALLY_INVISIBLE is the one that cannot lose, and the reason is
-- in its own documentation: "sets the provided entity not visible FOR
-- YOURSELF for the CURRENT FRAME". It is not a property at all -- there is
-- nothing for the owner to overwrite and nothing to replicate. It just has to
-- be re-asserted every frame, which is why every previous attempt on a TICK
-- loop was structurally unable to work.
--
-- FRAME, and gated on MY OWN STATE rather than on each other player's. If I
-- am in the lobby then everyone in my scope is in the lobby with me -- a
-- player in a match is in a different routing bucket and cannot be near me --
-- so "hide everyone else" is both simpler and more robust than consulting a
-- roster mirror that may be a beat behind. Outside the lobby the loop does
-- nothing but read one state field.
--
-- No bookkeeping and nothing to un-hide: the flag lasts one frame, so the
-- moment this stops calling, they are visible again.
BR.Loop.register(BR.Loop.FRAME, 'squadmates.lobbyhide', function()
    if BR.State.me.state ~= BR.PlayerState.LOBBY then return end

    local me = PlayerId()
    for _, player in ipairs(GetActivePlayers()) do -- scope-ok: presentation-only hiding of co-located lobby peds
        if player ~= me then
            local ped = GetPlayerPed(player) -- scope-ok: same presentation-only use
            if ped and ped ~= 0 then
                SetEntityLocallyInvisible(ped)
            end
        end
    end
end)

-- Match over: the squad no longer exists, so neither does its presence.
RegisterNetEvent(BR.Net.STATE)
AddEventHandler(BR.Net.STATE, function(d)
    if d.state == BR.MatchState.ENDED
       or d.state == BR.MatchState.CLEANUP
       or d.state == BR.MatchState.WAITING then
        clearAll()
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    clearAll()
end)

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

--- Coerce one preference off the wire. Never throws, never returns nil.
---
--- The same widened band client/dui.lua uses, and for the same reason: br_ui
--- owns the REAL range (0.80..1.30 and 0.90..1.15, clamped in its settings.lua
--- before it stores), and repeating those exact numbers here would give the
--- project a third clamp to keep in step. This one only exists to stop a
--- hand-fired event or a stale build putting a nil, a NaN or a 40x name on the
--- frame path.
--- @param v any
--- @param fallback number
--- @return number
local function pref(v, fallback)
    v = tonumber(v)
    if not v or v ~= v then return fallback end   -- nil, or NaN, which compares false to itself
    if v < 0.5 then return 0.5 end
    if v > 2.0 then return 2.0 end
    return v
end

--- THE SAME EVENT client/dui.lua AND client/voice.lua ALREADY LISTEN TO, fired
--- by br_ui's client/settings.lua on every push and every save.
---
--- NOTHING TO PUSH ANYWHERE. Unlike a DUI -- which is a second browser that has
--- to be told -- the name is drawn by this file, per frame, from this table. So
--- changing it changes the next frame, for every mate already on screen and
--- every one that streams in later. There is nothing to miss and no page to be
--- half-started.
AddEventHandler('br:settings:changed', function(s)
    if type(s) ~= 'table' then return end
    prefs.ui   = pref(s.uiScale, prefs.ui)
    prefs.text = pref(s.textScale, prefs.text)
end)

--- ASK, RATHER THAN WAIT -- and ask FROM THIS FILE rather than leaning on
--- client/dui.lua's identical request.
---
--- br_ui pushes on `br:ui:ready`, which covers a fresh join and a br_ui restart
--- but NOT a `restart br_core` on its own: this file would start at 1.00 and no
--- push would ever be coming. dui.lua fires the same request from the same
--- resource event, so in practice one of the two would answer for both -- but
--- "my names are the right size because a different file happened to ask" is
--- precisely the silent half-wiring this project keeps shipping, and it breaks
--- the day dui.lua's line moves.
---
--- The cost of asking twice is one extra push, and BR.Settings.push is
--- documented idempotent: it re-sends the stored object and re-fires this
--- event, so a second answer costs a repaint and cannot desync anything.
AddEventHandler('onClientResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    TriggerEvent('br:settings:request')
end)
