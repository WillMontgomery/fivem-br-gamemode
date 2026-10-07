-- Locker v2's server half (#28, Season 2): a player's saved custom peds and the
-- ped they wear, kept in DynamoDB through br_ddb.
--
-- ═══ THE CLIENT DECIDES WHAT IT LOOKS LIKE, THIS FILE DECIDES WHAT IS KEPT ═══
--
-- The ped itself is cosmetic and client-only, as in Season 1 (client/locker.lua
-- says why). What a client cannot be trusted with is the RECORD: every write
-- here checks, in this order, the season, the name (Roman letters and digits,
-- 1 to 24 -- owner, 2026-10-07), the id's shape and that this player owns it,
-- the appearance's size BEFORE it is decoded and then its form
-- (br_lib/shared/appearance.lua), and a rate. A refusal answers RESULT with
-- one reason: season, name, appearance, missing, rate, store or lobby.
--
-- ═══ ONE CACHE PER LICENSE ═══
--
-- A fetch reads the database once (the profile's worn record, then the
-- player's `ped#` rows) and every write after it updates the cache from the
-- answer, the shape server/market.lua set. A second fetch inside fetchMs is
-- answered from the cache. A fetch that FAILED leaves every write refused as
-- `store`: writing over rows this server could not read is how a player loses
-- one.
--
-- ═══ ONE ANSWER PER PLAYER PER fetchMs ═══
--
-- An answer is the whole list, every headshot in it, and the owner set no
-- limit on saved peds; the asking is a few bytes. So a source is answered at
-- most once every fetchMs: asking again sooner is answered ONCE, when that
-- time is up (never dropped, so a real client always hears back), and a source
-- asking while a read is in flight waits on it once, however often it asks.
-- (#28 review: 200 asks in 5 s queued 67.7 MB of answers.) The writes need no
-- such rule: each is a token from the bucket below, and a refusal is a few
-- bytes back for a few bytes in.
--
-- ═══ THE WORN PED ═══
--
-- What a player rejoins with: "we must recall the last selected ped when they
-- re-join the server, so they join back using the same ped as they left with"
-- (owner, 2026-10-07). A stock pick or a saved ped, written as `locker2` on the
-- profile row -- at most once every wearMs, and at once when the player drops.
-- A saved ped's appearance is COPIED into it, so deleting that ped leaves the
-- player wearing it, and every successful save makes the saved ped the worn one.
--
-- ═══ NO br_ddb ═══
--
-- A box without it (a dev box with no AWS) keeps everything in memory for the
-- session and says so once.

BR = BR or {}
BR.Locker2 = BR.Locker2 or {}

local L = BR.Locker2
local A = BR.Appearance

local function cfg() return BR.Config.Locker2 end

--- Is Locker v2 on? The server's own season, never a client's word.
local function on()
    return BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('locker2')
end

--- license -> { loaded, failed, fetching, fetchAt, waiters, waiting, sentAt,
---              deferred, peds = {[id]=ped}, worn, wornDirty, wornAt, wornTimer,
---              tokens, tokenAt }
local cache = {}
--- src -> license
local licenseOf = {}

local warnedNoStore = false

--- Epoch milliseconds, for the rows' `cr` and `up` and a new ped's id.
local function nowMs()
    return math.floor(os.time() * 1000 + (GetGameTimer() % 1000))
end

--- @param src integer
--- @return string|nil
local function licenseFor(src)
    if licenseOf[src] then return licenseOf[src] end
    local byKind = BR.Identity and BR.Identity.ofPlayer(src)
    if not byKind or not byKind.license then return nil end
    local lic = BR.Identity.qualified('license', byKind.license)
    licenseOf[src] = lic
    return lic
end

local function entryFor(lic)
    local e = cache[lic]
    if not e then
        e = { loaded = false, failed = false, fetching = false, fetchAt = nil, waiters = {},
              -- src -> true while it waits on a read; src -> when it was last
              -- answered; src -> true while an answer to it is held back.
              waiting = {}, sentAt = {}, deferred = {},
              peds = {}, worn = nil, wornDirty = false, wornAt = nil, wornTimer = false,
              tokens = cfg().writeBucket, tokenAt = GetGameTimer() }
        cache[lic] = e
    end
    return e
end

--- Is br_ddb there to write to? Says once when it is not.
local function stored()
    if GetResourceState('br_ddb') == 'started' then return true end
    if not warnedNoStore then
        warnedNoStore = true
        print('^3[br_core] locker2: br_ddb is not started -- saved peds live in memory for this session^7')
    end
    return false
end

-- ── br_ddb requests ──────────────────────────────────────────────────────────

local nextReq = 0
local pending = {}

local function reply(req, ok, extra)
    local cb = pending[req]
    if not cb then return end
    pending[req] = nil
    cb(ok == true, type(extra) == 'table' and extra or {})
end

for _, verb in ipairs({ 'lockerFetch', 'pedPut', 'pedRename', 'pedShot', 'pedDelete', 'wornSet' }) do
    AddEventHandler('br:ddb:' .. verb .. 'Result', reply)
end

--- One br_ddb request with a timeout; cb(ok, extra). With no br_ddb the
--- answer is yes at once, which is what keeps a dev box's memory working.
local function ask(verb, cb, ...)
    if not stored() then
        cb(true, {})
        return
    end
    nextReq = nextReq + 1
    local req = nextReq
    pending[req] = cb
    SetTimeout(6000, function()
        if pending[req] then
            pending[req] = nil
            cb(false, { error = 'timed out' })
        end
    end)
    TriggerEvent('br:ddb:' .. verb, req, ...)
end

-- ── what goes back to the client ─────────────────────────────────────────────

local function pedOut(p)
    return { id = p.id, name = p.name, a = p.a, up = p.up, img = p.img }
end

local function wornOut(w)
    if not w then return nil end
    return { k = w.k, id = w.id, a = w.a }
end

local function sortedPeds(e)
    local ids = {}
    for id in pairs(e.peds) do ids[#ids + 1] = id end
    table.sort(ids)
    local out = {}
    for i, id in ipairs(ids) do out[i] = pedOut(e.peds[id]) end
    return out
end

--- The whole list, LATENT: it can be a few dozen KB with headshots.
local function sendState(src, e)
    local payload = { worn = wornOut(e.worn), store = not e.failed }
    if e.loaded then payload.peds = sortedPeds(e) end
    e.sentAt[src] = GetGameTimer()
    TriggerLatentClientEvent(BR.Net.LOCKER2_STATE, src, 128000, payload)
end

--- Everyone waiting on a read, answered once each.
local function answerWaiters(e)
    local waiters = e.waiters
    e.waiters, e.waiting = {}, {}
    for _, w in ipairs(waiters) do sendState(w, e) end
end

local function result(src, req, ok, reason, extra)
    local out = extra or {}
    out.req, out.ok, out.reason = req, ok, reason
    TriggerClientEvent(BR.Net.LOCKER2_RESULT, src, out)
end

-- ── the worn ped ─────────────────────────────────────────────────────────────

--- The worn record as the profile row keeps it. The cache holds a saved ped's
--- appearance as its canonical string already, so it is written as it is.
local function wornString(w)
    if not w then return nil end
    if w.k == 's' then return A.encodeWorn(w) end
    if w.k == 'p' and A.isPedId(w.id) and type(w.a) == 'string' then
        return ('{"k":"p","id":"%s","a":%s}'):format(w.id, w.a)
    end
    return nil
end

local function flushWorn(lic)
    local e = cache[lic]
    if not e or not e.wornDirty then return end
    e.wornDirty = false
    e.wornAt = GetGameTimer()
    local s = wornString(e.worn)
    if not s then return end
    if not stored() then return end
    ask('wornSet', function(ok, extra)
        if not ok then
            print(('^3[br_core] locker2: the worn ped was not written for %s (%s)^7')
                :format(lic, tostring(extra.error or extra.refused)))
        end
    end, lic, s)
end

--- Coalesced: at most one write per wearMs, the last ped worn winning.
local function setWorn(lic, e, w)
    if e.worn and e.worn.k == w.k and e.worn.id == w.id and e.worn.a == w.a then return end
    e.worn = w
    e.wornDirty = true
    if e.wornTimer then return end
    local wait = 0
    if e.wornAt then
        wait = math.max(0, e.wornAt + cfg().wearMs - GetGameTimer())
    end
    e.wornTimer = true
    SetTimeout(wait, function()
        e.wornTimer = false
        flushWorn(lic)
    end)
end

-- ── the rate ─────────────────────────────────────────────────────────────────

local function takeToken(e)
    local c = cfg()
    local now = GetGameTimer()
    local refill = (now - e.tokenAt) // c.writeRefillMs
    if refill > 0 then
        e.tokens = math.min(c.writeBucket, e.tokens + refill)
        e.tokenAt = e.tokenAt + refill * c.writeRefillMs
    end
    if e.tokens < 1 then return false end
    if e.tokens >= c.writeBucket then e.tokenAt = now end
    e.tokens = e.tokens - 1
    return true
end

-- ── fetch ────────────────────────────────────────────────────────────────────

--- Read this player's record (or answer from the cache), then send it.
--- @param src integer
--- @param lic string
function L.fetch(src, lic)
    local e = entryFor(lic)
    local now = GetGameTimer()
    if e.fetching then
        if not e.waiting[src] then
            e.waiting[src] = true
            e.waiters[#e.waiters + 1] = src
        end
        return
    end
    -- Answered inside fetchMs already: once more when it is up, and only once.
    local last = e.sentAt[src]
    if last and now - last < cfg().fetchMs then
        if not e.deferred[src] then
            e.deferred[src] = true
            SetTimeout(last + cfg().fetchMs - now, function()
                e.deferred[src] = nil
                if cache[lic] == e and licenseOf[src] == lic then L.fetch(src, lic) end
            end)
        end
        return
    end
    if e.fetchAt and now - e.fetchAt < cfg().fetchMs then
        sendState(src, e)
        return
    end
    e.fetchAt = now
    e.fetching = true
    e.waiters, e.waiting = { src }, { [src] = true }
    if not stored() then
        e.fetching, e.loaded, e.failed = false, true, false
        answerWaiters(e)
        return
    end
    ask('lockerFetch', function(ok, extra)
        e.fetching = false
        if ok then
            local peds = {}
            for _, p in ipairs(type(extra.peds) == 'table' and extra.peds or {}) do
                local a = type(p) == 'table' and A.decode(p.a) or nil
                if a and A.isPedId(p.id) and A.isName(p.name) then
                    peds[p.id] = { id = p.id, name = p.name, a = A.encode(a),
                                   cr = math.tointeger(p.cr) or 0, up = math.tointeger(p.up) or 0,
                                   img = type(p.img) == 'string' and p.img or nil }
                end
            end
            e.peds = peds
            -- A wear this session already made outranks what the row said.
            if not e.wornDirty then
                local w = A.decodeWorn(extra.worn)
                if w and w.a then w.a = A.encode(w.a) end
                e.worn = w
            end
            e.loaded, e.failed = true, false
        else
            e.failed = true
            print(('^3[br_core] locker2: saved peds could not be read for %s (%s) -- writes refused until a read works^7')
                :format(lic, tostring(extra.error)))
        end
        answerWaiters(e)
    end, lic)
end

-- ── the writes ───────────────────────────────────────────────────────────────

--- Shared checks. Returns the entry, or nil and the reason.
local function ready(src)
    if not on() then return nil, 'season' end
    local lic = licenseFor(src)
    if not lic then return nil, 'store' end
    return lic, nil
end

local function writable(e)
    return e ~= nil and e.loaded and not e.failed
end

--- The appearance, size first, then its form. The canonical string or nil.
local function appearanceOf(raw)
    if type(raw) ~= 'string' or #raw > A.MAX_BYTES then return nil end
    local a = A.decode(raw)
    if not a then return nil end
    return A.encode(a)
end

local function isImage(img)
    if type(img) ~= 'string' then return false end
    local prefix = 'data:image/webp;base64,'
    if #img > #prefix + math.ceil(8192 / 3) * 4 or img:sub(1, #prefix) ~= prefix then return false end
    return img:sub(#prefix + 1):match('^[A-Za-z0-9+/]+=?=?$') ~= nil
end

local function reqOf(d)
    return type(d) == 'table' and math.tointeger(d.req) or nil
end

RegisterNetEvent(BR.Net.LOCKER2_FETCH)
AddEventHandler(BR.Net.LOCKER2_FETCH, function()
    local src = source
    if not on() then return end
    local lic = licenseFor(src)
    if not lic then return end
    L.fetch(src, lic)
end)

RegisterNetEvent(BR.Net.LOCKER2_SAVE)
AddEventHandler(BR.Net.LOCKER2_SAVE, function(d)
    local src = source
    local req = reqOf(d)
    if not req then return end
    local lic, why = ready(src)
    if not lic then return result(src, req, false, why) end
    local op = d.op
    if op ~= 'new' and op ~= 'update' and op ~= 'replace' then return result(src, req, false, 'missing') end
    if op == 'new' then
        if not A.isName(d.name) then return result(src, req, false, 'name') end
        if d.id ~= nil then return result(src, req, false, 'missing') end
    elseif not A.isPedId(d.id) then
        return result(src, req, false, 'missing')
    end
    local e = cache[lic]
    if not writable(e) then return result(src, req, false, 'store') end
    local p = op ~= 'new' and e.peds[d.id] or nil
    if op ~= 'new' and not p then return result(src, req, false, 'missing') end
    local canon = appearanceOf(d.a)
    if not canon then return result(src, req, false, 'appearance') end
    if not takeToken(e) then return result(src, req, false, 'rate') end

    local now = nowMs()
    local id, rec
    if op == 'new' then
        repeat id = A.newId(now) until not e.peds[id]
        rec = { n = d.name, a = canon, cr = now, up = now }
    else
        id = d.id
        rec = { n = p.name, a = canon, cr = p.cr, up = now }
    end
    ask('pedPut', function(ok, extra)
        if not ok then
            if extra.refused == 'missing' then
                e.peds[id] = nil
                return result(src, req, false, 'missing', { id = id, gone = true })
            end
            return result(src, req, false, 'store')
        end
        local ped = e.peds[id] or { id = id }
        ped.name, ped.a, ped.cr, ped.up, ped.img = rec.n, rec.a, rec.cr, rec.up, nil
        e.peds[id] = ped
        setWorn(lic, e, { k = 'p', id = id, a = canon })
        result(src, req, true, nil, { id = id, ped = pedOut(ped), worn = wornOut(e.worn) })
    end, lic, id, rec, op == 'new')
end)

RegisterNetEvent(BR.Net.LOCKER2_RENAME)
AddEventHandler(BR.Net.LOCKER2_RENAME, function(d)
    local src = source
    local req = reqOf(d)
    if not req then return end
    local lic, why = ready(src)
    if not lic then return result(src, req, false, why) end
    if not A.isName(d.name) then return result(src, req, false, 'name') end
    if not A.isPedId(d.id) then return result(src, req, false, 'missing') end
    local e = cache[lic]
    if not writable(e) then return result(src, req, false, 'store') end
    local p = e.peds[d.id]
    if not p then return result(src, req, false, 'missing') end
    if not takeToken(e) then return result(src, req, false, 'rate') end
    local now, id, name = nowMs(), d.id, d.name
    ask('pedRename', function(ok, extra)
        if not ok then
            if extra.refused == 'missing' then
                e.peds[id] = nil
                return result(src, req, false, 'missing', { id = id, gone = true })
            end
            return result(src, req, false, 'store')
        end
        p.name, p.up = name, now
        result(src, req, true, nil, { id = id, ped = pedOut(p) })
    end, lic, id, name, now)
end)

RegisterNetEvent(BR.Net.LOCKER2_DELETE)
AddEventHandler(BR.Net.LOCKER2_DELETE, function(d)
    local src = source
    local req = reqOf(d)
    if not req then return end
    local lic, why = ready(src)
    if not lic then return result(src, req, false, why) end
    if not A.isPedId(d.id) then return result(src, req, false, 'missing') end
    local e = cache[lic]
    if not writable(e) then return result(src, req, false, 'store') end
    if not e.peds[d.id] then return result(src, req, false, 'missing') end
    if not takeToken(e) then return result(src, req, false, 'rate') end
    local id = d.id
    ask('pedDelete', function(ok)
        if not ok then return result(src, req, false, 'store') end
        e.peds[id] = nil
        result(src, req, true, nil, { id = id, gone = true })
    end, lic, id)
end)

RegisterNetEvent(BR.Net.LOCKER2_SHOT)
AddEventHandler(BR.Net.LOCKER2_SHOT, function(d)
    local src = source
    local req = reqOf(d)
    if not req then return end
    local lic, why = ready(src)
    if not lic then return result(src, req, false, why) end
    if not A.isPedId(d.id) then return result(src, req, false, 'missing') end
    local e = cache[lic]
    if not writable(e) then return result(src, req, false, 'store') end
    local p = e.peds[d.id]
    if not p then return result(src, req, false, 'missing') end
    if not isImage(d.img) then return result(src, req, false, 'appearance') end
    if not takeToken(e) then return result(src, req, false, 'rate') end
    local id, img = d.id, d.img
    ask('pedShot', function(ok, extra)
        if not ok then
            if extra.refused == 'missing' then
                e.peds[id] = nil
                return result(src, req, false, 'missing', { id = id, gone = true })
            end
            return result(src, req, false, 'store')
        end
        p.img = img
        result(src, req, true, nil, { id = id, ped = pedOut(p) })
    end, lic, id, img)
end)

RegisterNetEvent(BR.Net.LOCKER2_WEAR)
AddEventHandler(BR.Net.LOCKER2_WEAR, function(d)
    local src = source
    if type(d) ~= 'table' or not on() then return end
    local entry = BR.Roster and BR.Roster.get and BR.Roster.get(src)
    if not entry or entry.state ~= BR.PlayerState.LOBBY then return end
    local lic = licenseFor(src)
    if not lic then return end
    local e = entryFor(lic)
    if d.k == 's' and A.isStockId(d.id) then
        setWorn(lic, e, { k = 's', id = d.id })
    elseif d.k == 'p' and A.isPedId(d.id) and writable(e) and e.peds[d.id] then
        setWorn(lic, e, { k = 'p', id = d.id, a = e.peds[d.id].a })
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    local lic = licenseOf[src]
    licenseOf[src] = nil
    if not lic then return end
    local e = cache[lic]
    if e then e.sentAt[src], e.deferred[src] = nil, nil end
    flushWorn(lic)
    for _, other in pairs(licenseOf) do
        if other == lic then return end
    end
    cache[lic] = nil
end)

--- The cached record of a license, for the suites.
--- @param lic string
--- @return table|nil
function L.entry(lic) return cache[lic] end
