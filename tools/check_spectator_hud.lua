-- Static gate: a spectator's HUD describes the player on screen.
--
-- ═══ THE BUG ═══
--
-- "the health/shield/inventory don't show properly. They should be fully
-- populated" -- the owner, from the playtest. They WERE populated. They were
-- populated with the dead viewer's own numbers -- zero health, zero shield, an
-- inventory that dying had cleared -- because the camera changed subject and
-- the HUD did not.
--
-- ═══ WHY A TEXT GATE, AND WHAT IS TESTED PROPERLY ELSEWHERE ═══
--
-- The INVENTORY half has a real behaviour test: tools/test_client.lua loads
-- client/inventory.lua, fires the feed event and reads the envelope that comes
-- out. That is the better instrument and it is used where it reaches.
--
-- The other two halves it cannot reach:
--
--   client/state.lua  is loaded by one suite (tools/test_roster.lua) and not by
--                     the one that owns the inventory, so the vitals
--                     substitution has no home to be driven from.
--
--   server/spectate.lua's feed is not a value at all. What matters about it is
--                     WHERE the inventory goes -- one recipient, chosen by a
--                     policy already applied -- and "it was not broadcast" is
--                     not something a suite can observe.
--
-- So this reads them as text, and it is aimed at the two mistakes that would
-- not look like mistakes: a second copy of health on the wire, and an
-- inventory that leaves the server to anybody but the one watcher.
--
-- Run standalone:  lua tools/check_spectator_hud.lua

local ROOT = 'resources/[fivem-royale]/'

local failures = 0

local function fail(msg, why)
    failures = failures + 1
    io.write('FAIL  ', msg, '\n')
    if why then io.write('      ', why, '\n') end
end

--- Source with comments stripped. Every file this reads explains itself at
--- length and names the very calls being looked for -- including this gate's
--- own reasoning quoted back into them -- so a check satisfied by prose would
--- pass on a file that had deleted the code and kept the essay.
local function codeOf(src)
    src = src:gsub('%-%-%[%[.-%]%]', ' ')
    src = src:gsub('%-%-[^\n]*', '')
    return src
end

local function read(rel)
    local fh = io.open(ROOT .. rel, 'r')
    if not fh then
        fail(rel .. ' is missing')
        return nil
    end
    local s = fh:read('a')
    fh:close()
    return s
end

-- ------------------------------------------------- health and shield, client ---

local state = read('br_core/client/state.lua')
if state then
    local code = codeOf(state)

    -- THE HUD ASKS WHO IS BEING WATCHED. Without this the bars are the dead
    -- viewer's, which is the reported bug exactly.
    --
    -- THE WHOLE EXPRESSION IS PINNED, NOT THE NAME. `BR.Spectate.targetSrc`
    -- appearing somewhere is not the claim -- `local watching = nil and
    -- BR.Spectate.targetSrc` contains it, never calls it, and puts the bug
    -- straight back while every mention of the function is still in the file.
    -- That mutation escaped this gate's first draft.
    if not code:find('local watching = BR%.Spectate and BR%.Spectate%.targetSrc')
        or not code:find('BR%.Spectate%.targetSrc%(%)') then
        fail('client/state.lua does not CALL BR.Spectate.targetSrc() for the HUD',
             'the HUD would go back to drawing the dead viewer\'s own vitals')
    end

    -- IT READS THE ROSTER MIRROR, NOT A SECOND WIRE. `hp` and `armour` are
    -- already in roster.lua's PUBLIC_FIELDS and already arrive for every player
    -- in the match, so asking the server to send them again down the spectate
    -- feed would be two representations of one fact -- and the second one would
    -- be the one that goes stale.
    if not code:find('S%.roster%[watching%]') then
        fail('the spectated vitals do not come from the roster mirror',
             'a second copy of a public fact is this project\'s signature bug')
    end

    -- WHO THE BARS ARE ABOUT IS PART OF THE DEDUPE. BR.PushHud only sends when
    -- a value changed; two squadmates on the same health are the same numbers,
    -- so without this a cycle to the next target sends nothing and the HUD
    -- keeps describing the previous one.
    if not code:find('watching == lastPush%.watching') then
        fail('the HUD dedupe does not include WHO is being watched',
             'stepping to a target on identical health would not repaint')
    end
end

-- ------------------------------------------------------- the target's ped ---

