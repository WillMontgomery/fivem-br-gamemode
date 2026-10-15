-- Locker v2 (#28, Season 2): the ped picker. Stock peds, Custom (male) and
-- Custom (female) on the MP freemode peds, and the player's saved peds.
--
-- ═══ SEASON 1 IS NOT THIS FILE ═══
--
-- "The existing Locker experience is our finished Season 1 product - make sure
-- that stays in and remains untouched" (owner, 2026-10-07). client/locker.lua
-- is that product and runs exactly as before wherever BR.Season.has('locker2')
-- is false. It asks this file two questions and nothing else:
--
--   BR.LockerV2.defer()     at its first lobby tick: hold your first apply?
--                           Yes while the season is still unknown (at most
--                           unknownWaitMs) and on Season 2.
--   BR.LockerV2.wantHash()  client/loading.lua and client/lobbyped.lua: which
--                           model are we waiting to see? nil off Season 2, so
--                           Season 1 asks its own chosen() as it always did.
--
-- This file never writes Season 1's kvp ('br:locker:ped'), reads its choice
-- only through BR.Locker.chosen(), and calls BR.Locker.apply(nil) only when a
-- live `brseason` takes a client from Season 2 back to Season 1.
--
-- ═══ THE APPLY IS THE PREVIEW, AS IN SEASON 1 ═══
--
-- Every click changes the ped in front of the lobby camera at once. A stock
-- pick is worn at once with no Save (owner's confirmed assumption). A custom
-- ped is a DRAFT held here: dirty once it differs from where it began, saved
-- through the server, discarded on close and on leaving the lobby. The worn
-- ped -- what the player rejoins with -- is the server's record
-- (server/locker2.lua), mirrored in this machine's kvp 'br:locker2:worn'.
--
-- ═══ THE PAGE IS PRESENTATION ═══
--
-- ui-src/src/screens/LockerV2.tsx ("My Looks") draws what BR.Nui.LOCKER2 says
-- and sends the br/locker2/* callbacks. Every one is checked again here, and
-- refused while the entrance walk holds the ped (BR.LobbyPed.lockerLocked),
-- while a ped is loading, or while a write is waiting on the server -- a new
-- or another saved look also while there are unsaved changes.

BR = BR or {}
BR.LockerV2 = {}

local V = BR.LockerV2
local A = BR.Appearance
local isTrue = BR.NativeTruthy

local KVP = 'br:locker2:worn'

local function C() return BR.Config.Locker2 end

--- Is Locker v2 on, in the season this client is running?
local function claims()
    return BR.Season.has('locker2')
end

local S = {
    --- The ped the player wears: { k = 's', id } or { k = 'p', id, a }.
    worn = nil,
    --- Saved peds, oldest first: { id, name, a, up, img }.
    peds = {},
    --- Whether the server has ever answered this session, and its last word.
    serverSeen = false,
    serverWorn = nil,
    store = true,
    --- The first apply: 'idle', 'waiting' (for the server's worn ped), 'done'.
    first = 'idle',
    firstAt = nil,
    --- The model we are waiting to see: 0 before the first apply has decided.
    want = 0,
    --- The last look this file put on the ped: { model, a (nil for stock), ped }.
    applied = nil,
    --- A swap in flight.
    applying = false,
    --- A wear held until the entrance walk lets go of the ped.
    pending = nil,
    --- The page.
    open = false,
    tab = nil,
    --- The custom look being edited: { sex, a, base, editing, dirty, cat, tats,
    --- hist } (`tats`: its tattoo rows, see tatRowsOf; `hist`: its Undo and
    --- Redo; `base` nil for a new look).
    draft = nil,
    --- A save, rename or delete waiting on the server: its req.
    busy = nil,
    --- A stock pick being streamed, and the press that came after it.
    loadingId = nil,
    queued = nil,
    wasLobby = false,
    wasOn = nil,
    lastLocked = nil,
}

local nextReq = 0
--- req -> id, for headshot uploads waiting on the server.
local shotReqs = {}

-- ---------------------------------------------------------------------------
-- The stock roster
-- ---------------------------------------------------------------------------

--- THE STOCK TAB IS SEASON 1'S LIST, AS SEASON 1 SENDS IT. client/locker.lua
--- drops every model this build does not have and sends the page the rest
--- (BR.Nui.LOCKER, on ready and on every change); that list is heard here as
--- it goes by, so "every option the locker has today" is the same list by
--- construction, and checking 77 models again costs nothing.
local s1List = nil
AddEventHandler('br:ui:sendLocal', function(kind, data)
    if kind == BR.Nui.LOCKER and type(data) == 'table' and type(data.peds) == 'table' then
        s1List = data.peds
    end
end)

--- Only if Season 1 has not sent its list yet: the same check it makes.
local verified = nil
local function roster()
    if s1List then
        local out = {}
        for _, p in ipairs(s1List) do
            local entry = BR.PedById(p.id)
            if entry.id == p.id then out[#out + 1] = entry end
        end
        if #out > 0 then return out end
    end
    if verified then return verified end
    verified = {}
    for _, p in ipairs(BR.Config.Peds) do
        local hash = GetHashKey(p.model)
        if isTrue(IsModelInCdimage(hash)) and isTrue(IsModelValid(hash)) then
            verified[#verified + 1] = p
        end
    end
    if #verified == 0 then verified = BR.Config.Peds end
    return verified
end

local function stockById(id)
    if type(id) ~= 'string' then return nil end
    if s1List then
        for _, p in ipairs(s1List) do
            if p.id == id then
                local entry = BR.PedById(id)
                return entry.id == id and entry or nil
            end
        end
        return nil
    end
    for _, p in ipairs(roster()) do
        if p.id == id then return p end
    end
    return nil
end

local function locked()
    return BR.LobbyPed ~= nil and BR.LobbyPed.lockerLocked ~= nil and BR.LobbyPed.lockerLocked() == true
end

--- The only state a ped is ever put on in: a model swap anywhere else is a
--- new, unarmed, frozen ped in the middle of a match.
local function inLobby()
    return BR.State.me.state == BR.PlayerState.LOBBY
end

--- Is the entrance actually walking the ped? A swap now would strand it.
local function walkingNow()
    return BR.LobbyPed ~= nil and BR.LobbyPed.walking ~= nil and BR.LobbyPed.walking() == true
end

local function pedById(id)
    for i, p in ipairs(S.peds) do
        if p.id == id then return p, i end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Putting an appearance on a ped
-- ---------------------------------------------------------------------------

--- The look's starting face (`f`, an index into BR.Config.Locker2.faces; the
--- first when absent or past the list), as the head blend's one shape.
local function headBlend(ped, a)
    local faces = C().faces[a.s]
    local shape = faces[(a.f or 0) + 1] or faces[1]
    SetPedHeadBlendData(ped, shape, shape, 0, a.sk, a.sk, 0, 0.0, 0.0, 0.0, false)
end

local function features(ped, a)
    for i = 1, A.FEATURES do SetPedFaceFeature(ped, i - 1, a.ff[i] / 100.0) end
end

local function overlay(ped, a, i)
    local o = a.o[i]
    SetPedHeadOverlay(ped, i - 1, o[1], o[2] / 100.0)
    local pal = C().overlayPalette[i - 1]
    if pal then SetPedHeadOverlayColor(ped, i - 1, pal, o[3], o[3]) end
end

local function overlays(ped, a)
    for i = 1, A.OVERLAYS do overlay(ped, a, i) end
end

local function hair(ped, a)
    SetPedComponentVariation(ped, 2, a.c[2][1], a.c[2][2], 0)
    SetPedHairColor(ped, a.h[1], a.h[2])
end

local function component(ped, a, slot)
    SetPedComponentVariation(ped, slot, a.c[slot][1], a.c[slot][2], 0)
end

local function prop(ped, a, i)
    local p, slot = a.p[i], A.PROPS[i]
    if p[1] < 0 then
        ClearPedProp(ped, slot)
    else
        SetPedPropIndex(ped, slot, p[1], p[2], true)
    end
end

-- ═══ TATTOOS (owner, 2026-10-11) ═══
--
-- br_lib/config/tattoos.lua lists them by the game's shop label key; the
-- appearance's `t` says which are on (br_lib/shared/appearance.lua). Each is
-- put on with the overlay of the look's own sex, and only where this game
-- build has its collection. A key the list does not know is skipped.
--
-- AT MOST 10 A BODY ZONE (owner, 2026-10-12: "You can just make it max 10 per
-- category"): a look is worn with the first A.TATTOOS_PER_ZONE of each zone
-- in the list's order, a draft starts with only those, the page's Add stops
-- there, and a save past it is refused here and on the server.

--- The list, indexed once: each label key's row, and whether this build has
--- its collection.
local tatIdx = nil
local function tattooIndex()
    if tatIdx then return tatIdx end
    local cfg = BR.Config.Tattoos
    local b = type(GetGameBuildNumber) == 'function' and GetGameBuildNumber() or 0
    local build = type(b) == 'number' and b or 0
    tatIdx = { byKey = {}, avail = {}, hash = { m = {}, f = {} } }
    for i, row in ipairs(cfg and cfg.list or {}) do
        tatIdx.byKey[row[1]] = i
        local need = cfg.builds and cfg.builds[row[3]]
        tatIdx.avail[i] = need == nil or build <= 0 or build >= need
    end
    return tatIdx
end

--- Row i's overlay name for a sex, or nil: that sex has none, or this build
--- lacks the set.
local function tattooFor(i, sex)
    local idx = tattooIndex()
    if not idx.avail[i] then return nil end
    local row = BR.Config.Tattoos.list[i]
    local name = row and row[sex == 'f' and 5 or 4]
    return type(name) == 'string' and name or nil
end

--- Row i's { collection hash, overlay hash } for a sex, or nil.
local function tattooHash(i, sex)
    local idx = tattooIndex()
    local cached = idx.hash[sex][i]
    if cached ~= nil then return cached or nil end
    local name = tattooFor(i, sex)
    local h = name and { GetHashKey(BR.Config.Tattoos.list[i][3]), GetHashKey(name) } or false
    idx.hash[sex][i] = h
    return h or nil
end

--- A label key's body zone, for a sex that can wear it here; nil otherwise.
local function tattooZone(key, sex)
    local i = tattooIndex().byKey[key]
    return i and tattooFor(i, sex) and BR.Config.Tattoos.list[i][2] or nil
end

--- The rows of `a`'s tattoos this ped can wear, in the list's order: the
--- first TATTOOS_PER_ZONE of each zone, and no more.
local function tattooRows(a)
    local idx = tattooIndex()
    local all = {}
    for _, key in ipairs(A.tattoos(a)) do
        local i = idx.byKey[key]
        if i and tattooFor(i, a.s) then all[#all + 1] = i end
    end
    table.sort(all)
    local out, perZone = {}, {}
    for _, i in ipairs(all) do
        local z = BR.Config.Tattoos.list[i][2]
        local n = (perZone[z] or 0) + 1
        if n <= A.TATTOOS_PER_ZONE then
            perZone[z] = n
            out[#out + 1] = i
        end
    end
    return out
end

--- `a` with the tattoos past a zone's cap taken off, as tattooRows leaves
--- them: a saved ped from the day there was no cap, opened to edit. A key that
--- is never worn here is left as it was.
local function capTattoos(a)
    local kept = {}
    for _, i in ipairs(tattooRows(a)) do kept[i] = true end
    local idx = tattooIndex()
    for _, key in ipairs(A.tattoos(a)) do
        local i = idx.byKey[key]
        if i and tattooFor(i, a.s) and not kept[i] then A.setTattoo(a, key, false) end
    end
    return a
end

--- Exactly `a`'s tattoos on the ped, and how many went on. A decoration only
--- ever comes off with all the others, so taking one off is this too. Nothing
--- else this resource puts on a ped is a decoration -- the hair is a
--- component, with no fade -- so the clear takes nothing that is not ours.
local function tattoos(ped, a)
    ClearPedDecorations(ped)
    local rows = tattooRows(a)
    for _, i in ipairs(rows) do
        local h = tattooHash(i, a.s)
        AddPedDecorationFromHashes(ped, h[1], h[2])
    end
    return #rows
end

--- How many decorations the ped carries, where the runtime can say.
local function decoCount(ped)
    if type(GetPedDecorations) ~= 'function' then return nil end
    local d = GetPedDecorations(ped)
    return type(d) == 'table' and #d or nil
end

--- What the ped carries just after its tattoos went on: none asks nothing.
local function noteDecos(ped, put)
    S.decos = { ped = ped, n = (put or 0) > 0 and decoCount(ped) or 0 }
end

--- Has the ped lost decorations since they went on -- a resurrection that kept
--- its handle? Against what it carried then, not against the list, so an
--- engine that draws fewer than it was asked to is not asked again every pass.
local function tattoosLost(ped)
    local d = S.decos
    if not d or d.ped ~= ped or not d.n or d.n == 0 then return false end
    local n = decoCount(ped)
    return n ~= nil and n < d.n
end

--- A ped that lost some gets its tattoos back, and what it carries then is
--- noted: a ped given fewer back than before is not asked again every pass.
local function restoreLost(ped, a)
    if tattoosLost(ped) then noteDecos(ped, tattoos(ped, a)) end
end

--- The whole appearance, in one block with no wait: head blend, face
--- features, overlays and their colors, hair and its color, eyes, components,
--- props, tattoos. Every part syncs to other players only with a head blend
--- set, which is why the blend is always first and always applied.
--- @param ped number
--- @param a table
--- @return integer  how many tattoos went on
function V.applyTo(ped, a)
    headBlend(ped, a)
    features(ped, a)
    overlays(ped, a)
    hair(ped, a)
    SetPedEyeColor(ped, a.e)
    for slot = 1, A.COMPS do
        if slot ~= 2 then component(ped, a, slot) end
    end
    for i = 1, #A.PROPS do prop(ped, a, i) end
    return tattoos(ped, a)
end

--- The head blend settles over a few frames, and an overlay set before it has
--- can be lost. So both are asserted again once it has finished (or after
--- headBlendWaitMs), if the ped still wears this look -- and its tattoos, if
--- any went missing meanwhile.
local function reassertLater(ped, a)
    Citizen.CreateThread(function()
        local deadline = GetGameTimer() + C().headBlendWaitMs
        while GetGameTimer() < deadline and not isTrue(HasPedHeadBlendFinished(ped)) do
            Citizen.Wait(50)
        end
        if S.applied and S.applied.ped == ped and S.applied.a == a then
            headBlend(ped, a)
            features(ped, a)
            overlays(ped, a)
            restoreLost(ped, a)
        end
    end)
end

local function noteApplied(model, a, ped)
    S.applied = { model = model, a = a, ped = ped }
    S.want = model
    S.dressed = true
end

--- The model a worn record wants.
local function modelOf(rec)
    if rec.k == 'p' then return GetHashKey(C().models[rec.a.s]) end
    local entry = stockById(rec.id) or stockById(BR.Locker.chosen()) or roster()[1]
    return GetHashKey(entry.model)
end

--- Swap the player's model and dress it, as client/locker.lua's apply does --
--- the same order and the same re-assertions, because SetPlayerModel hands
--- back a NEW ped with GTA's health model and no weapons -- and then the
--- appearance, in the same frame. Never writes Season 1's kvp.
--- @param hash number
--- @param a table|nil  nil for a stock ped
--- @param cb function|nil  (ok)
--- @param keep boolean|nil  an entrance still waiting for its model keeps going
local function swap(hash, a, cb, keep)
    if S.applying then
        if cb then cb(false) end
        return
    end
    S.applying = true
    S.want = hash

    -- A swap drops the entrance walk rather than stranding it (locker.lua) --
    -- except the one an entrance is waiting for. client/lobbyped.lua's run()
    -- holds the walk until wantHash()'s model is on the player and reads the
    -- new handle after, so a swap landing in that wait is the one it expects.
    if BR.LobbyPed and BR.LobbyPed.entering() and not (keep and not walkingNow()) then
        BR.LobbyPed.stop('the character was changed')
    end

    Citizen.CreateThread(function()
        RequestModel(hash)
        local deadline = GetGameTimer() + 5000
        while not isTrue(HasModelLoaded(hash)) and GetGameTimer() < deadline do
            Citizen.Wait(50)
        end
        if not isTrue(HasModelLoaded(hash)) then
            print(('[br_core] locker2: model %s never streamed'):format(tostring(hash)))
            S.applying = false
            S.want = GetEntityModel(PlayerPedId())
            if cb then cb(false) end
            return
        end
        -- THE LOBBY WAS LEFT WHILE THE MODEL STREAMED IN (up to 5 s): no swap
        -- (see inLobby). The worn ped goes back on at the next lobby arrival;
        -- `left` tells a caller this was no failure to load.
        if not inLobby() then
            SetModelAsNoLongerNeeded(hash)
            S.applying = false
            S.want = GetEntityModel(PlayerPedId())
            if cb then cb(false, 'left') end
            return
        end

        local before = PlayerPedId()
        local pos = GetEntityCoords(before)
        local heading = GetEntityHeading(before)

        SetPlayerModel(PlayerId(), hash)
        SetModelAsNoLongerNeeded(hash)

        local ped = PlayerPedId()
        if BR.Spawn and BR.Spawn.concealPed then BR.Spawn.concealPed() end
        SetEntityCoordsNoOffset(ped, pos.x, pos.y, pos.z, false, false, false)
        SetEntityHeading(ped, heading)

        BR.Native.initHealthModel()
        SetPedDefaultComponentVariation(ped)
        SetPedCanRagdoll(ped, false)
        FreezeEntityPosition(ped, true)

        if a then noteDecos(ped, V.applyTo(ped, a)) end
        noteApplied(hash, a, ped)
        S.applying = false
        if a then reassertLater(ped, a) end
        if cb then cb(true) end
    end)
end

--- Put a look on the player: in place when the model is already right and it
--- is a custom one, a swap otherwise.
--- @param hash number
--- @param a table|nil
--- @param cb function|nil
--- @param keep boolean|nil  see swap
local function dress(hash, a, cb, keep)
    local ped = PlayerPedId()
    if a and GetEntityModel(ped) == hash and not S.applying then
        noteDecos(ped, V.applyTo(ped, a))
        noteApplied(hash, a, ped)
        reassertLater(ped, a)
        if cb then cb(true) end
        return
    end
    if not a and GetEntityModel(ped) == hash and not S.applying then
        noteApplied(hash, nil, ped)
        if cb then cb(true) end
        return
    end
    swap(hash, a, cb, keep)
end

--- Is this record what the ped already wears?
local function wearing(rec)
    if not rec or not S.applied then return false end
    if S.applied.model ~= modelOf(rec) then return false end
    if rec.k == 's' then return S.applied.a == nil end
    return A.equal(S.applied.a, rec.a)
end

local function remember(rec)
    local s = A.encodeWorn(rec)
    if s then SetResourceKvp(KVP, s) end
end

--- Wear a record, now or once the entrance lets go of the ped.
---
--- TWO WAITS, BY WHO ASKED. The first apply and a lobby arrival are what the
--- entrance waits for (wantHash), so they wait only for a ped that is actually
--- WALKING. A later change -- the server's record arriving after the first
--- apply fell back to this machine's -- waits for the whole lock, as a pick
--- from the page does.
--- @param rec table
--- @param cb function|nil
--- @param early boolean|nil  the first apply or an arrival
local function wear(rec, cb, early)
    if not rec then return end
    if wearing(rec) then
        S.pending = nil
        if cb then cb(true) end
        return
    end
    -- OUTSIDE THE LOBBY NOTHING IS PUT ON (#28 review): a swap there hands the
    -- player a new ped with no weapons, GTA's health model and frozen in place.
    -- A server answer that lands mid-match is held, and only the lobby tick
    -- drains what is held.
    if (early and walkingNow()) or (not early and locked()) or S.applying or not inLobby() then
        S.pending = rec
        S.pendingEarly = early == true
        S.want = modelOf(rec)
        return
    end
    S.pending = nil
    dress(modelOf(rec), rec.k == 'p' and A.copy(rec.a) or nil, cb, early)
end

-- ---------------------------------------------------------------------------
-- The page
-- ---------------------------------------------------------------------------
--
-- ═══ MY LOOKS (owner, 2026-10-12/13/14) ═══
--
-- The page has views, not tabs (ui-src/src/screens/lockerv2/model.ts View),
-- and asks this file to start a draft (LOCKER2_NEW: a new custom look,
-- randomized; LOCKER2_EDIT: a saved one) and to leave it (LOCKER2_LEAVE). The
-- draft is the whole look -- its `x` the extras on it, in the order put on --
-- and its history: every change records the look as it was, Undo puts that
-- back. Lua still names the tab it shows the ped for (`male`/`female` while a
-- draft is up) and echoes the page's last numbered request as `tabSeq`.

--- Lua's tab for a draft of each sex.
local CUSTOM = { m = 'male', f = 'female' }

local function catOf(k)
    for _, cat in ipairs(C().categories) do
        for _, rk in ipairs(cat.rows) do
            if rk == k then return cat end
        end
    end
    return nil
end

--- A category by its id: a row category or one of the Tattoos section's.
local function catById(id)
    for _, cat in ipairs(C().categories) do
        if cat.id == id then return cat end
    end
    for _, cat in ipairs(C().tattooCats or {}) do
        if cat.id == id then return cat end
    end
    return nil
end

local function propIndex(slot)
    for i, s in ipairs(A.PROPS) do
        if s == slot then return i end
    end
    return nil
end

local function indexOf(list, v)
    for i, x in ipairs(list) do
        if x == v then return i end
    end
    return nil
end

--- Is this one of the extras ("Add more"'s list)?
local function isExtra(id)
    return type(id) == 'string' and indexOf(C().extras, id) ~= nil
end

local function modelOfSex(sex) return GetHashKey(C().models[sex]) end

--- Is the ped on screen the draft's freemode ped? Every list, every forced
--- piece and every apply asks the ped itself.
local function modelReady(d)
    return GetEntityModel(PlayerPedId()) == modelOfSex(d.sex)
end

--- A component row's "none", first in its list: the undershirt's, or an
--- extra's drawable that draws nothing. nil for a row that has none.
local function noneOf(slot, sex)
    if slot == 8 then return C().undershirtNone[sex] end
    return C().componentNone[slot]
end

--- What a row key edits, as (kind, a getter, a setter). nil for no such key.
local function field(k)
    if k == 'shape' then
        return 'count', function(a) return a.f or 0 end, function(a, v) a.f = v ~= 0 and v or nil end
    elseif k == 'sk' then
        return 'count', function(a) return a.sk end, function(a, v) a.sk = v end
    elseif k == 'e' then
        return 'count', function(a) return a.e end, function(a, v) a.e = v end
    elseif k == 'h1' then
        return 'count', function(a) return a.h[2] end, function(a, v) a.h[2] = v end
    end
    local n = k:match('^ff(%d+)$')
    if n then
        local i = tonumber(n) + 1
        if i > A.FEATURES then return nil end
        return 'slider', function(a) return a.ff[i] end, function(a, v) a.ff[i] = v end
    end
    n = k:match('^o(%d+)op$')
    if n then
        local i = tonumber(n) + 1
        if i > A.OVERLAYS then return nil end
        return 'slider', function(a) return a.o[i][2] end, function(a, v) a.o[i][2] = v end
    end
    n = k:match('^o(%d+)$')
    if n then
        local i = tonumber(n) + 1
        if i > A.OVERLAYS then return nil end
        return 'count', function(a) return a.o[i][1] end, function(a, v) a.o[i][1] = v end
    end
    n = k:match('^c(%d+)$')
    if n then
        local slot = tonumber(n)
        if slot < 1 or slot > A.COMPS then return nil end
        return 'count', function(a) return a.c[slot][1] end,
            function(a, v)
                if a.c[slot][1] ~= v then a.c[slot][2] = 0 end
                a.c[slot][1] = v
            end
    end
    n = k:match('^p(%d+)$')
    if n then
        local i = propIndex(tonumber(n))
        if not i then return nil end
        return 'count', function(a) return a.p[i][1] end,
            function(a, v)
                if a.p[i][1] ~= v then a.p[i][2] = 0 end
                a.p[i][1] = v
            end
    end
    return nil
end

--- A slider's range and default.
local function sliderRange(k)
    local n = k:match('^ff(%d+)$')
    if n then
        local i = tonumber(n)
        return (i == 18 or i == 19) and 0 or -100, 100, 0
    end
    return 0, 100, 100
end

-- ═══ THE ITEMS (owner, 2026-10-14: "if the answer is it doesn't draw anything
-- - then remove that item from the list entirely") ═══
--
-- A row's list holds only what the game will draw: a drawable this build has
-- (not gen9-only), with a texture to draw, that IS_PED_COMPONENT_VARIATION_VALID
-- passes -- and, for a prop, one with a texture. A row with a "none" keeps it
-- first. So `v/n` counts real items. Each list is built the first time its row
-- is drawn (a category on the look, never the extras that are not) and kept
-- for the session; nothing is listed when the page opens.

--- The option lists, per sex, and how many drawables each left out.
local optionCache = { m = {}, f = {} }
local removedBy = { m = {}, f = {} }

--- How many drawables each row's list left out for a sex, of the lists built.
--- @param sex string
--- @return table
function V.removed(sex) return removedBy[sex] or {} end
--- An item's textures, per sex: [k .. ':' .. drawable] = { t... }.
local texCache = { m = {}, f = {} }
local missingLogged = {}

local function gen9(ped, slot, d)
    if type(IsPedComponentVariationGen9Exclusive) ~= 'function' then return false end
    return isTrue(IsPedComponentVariationGen9Exclusive(ped, slot, d))
end

--- Does the game draw this component drawable?
local function drawableOk(ped, slot, d)
    if gen9(ped, slot, d) then return false end
    if GetNumberOfPedTextureVariations(ped, slot, d) <= 0 then return false end
    return isTrue(IsPedComponentVariationValid(ped, slot, d, 0))
end

local function range(lo, hi)
    local out = {}
    for v = lo, hi do out[#out + 1] = v end
    return out
end

--- The values a count row steps through, in order -- none first where a row
--- has one -- or nil when the ped on screen is not this sex's freemode ped.
local function options(k, sex)
    local cached = optionCache[sex][k]
    if cached then return cached end
    local ped = PlayerPedId()
    if GetEntityModel(ped) ~= modelOfSex(sex) then return nil end
    local list
    if k == 'shape' then
        list = range(0, #C().faces[sex] - 1)
    elseif k == 'sk' then
        list = range(0, 45)
    elseif k == 'e' then
        list = range(0, 30)
    elseif k == 'h1' then
        list = range(0, math.min(C().paletteMax, math.max(1, GetNumHairColors())) - 1)
    elseif k:match('^o%d+$') then
        local i = tonumber(k:sub(2))
        local n = math.min(255, GetPedHeadOverlayNum(i))
        list = {}
        if i ~= A.EYEBROWS then list[1] = A.NONE end
        for v = 0, n - 1 do list[#list + 1] = v end
        if #list == 0 then list[1] = 0 end
    elseif k:match('^c%d+$') then
        local slot = tonumber(k:sub(2))
        local n = math.min(1024, GetNumberOfPedDrawableVariations(ped, slot))
        list = {}
        local none = noneOf(slot, sex)
        if none then list[1] = none end
        local gone = 0
        for d = 0, n - 1 do
            if d ~= none then
                if drawableOk(ped, slot, d) then list[#list + 1] = d else gone = gone + 1 end
            end
        end
        removedBy[sex][k] = gone
        if #list == 0 then list[1] = 0 end
    elseif k:match('^p%d+$') then
        local slot = tonumber(k:sub(2))
        local n = math.min(1024, GetNumberOfPedPropDrawableVariations(ped, slot))
        list = { -1 }
        local gone = 0
        for d = 0, n - 1 do
            if GetNumberOfPedPropTextureVariations(ped, slot, d) > 0 then list[#list + 1] = d else gone = gone + 1 end
        end
        removedBy[sex][k] = gone
    else
        return nil
    end
    optionCache[sex][k] = list
    return list
end

--- An item's textures, in order: for a component the ones the game says are
--- valid, for a prop its count -- 32 at most, all the sync tree carries.
local function textures(ped, sex, k, d)
    local key = k .. ':' .. d
    local cached = texCache[sex][key]
    if cached then return cached end
    local slot = tonumber(k:sub(2))
    local list = {}
    if k:sub(1, 1) == 'c' then
        local n = math.min(32, GetNumberOfPedTextureVariations(ped, slot, d))
        for t = 0, n - 1 do
            if isTrue(IsPedComponentVariationValid(ped, slot, d, t)) then list[#list + 1] = t end
        end
    else
        local n = math.min(32, GetNumberOfPedPropTextureVariations(ped, slot, d))
        for t = 0, n - 1 do list[#list + 1] = t end
    end
    if #list == 0 then list[1] = 0 end
    texCache[sex][key] = list
    return list
end

--- How many colors a row's item has: its textures, or its palette.
---
--- AN ITEM THAT IS NOT ON THE PED HAS ONE: no prop, an overlay of none, a
--- component's none. Its color shows on nothing, so it gets no swatches, and
--- a press of one would only make the draft differ where nobody can see (#28
--- review). Appearance.encode writes a none overlay's color and opacity as
--- their defaults for the same reason.
local function colorsOf(k, a, ped, sex)
    if k == 'c2' then return math.min(C().paletteMax, GetNumHairColors()) end
    local n = k:match('^o(%d+)$')
    if n then
        local pal = C().overlayPalette[tonumber(n)]
        if not pal or a.o[tonumber(n) + 1][1] == A.NONE then return 1 end
        return math.min(C().paletteMax, pal == 1 and GetNumHairColors() or GetNumMakeupColors())
    end
    n = k:match('^c(%d+)$')
    if n then
        local slot = tonumber(n)
        if a.c[slot][1] == noneOf(slot, sex) then return 1 end
        return #textures(ped, sex, k, a.c[slot][1])
    end
    n = k:match('^p(%d+)$')
    if n then
        local i = propIndex(tonumber(n))
        if not i or a.p[i][1] < 0 then return 1 end
        return #textures(ped, sex, k, a.p[i][1])
    end
    return 1
end

--- Which of the game's two palettes a row's colors come from, or nil.
local function palOf(k)
    if k == 'c2' or k == 'h1' then return 'hair' end
    local n = k:match('^o(%d+)$')
    local pal = n and C().overlayPalette[tonumber(n)]
    if pal == 1 then return 'hair' elseif pal == 2 then return 'makeup' end
    return nil
end

--- The color a row wears, 0-based: in its palette, or its item's place among
--- its textures. nil for a row with none (the highlight is its own value).
local function colorOf(k, a, ped, sex)
    if k == 'c2' then return a.h[1] end
    local n = k:match('^o(%d+)$')
    if n then return C().overlayPalette[tonumber(n)] and a.o[tonumber(n) + 1][3] or nil end
    n = k:match('^c(%d+)$')
    if n then
        local slot = tonumber(n)
        return (indexOf(textures(ped, sex, k, a.c[slot][1]), a.c[slot][2]) or 1) - 1
    end
    n = k:match('^p(%d+)$')
    if n then
        local i = propIndex(tonumber(n))
        if not i or a.p[i][1] < 0 then return nil end
        return (indexOf(textures(ped, sex, k, a.p[i][1]), a.p[i][2]) or 1) - 1
    end
    return nil
end

--- Is this slider an opacity of an overlay that is none? It moves nothing on
--- the ped, so it is sent `off` and a set of it is refused (#28 review).
local function sliderOff(k, a)
    local n = k:match('^o(%d+)op$')
    return n ~= nil and a.o[tonumber(n) + 1][1] == A.NONE
end

-- ═══ ITEM NAMES, OFF (owner, 2026-10-14: "All or nothing on that") ═══
--
-- The game names an item through its shop data -- GET_HASH_NAME_FOR_COMPONENT
-- (or _FOR_PROP), the shop struct's label, GetLabelText -- for some items and
-- not others (tops about three in four, legs half, bags none). So no row
-- carries a name, and none is looked up, unless its category is in
-- BR.Config.Locker2.names; the page draws a name only for a category in its
-- own NAMED_CATS (ui-src/src/screens/lockerv2/model.ts). Both are empty.

local nameCache = { m = {}, f = {} }
local SHOP_COMPONENT, SHOP_PROP = 0x74C0E2A57EC66760, 0x5D5CAFF661DDF6FC
local HASH_COMPONENT, HASH_PROP = 0x0368B3A838070348, 0x5D6160275CAEC8DD

--- The game's name for a row's item, or nil.
local function itemName(ped, sex, k, a)
    local slot = tonumber(k:match('^[cp](%d+)$') or '')
    if not slot then return nil end
    local prop = k:sub(1, 1) == 'p'
    local d, t
    if prop then
        local i = propIndex(slot)
        if not i or a.p[i][1] < 0 then return nil end
        d, t = a.p[i][1], a.p[i][2]
    else
        d, t = a.c[slot][1], a.c[slot][2]
    end
    local key = k .. ':' .. d .. ':' .. t
    local hit = nameCache[sex][key]
    if hit ~= nil then return hit or nil end
    local ok, name = pcall(function()
        local h = Citizen.InvokeNative(prop and HASH_PROP or HASH_COMPONENT, ped, slot, d, t, Citizen.ResultAsInteger())
        if not h or h == 0 then return nil end
        local buf = string.rep('\0', 512)
        Citizen.InvokeNative(prop and SHOP_PROP or SHOP_COMPONENT, h, buf)
        if string.unpack('<i4', buf, 9) ~= h then return nil end
        local gxt = buf:sub(73, 136):match('^[^%z]+')
        if not gxt then return nil end
        local s = GetLabelText(gxt)
        return type(s) == 'string' and s ~= '' and s ~= 'NULL' and s or nil
    end)
    name = ok and name or nil
    nameCache[sex][key] = name or false
    return name
end

-- ═══ THE GAME'S FORCED COMPONENTS (#28, the game-data check) ═══
--
-- A shop top names what it is worn with, per texture: its arms (about nine
-- tops in ten), often its undershirt, and a jumpsuit its legs and shoes
-- (GET_SHOP_PED_APPAREL_FORCED_COMPONENT_COUNT, GET_FORCED_COMPONENT). An
-- undershirt names its arms. So a top put on -- a step, a set, a color, a
-- Randomize -- puts those on as the game would: the top's first, then the
-- undershirt's own where the top named none. An undershirt put on puts on its
-- arms where the top names none. The Arms row stays the player's: it changes
-- nothing else, and a top with no shop data (the 16 base tops) leaves the
-- arms as they are.
--
-- A target named by the hash of "0" is a base item, given as a flat index over
-- the slot's textures, drawable by drawable. Any other is a DLC item, found by
-- its own shop hash among the slot's (read once per sex and slot).

local forcedCache = { m = {}, f = {} }
local flatCache = { m = {}, f = {} }
local hashIndex = { m = {}, f = {} }
local ZERO = nil

--- A hash as 32 unsigned bits: one native hands it back signed, another may
--- not, and the two are compared.
local function h32(h)
    return math.type(h) == 'integer' and h & 0xFFFFFFFF or h
end

--- A hash that names no shop item.
local function noItem(h)
    ZERO = ZERO or h32(GetHashKey('0'))
    return h == nil or h == 0 or h32(h) == ZERO
end

local function forcedCount(h)
    local fn = GetShopPedApparelForcedComponentCount or GetNumForcedComponents
    return fn and fn(h) or 0
end

--- A base item's flat index as its drawable and texture.
local function decodeFlat(ped, sex, slot, enum)
    local cum = flatCache[sex][slot]
    if not cum then
        cum = {}
        local total = 0
        local n = math.min(1024, GetNumberOfPedDrawableVariations(ped, slot))
        for d = 0, n - 1 do
            total = total + math.max(0, GetNumberOfPedTextureVariations(ped, slot, d))
            cum[d + 1] = total
        end
        flatCache[sex][slot] = cum
    end
    local before = 0
    for i, upto in ipairs(cum) do
        if enum < upto then return i - 1, enum - before end
        before = upto
    end
    return nil
end

--- A DLC item's drawable and texture by its shop hash.
local function byHash(ped, sex, slot, h)
    local idx = hashIndex[sex][slot]
    if not idx then
        idx = {}
        local n = math.min(1024, GetNumberOfPedDrawableVariations(ped, slot))
        for d = 0, n - 1 do
            for t = 0, math.min(32, GetNumberOfPedTextureVariations(ped, slot, d)) - 1 do
                local x = GetHashNameForComponent(ped, slot, d, t)
                if not noItem(x) and idx[h32(x)] == nil then idx[h32(x)] = { d, t } end
            end
        end
        hashIndex[sex][slot] = idx
    end
    local hit = idx[h32(h)]
    if hit then return hit[1], hit[2] end
    return nil
end

--- What the item in `slot` forces, as { slot, drawable, texture }s: only the
--- slots of forcedSlots, only what the game says is valid.
local function forcedOf(ped, sex, slot, d, t)
    local key = slot .. ':' .. d .. ':' .. t
    local hit = forcedCache[sex][key]
    if hit then return hit end
    local out = {}
    local wanted = {}
    for _, s in ipairs(C().forcedSlots or {}) do wanted[s] = true end
    local ok = pcall(function()
        local h = GetHashNameForComponent(ped, slot, d, t)
        if noItem(h) then return end
        for i = 0, math.min(16, forcedCount(h)) - 1 do
            local nameHash, enum, ctype = GetForcedComponent(h, i)
            if wanted[ctype] and ctype ~= slot then
                local fd, ft
                if noItem(nameHash) then
                    fd, ft = decodeFlat(ped, sex, ctype, enum or 0)
                else
                    fd, ft = byHash(ped, sex, ctype, nameHash)
                end
                if fd and ft and ft < 32 and isTrue(IsPedComponentVariationValid(ped, ctype, fd, ft)) then
                    out[#out + 1] = { ctype, fd, ft }
                end
            end
        end
    end)
    if not ok then out = {} end
    forcedCache[sex][key] = out
    return out
end

--- After the top (11) or the undershirt (8) changed: the pieces they force.
local function applyForced(d, ped, changed)
    local a = d.a
    local function put(list, skip)
        local done = {}
        for _, f in ipairs(list) do
            if not (skip and skip[f[1]]) then
                a.c[f[1]][1], a.c[f[1]][2] = f[2], f[3]
                done[f[1]] = true
            end
        end
        return done
    end
    local top = forcedOf(ped, d.sex, 11, a.c[11][1], a.c[11][2])
    local skip
    if changed == 11 then
        skip = put(top)
    elseif changed == 8 then
        skip = {}
        for _, f in ipairs(top) do skip[f[1]] = true end
    else
        return
    end
    skip[8], skip[11] = true, true
    put(forcedOf(ped, d.sex, 8, a.c[8][1], a.c[8][2]), skip)
end

--- The pieces a row's change forces, when the ped is the draft's.
local function forcedAfter(d, k)
    if (k ~= 'c11' and k ~= 'c8') or not modelReady(d) then return end
    applyForced(d, PlayerPedId(), k == 'c11' and 11 or 8)
end

-- ═══ THE EXTRAS (owner, 2026-10-13/14) ═══

local function tatZones()
    local cfg = BR.Config.Tattoos
    return cfg and cfg.zones or {}
end

--- Is extra `id` on the look: any of its rows off none, or a tattoo it wears.
local function extraOn(a, id)
    if id == 'tattoos' then return #tattooRows(a) > 0 end
    local cat = catById(id)
    for _, k in ipairs(cat and cat.rows or {}) do
        local n = k:match('^c(%d+)$')
        if n and a.c[tonumber(n)][1] ~= (C().componentNone[tonumber(n)] or 0) then return true end
        n = k:match('^p(%d+)$')
        if n and a.p[propIndex(tonumber(n))][1] >= 0 then return true end
        n = k:match('^o(%d+)$')
        if n and a.o[tonumber(n) + 1][1] ~= A.NONE then return true end
    end
    return false
end

--- The look's extras in order: its `x`, then any that is on and that `x`
--- does not name (a look saved before My Looks), in the extras' own order.
local function extrasOf(a)
    local out, seen = {}, {}
    for _, id in ipairs(type(a.x) == 'table' and a.x or {}) do
        if isExtra(id) and not seen[id] then
            out[#out + 1] = id
            seen[id] = true
        end
    end
    for _, id in ipairs(C().extras) do
        if not seen[id] and extraOn(a, id) then
            out[#out + 1] = id
            seen[id] = true
        end
    end
    return out
end

--- `a.x` made whole: every extra on is listed.
local function syncExtras(a)
    local x = extrasOf(a)
    a.x = #x > 0 and x or nil
end

-- ═══ THE TATTOO ROWS ═══
--
-- "a list, starting empty, with add and remove buttons ... You can just make
-- it max 10 per category" (owner, 2026-10-12), now one list under the Tattoos
-- extra (2026-10-14: "starting with a bunch of add buttons is not intuitive
-- ... fix that"): "Add more" asks the zone and the tattoo. The rows are the
-- draft's, per body zone, { r, i }: `i` the tattoo's row in the list, `r` the
-- row's own id, never given twice in a session, so a choice or a Remove the
-- page sends lands on that row and never on another draft's. The look's `t`
-- says which tattoos are on, and these the order the page lists them in,
-- which the save cannot hold: a look opens with its rows in the list's order,
-- at most TATTOOS_PER_ZONE a zone (tattooRows).
local nextTatRow = 0
local function tatRowsOf(a)
    local out = {}
    for _, z in ipairs(tatZones()) do out[z] = {} end
    for _, i in ipairs(tattooRows(a)) do
        local rows = out[BR.Config.Tattoos.list[i][2]]
        if rows then
            nextTatRow = nextTatRow + 1
            rows[#rows + 1] = { r = nextTatRow, i = i }
        end
    end
    return out
end

--- The rows as the page gets them, zone by zone: { r, z, i }, a few bytes
--- each. The tattoos' names go once, when the page asks (LOCKER2_TATS).
local function tatRowsOut(d)
    local out = {}
    for _, z in ipairs(tatZones()) do
        for _, row in ipairs(d.tats and d.tats[z] or {}) do
            out[#out + 1] = { r = row.r, z = z, i = row.i }
        end
    end
    return out
end

--- The tattoos a zone's rows hold, but `skip`'s.
local function usedIn(rows, skip)
    local used = {}
    for _, row in ipairs(rows) do
        if row ~= skip then used[row.i] = true end
    end
    return used
end

--- A zone's tattoos for a sex, in the list's order. No names: Randomize picks
--- from these without asking the game for a word.
local zoneIdCache = { m = {}, f = {} }
local function zoneIds(sex, z)
    local hit = zoneIdCache[sex][z]
    if hit then return hit end
    local out = {}
    for i, row in ipairs(BR.Config.Tattoos and BR.Config.Tattoos.list or {}) do
        if row[2] == z and tattooFor(i, sex) then out[#out + 1] = i end
    end
    zoneIdCache[sex][z] = out
    return out
end

--- The row with id `r`, and its zone's rows and its place there.
local function tatRowById(d, r)
    for _, z in ipairs(tatZones()) do
        for k, row in ipairs(d.tats[z] or {}) do
            if row.r == r then return row, d.tats[z], k end
        end
    end
    return nil
end

--- A new row at the foot of zone `z`, wearing tattoo `i`.
local function addTatRow(d, z, i)
    nextTatRow = nextTatRow + 1
    local rows = d.tats[z]
    rows[#rows + 1] = { r = nextTatRow, i = i }
    A.setTattoo(d.a, BR.Config.Tattoos.list[i][1], true)
end

--- Every row off, and its tattoo with it. A key never worn here (a set no list
--- knows, the other sex's alone) stays in the look, where it draws nothing.
local function clearTats(d)
    for _, z in ipairs(tatZones()) do
        for _, row in ipairs(d.tats[z] or {}) do
            A.setTattoo(d.a, BR.Config.Tattoos.list[row.i][1], false)
        end
        d.tats[z] = {}
    end
end

-- ═══ THE ROWS THE PAGE DRAWS ═══

--- A category's rows, sent while it is on the look: the core always, an
--- extra once it is listed. So a list is built when its row is first drawn.
local function rowsFor(d)
    local rows = {}
    local ped = PlayerPedId()
    if GetEntityModel(ped) ~= modelOfSex(d.sex) then return rows end
    local listed = {}
    for _, id in ipairs(d.a.x or {}) do listed[id] = true end
    local named = {}
    for _, id in ipairs(C().names or {}) do named[id] = true end
    for _, cat in ipairs(C().categories) do
        if not cat.extra or listed[cat.id] then
            for _, k in ipairs(cat.rows) do
                local kind, get = field(k)
                if kind == 'slider' then
                    local lo, hi, def = sliderRange(k)
                    rows[#rows + 1] = { k = k, cat = cat.id, kind = 'slider', v = get(d.a),
                                        min = lo, max = hi, def = def, off = sliderOff(k, d.a) or nil }
                elseif kind == 'count' then
                    local list = options(k, d.sex)
                    if list then
                        local v = get(d.a)
                        local pos = indexOf(list, v)
                        if not pos then
                            if not missingLogged[k .. '=' .. tostring(v)] then
                                missingLogged[k .. '=' .. tostring(v)] = true
                                print(('[br_core] locker2: %s %s is not on this build; shown as 1')
                                    :format(k, tostring(v)))
                            end
                            pos = 1
                        end
                        rows[#rows + 1] = { k = k, cat = cat.id, kind = 'count', v = pos, n = #list,
                                            colors = colorsOf(k, d.a, ped, d.sex), pal = palOf(k),
                                            c = k ~= 'h1' and colorOf(k, d.a, ped, d.sex) or nil,
                                            name = named[cat.id] and itemName(ped, d.sex, k, d.a) or nil }
                    end
                end
            end
        end
    end
    return rows
end

--- A tattoo's name: the game's own text for its label key, or nil where the
--- game has none (GetLabelText answers 'NULL'). The page names those itself.
local function labelOf(key)
    if type(GetLabelText) ~= 'function' then return nil end
    local s = GetLabelText(key)
    if type(s) ~= 'string' or s == '' or s == 'NULL' then return nil end
    return s
end

--- One sex's tattoos as the page lists them, built once: by body zone in the
--- list's order of zones, each zone by name, the ones with no name last.
local catalogs = {}
local function catalog(sex)
    if catalogs[sex] then return catalogs[sex] end
    local cfg = BR.Config.Tattoos
    local byZone = {}
    for i, row in ipairs(cfg and cfg.list or {}) do
        if tattooFor(i, sex) then
            byZone[row[2]] = byZone[row[2]] or {}
            local items = byZone[row[2]]
            items[#items + 1] = { i = i, name = labelOf(row[1]) }
        end
    end
    local zones = {}
    for _, z in ipairs(cfg and cfg.zones or {}) do
        local items = byZone[z]
        if items then
            table.sort(items, function(x, y)
                if (x.name ~= nil) ~= (y.name ~= nil) then return x.name ~= nil end
                local lx, ly = x.name and x.name:lower(), y.name and y.name:lower()
                if lx ~= ly then return lx < ly end
                return x.i < y.i
            end)
            zones[#zones + 1] = { z = z, items = items }
        end
    end
    catalogs[sex] = { sex = sex, zones = zones }
    return catalogs[sex]
end

--- THE PALETTES the swatch grids draw (LOCKER2_PAL), built once: the game's
--- hair and makeup colors as `#rrggbb`, paletteMax of each at most.
local palettes = nil
local function palettesOut()
    if palettes then return palettes end
    local function list(count, rgb)
        local out = {}
        if not rgb then return out end
        for i = 0, math.min(C().paletteMax, count) - 1 do
            local r, g, b = rgb(i)
            out[#out + 1] = ('#%02x%02x%02x'):format(math.tointeger(r) or 0, math.tointeger(g) or 0,
                math.tointeger(b) or 0)
        end
        return out
    end
    palettes = {
        hair = list(GetNumHairColors(), GetPedHairRgbColor or GetPedHairTintColor),
        makeup = list(GetNumMakeupColors(), GetPedMakeupRgbColor or GetPedMakeupTintColor),
    }
    return palettes
end

--- My Looks while the saved looks are still being fetched, as the page opens:
--- it holds the loading indicator there until the server answers (owner,
--- 2026-10-07: "show a loading icon while we wait for the results").
local function fetching()
    return not S.serverSeen
end

local function defaultTab()
    return (#S.peds > 0 or fetching()) and 'peds' or 'stock'
end

--- The stock roster as the page gets it, built once.
local stockList = nil

--- Send the page everything it draws. Never an appearance.
function V.push()
    if not claims() then
        -- Only to a page that was told it was on: a Season 1 client never
        -- hears from this file at all.
        if S.everOn then TriggerEvent('br:ui:sendLocal', BR.Nui.LOCKER2, { on = false }) end
        return
    end
    S.everOn = true
    local stock = s1List
    if not stock then
        if not stockList then
            stockList = {}
            for _, p in ipairs(roster()) do stockList[#stockList + 1] = { id = p.id, name = p.name } end
        end
        stock = stockList
    end
    -- NO PICTURE RIDES ON A PUSH (#28 review). This is sent on every press,
    -- up to one a slider's 60 ms, and the owner set no limit on saved peds:
    -- with every headshot in it, each push grew by a few KB a ped. A card's
    -- picture goes to the page once, on its own (client/locker2shot.lua, when
    -- the page asks for the cards it has none for), and the page keeps it.
    local peds = {}
    for _, p in ipairs(S.peds) do
        peds[#peds + 1] = { id = p.id, name = p.name, up = p.up }
    end
    local edit = nil
    local d = S.draft
    if d then
        edit = { sex = d.sex, editing = d.editing, dirty = d.dirty, cat = d.cat, rows = rowsFor(d),
                 tats = tatRowsOut(d), extras = d.a.x or {},
                 undo = #d.hist.past > 0, redo = #d.hist.future > 0 }
    end
    TriggerEvent('br:ui:sendLocal', BR.Nui.LOCKER2, {
        on = true,
        tab = S.tab or defaultTab(),
        -- The page's last numbered request this answer has seen (see the
        -- ACTIONS handler): the page follows Lua's draft once it is its own
        -- latest.
        tabSeq = S.tabSeq,
        stock = stock,
        peds = peds,
        worn = S.worn and { k = S.worn.k, id = S.worn.id } or nil,
        loading = S.loadingId,
        locked = locked(),
        busy = S.busy ~= nil,
        fetching = fetching(),
        edit = edit,
    })
end

-- ---------------------------------------------------------------------------
-- The server
-- ---------------------------------------------------------------------------

--- A ped as the server sends it, decoded; nil when it is not one.
local function pedIn(p)
    if type(p) ~= 'table' or not A.isPedId(p.id) or not A.isName(p.name) then return nil end
    local a = A.decode(p.a)
    if not a then return nil end
    return { id = p.id, name = p.name, a = a, up = math.tointeger(p.up) or 0,
             img = type(p.img) == 'string' and p.img or nil }
end

local function wornIn(w)
    if type(w) ~= 'table' then return nil end
    if w.k == 's' and A.isStockId(w.id) then return { k = 's', id = w.id } end
    if w.k == 'p' and A.isPedId(w.id) then
        local a = A.decode(w.a)
        if a then return { k = 'p', id = w.id, a = a } end
    end
    return nil
end

local function fetch()
    S.fetchAt = GetGameTimer()
    TriggerServerEvent(BR.Net.LOCKER2_FETCH, {})
end

--- THE SAVED LOOKS ARE ASKED FOR ONCE (#28 lag: every open asked again, and
--- the server read every look and headshot from the database each time). The
--- join's first apply asks; every write's answer keeps the list current. An
--- open asks again only when no answer has come (and the last ask is fetchMs
--- old), when the server could not read them, or when the answer is
--- refreshMs old.
local function stale()
    local now = GetGameTimer()
    if not S.serverSeen then return S.fetchAt == nil or now - S.fetchAt >= C().fetchMs end
    if S.store == false then return true end
    return S.stateAt ~= nil and now - S.stateAt >= C().refreshMs
end

local function sendWear(rec)
    TriggerServerEvent(BR.Net.LOCKER2_WEAR, { k = rec.k, id = rec.id })
end

RegisterNetEvent(BR.Net.LOCKER2_STATE)
AddEventHandler(BR.Net.LOCKER2_STATE, function(d)
    if type(d) ~= 'table' or not claims() then return end
    S.serverSeen = true
    S.stateAt = GetGameTimer()
    S.store = d.store ~= false
    if type(d.peds) == 'table' then
        local list = {}
        for _, p in ipairs(d.peds) do
            local ped = pedIn(p)
            if ped then list[#list + 1] = ped end
        end
        table.sort(list, function(x, y) return x.id < y.id end)
        S.peds = list
    end
    local w = wornIn(d.worn)
    S.serverWorn = w
    -- A LATER ANSWER THAT DIFFERS is worn once the walk lets go of the ped:
    -- the appearance alone when the model is the same, a swap otherwise.
    if S.first == 'done' and w and not S.draft and not wearing(w)
       and not (S.worn and A.encodeWorn(S.worn) == A.encodeWorn(w)) then
        S.worn = w
        remember(w)
        wear(w)
    end
    if S.tab == 'peds' and #S.peds == 0 then S.tab = 'stock' end
    V.push()
end)

-- WRITTEN (proposal for the owner): the toast for any refused or failed save,
-- rename, delete or headshot.
local FAILED = 'Something went wrong. Try again.'

RegisterNetEvent(BR.Net.LOCKER2_RESULT)
AddEventHandler(BR.Net.LOCKER2_RESULT, function(d)
    if type(d) ~= 'table' then return end
    local req = math.tointeger(d.req)
    if req and shotReqs[req] then
        local id = shotReqs[req]
        shotReqs[req] = nil
        local p = pedById(id)
        -- Kept for the next time the page asks; the page already has it.
        if d.ok == true and p and type(d.ped) == 'table' and type(d.ped.img) == 'string' then
            p.img = d.ped.img
        end
        return
    end
    if req == nil or req ~= S.busy then return end
    local op = S.busyOp
    S.busy, S.busyOp, S.busyAt = nil, nil, nil
    if d.gone == true and A.isPedId(d.id) then
        local _, i = pedById(d.id)
        if i then table.remove(S.peds, i) end
        if S.draft and S.draft.editing == d.id then S.draft.editing = nil end
    end
    if d.ok == true then
        local ped = pedIn(d.ped)
        if ped then
            local _, i = pedById(ped.id)
            if i then S.peds[i] = ped else S.peds[#S.peds + 1] = ped end
            table.sort(S.peds, function(x, y) return x.id < y.id end)
        end
        local w = wornIn(d.worn)
        if w then
            S.worn = w
            remember(w)
        end
        if ped and S.draft and op == 'save' then
            -- A SAVE: the draft is now that saved look, unchanged.
            S.draft.editing = ped.id
            S.draft.base = A.copy(S.draft.a)
            S.draft.dirty = false
            if BR.Locker2Shot then BR.Locker2Shot.fromPlayer(ped.id, ped.up) end
        end
    else
        BR.Notify(FAILED, 'warn')
    end
    if S.tab == 'peds' and #S.peds == 0 then S.tab = 'stock' end
    V.push()
end)

-- ---------------------------------------------------------------------------
-- The draft
-- ---------------------------------------------------------------------------

--- A draft: the look being edited, where it began (`base`, nil for a new look,
--- which is never clean), and its history.
local function newDraft(sex, a, base, editing)
    return { sex = sex, a = a, base = base, editing = editing, dirty = base == nil, cat = nil,
             tats = tatRowsOf(a), hist = { past = {}, future = {}, key = nil, at = 0 } }
end

local function touched()
    local d = S.draft
    d.dirty = d.base == nil or not A.equal(d.a, d.base)
end

--- The whole draft on the ped, in place, when the ped is the draft's.
local function applyAll()
    local d = S.draft
    local ped = PlayerPedId()
    if not d or GetEntityModel(ped) ~= modelOfSex(d.sex) then return end
    local a = A.copy(d.a)
    noteDecos(ped, V.applyTo(ped, a))
    noteApplied(GetEntityModel(ped), a, ped)
    reassertLater(ped, a)
end

--- A draft starts on NO category, with the camera home on the whole ped.
---
--- THE CATEGORY THE PAGE LIGHTS IS WHERE THE CAMERA IS (#28 review): `cat` is
--- set only by LOCKER2_CAT, which moves the camera there, and a draft that
--- starts -- New, Edit -- sends the camera home and clears it.
---
--- A LOOK PAST THE TATTOO CAP (saved the day there was none) starts without
--- what it never wore, base included: nothing to save until something changes.
--- A look saved before My Looks starts with its extras listed (syncExtras),
--- base included, for the same reason.
local function startDraft(sex, a, editing)
    local look = capTattoos(A.copy(a))
    syncExtras(look)
    S.draft = newDraft(sex, A.copy(look), A.copy(look), editing)
    if BR.LobbyCam and BR.LobbyCam.unfocus then BR.LobbyCam.unfocus() end
    dress(modelOfSex(sex), A.copy(look), function() V.push() end)
end

--- Throw the draft away and bring the camera home.
local function discard()
    local had = S.draft ~= nil
    S.draft = nil
    if BR.LobbyCam and BR.LobbyCam.unfocus then BR.LobbyCam.unfocus() end
    return had
end

-- ═══ UNDO AND REDO (owner, 2026-10-13: "yes") ═══
--
-- Lua holds the draft, so Lua holds its history, by the page's own rules
-- (ui-src/src/screens/lockerv2/model.ts record, undoStep, redoStep): a change
-- records the look as it was; Undo puts that back and keeps the present for
-- Redo; a new change clears Redo. Touches of one row closer than coalesceMs
-- are one step -- a slider's drag, a held arrow -- and at most historyMax are
-- kept. A step is everything one press did: a top's forced arms with the top,
-- every extra Randomize put on with the rest.

local function copyTats(t)
    local out = {}
    for z, rows in pairs(t) do
        out[z] = {}
        for k, r in ipairs(rows) do out[z][k] = { r = r.r, i = r.i } end
    end
    return out
end

local function snap(d)
    return { a = A.copy(d.a), tats = copyTats(d.tats) }
end

--- Run `fn` on the draft. If the look came out different, the look as it was
--- is one step of the history (merged with the last one for the same `key`
--- inside coalesceMs) and the draft is touched. Returns whether it changed.
local function change(key, fn)
    local d = S.draft
    local before = snap(d)
    if not fn(d) then
        d.a, d.tats = before.a, before.tats
        return false
    end
    syncExtras(d.a)
    if A.encode(before.a) == A.encode(d.a) then return false end
    local h = d.hist
    local now = GetGameTimer()
    if not (key ~= nil and key == h.key and now - h.at < C().coalesceMs) then
        h.past[#h.past + 1] = before
        while #h.past > C().historyMax do table.remove(h.past, 1) end
    end
    h.future = {}
    h.key, h.at = key, now
    touched()
    return true
end

--- One step back (`from` the past) or forward (the future): the look put
--- back whole, and onto the ped.
local function travel(from, to)
    local d = S.draft
    if not d then return false end
    local s = table.remove(d.hist[from])
    if not s then return false end
    local list = d.hist[to]
    list[#list + 1] = snap(d)
    d.hist.key, d.hist.at = nil, 0
    d.a, d.tats = s.a, s.tats
    touched()
    applyAll()
    return true
end

--- Apply the part of the draft one key changed.
local function applyKey(k)
    local d = S.draft
    local ped = PlayerPedId()
    if GetEntityModel(ped) ~= modelOfSex(d.sex) then return end
    if k == 'sk' or k == 'shape' then
        headBlend(ped, d.a)
        features(ped, d.a)
        overlays(ped, d.a)
    elseif k == 'e' then
        SetPedEyeColor(ped, d.a.e)
    elseif k == 'h1' or k == 'c2' then
        hair(ped, d.a)
    elseif k:match('^ff') then
        local i = tonumber(k:sub(3)) + 1
        SetPedFaceFeature(ped, i - 1, d.a.ff[i] / 100.0)
    elseif k:match('^o') then
        overlay(ped, d.a, tonumber(k:match('^o(%d+)')) + 1)
    elseif k == 'c11' or k == 'c8' then
        -- What the top or undershirt forced went on with it.
        for slot = 1, A.COMPS do
            if slot ~= 2 then component(ped, d.a, slot) end
        end
    elseif k:match('^c') then
        component(ped, d.a, tonumber(k:sub(2)))
    elseif k:match('^p') then
        prop(ped, d.a, propIndex(tonumber(k:sub(2))))
    end
    noteApplied(GetEntityModel(ped), A.copy(d.a), ped)
end

local function stepRow(k, delta)
    local d = S.draft
    local kind, get, set = field(k)
    if kind ~= 'count' or not catOf(k) then return false end
    local list = options(k, d.sex)
    if not list then return false end
    local pos = indexOf(list, get(d.a)) or 1
    pos = ((pos - 1 + delta) % #list) + 1
    set(d.a, list[pos])
    return true
end

local function setRow(k, v)
    local d = S.draft
    local kind, _, set = field(k)
    if not kind or not catOf(k) then return false end
    v = math.tointeger(tonumber(v))
    if v == nil then return false end
    if kind == 'slider' then
        local lo, hi = sliderRange(k)
        if v < lo or v > hi or sliderOff(k, d.a) then return false end
        set(d.a, v)
        return true
    end
    local list = options(k, d.sex)
    if not list or v < 1 or v > #list then return false end
    set(d.a, list[v])
    -- A RESET PUTS BACK EVERYTHING THE ROW'S BUTTONS CHANGE: the item and its
    -- color -- a component's or a prop's texture, an overlay's color, the Hair
    -- row's hair color. An opacity is a row of its own, with its own reset.
    local c = k:match('^c(%d+)$')
    if c then d.a.c[tonumber(c)][2] = 0 end
    if k == 'c2' then d.a.h[1] = 0 end
    local p = k:match('^p(%d+)$')
    if p then d.a.p[propIndex(tonumber(p))][2] = 0 end
    local o = k:match('^o(%d+)$')
    if o then d.a.o[tonumber(o) + 1][3] = 0 end
    return true
end

--- A swatch's press: the row's color `c`, 0-based -- in its palette, or the
--- item's `c`th texture (owner, 2026-10-14: "any button showing "next color"
--- should have a button for a color swatch instead"). Refused for an item
--- that shows no color, past its colors, or the color already on.
local function setColor(k, c)
    local d = S.draft
    if not catOf(k) or math.type(c) ~= 'integer' or c < 0 then return false end
    local ped = PlayerPedId()
    if k == 'h1' or k:match('^o%d+op$') then return false end
    local n = colorsOf(k, d.a, ped, d.sex)
    if n <= 1 or c >= n then return false end
    if k == 'c2' then
        d.a.h[1] = c
        return true
    end
    local o = k:match('^o(%d+)$')
    if o then
        d.a.o[tonumber(o) + 1][3] = c
        return true
    end
    local slot = tonumber(k:match('^c(%d+)$') or '')
    if slot then
        d.a.c[slot][2] = textures(ped, d.sex, k, d.a.c[slot][1])[c + 1]
        return true
    end
    local p = k:match('^p(%d+)$')
    local i = p and propIndex(tonumber(p))
    if not i or d.a.p[i][1] < 0 then return false end
    d.a.p[i][2] = textures(ped, d.sex, k, d.a.p[i][1])[c + 1]
    return true
end

-- ═══ RANDOMIZE (owner, 2026-10-13: "a randomize button for the whole ped";
-- 2026-10-14: "the randomize button should randomize those additional
-- categories too, and add them to the list when it sets them") ═══

local function rand(lo, hi)
    if hi <= lo then return lo end
    return math.random(lo, hi)
end

--- A random entry of `list`, from its `from`th on (the first otherwise).
local function pick(list, from)
    from = from or 1
    if #list < from then return list[1] end
    return list[rand(from, #list)]
end

--- A count row on a random item, from its list's `from`th on, wearing a
--- random texture of it.
local function randomItem(d, ped, k, from)
    local list = options(k, d.sex)
    if not list then return end
    local _, _, set = field(k)
    local v = pick(list, from)
    set(d.a, v)
    local slot = tonumber(k:match('^c(%d+)$') or '')
    if slot then
        d.a.c[slot][2] = v == noneOf(slot, d.sex) and 0 or pick(textures(ped, d.sex, k, v))
        return
    end
    local p = k:match('^p(%d+)$')
    local i = p and propIndex(tonumber(p))
    if i then d.a.p[i][2] = v < 0 and 0 or pick(textures(ped, d.sex, k, v)) end
end

--- RANDOMIZE'S CORE, and a new custom look: a starting face, the eyes, the
--- skin, the face's features near the middle, a hairstyle and its colors (the
--- eyebrows and a man's beard in them), and the clothes -- with what the top
--- forces.
local function randomizeCore(d)
    local a, R = d.a, C().random
    local ped = PlayerPedId()
    local f = rand(0, #C().faces[d.sex] - 1)
    a.f = f ~= 0 and f or nil
    a.e = rand(0, R.naturalEyes - 1)
    a.sk = rand(0, 45)
    for i = 1, A.FEATURES do
        a.ff[i] = rand((i == 19 or i == 20) and 0 or -R.featureSpread, R.featureSpread)
    end
    local color = rand(0, R.naturalHair - 1)
    a.h = { color, rand(0, R.naturalHair - 1) }
    randomItem(d, ped, 'c2', 2)
    a.c[2][2] = 0
    local brows = options('o2', d.sex)
    if brows then a.o[A.EYEBROWS + 1] = { pick(brows), 100, color } end
    local beard = options('o1', d.sex)
    if d.sex == 'm' and beard and rand(0, 1) == 1 then
        a.o[2] = { pick(beard, 2), 100, color }
    else
        a.o[2] = { A.NONE, 100, 0 }
    end
    for _, k in ipairs({ 'c11', 'c8', 'c4', 'c6' }) do randomItem(d, ped, k, 1) end
    applyForced(d, ped, 11)
end

--- An extra taken off: every row of it back to none, its tattoos gone.
local function clearExtra(d, id)
    if id == 'tattoos' then
        clearTats(d)
        return
    end
    local cat = catById(id)
    for _, k in ipairs(cat and cat.rows or {}) do
        local n = k:match('^c(%d+)$')
        if n then d.a.c[tonumber(n)] = { C().componentNone[tonumber(n)] or 0, 0 } end
        n = k:match('^p(%d+)$')
        if n then d.a.p[propIndex(tonumber(n))] = { -1, 0 } end
        n = k:match('^o(%d+)$')
        if n then d.a.o[tonumber(n) + 1] = { A.NONE, 100, 0 } end
    end
end

--- An extra put on by Randomize: an item of each of its rows (never none),
--- Makeup a random color of each, Tattoos a few in zones with room.
local function randomExtra(d, ped, id)
    local R = C().random
    if id == 'tattoos' then
        clearTats(d)
        for _ = 1, rand(R.tattoosMin, R.tattoosMax) do
            local open = {}
            for _, z in ipairs(tatZones()) do
                local free = {}
                if #d.tats[z] < A.TATTOOS_PER_ZONE then
                    local used = usedIn(d.tats[z])
                    for _, i in ipairs(zoneIds(d.sex, z)) do
                        if not used[i] then free[#free + 1] = i end
                    end
                end
                if #free > 0 then open[#open + 1] = { z = z, free = free } end
            end
            if #open == 0 then break end
            local pickZ = open[rand(1, #open)]
            addTatRow(d, pickZ.z, pickZ.free[rand(1, #pickZ.free)])
        end
        return
    end
    local cat = catById(id)
    for _, k in ipairs(cat and cat.rows or {}) do
        local o = k:match('^o(%d+)$')
        if o then
            local list = options(k, d.sex)
            if list then
                local pal = C().overlayPalette[tonumber(o)]
                local n = pal and math.min(C().paletteMax, pal == 1 and GetNumHairColors() or GetNumMakeupColors()) or 1
                d.a.o[tonumber(o) + 1] = { pick(list), 100, rand(0, math.max(1, n) - 1) }
            end
        elseif field(k) == 'count' then
            randomItem(d, ped, k, 2)
        end
    end
end

--- THE WHOLE LOOK: the core, then each extra on (a chance of random.extra) or
--- off. The extras it keeps keep their places; the ones it puts on join the
--- end, in a random order; the ones it takes off go back to none.
local function randomizeAll(d)
    local ped = PlayerPedId()
    randomizeCore(d)
    local on = {}
    for _, id in ipairs(C().extras) do on[id] = math.random() < C().random.extra end
    local x = {}
    for _, id in ipairs(d.a.x or {}) do
        if on[id] then x[#x + 1] = id else clearExtra(d, id) end
    end
    local added = {}
    for _, id in ipairs(C().extras) do
        if on[id] and not indexOf(x, id) then added[#added + 1] = id end
    end
    for i = #added, 2, -1 do
        local j = rand(1, i)
        added[i], added[j] = added[j], added[i]
    end
    for _, id in ipairs(added) do x[#x + 1] = id end
    d.a.x = x
    for _, id in ipairs(x) do randomExtra(d, ped, id) end
end

-- ---------------------------------------------------------------------------
-- Open, close and the gestures
-- ---------------------------------------------------------------------------

--- "Physically clean and dry the ped using natives when they enter the new
--- locker UI" (owner, 2026-10-07). Never ClearPedDecorations: tattoos are not
--- dirt.
local function cleanAndDry()
    local ped = PlayerPedId()
    ClearPedBloodDamage(ped)
    ResetPedVisibleDamage(ped)
    ClearPedWetness(ped)
    ClearPedEnvDirt(ped)
end

--- Close the page's state: the draft discarded, the worn ped back, the camera
--- home. Safe to call twice.
function V.close()
    if not S.open and not S.draft then return end
    S.open = false
    discard()
    S.tab = nil
    if S.first == 'done' and S.worn and BR.State.me.state == BR.PlayerState.LOBBY then wear(S.worn) end
    V.push()
end

--- THE OPEN IS ONE PUSH (#28 lag): the state as it is, the ped cleaned, and
--- the server asked again only when what this side holds is stale.
local function open()
    S.open = true
    S.draft = nil
    S.tab = defaultTab()
    -- No numbered request of this opening has been seen yet.
    S.tabSeq = nil
    V.push()
    cleanAndDry()
    if stale() then fetch() end
end

local function wearStock(id)
    if not stockById(id) then return end
    if S.loadingId then
        S.queued = id
        return
    end
    S.loadingId = id
    V.push()
    local rec = { k = 's', id = id }
    dress(modelOf(rec), nil, function(ok, why)
        S.loadingId = nil
        if ok then
            S.worn = rec
            remember(rec)
            sendWear(rec)
        elseif why ~= 'left' then
            -- Season 1's words for the same failure. A match that started
            -- while the model streamed in is not one: nothing changed.
            BR.Notify('That character could not be loaded.', 'warn')
        end
        local nextId = S.queued
        S.queued = nil
        if nextId and nextId ~= id and why ~= 'left' then wearStock(nextId) else V.push() end
    end)
end

local function wearSaved(id)
    local p = pedById(id)
    if not p then return end
    local rec = { k = 'p', id = id, a = A.copy(p.a) }
    S.loadingId = id
    V.push()
    dress(modelOf(rec), A.copy(p.a), function(ok, why)
        S.loadingId = nil
        if ok then
            S.worn = rec
            remember(rec)
            sendWear(rec)
        elseif why ~= 'left' then
            BR.Notify('That character could not be loaded.', 'warn')
        end
        V.push()
    end)
end

local function newReq()
    nextReq = nextReq + 1
    return nextReq
end

--- { op = 'new', name } or { op = 'update', id, name }: a new look is named,
--- an update saves over the look being edited and renames it to the name
--- typed in the save dialog.
local function save(data)
    local d = S.draft
    if not d or not d.dirty then return end
    -- Never past 10 tattoos a body zone, which the server refuses too.
    if A.tattoosOverCap(d.a, tattooZone) then return end
    local a = A.encode(d.a)
    if not a then return end
    local op = data.op
    local payload
    if op == 'new' then
        if not A.isName(data.name) then return end
        payload = { op = 'new', name = data.name, a = a }
    elseif op == 'update' then
        if not d.editing or not pedById(d.editing) then return end
        if data.id ~= nil and data.id ~= d.editing then return end
        if data.name ~= nil and not A.isName(data.name) then return end
        payload = { op = 'update', id = d.editing, name = data.name, a = a }
    else
        return
    end
    payload.req = newReq()
    S.busy, S.busyOp, S.busyAt = payload.req, 'save', GetGameTimer()
    TriggerServerEvent(BR.Net.LOCKER2_SAVE, payload)
end

--- The camera buttons (LOCKER2_CAM): turn around, a step of zoom (the
--- buttons and the wheel), and Reset view -- the look facing the camera again
--- and the camera back on the category's framing. Turning is Season 1's own
--- spin (LOCKER_SPIN), which the page sends for the rotate buttons and a drag.
local function camera(data)
    local LC = BR.LobbyCam
    if data.op == 'turn' then
        BR.Locker.spinBy(180)
    elseif data.op == 'zoom' then
        local dz = math.tointeger(tonumber(data.d))
        if (dz == 1 or dz == -1) and LC and LC.zoom then LC.zoom(dz) end
    elseif data.op == 'reset' then
        local home = BR.Config.Match.lobbyPos.heading
        BR.Locker.spinBy(((home - GetEntityHeading(PlayerPedId()) + 180.0) % 360.0) - 180.0)
        local cat = S.draft and S.draft.cat and catById(S.draft.cat)
        if LC and LC.resetView then LC.resetView(cat and cat.cam or nil) end
    end
end

--- The gestures that change something. Refused while the ped is held by the
--- walk, loading, or waiting on the server. A handler that returns false
--- changed nothing, and nothing is pushed.
local ACTIONS = {}

--- { sex, seq }: a new custom look -- the core randomized, no extras -- on the
--- freemode ped of that sex. Never clean: it has never been saved.
ACTIONS[BR.NuiCb.LOCKER2_NEW] = function(data)
    if S.draft and S.draft.dirty then return end
    local sex = data.sex
    if sex ~= 'm' and sex ~= 'f' then return end
    S.tab = CUSTOM[sex]
    local d = newDraft(sex, A.default(sex), nil, nil)
    S.draft = d
    if BR.LobbyCam and BR.LobbyCam.unfocus then BR.LobbyCam.unfocus() end
    dress(modelOfSex(sex), A.copy(d.a), function(ok)
        if ok and S.draft == d and modelReady(d) then
            randomizeCore(d)
            syncExtras(d.a)
            applyAll()
        end
        V.push()
    end)
    return false
end

--- { id, seq }: a saved look, to edit.
ACTIONS[BR.NuiCb.LOCKER2_EDIT] = function(data)
    if S.draft and S.draft.dirty then return end
    local p = pedById(data.id)
    if not p then return end
    S.tab = CUSTOM[p.a.s]
    startDraft(p.a.s, p.a, p.id)
    return false
end

--- { seq }: out of the editor -- the draft dropped (the page asked first if it
--- was unsaved) and the worn look put back on.
ACTIONS[BR.NuiCb.LOCKER2_LEAVE] = function()
    discard()
    S.tab = defaultTab()
    if S.worn then wear(S.worn) end
end

ACTIONS[BR.NuiCb.LOCKER2_STEP] = function(data)
    local k = data.k
    local delta = math.tointeger(tonumber(data.d))
    if not S.draft or type(k) ~= 'string' or (delta ~= 1 and delta ~= -1) then return false end
    local ok = change(k, function(d)
        if not stepRow(k, delta) then return false end
        forcedAfter(d, k)
        return true
    end)
    if ok then applyKey(k) end
    return ok
end

ACTIONS[BR.NuiCb.LOCKER2_SET] = function(data)
    local k = data.k
    if not S.draft or type(k) ~= 'string' then return false end
    local ok = change(k, function(d)
        if not setRow(k, data.v) then return false end
        forcedAfter(d, k)
        return true
    end)
    if ok then applyKey(k) end
    return ok
end

ACTIONS[BR.NuiCb.LOCKER2_COLOR] = function(data)
    local k = data.k
    local c = math.tointeger(tonumber(data.c))
    if not S.draft or type(k) ~= 'string' or not c or not modelReady(S.draft) then return false end
    local ok = change(k .. ':c', function(d)
        if not setColor(k, c) then return false end
        forcedAfter(d, k)
        return true
    end)
    if ok then applyKey(k) end
    return ok
end

ACTIONS[BR.NuiCb.LOCKER2_RANDOM] = function()
    local d = S.draft
    if not d or not modelReady(d) then return false end
    local ok = change(nil, function()
        randomizeAll(d)
        return true
    end)
    if ok then applyAll() end
    return ok
end

ACTIONS[BR.NuiCb.LOCKER2_UNDO] = function()
    return travel('past', 'future')
end

ACTIONS[BR.NuiCb.LOCKER2_REDO] = function()
    return travel('future', 'past')
end

--- { id, on }: "Add more" puts an extra on at the END of the list, wearing
--- its first item (Makeup and Tattoos with nothing on yet, to be chosen); its
--- trash icon takes it off, every row of it back to none.
ACTIONS[BR.NuiCb.LOCKER2_EXTRA] = function(data)
    local d = S.draft
    local id = data.id
    if not d or not isExtra(id) or not modelReady(d) then return false end
    local on = data.on == true
    if on == (indexOf(d.a.x or {}, id) ~= nil) then return false end
    local ok = change(nil, function()
        local x = {}
        for _, e in ipairs(d.a.x or {}) do
            if e ~= id then x[#x + 1] = e end
        end
        if on then
            x[#x + 1] = id
            local cat = catById(id)
            local k = cat and cat.rows and cat.rows[1]
            if k and k:match('^[cp]%d+$') then
                local list = options(k, d.sex)
                local _, _, set = field(k)
                if list and list[2] then set(d.a, list[2]) end
            end
        else
            clearExtra(d, id)
        end
        d.a.x = x
        return true
    end)
    if ok then applyAll() end
    return ok
end

--- { ks }: these rows back to their defaults, one step -- a face group's
--- reset.
ACTIONS[BR.NuiCb.LOCKER2_DEFAULTS] = function(data)
    local d = S.draft
    if not d or type(data.ks) ~= 'table' then return false end
    local ok = change(nil, function()
        local any = false
        for n, k in ipairs(data.ks) do
            if n > 64 then break end
            local kind, get, set
            if type(k) == 'string' then kind, get, set = field(k) end
            if kind == 'slider' and catOf(k) and not sliderOff(k, d.a) then
                local _, _, def = sliderRange(k)
                if get(d.a) ~= def then
                    set(d.a, def)
                    any = true
                end
            end
        end
        return any
    end)
    if ok then applyAll() end
    return ok
end

--- The page sends this on every summary line pressed and every row touched,
--- the same category or not: whether the camera has to move is decided here,
--- off where the camera actually is, never off the page's copy of `cat`.
ACTIONS[BR.NuiCb.LOCKER2_CAT] = function(data)
    if not S.draft then return false end
    local cat = catById(data.cat)
    if not cat then return false end
    local LC = BR.LobbyCam
    local there = LC and LC.focused and LC.focused() == cat.cam
    -- Nothing to move and nothing to draw: no push either, since every row
    -- touched sends this.
    if there and S.draft.cat == cat.id then return false end
    S.draft.cat = cat.id
    if LC and LC.focus and not there then LC.focus(cat.cam) end
end

--- A change to the draft's tattoos, onto the preview at once: one more
--- decoration for an Add (`added`), and for a choice or a Remove the rest put
--- back, since decorations only come off together.
local function tatChanged(added)
    local d = S.draft
    local ped = PlayerPedId()
    if GetEntityModel(ped) ~= modelOfSex(d.sex) then return end
    if added then
        local h = tattooHash(added, d.sex)
        AddPedDecorationFromHashes(ped, h[1], h[2])
        noteDecos(ped, 1)
    else
        noteDecos(ped, tattoos(ped, d.a))
    end
    noteApplied(GetEntityModel(ped), A.copy(d.a), ped)
end

--- { z, i }: "Add more" in the Tattoos extra, once the player has picked the
--- zone and the tattoo -- a new row at the foot of that zone. Refused at the
--- zone's cap, for a tattoo a row of the zone holds, or one not of the zone
--- and the draft's sex. All free.
ACTIONS[BR.NuiCb.LOCKER2_TAT_ADD] = function(data)
    local d = S.draft
    local z, i = data.z, math.tointeger(tonumber(data.i))
    if not d or type(z) ~= 'string' or not i then return false end
    local rows = d.tats[z]
    if not rows or #rows >= A.TATTOOS_PER_ZONE or not tattooFor(i, d.sex) then return false end
    if BR.Config.Tattoos.list[i][2] ~= z or usedIn(rows)[i] then return false end
    local ok = change(nil, function()
        addTatRow(d, z, i)
        return true
    end)
    if ok then tatChanged(i) end
    return ok
end

--- { r, i }: a row's tattoo, chosen in its list -- one of its own zone's for
--- the draft's sex, and none another row of the zone holds.
ACTIONS[BR.NuiCb.LOCKER2_TAT_SET] = function(data)
    local d = S.draft
    local r, i = math.tointeger(tonumber(data.r)), math.tointeger(tonumber(data.i))
    if not d or not r or not i then return false end
    local row, rows = tatRowById(d, r)
    if not row or i == row.i or not tattooFor(i, d.sex) then return false end
    local list = BR.Config.Tattoos.list
    if list[i][2] ~= list[row.i][2] or usedIn(rows, row)[i] then return false end
    local ok = change(nil, function()
        local live = tatRowById(d, r)
        A.setTattoo(d.a, list[live.i][1], false)
        A.setTattoo(d.a, list[i][1], true)
        live.i = i
        return true
    end)
    if ok then tatChanged(nil) end
    return ok
end

--- { r }: a row's trash icon.
ACTIONS[BR.NuiCb.LOCKER2_TAT_DEL] = function(data)
    local d = S.draft
    local r = math.tointeger(tonumber(data.r))
    if not d or not r or not tatRowById(d, r) then return false end
    local ok = change(nil, function()
        local row, rows, k = tatRowById(d, r)
        table.remove(rows, k)
        A.setTattoo(d.a, BR.Config.Tattoos.list[row.i][1], false)
        return true
    end)
    if ok then tatChanged(nil) end
    return ok
end

ACTIONS[BR.NuiCb.LOCKER2_WEAR] = function(data)
    if S.draft and S.draft.dirty then return end
    if data.k == 's' then
        wearStock(data.id)
    elseif data.k == 'p' and A.isPedId(data.id) then
        wearSaved(data.id)
    end
end

ACTIONS[BR.NuiCb.LOCKER2_SAVE] = function(data)
    save(data)
end

ACTIONS[BR.NuiCb.LOCKER2_RENAME] = function(data)
    if not A.isPedId(data.id) or not pedById(data.id) or not A.isName(data.name) then return end
    local req = newReq()
    S.busy, S.busyOp, S.busyAt = req, 'rename', GetGameTimer()
    TriggerServerEvent(BR.Net.LOCKER2_RENAME, { req = req, id = data.id, name = data.name })
end

ACTIONS[BR.NuiCb.LOCKER2_DELETE] = function(data)
    if not A.isPedId(data.id) or not pedById(data.id) then return end
    local req = newReq()
    S.busy, S.busyOp, S.busyAt = req, 'delete', GetGameTimer()
    TriggerServerEvent(BR.Net.LOCKER2_DELETE, { req = req, id = data.id })
end

--- The requests that start or end a draft, which the page numbers.
local NUMBERED = {
    [BR.NuiCb.LOCKER2_NEW] = true, [BR.NuiCb.LOCKER2_EDIT] = true, [BR.NuiCb.LOCKER2_LEAVE] = true,
}

AddEventHandler('br:ui:action', function(name, data)
    if type(name) ~= 'string' or name:sub(1, 11) ~= 'br/locker2/' then return end
    if not claims() then return end
    data = type(data) == 'table' and data or {}

    if name == BR.NuiCb.LOCKER2_OPEN then
        if BR.State.me.state == BR.PlayerState.LOBBY then open() end
        return
    elseif name == BR.NuiCb.LOCKER2_CLOSE then
        V.close()
        return
    elseif name == BR.NuiCb.LOCKER2_SHOTS then
        if BR.Locker2Shot and type(data.ids) == 'table' then
            local list = {}
            for _, id in ipairs(data.ids) do
                local p = pedById(id)
                if p then
                    -- The ped the player is wearing is shot off the player.
                    local own = S.worn and S.worn.k == 'p' and S.worn.id == p.id and wearing(S.worn)
                    list[#list + 1] = { id = p.id, up = p.up, a = p.a, img = p.img, own = own or nil }
                end
            end
            BR.Locker2Shot.request(list)
        end
        return
    elseif name == BR.NuiCb.LOCKER2_SHOTDONE then
        if BR.Locker2Shot then BR.Locker2Shot.done(data.id) end
        return
    elseif name == BR.NuiCb.LOCKER2_TATS then
        -- The list the page draws the Tattoos extra from, once per sex: it
        -- changes nothing, so nothing refuses it.
        if data.sex == 'm' or data.sex == 'f' then
            TriggerEvent('br:ui:sendLocal', BR.Nui.LOCKER2_TATS, catalog(data.sex))
        end
        return
    elseif name == BR.NuiCb.LOCKER2_PAL then
        -- The swatch grids' colors, likewise.
        TriggerEvent('br:ui:sendLocal', BR.Nui.LOCKER2_PAL, palettesOut())
        return
    elseif name == BR.NuiCb.LOCKER2_CAM then
        -- The camera, never the look: no push, and no draft needed.
        if S.open and inLobby() and not locked() then camera(data) end
        return
    elseif name == BR.NuiCb.LOCKER2_SHOT then
        local wanted = BR.Locker2Shot ~= nil and BR.Locker2Shot.takeSave(data.id)
        if wanted and pedById(data.id) and type(data.img) == 'string' then
            local req = newReq()
            shotReqs[req] = data.id
            TriggerServerEvent(BR.Net.LOCKER2_SHOT, { req = req, id = data.id, img = data.img })
        end
        return
    end

    local act = ACTIONS[name]
    if not act then return end
    -- THE PAGE MOVES ITS VIEW ON THE PRESS, BEFORE THIS ANSWERS (#28 review).
    -- So every request that starts or ends a draft carries the page's own
    -- sequence number, and every push after it -- refused or not -- says which
    -- request it has seen. Once that is the page's latest, the page follows
    -- this file's draft, so a refusal it could not foresee (a model still
    -- streaming in) takes it back rather than leaving it in an editor Lua never
    -- opened.
    if NUMBERED[name] then S.tabSeq = math.tointeger(data.seq) end
    -- A STOCK PICK WHILE ONE IS LOADING IS REMEMBERED, NOT REFUSED: pressing
    -- four quickly ends on the fourth (Season 1's rule, locker.lua).
    if name == BR.NuiCb.LOCKER2_WEAR and data.k == 's' and S.open and not locked() and not S.busy
       and S.loadingId and stockById(S.loadingId) then
        if stockById(data.id) then S.queued = data.id end
        V.push()
        return
    end
    -- Not in the lobby is refused too: the page is up there alone, and the
    -- lobby tick closes it within a tick of leaving.
    if not S.open or not inLobby() or locked() or S.loadingId or S.applying or S.busy then
        V.push()
        return
    end
    if act(data) ~= false then V.push() end
end)

-- Leaving the locker any other way -- a match starting pops it off the focus
-- stack (client/state.lua), the watchdog clears the stack -- is a close: the
-- draft goes and the camera comes home. Chat opened over it is not.
AddEventHandler('br:ui:focusChanged', function(top)
    if not S.open then return end
    if top ~= 'locker' and top ~= 'chat' then V.close() end
end)

AddEventHandler('br:ui:ready', function()
    V.push()
end)

-- A SEASON CHANGE IS TOLD TO THE PAGE FROM THE LOBBY. The page only draws the
-- locker there, and a switch can land mid-match (perf_client's worlds switch
-- in every phase), where nothing here should cost a thing.
BR.Season.onChange(function()
    S.repush = true
end)

-- ---------------------------------------------------------------------------
-- Season 1's two questions
-- ---------------------------------------------------------------------------

local unknownSince = nil

--- Should Season 1's locker hold its first apply? While the season is unknown
--- (unknownWaitMs at most, so a Season 1 client never waits on a Season 2
--- question for long) and while Locker v2 is on -- and, once v2 HAS been on
--- this session (a live `brseason` back to Season 1), while the entrance holds
--- the ped, as every other change waits. A client that was only ever on
--- Season 1 never reaches that last clause.
--- @return boolean
function V.defer()
    if BR.Season.current() == nil then
        unknownSince = unknownSince or GetGameTimer()
        return GetGameTimer() - unknownSince < C().unknownWaitMs
    end
    if claims() then return true end
    return S.everClaimed == true and locked()
end

--- Which model the loading screen and the entrance walk should wait to see:
--- nil off Locker v2 (Season 1 asks its own), 0 while the first apply is still
--- deciding (nothing matches it, so both wait -- each within its own bound),
--- otherwise the model being put on or already on.
--- @return number|nil
function V.wantHash()
    if not claims() then return nil end
    if S.first ~= 'done' then return 0 end
    return S.want
end

-- ---------------------------------------------------------------------------
-- The lobby tick: the first apply, arrivals, the gate, the lock
-- ---------------------------------------------------------------------------

--- How long a write may wait on the server before the page is given back.
local BUSY_MS = 10000

local function firstApply()
    S.first = 'done'
    S.waitTicks = nil
    local rec = S.serverWorn
    if not rec then rec = A.decodeWorn(GetResourceKvpString(KVP)) end
    if rec and rec.k == 's' and not stockById(rec.id) then rec = nil end
    if not rec then rec = { k = 's', id = BR.Locker.chosen() } end
    S.worn = rec
    remember(rec)
    wear(rec, nil, true)
    V.push()
end

--- Live `brseason` back to Season 1: the page closes, the camera comes home,
--- and -- in the lobby, once the entrance has let go of the ped -- Season 1's
--- ped goes back on if this one is not it.
local function gateOff()
    S.open = false
    discard()
    S.tab = nil
    S.first = 'idle'
    S.waitTicks = nil
    S.applied = nil
    S.pending = nil
    S.serverSeen, S.serverWorn = false, nil
    S.restoreS1 = S.dressed == true
    S.dressed = false
    S.repush = true
end

--- The other half of gateOff, from the lobby tick.
local function restoreS1()
    S.restoreS1 = false
    local want = GetHashKey(BR.PedById(BR.Locker.chosen()).model)
    if GetEntityModel(PlayerPedId()) ~= want then BR.Locker.apply(nil) end
end

BR.Loop.register(BR.Loop.TICK, 'locker2.lobby', function()
    local onNow = claims()
    if onNow then S.everClaimed = true end
    if onNow ~= S.wasOn then
        local was = S.wasOn
        S.wasOn = onNow
        if was == true and not onNow then gateOff() end
    end
    local inLobby = BR.State.me.state == BR.PlayerState.LOBBY
    if not onNow then
        if inLobby and (S.repush or S.restoreS1) and not locked() then
            if S.repush then
                S.repush = false
                V.push()
            end
            if S.restoreS1 then restoreS1() end
        end
        return
    end

    if not inLobby then
        -- The draft is discarded when the lobby is left. The look stays on
        -- the ped (a match started mid-edit plays in it) and the worn ped goes
        -- back on at the next lobby arrival.
        if S.draft or S.open then
            S.open = false
            S.tab = nil
            discard()
        end
        S.wasLobby = false
        return
    end

    if not S.wasLobby then
        S.wasLobby = true
        if S.first == 'done' and S.worn and not wearing(S.worn) then wear(S.worn, nil, true) end
    end

    if S.repush then
        S.repush = false
        V.push()
    end

    -- THE FIRST APPLY WAITS FOR THE SERVER, joinWaitMs at most, counted in
    -- ticks (this band runs every 100 ms) rather than read off a clock.
    if S.first == 'idle' then
        S.first = 'waiting'
        S.waitTicks = 0
        fetch()
    end
    if S.first == 'waiting' then
        S.waitTicks = S.waitTicks + 1
        if S.serverSeen or S.waitTicks * 100 >= C().joinWaitMs then firstApply() end
    end

    -- A held wear goes on the moment what held it lets go (table reads until then).
    if S.pending and not S.applying
       and ((S.pendingEarly and not walkingNow()) or (not S.pendingEarly and not locked())) then
        wear(S.pending, nil, S.pendingEarly)
    end

    local l = locked()
    if l ~= S.lastLocked then
        S.lastLocked = l
        if S.open then V.push() end
    end

    -- A write the server never answered does not hold the page forever.
    if S.busy and GetGameTimer() - S.busyAt > BUSY_MS then
        S.busy, S.busyOp, S.busyAt = nil, nil, nil
        BR.Notify(FAILED, 'warn')
        V.push()
    end
end)

-- ---------------------------------------------------------------------------
-- The watcher: the custom ped stays dressed
-- ---------------------------------------------------------------------------
--
-- Resurrections, spawns, the parachute and a bike's helmet all touch the ped's
-- components and props. So every watchMs, while a custom look this file put on
-- is on a ped of its model, the eleven components and five props are compared
-- with that look and the whole look re-applied on any difference -- and
-- re-applied outright when the ped handle itself is new. The bag slot is the
-- parachute's while one is held or in use, and the hat slot a helmet's while
-- one is worn; neither is compared then. The reference is the last look
-- applied, so an unsaved edit is kept, not undone. Tattoos go back on with the
-- whole look on a new handle, and on their own when the same ped carries fewer
-- decorations than just after they went on.
--
-- IN EVERY STATE THE PLAYER HAS A PED TO BE SEEN IN (#28 review): the lobby,
-- the warmup pad, the plane, the drop, the match and downed. The warmup trip
-- itself resurrects the player (client/spawn.lua's toWarmupPad, through
-- BR.Spawn.respawn), so a watch that began only at ALIVE left a new ped bare
-- through the showroom, the plane and the skydive. Not once out (a body, then
-- a spectator) or gone.

local PARACHUTE = nil
local nextWatch = 0

local WATCHED = {
    [BR.PlayerState.LOBBY] = true, [BR.PlayerState.WARMUP] = true, [BR.PlayerState.BUS] = true,
    [BR.PlayerState.FREEFALL] = true, [BR.PlayerState.GLIDE] = true,
    [BR.PlayerState.ALIVE] = true, [BR.PlayerState.DBNO] = true,
}

BR.Loop.register(BR.Loop.TICK, 'locker2.watch', function()
    local ap = S.applied
    if not ap or not ap.a or S.applying then return end
    if not WATCHED[BR.State.me.state] then return end
    if not claims() then return end
    local now = GetGameTimer()
    if now < nextWatch then return end
    nextWatch = now + C().watchMs

    local ped = PlayerPedId()
    if GetEntityModel(ped) ~= ap.model then return end
    local a = ap.a
    if ped ~= ap.ped then
        ap.ped = ped
        noteDecos(ped, V.applyTo(ped, a))
        reassertLater(ped, a)
        return
    end

    PARACHUTE = PARACHUTE or GetHashKey('GADGET_PARACHUTE')
    local chute = isTrue(HasPedGotWeapon(ped, PARACHUTE, false)) or GetPedParachuteState(ped) >= 0
    local helmet = isTrue(IsPedWearingHelmet(ped))
    local differs = false
    for slot = 1, A.COMPS do
        if not (slot == 5 and chute) then
            if GetPedDrawableVariation(ped, slot) ~= a.c[slot][1]
               or GetPedTextureVariation(ped, slot) ~= a.c[slot][2] then
                differs = true
                break
            end
        end
    end
    if not differs then
        for i, slot in ipairs(A.PROPS) do
            if not (slot == 0 and helmet) then
                local d = GetPedPropIndex(ped, slot)
                local want = a.p[i][1]
                if d ~= want or (want >= 0 and GetPedPropTextureIndex(ped, slot) ~= a.p[i][2]) then
                    differs = true
                    break
                end
            end
        end
    end
    if differs then
        headBlend(ped, a)
        features(ped, a)
        overlays(ped, a)
        hair(ped, a)
        SetPedEyeColor(ped, a.e)
        for slot = 1, A.COMPS do
            if slot ~= 2 and not (slot == 5 and chute) then component(ped, a, slot) end
        end
        for i, slot in ipairs(A.PROPS) do
            if not (slot == 0 and helmet) then prop(ped, a, i) end
        end
        reassertLater(ped, a)
    end
    -- THE SAME PED WITH ITS TATTOOS GONE (a resurrection can keep the handle):
    -- they go back on. Asked only of a ped that had some.
    restoreLost(ped, a)
end)

-- ---------------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------------

RegisterCommand('brlocker2', function(_, args)
    print('=== locker2 ===')
    print(('  on       %s'):format(tostring(claims())))
    print(('  first    %s'):format(S.first))
    print(('  worn     %s'):format(S.worn and A.encodeWorn(S.worn) or 'none'))
    print(('  peds     %d'):format(#S.peds))
    print(('  tab      %s  draft %s'):format(tostring(S.tab), S.draft and (S.draft.dirty and 'dirty' or 'clean') or 'none'))
    print(('  applied  %s'):format(S.applied and (S.applied.a and 'custom' or 'stock') or 'none'))
    -- In the look, and the decorations the engine says the ped carries now:
    -- the playtest's count for whether every tattoo in the rows is drawn.
    print(('  tattoos  %d  decorations %s'):format(S.applied and S.applied.a and #tattooRows(S.applied.a) or 0,
        tostring(decoCount(PlayerPedId()) or '?')))
    -- THE ITEMS EACH ROW LEFT OUT (the valid-item filter): the playtest's
    -- count, per sex, of the drawables the game would draw nothing for.
    for _, sex in ipairs({ 'm', 'f' }) do
        local keys = {}
        for k in pairs(V.removed(sex)) do keys[#keys + 1] = k end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do parts[#parts + 1] = ('%s %d'):format(k, V.removed(sex)[k]) end
        if #parts > 0 then print(('  dropped  %s: %s'):format(sex, table.concat(parts, ', '))) end
    end
end, false)

--- The state, for the suites.
--- @return table
function V.state() return S end
