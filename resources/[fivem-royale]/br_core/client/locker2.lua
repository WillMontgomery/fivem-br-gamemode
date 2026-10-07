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
-- ui-src/src/screens/LockerV2.tsx draws what BR.Nui.LOCKER2 says and sends the
-- br/locker2/* callbacks. Every one is checked again here, and refused while
-- the entrance walk holds the ped (BR.LobbyPed.lockerLocked), while a ped is
-- loading, or while a write is waiting on the server -- `tab` also while there
-- are unsaved changes.

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
    --- The custom ped being edited: { sex, a, base, editing, dirty, cat }.
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

local function headBlend(ped, a)
    local shape = C().shape[a.s]
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

--- The whole appearance, in one block with no wait: head blend, face
--- features, overlays and their colors, hair and its color, eyes, components,
--- props. Every part syncs to other players only with a head blend set, which
--- is why the blend is always first and always applied.
--- @param ped number
--- @param a table
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
end

--- The head blend settles over a few frames, and an overlay set before it has
--- can be lost. So both are asserted again once it has finished (or after
--- headBlendWaitMs), if the ped still wears this look.
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

        if a then V.applyTo(ped, a) end
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
        V.applyTo(ped, a)
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

local CUSTOM = { male = 'm', female = 'f' }
local TABS = { peds = true, stock = true, male = true, female = true }

local function catOf(k)
    for _, cat in ipairs(C().categories) do
        for _, rk in ipairs(cat.rows) do
            if rk == k then return cat end
        end
    end
    return nil
end

local function propIndex(slot)
    for i, s in ipairs(A.PROPS) do
        if s == slot then return i end
    end
    return nil
end

--- What a row key edits, as (kind, a getter, a setter). nil for no such key.
local function field(k)
    if k == 'sk' then
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

--- The option lists, per sex, enumerated off the freemode ped once it is on.
local optionCache = { m = {}, f = {} }
local missingLogged = {}

local function gen9(ped, slot, d)
    if type(IsPedComponentVariationGen9Exclusive) ~= 'function' then return false end
    return isTrue(IsPedComponentVariationGen9Exclusive(ped, slot, d))
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
    if GetEntityModel(ped) ~= GetHashKey(C().models[sex]) then return nil end
    local list
    if k == 'sk' then
        list = range(0, 45)
    elseif k == 'e' then
        list = range(0, 30)
    elseif k == 'h1' then
        list = range(0, math.min(64, math.max(1, GetNumHairColors())) - 1)
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
        local none = slot == 8 and C().undershirtNone[sex] or nil
        if none then list[1] = none end
        for d = 0, n - 1 do
            if d ~= none and not gen9(ped, slot, d) then
                list[#list + 1] = d
            end
        end
        if #list == 0 then list[1] = 0 end
    elseif k:match('^p%d+$') then
        local slot = tonumber(k:sub(2))
        local n = math.min(1024, GetNumberOfPedPropDrawableVariations(ped, slot))
        list = { -1 }
        for d = 0, n - 1 do list[#list + 1] = d end
    else
        return nil
    end
    optionCache[sex][k] = list
    return list
end

local function indexOf(list, v)
    for i, x in ipairs(list) do
        if x == v then return i end
    end
    return nil
end

--- How many colors a row's item has: its textures, or its palette.
---
--- AN ITEM THAT IS NOT ON THE PED HAS ONE: no prop, and an overlay of none.
--- Its color shows on nothing, so it gets no Next color, and a press of one
--- would only make the draft differ where nobody can see (#28 review).
--- Appearance.encode writes a none overlay's color and opacity as their
--- defaults for the same reason.
local function colorsOf(k, a, ped)
    if k == 'c2' then return math.min(64, GetNumHairColors()) end
    local n = k:match('^o(%d+)$')
    if n then
        local pal = C().overlayPalette[tonumber(n)]
        if not pal or a.o[tonumber(n) + 1][1] == A.NONE then return 1 end
        return math.min(64, pal == 1 and GetNumHairColors() or GetNumMakeupColors())
    end
    n = k:match('^c(%d+)$')
    if n then
        local slot = tonumber(n)
        return math.min(32, GetNumberOfPedTextureVariations(ped, slot, a.c[slot][1]))
    end
    n = k:match('^p(%d+)$')
    if n then
        local i = propIndex(tonumber(n))
        if not i or a.p[i][1] < 0 then return 1 end
        return math.min(32, GetNumberOfPedPropTextureVariations(ped, A.PROPS[i], a.p[i][1]))
    end
    return 1
end

--- Is this slider an opacity of an overlay that is none? It moves nothing on
--- the ped, so it is sent `off` and a set of it is refused (#28 review).
local function sliderOff(k, a)
    local n = k:match('^o(%d+)op$')
    return n ~= nil and a.o[tonumber(n) + 1][1] == A.NONE
end

local function rowsFor(d)
    local rows, cats = {}, {}
    local ped = PlayerPedId()
    if GetEntityModel(ped) ~= GetHashKey(C().models[d.sex]) then return rows, cats end
    for _, cat in ipairs(C().categories) do
        local any = false
        for _, k in ipairs(cat.rows) do
            local kind, get = field(k)
            if kind == 'slider' then
                local lo, hi, def = sliderRange(k)
                rows[#rows + 1] = { k = k, cat = cat.id, kind = 'slider', v = get(d.a),
                                    min = lo, max = hi, def = def, off = sliderOff(k, d.a) or nil }
                any = true
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
                                        colors = colorsOf(k, d.a, ped) }
                    any = true
                end
            end
        end
        if any then cats[#cats + 1] = cat.id end
    end
    return rows, cats
end

--- My peds while the saved peds are still being fetched, as the page opens:
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
    if S.draft and CUSTOM[S.tab] then
        local rows, cats = rowsFor(S.draft)
        edit = { sex = S.draft.sex, editing = S.draft.editing, dirty = S.draft.dirty,
                 cat = S.draft.cat, cats = cats, rows = rows }
    end
    TriggerEvent('br:ui:sendLocal', BR.Nui.LOCKER2, {
        on = true,
        tab = S.tab or defaultTab(),
        -- The page's last `tab` request this answer has seen (see ACTIONS'
        -- handler): the page follows `tab` once it is its own latest.
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
    TriggerServerEvent(BR.Net.LOCKER2_FETCH, {})
end

local function sendWear(rec)
    TriggerServerEvent(BR.Net.LOCKER2_WEAR, { k = rec.k, id = rec.id })
end

RegisterNetEvent(BR.Net.LOCKER2_STATE)
AddEventHandler(BR.Net.LOCKER2_STATE, function(d)
    if type(d) ~= 'table' or not claims() then return end
    S.serverSeen = true
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
            -- A SAVE: the draft is now that saved ped, unchanged.
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

--- A new draft starts on NO category, with the camera home on the whole ped.
---
--- THE ANCHOR THE PAGE LIGHTS IS WHERE THE CAMERA IS (#28 review): `cat` is
--- set only by LOCKER2_CAT, which moves the camera there, and a draft that
--- starts -- a Custom tab, Create, Edit -- sends the camera home and clears it.
--- A draft that began on Face with the camera wherever the last one left it
--- lit Face over the feet, and pressing Face then moved nothing.
local function startDraft(sex, a, editing)
    S.draft = { sex = sex, a = A.copy(a), base = A.copy(a), editing = editing, dirty = false,
                cat = nil }
    if BR.LobbyCam and BR.LobbyCam.unfocus then BR.LobbyCam.unfocus() end
    dress(GetHashKey(C().models[sex]), A.copy(a), function() V.push() end)
end

--- Throw the draft away and put the worn ped back.
local function discard()
    local had = S.draft ~= nil
    S.draft = nil
    if BR.LobbyCam and BR.LobbyCam.unfocus then BR.LobbyCam.unfocus() end
    return had
end

local function touched()
    local d = S.draft
    d.dirty = not A.equal(d.a, d.base)
end

--- Apply the part of the draft one key changed.
local function applyKey(k)
    local d = S.draft
    local ped = PlayerPedId()
    if GetEntityModel(ped) ~= GetHashKey(C().models[d.sex]) then return end
    if k == 'sk' then
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
    local kind, get, set = field(k)
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
    -- Next color -- a component's or a prop's texture, an overlay's color,
    -- the Hair row's hair color. An opacity is a row of its own, with its own
    -- reset.
    local c = k:match('^c(%d+)$')
    if c then d.a.c[tonumber(c)][2] = 0 end
    if k == 'c2' then d.a.h[1] = 0 end
    local p = k:match('^p(%d+)$')
    if p then d.a.p[propIndex(tonumber(p))][2] = 0 end
    local o = k:match('^o(%d+)$')
    if o then d.a.o[tonumber(o) + 1][3] = 0 end
    return true
end

local function nextColor(k)
    local d = S.draft
    if not catOf(k) then return false end
    local ped = PlayerPedId()
    local n = colorsOf(k, d.a, ped)
    if n <= 1 then return false end
    if k == 'c2' then
        d.a.h[1] = (d.a.h[1] + 1) % n
        return true
    end
    local o = k:match('^o(%d+)$')
    if o then
        local i = tonumber(o) + 1
        d.a.o[i][3] = (d.a.o[i][3] + 1) % n
        return true
    end
    local c = k:match('^c(%d+)$')
    if c then
        local slot = tonumber(c)
        d.a.c[slot][2] = (d.a.c[slot][2] + 1) % n
        return true
    end
    local p = k:match('^p(%d+)$')
    if p then
        local i = propIndex(tonumber(p))
        if not i or d.a.p[i][1] < 0 then return false end
        d.a.p[i][2] = (d.a.p[i][2] + 1) % n
        return true
    end
    return false
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

local function open()
    S.open = true
    S.draft = nil
    S.tab = defaultTab()
    -- No `tab` request of this opening has been seen yet.
    S.tabSeq = nil
    V.push()
    cleanAndDry()
    fetch()
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

local function save(data)
    local d = S.draft
    if not d or not d.dirty then return end
    local a = A.encode(d.a)
    if not a then return end
    local op = data.op
    local payload
    if op == 'new' then
        if not A.isName(data.name) then return end
        payload = { op = 'new', name = data.name, a = a }
    elseif op == 'update' then
        if not d.editing or not pedById(d.editing) then return end
        payload = { op = 'update', id = d.editing, a = a }
    elseif op == 'replace' then
        if not A.isPedId(data.id) or not pedById(data.id) then return end
        payload = { op = 'replace', id = data.id, a = a }
    else
        return
    end
    payload.req = newReq()
    S.busy, S.busyOp, S.busyAt = payload.req, 'save', GetGameTimer()
    TriggerServerEvent(BR.Net.LOCKER2_SAVE, payload)
end

--- The gestures that change something. Refused while the ped is held by the
--- walk, loading, or waiting on the server.
local ACTIONS = {}

ACTIONS[BR.NuiCb.LOCKER2_TAB] = function(data)
    local tab = data.tab
    if not TABS[tab] or tab == S.tab then return end
    if S.draft and S.draft.dirty then return end
    if tab == 'peds' and #S.peds == 0 and not fetching() then return end
    local sex = CUSTOM[tab]
    if sex then
        S.tab = tab
        startDraft(sex, A.default(sex), nil)
    else
        discard()
        S.tab = tab
        if S.worn then wear(S.worn) end
    end
end

ACTIONS[BR.NuiCb.LOCKER2_EDIT] = function(data)
    if S.draft and S.draft.dirty then return end
    local p = pedById(data.id)
    if not p then return end
    S.tab = p.a.s == 'f' and 'female' or 'male'
    startDraft(p.a.s, p.a, p.id)
end

ACTIONS[BR.NuiCb.LOCKER2_RESET] = function()
    local d = S.draft
    if not d then return end
    d.a = A.copy(d.base)
    d.dirty = false
    dress(GetHashKey(C().models[d.sex]), A.copy(d.a))
end

ACTIONS[BR.NuiCb.LOCKER2_STEP] = function(data)
    if not S.draft or type(data.k) ~= 'string' then return end
    local delta = math.tointeger(tonumber(data.d))
    if delta ~= 1 and delta ~= -1 then return end
    if stepRow(data.k, delta) then
        touched()
        applyKey(data.k)
    end
end

ACTIONS[BR.NuiCb.LOCKER2_SET] = function(data)
    if not S.draft or type(data.k) ~= 'string' then return end
    if setRow(data.k, data.v) then
        touched()
        applyKey(data.k)
    end
end

ACTIONS[BR.NuiCb.LOCKER2_COLOR] = function(data)
    if not S.draft or type(data.k) ~= 'string' then return end
    if nextColor(data.k) then
        touched()
        applyKey(data.k)
    end
end

--- The page sends this on every anchor press and every row touched, the same
--- category or not: whether the camera has to move is decided here, off where
--- the camera actually is, never off the page's copy of `cat`.
ACTIONS[BR.NuiCb.LOCKER2_CAT] = function(data)
    if not S.draft then return end
    for _, cat in ipairs(C().categories) do
        if cat.id == data.cat then
            local LC = BR.LobbyCam
            local there = LC and LC.focused and LC.focused() == cat.cam
            -- Nothing to move and nothing to draw: no push either, since every
            -- row touched sends this.
            if there and S.draft.cat == cat.id then return false end
            S.draft.cat = cat.id
            if LC and LC.focus and not there then LC.focus(cat.cam) end
            return
        end
    end
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
    -- THE PAGE MOVES ITS TAB ON THE PRESS, BEFORE THIS ANSWERS (#28 review).
    -- So every `tab` carries the page's own sequence number, and every push
    -- after it -- the one this handler always makes, refused or not -- says
    -- which request it has seen. Once that is the page's latest, the page shows
    -- this file's tab, so a refusal it could not foresee (a model still
    -- streaming in) takes it back rather than leaving it on a tab Lua never
    -- switched to.
    if name == BR.NuiCb.LOCKER2_TAB then S.tabSeq = math.tointeger(data.seq) end
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
-- applied, so an unsaved edit is kept, not undone.
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
        V.applyTo(ped, a)
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
end, false)

--- The state, for the suites.
--- @return table
function V.state() return S end