local spec = read('br_core/client/spectate.lua')
if spec then
    local code = codeOf(spec)

    if not code:find('function BR%.Spectate%.targetSrc') then
        fail('client/spectate.lua does not expose the target',
             'client/state.lua reads it behind a nil-guard, so a rename here '
             .. 'fails OPEN: the HUD silently goes back to the viewer\'s vitals')
    end

    -- A CHANGE OF SUBJECT FORCES A REPAINT. Same argument as the dedupe above,
    -- from the other end.
    if not code:find('BR%.PushHud%(true%)') then
        fail('a change of spectate target does not force a HUD push')
    end

    -- AND THE INVENTORY IS FORWARDED RATHER THAN DECODED HERE. This file owns a
    -- camera; the bar is somebody else's business.
    --
    -- BOTH EDGES, COUNTED. The event name appears TWICE for two different
    -- reasons -- the forward on a push that carries one, and the explicit clear
    -- when a session stops -- so "the string is in the file" is satisfied by
    -- either one alone. Deleting the forward and keeping the clear leaves a bar
    -- that never fills; deleting the clear and keeping the forward leaves a
    -- player staring at the last loadout they watched. Both escaped a version
    -- of this gate that only looked for the name.
    if not code:find("TriggerEvent%('br:spectate:inv', d%.inv%)") then
        fail('the target\'s inventory is not forwarded to the inventory module',
             'the bar would never be given anything to draw')
    end
    if not code:find("TriggerEvent%('br:spectate:inv', nil%)") then
        fail('a session ending does not clear the spectated inventory',
             'the viewer would keep the last watched player\'s bar')
    end
end

-- --------------------------------------------------------- the server feed ---

local server = read('br_core/server/spectate.lua')
if server then
    local code = codeOf(server)

    if not code:find('BR%.Inv%.publicFor') then
        fail('the spectate feed never reads the target\'s inventory',
             'the bar has nothing to draw and goes back to the empty one')
    end

    -- ═══ THE ASSERTION THIS FILE EXISTS FOR ═══
    --
    -- An inventory is NOT in roster.lua's PUBLIC_FIELDS and must never become
    -- public: what somebody is holding is exactly what a wallhack wants. It may
    -- leave the server only on the spectate event, addressed to the ONE watcher
    -- whose right to look at this player the server has already decided.
    --
    -- A BROADCAST IS THE FAILURE. TriggerClientEvent(..., -1, ...) in this file
    -- would hand every client in the server the loadout of everybody being
    -- watched, and it would look completely correct in game -- the bar would
    -- fill in, the playtest would pass, and the leak would be invisible.
    if code:find('TriggerClientEvent%s*%(%s*[^,]+,%s*%-1') then
        fail('server/spectate.lua broadcasts to every client',
             'an inventory is not public; it goes to the one watcher the '
             .. 'server chose and to nobody else')
    end

    -- THE FEED DEDUPES. Late in a match most of the lobby is dead and watching
    -- somebody; sending five slots per session per tick anyway is the whole
    -- roster's inventory crossing the wire 4 Hz for the rest of the round.
    -- THE SIGNATURE IS COMPUTED FROM THE INVENTORY AND COMPARED TO THE STORED
    -- ONE. Both halves are pinned: `invSig` merely APPEARING is satisfied by
    -- the function's own definition, so a body that computed something else --
    -- a timestamp, a counter, a random -- would keep the name, keep the field,
    -- and send the whole payload on every tick anyway. That escaped this gate's
    -- first draft.
    if not code:find('local sig = invSig%(inv%)')
        or not code:find('sig ~= s%.invSig') then
        fail('the inventory is sent on every feed tick with no working dedupe',
             'client/state.lua makes the same argument about the HUD -- "600 '
             .. 'pointless messages a minute"')
    end

    -- A NEW TARGET RESENDS UNCONDITIONALLY. The signature is derived from
    -- CONTENTS, so two squadmates holding the same rifle produce the same one --
    -- and the push after a cycle would then send nothing, leaving the bar
    -- showing the player just stepped off.
    if not code:find('s%.invSig = nil') then
        fail('cycling to a new target does not force the inventory to resend',
             'two targets with identical loadouts would leave the bar stale')
    end
end

-- -------------------------------------------------------------- the client bar ---

local inv = read('br_core/client/inventory.lua')
if inv then
    local code = codeOf(inv)

    if not code:find('spectated or inv') then
        fail('the inventory bar does not substitute the spectated inventory',
             'this is the one place the swap may happen -- the interface has no '
             .. 'notion of spectating and must not grow one')
    end
end

if failures > 0 then
    io.write(('\ncheck_spectator_hud: %d problem(s)\n'):format(failures))
    os.exit(1)
end

io.write('ok   a spectator\'s HUD reads the watched player -- vitals off the '
    .. 'public roster,\n     inventory off the session feed, sent to one '
    .. 'watcher and deduped\n')
