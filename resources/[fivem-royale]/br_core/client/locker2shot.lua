-- Locker v2's headshots (#28, Season 2): a picture on each My peds card.
--
-- Owner, 2026-10-07: "in the list of saved peds we should display a headshot
-- using RegisterPedHeadshot - if we can display it in NUI and store it in DDB.
-- That's the tricky part though - let's not overly focus on that."
--
-- ═══ TAKEN AT SAVE, KEPT ON THE SERVER ═══
--
-- A ped is shot as it is saved, off the player's own ped, which is wearing
-- exactly what was saved. The page draws the engine's texture
-- (https://nui-img/<txd>/<txd>) to a canvas, sends it back as a small webp
-- (br/locker2/shot), and server/locker2.lua stores it with the ped. A ped
-- saved before that -- or whose upload failed -- is shot once a session off a
-- LOCAL clone (never networked, so nobody else sees it), when the page asks.
--
-- ONE AT A TIME, AND NOTHING KEPT. Each shot is unregistered, and its clone
-- deleted, when the page says it has the picture or after shotWaitMs. Any
-- failure leaves the card plain; nothing is retried.

BR = BR or {}
BR.Locker2Shot = {}

local Shot = BR.Locker2Shot
local isTrue = BR.NativeTruthy

local function C() return BR.Config.Locker2 end

--- Waiting: { id, up, a?, save? }. A save shot goes to the front.
local queue = {}
--- The shot the page has: { id, handle, clone, save, at }.
local current = nil
local running = false
--- A cache-buster for nui-img: a txd name is reused between shots.
local nonce = 0
--- Save shots the page has had, waiting for its upload: [id] = true.
local savesDone = {}

local function send(t)
    TriggerEvent('br:ui:sendLocal', BR.Nui.LOCKER2_SHOT, t)
end

--- Unregister the shot the page had and delete its clone.
local function release()
    local c = current
    current = nil
    if not c then return end
    if c.save then savesDone[c.id] = true end
    if c.handle then UnregisterPedheadshot(c.handle) end
    if c.clone and isTrue(DoesEntityExist(c.clone)) then DeletePed(c.clone) end
end

--- A local clone dressed as `a`, or nil. Under the lobby mark, frozen and with
--- no collision, so it is never in the shot the player is looking at.
local function cloneOf(a)
    local hash = GetHashKey(C().models[a.s])
    RequestModel(hash)
    local deadline = GetGameTimer() + C().shotWaitMs
    while not isTrue(HasModelLoaded(hash)) and GetGameTimer() < deadline do Citizen.Wait(50) end
    if not isTrue(HasModelLoaded(hash)) then return nil end
    local p = GetEntityCoords(PlayerPedId())
    local ped = CreatePed(4, hash, p.x, p.y, p.z - 10.0, 0.0, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not ped or ped == 0 or not isTrue(DoesEntityExist(ped)) then return nil end
    FreezeEntityPosition(ped, true)
    SetEntityCollision(ped, false, false)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    BR.LockerV2.applyTo(ped, a)
    local blend = GetGameTimer() + C().headBlendWaitMs
    while GetGameTimer() < blend and not isTrue(HasPedHeadBlendFinished(ped)) do Citizen.Wait(50) end
    return ped
end

local function shoot(job)
    local ped, clone = nil, nil
    if job.save or job.own then
        ped = PlayerPedId()
    elseif job.a then
        clone = cloneOf(job.a)
        ped = clone
    end
    if not ped then return end

    local handle = RegisterPedheadshot(ped)
    local deadline = GetGameTimer() + C().shotWaitMs
    while GetGameTimer() < deadline
          and not (isTrue(IsPedheadshotReady(handle)) and isTrue(IsPedheadshotValid(handle))) do
        Citizen.Wait(50)
    end
    if not (isTrue(IsPedheadshotReady(handle)) and isTrue(IsPedheadshotValid(handle))) then
        UnregisterPedheadshot(handle)
        if clone and isTrue(DoesEntityExist(clone)) then DeletePed(clone) end
        return
    end

    local txd = GetPedheadshotTxdString(handle)
    nonce = nonce + 1
    current = { id = job.id, handle = handle, clone = clone, save = job.save, at = GetGameTimer() }
    send({ id = job.id, up = job.up, txd = txd,
           url = ('https://nui-img/%s/%s?v=%d'):format(txd, txd, nonce),
           save = job.save or nil })

    -- Until the page says it has the picture, or shotWaitMs.
    local mine = current
    local until_ = GetGameTimer() + C().shotWaitMs
    while current == mine and GetGameTimer() < until_ do Citizen.Wait(50) end
    if current == mine then release() end
end

local function run()
    if running then return end
    running = true
    Citizen.CreateThread(function()
        while #queue > 0 do
            local job = table.remove(queue, 1)
            local ok, err = pcall(shoot, job)
            if not ok then
                print(('[br_core] locker2: headshot for %s failed (%s)'):format(tostring(job.id), tostring(err)))
                release()
            end
        end
        running = false
    end)
end

local function queued(id)
    for _, j in ipairs(queue) do
        if j.id == id then return true end
    end
    return current ~= nil and current.id == id
end

--- Cards with no picture: the stored one when the server has it, else one
--- taken now -- off the player for the ped they are wearing (`own`), off a
--- clone for the rest -- once each.
--- @param peds table  { { id, up, a, img?, own? } }
function Shot.request(peds)
    for _, p in ipairs(peds) do
        if p.img then
            send({ id = p.id, up = p.up, img = p.img })
        elseif p.a and not queued(p.id) then
            queue[#queue + 1] = { id = p.id, up = p.up, a = p.a, own = p.own }
        end
    end
    run()
end

--- The ped just saved, off the player's own ped, ahead of anything waiting.
--- @param id string
--- @param up number
function Shot.fromPlayer(id, up)
    table.insert(queue, 1, { id = id, up = up, save = true })
    run()
end

--- The page has the picture (or gave up). Returns 'save' when it was a save's
--- shot, which the caller then uploads.
--- @param id any
--- @return string|nil
function Shot.done(id)
    if not current or current.id ~= id then return nil end
    local save = current.save
    release()
    return save and 'save' or 'clone'
end

--- The page's upload of a save shot: true once per save shot of `id`,
--- whether the page said it was done first or not.
--- @param id any
--- @return boolean
function Shot.takeSave(id)
    if current and current.id == id and current.save then release() end
    if savesDone[id] then
        savesDone[id] = nil
        return true
    end
    return false
end

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    release()
end)
