-- The Yubikey (#396, Season 2), server half: who holds one, and every way one
-- changes hands.
--
-- ═══ THE OWNER'S RULES, 2026-10-04 ═══
--
--   * An OWNED item: "an item they own and must be displayed as an icon
--     somewhere on the screen to show it's equipped, however it doesn't take up
--     an inventory slot. This means it can carry with them to another match if
--     they choose not to use it."
--   * At most one per player; a holder cannot pick up a second.
--   * "If they are killed, the Yubikey in their possession should drop on the
--     ground as a standard pickup."
--   * Sources: "a 50/50 chance in airdrops", and "a small chance in legendary
--     crates" -- both EXTRA items, so today's loot odds do not move. The
--     crates' chance changed on 2026-10-06 (round 5): "We should have the
--     same chance of yubikeys in crates as something rare" and "let's make
--     the Yubikey rare then, not legendary" -- so EVERY crate rolls one, at
--     the chance an average rare item is in a crate (below, Y.extraFor).
--   * "When they pickup a Yubikey for the first time, we need to tell them what
--     it can do and how to use it." -- since round 5 (2026-10-06) the owner's
--     own words on a tutorial-style card the player dismisses with Enter
--     (YUBIKEY_STATE's `first`; br_core/client/yubikey.lua shows it).
--   * Leaving a match alive keeps the key since round 6 (2026-10-07: "the
--     ownership of an unused Yubikey doesn't actually persist between
--     matches as it should"): BR.Config.Terminals.leaveDrops, default false.
--     True drops it where they stood, like a death.
--   * AND NOTHING TAKES A KEY ONCE ITS MATCH IS DECIDED (round 6): a death, a
--     walk-out or a disconnect in the verdict's seconds -- the winners are
--     still ALIVE until the sweep sends them home -- or at cleanup leaves the
--     key with its holder. Dropped there, it lay in loot the match was about
--     to clear, where nobody could pick it up. See `fighting` below.
--
-- ═══ WHERE IT LIVES ═══
--
-- On the PROFILE ROW (js-src/br_ddb/src/yubikey.js): `yubikey` and
-- `yubikeySeen`, read by the one connect read server/market.lua already makes
-- (BR.Market.load hands them here) and written by br:ddb:yubikeySet, whose
-- condition is the cap of one at the storage layer.
--
-- THE SESSION CACHE BELOW IS WHAT THE GAME READS, and every change writes
-- through. In memory first, because the change is happening NOW -- a key leaves
-- the ground the instant it is picked up -- and a failed write is a log line,
-- never a refusal: "a stats failure must never stop a match" is this project's
-- rule for the database, and a key is no different. The cost, stated plainly:
-- a write that fails leaves the row one step behind the session, so a key
-- picked up during an outage is not there next session and a key spent during
-- one comes back. Both are rare and both say so on the console.
--
-- ═══ A KEY ON THE GROUND IS ORDINARY LOOT ═══
--
-- kind 'yubikey', spawned through BR.Loot.spawnStack and drawn by
-- client/loot.lua like a Volts pile: the "standard pickup". The claim handler in
-- server/loot.lua hands a claim of that kind to BR.Yubikey.claim and retires the
-- entry only when this says yes, so a refused pickup leaves the key where it
-- lay.
--
-- ═══ SEASON 1 SEES NONE OF IT ═══
--
-- Every door asks BR.Season.has('terminals'). Off, nobody holds a key (the row
-- is not touched -- a key held on a Season 2 box is still there when it comes
-- back), no container rolls one, no death drops one and no client is told one
-- exists.

BR = BR or {}
BR.Yubikey = BR.Yubikey or {}

local Y = BR.Yubikey

local function cfg() return BR.Config.Terminals end
local function copy() return BR.Config.Terminals.copy end

--- Is the feature on? NIL-SAFE, so a harness without the season module has none.
--- @return boolean
local function on()
    return BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('terminals') == true
end
Y.on = on

--- Is this match still being fought -- the bus or the round itself? A key
--- leaves its holder by a death or a leave ONLY in a match that is: from the
--- verdict on (ENDED, CLEANUP) the ground it would drop on is loot about to be
--- cleared, and the player keeps what they finished the match holding (round
--- 6). Warmup is not the match either; its doors already say so.
--- @param m table|nil
--- @return boolean
local function fighting(m)
    return m ~= nil and (m.state == BR.MatchState.BUS or m.state == BR.MatchState.PLAYING)
end

--- license -> { held, seen, loaded }
local keys = {}

--- src -> license, filled when the profile arrives, so a drop or a leave can
--- write the right row after the player has gone.
local licenseOf = {}

local nextReq = 0
local pending = {}

AddEventHandler('br:ddb:yubikeySetResult', function(req, ok, extra)
    local cb = pending[req]
    if not cb then return end
    pending[req] = nil
    cb(ok, extra or {})
end)

--- Write one account's key through to its profile row. Fire and forget: the
--- answer is a console line, never a decision.
--- @param lic string
--- @param held boolean
--- @param why string
local function write(lic, held, why)
    if GetResourceState('br_ddb') ~= 'started' then
        print(('[br_core] yubikey: %s %s (%s) -- br_ddb is not started, so the profile row '
            .. 'is not written'):format(lic, held and 'gained' or 'lost', why))
        return
    end
    local req = nextReq + 1
    nextReq = req
    pending[req] = function(ok, extra)
        if ok then return end
        if extra.refused then
            -- The row is already in the state asked for: nothing to undo.
            print(('[br_core] yubikey: %s %s (%s) -- the row already said so (%s)')
                :format(lic, held and 'gained' or 'lost', why, tostring(extra.refused)))
        else
            print(('^1[br_core] yubikey: %s %s (%s) -- PROFILE WRITE FAILED (%s); this '
                .. 'session holds the right answer and the row does not^7')
                :format(lic, held and 'gained' or 'lost', why, tostring(extra.error)))
        end
    end
    SetTimeout(8000, function()
        if pending[req] then
            pending[req] = nil
            print(('^1[br_core] yubikey: %s %s (%s) -- no answer from br_ddb^7')
                :format(lic, held and 'gained' or 'lost', why))
        end
    end)
    TriggerEvent('br:ddb:yubikeySet', req, lic, held)
end

-- ------------------------------------------------------------- the state ---

--- The account entry for a connected player, or nil.
--- @param src integer
--- @return table|nil
local function entryOf(src)
    local lic = licenseOf[src]
    return lic and keys[lic] or nil
end

--- Does this player hold a key? False on a Season 1 server, false before the
--- profile has been read, false for anyone this file has never heard of.
--- @param src integer
--- @return boolean
function Y.holds(src)
    if not on() then return false end
    local k = entryOf(src)
    return k ~= nil and k.loaded == true and k.held == true
end

--- Has this player's squad spent its one use in the match they are in?
--- Answered by server/terminal.lua; false while that file is absent.
--- @param src integer
--- @return boolean
local function squadUsed(src)
    return BR.Terminal ~= nil and BR.Terminal.squadUsed ~= nil
        and BR.Terminal.squadUsed(src) == true
end

--- Tell one player where they stand: their key and their squad's use, and
--- whether they are in a squad match -- the fact the world's plate picks
--- `squad_used` or its `_solo` line by (BR.TerminalSolve.pick; owner, round 2).
--- Season 1 sends nothing at all.
---
--- `first`: this push gave them their FIRST KEY EVER (round 5), and their
--- client puts up the first-pickup card. Only Y.give says so, once per
--- account; every other push leaves it out.
--- @param src integer
--- @param first boolean|nil
function Y.push(src, first)
    if not on() then return end
    TriggerClientEvent(BR.Net.YUBIKEY_STATE, src, {
        held = Y.holds(src),
        squadUsed = squadUsed(src),
        squadMatch = BR.Terminal ~= nil and BR.Terminal.squadMatch ~= nil
            and BR.Terminal.squadMatch(src) == true,
        first = first == true or nil,
    })
end

--- The profile arrived (BR.Market.load's one connect read).
---
--- A FAILED READ IS NOT AN EMPTY ROW (round 6). br_ddb answers a read it could
--- not make with the empty inventory and an `error`, and the market a read
--- that never came back (br_ddb down, the 6 s timeout) with nil -- and both
--- used to replace this account's entry with "no key". On a reconnect that is
--- the key this session already knew it held, gone for the session. A failed
--- read now keeps what this session knows of the account; one it has never
--- seen holds nothing, as before, so a pickup still works (and its write,
--- refused by a row that does hold one, leaves both saying held).
--- @param src integer
--- @param lic string
--- @param i table|nil  br_ddb's inventory answer, or nil when it failed
--- @param extra table|nil  the read's extra answer; `error` when it failed
function Y.loaded(src, lic, i, extra)
    if type(lic) ~= 'string' or lic == '' then return end
    licenseOf[src] = lic
    local failed = type(i) ~= 'table' or (type(extra) == 'table' and extra.error ~= nil)
    if failed and keys[lic] and keys[lic].loaded then
        print(("[br_core] yubikey: %s's profile read failed (%s) -- keeping this session's "
            .. 'answer, %s'):format(lic, tostring(type(extra) == 'table' and extra.error or 'no answer'),
            keys[lic].held and 'a key held' or 'no key'))
        Y.push(src)
        return
    end
    keys[lic] = {
        held = not failed and i.yubikey == true,
        seen = not failed and i.yubikeySeen == true,
        loaded = true,
    }
    Y.push(src)
end

--- Give this player a key.
--- @param src integer
--- @param why string  for the console: 'pickup', 'dev'
--- @return boolean ok, string|nil reason  'off' | 'loading' | 'holding'
function Y.give(src, why)
    if not on() then return false, 'off' end
    local k = entryOf(src)
    if not k or not k.loaded then return false, 'loading' end
    if k.held then return false, 'holding' end
    k.held = true
    local first = not k.seen
    k.seen = true
    write(licenseOf[src], true, why)
    -- ONCE PER PLAYER, EVER: the profile row's yubikeySeen, set by the write
    -- above. THE FIRST-PICKUP CARD (round 5): the owner's words (copy
    -- first_pickup) on br_ui's tutorial card, up until the player presses
    -- Enter -- the push says `first`, and their client does the rest. No
    -- toast: the card is the message.
    Y.push(src, first)
    print(('[br_core] yubikey: %s (%d) now holds a key (%s%s)')
        :format(GetPlayerName(src) or '?', src, why, first and ', first ever' or ''))
    return true, nil
end

--- The account a connected player's key is held under, or nil before the
--- profile has been read. server/terminal.lua keeps it with a run that spent
--- the key, so a refund reaches the right row however the source has moved.
--- @param src integer
--- @return string|nil
function Y.licenseOf(src)
    return licenseOf[src]
end

--- Give a key back to the account a terminal run took it from, when the run's
--- effect could not happen (server/terminal.lua; owner, round 2: a run is
--- paid for when it is accepted and carried out seconds later).
---
--- BY THE ACCOUNT, NOT THE SOURCE: the player may have disconnected in the
--- seconds between, and the account's entry outlives the source (see the
--- playerDropped handler below). Never the first-pickup message -- this
--- account has had a key. Refused when it already holds one again (a key
--- picked up while the run loaded): the cap of one stands.
--- @param lic string|nil
--- @param why string  for the console
--- @return boolean
function Y.restore(lic, why)
    local k = type(lic) == 'string' and keys[lic] or nil
    if not (on() and k and k.loaded) or k.held then
        print(('[br_core] yubikey: %s not given back (%s) -- %s'):format(tostring(lic), tostring(why),
            not k and 'no such account this session' or k.held and 'it holds one already' or 'off'))
        return false
    end
    k.held = true
    write(lic, true, why)
    for src, l in pairs(licenseOf) do
        if l == lic then Y.push(src) end
    end
    print(('[br_core] yubikey: %s holds its key again (%s)'):format(lic, tostring(why)))
    return true
end

--- Take this player's key away.
--- @param src integer
--- @param why string  'used' | 'died' | 'left' | 'dev'
--- @return boolean  false when they held none
function Y.take(src, why)
    local k = entryOf(src)
    if not (on() and k and k.loaded and k.held) then return false end
    k.held = false
    write(licenseOf[src], false, why)
    Y.push(src)
    print(('[br_core] yubikey: %s (%d) no longer holds a key (%s)')
        :format(GetPlayerName(src) or '?', src, why))
    return true
end

-- ---------------------------------------------------------- on the ground ---

--- A Yubikey as a loot stack. `count` is 1 and means nothing: one key is one
--- entry.
---
--- RARE, so it glows blue on the ground and its label reads rare, like any rare
--- item: "the Yubikey ground glow should be blue for rare like anything else"
--- (owner, 2026-10-07). It was legendary, gold, from #396 -- and round 5 had
--- already made it as common in crates as a rare item ("let's make the Yubikey
--- rare then, not legendary"). A crate it bursts out of still shows its own
--- contents' rarity (Y.extraFor).
--- @return table
function Y.stack()
    local art = cfg().art or {}
    return {
        item = 'yubikey', kind = 'yubikey',
        rarity = BR.Rarity.RARE, count = 1,
        prop = art.keyProp,
    }
end

--- Drop a key at this spot in this match.
--- @param m table
--- @param x number @param y number @param z number
--- @param standZ number|nil  ground a ped was measured on (see BR.Loot.spawnStack)
--- @return table|nil entry
function Y.dropAt(m, x, y, z, standZ)
    if not (m and m.loot and BR.Loot and BR.Loot.spawnStack) then return nil end
    return BR.Loot.spawnStack(m, Y.stack(), x, y, z, nil, standZ)
end

--- A claim on a ground key (server/loot.lua's LOOT_CLAIM, kind 'yubikey').
--- Every other check -- the state, the rate, the subscription, the reach --
--- that handler has already made.
---
--- REFUSED, AND THE KEY STAYS, for a holder ("a holder can't pick up a
--- second"), who is told so; and silently for a player whose profile has not
--- arrived, who cannot yet be known not to hold one.
--- @param src integer
--- @return boolean  true when it was taken and the entry should be retired
function Y.claim(src)
    if not on() then return false end
    local ok, reason = Y.give(src, 'pickup')
    if ok then return true end
    if reason == 'holding' then
        BR.Server.notify(src, copy().already_holding, 'warn')
    end
    return false
end

--- Where a player who is leaving the fight with a key drops it.
--- @param m table
--- @param src integer
--- @param e table  their roster entry, with the position still on it
--- @param why string
local function dropFor(m, src, e, why)
    if not Y.take(src, why) then return end
    local p = e and e.pos
    if not p then
        print(('^3[br_core] yubikey: %s (%d) lost their key (%s) with no position on record '
            .. '-- nothing dropped^7'):format(GetPlayerName(src) or '?', src, why))
        return
    end
    -- AT THEIR FEET, vouched by the same ped root BR.Loot.deathBox scatters the
    -- rest of their kit around -- so the key lies in the middle of the ring.
    local entry = Y.dropAt(m, p.x, p.y, p.z, p.z)
    print(('[br_core] yubikey: dropped where %s (%d) stood (%s) -- entry %s')
        :format(e.name or '?', src, why, tostring(entry and entry.id)))
end

--- Eliminated (server/combat.lua, on the same edge the death box is built):
--- the key drops. A leaver (`cause == 'left'`, walking out mid-match) drops it
--- only while BR.Config.Terminals.leaveDrops says so.
--- @param m table
--- @param src integer
--- @param cause string
function Y.onEliminated(m, src, cause)
    if not on() or not Y.holds(src) then return end
    if cause == 'left' and cfg().leaveDrops ~= true then return end
    if not fighting(m) then
        print(('[br_core] yubikey: %s (%d) keeps their key (%s with match %s already %s)')
            :format(GetPlayerName(src) or '?', src, tostring(cause), tostring(m and m.id),
                tostring(m and m.state)))
        return
    end
    dropFor(m, src, BR.Roster.get(src), cause == 'left' and 'left' or 'died')
end

--- THE OTHER WAY OUT OF A MATCH: a disconnect. BR.Roster.remove calls this
--- before it takes the entry away -- a disconnect never reaches
--- BR.Combat.eliminate, so without this a holder about to lose a fight could
--- quit and keep the key.
---
--- IN THE FIGHT ONLY: alive, downed, on the bus or in the air. Warmup is not
--- the match (the pad is not where a key is lost), and a player already out
--- dropped theirs when they died.
--- @param src integer
--- @param e table  the roster entry, state not yet changed
function Y.leaving(src, e)
    if not on() or not e or not e.matchId then return end
    -- `source` in playerDropped is a STRING (server/guild.lua's note), and
    -- every table here is keyed by the number.
    src = tonumber(src) or e.src
    if not src then return end
    local st = e.state
    local inFight = st == BR.PlayerState.ALIVE or st == BR.PlayerState.DBNO
        or st == BR.PlayerState.BUS or st == BR.PlayerState.FREEFALL
        or st == BR.PlayerState.GLIDE
    if not inFight or not Y.holds(src) then return end
    if cfg().leaveDrops ~= true then return end
    local m = BR.Server.matchById and BR.Server.matchById(e.matchId) or nil
    -- The verdict's seconds: a winner still ALIVE quitting before the sweep.
    if not fighting(m) then return end
    dropFor(m, src, e, 'left')
end

-- ----------------------------------------------------------------- sources ---

--- An extra key for this container as it opens, or nil.
---
--- Called by server/loot.lua's openChest, after the container's contents were
--- decided and before they scatter. The roll is BR.TerminalSolve.extraRoll, on
--- its own stream, so nothing else in the container changes.
---
---   the airdrop   sources.airdropChance (0.5)
---   any crate     sources.crateChance: every tier, the chance an average rare
---                 item is in a crate (owner, 2026-10-06, round 5: "let's make
---                 the Yubikey rare then, not legendary"; tools/test_yubikey.lua
---                 measures it with the real loot generator and holds the
---                 config to it)
---
--- NOT on the warmup pad: a key found there would walk into the match with
--- somebody who never fought for it. Not a death box: that is a player's kit,
--- not a crate (its kind is 'deathbox').
---
--- THE CRATE STILL SHOWS WHAT IT SHOWED. Its rarity (the glow, the label) was
--- decided from its contents when the layout was built, and this roll happens
--- only as it opens, after that -- so a crate with a key in it looks exactly
--- like one without, and the key's own glow appears only in the burst.
--- @param m table
--- @param container table  the loot entry being opened
--- @return table|nil stack
function Y.extraFor(m, container)
    if not on() or not m or not m.loot or not container then return nil end
    -- The pad's crates carry `warmup`, and the pad's zone does too
    -- (server/loot.lua's warmup()).
    if container.warmup or m.warmup then return nil end
    local odds = cfg().sources or {}
    local chance, what = nil, nil
    if container.airdrop ~= nil then
        chance, what = odds.airdropChance, 'airdrop'
    elseif container.kind == 'chest' then
        chance, what = odds.crateChance, 'crate'
    end
    if not chance then return nil end
    if not BR.TerminalSolve.extraRoll(m.loot.seed, container.id, chance) then return nil end
    print(('[br_core] yubikey: the %s %s holds a key'):format(what, tostring(container.id)))
    return Y.stack()
end

-- ------------------------------------------------------------------- doors ---

-- A late joiner, a reconnect and a restarted br_core or br_ui: the client asks
-- for everything on br:ready, and its key is part of everything.
RegisterNetEvent(BR.Net.READY)
AddEventHandler(BR.Net.READY, function()
    local src = tonumber(source)
    if src then Y.push(src) end
end)

--- A reconnect whose profile server/market.lua still has cached: no second
--- read happens, so the license's key is already here and only the new source
--- needs to be told it is theirs.
--- @param src integer
--- @param lic string
function Y.adopt(src, lic)
    if type(lic) ~= 'string' or not keys[lic] then return end
    licenseOf[src] = lic
    Y.push(src)
end

-- AFTER roster.lua's handler, which runs first (it is earlier in the manifest)
-- and has already handed a leaver to Y.leaving. THE SOURCE GOES; THE LICENSE'S
-- ENTRY STAYS -- two booleans per account that has joined since the last
-- restart -- because server/market.lua may keep that account's profile cached
-- across a reconnect and not read it again (BR.Yubikey.adopt), and a key that
-- vanished from memory while the row still held it would be a holder treated
-- as empty-handed for a whole session. A fresh read replaces it whole.
AddEventHandler('playerDropped', function()
    local src = tonumber(source)
    if src then licenseOf[src] = nil end
end)

-- ---------------------------------------------------------------- dev ---

--- For server/terminal.lua's dev command: a key given or taken by hand, with
--- the same writes and the same messages as the real thing. The profile must
--- have arrived; a box without br_ddb loads every profile empty, so it always
--- has.
--- @param src integer
--- @param give boolean
--- @return boolean ok, string|nil reason
function Y.devSet(src, give)
    if give then return Y.give(src, 'dev') end
    if Y.take(src, 'dev') then return true, nil end
    return false, 'none'
end

--- `bryubikey unseen` (round 5): this player has never had a key, as far as
--- the first-pickup card is concerned, so their next one -- `bryubikey give`
--- or a real pickup -- shows it again. THIS SESSION'S FLAG ONLY: the profile
--- row keeps its yubikeySeen, and the next grant writes it true again, so a
--- reconnect reads the row's answer as before.
--- @param src integer
--- @return boolean ok, string|nil reason  'loading'
function Y.devUnseen(src)
    local k = entryOf(src)
    if not k or not k.loaded then return false, 'loading' end
    k.seen = false
    print(('[br_core] yubikey: %s (%d) will see the first-pickup card again (dev)')
        :format(GetPlayerName(src) or '?', src))
    return true, nil
end

--- `bryubikey drop` (round 5): a key on the ground at this spot, in the loot
--- this player is looking at (their match, or the warmup pad) -- the real
--- ground pickup, so the claim, the cap of one and the first-pickup card can
--- be tested the way a player meets them. Season 2 only, like every door.
--- @param src integer
--- @param x number @param y number @param z number
--- @return table|nil entry, string|nil reason  'off' | 'nowhere'
function Y.devDrop(src, x, y, z)
    if not on() then return nil, 'off' end
    local m = BR.Loot and BR.Loot.zoneOf and BR.Loot.zoneOf(src) or nil
    if not m then return nil, 'nowhere' end
    return Y.dropAt(m, x, y, z), nil
end
