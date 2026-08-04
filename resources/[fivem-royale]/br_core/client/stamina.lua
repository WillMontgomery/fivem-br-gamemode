-- Sprint stamina, Fortnite-shaped.
--
-- One meter: drains while genuinely sprinting on foot, recharges after a
-- short breath, and an EMPTIED meter blocks sprint until it climbs back to a
-- threshold -- so running dry costs a real tactical beat, not one frame.
--
-- GTA has its own stamina stat with a much worse failure mode: run it dry
-- and the engine drains HEALTH. RestorePlayerStamina keeps the engine's
-- meter topped up every tick, so ours is the only limiter that exists.
--
-- Purely client-side: the meter gates a CONTROL, not an outcome, so there
-- is nothing here worth server authority. The value rides the HUD envelope
-- for the bar above the vitals strip.

BR = BR or {}
BR.State = BR.State or {}

local cfgS  = BR.Config.Stamina
local stam  = cfgS.max
local lastDrainAt = 0
local blocked = false
local lastAt  = 0

BR.State.stamina = 100.0

-- The states where sprinting is a thing that can happen and cost something.
local ACTIVE = {}
local function activeStates()
    ACTIVE[BR.PlayerState.WARMUP] = true
    ACTIVE[BR.PlayerState.ALIVE]  = true
end

BR.Loop.register(BR.Loop.TICK, 'stamina.meter', function()
    if not next(ACTIVE) then activeStates() end

    local now = GetGameTimer()
    local dt = (lastAt > 0) and math.min(now - lastAt, 500) / 1000.0 or 0.0
    lastAt = now

    local me = BR.State.me.state
    if not ACTIVE[me] then
        -- Lobby, bus, descent, dead: the meter rests full and costs nothing.
        stam, blocked = cfgS.max, false
        BR.State.stamina = stam
        return
    end

    local ped = PlayerPedId()

    -- The engine's own meter stays pinned full -- see the header.
    RestorePlayerStamina(PlayerId(), 1.0)

    local sprinting = IsPedSprinting(ped) and IsPedOnFoot(ped)
    if sprinting then
        stam = math.max(0.0, stam - cfgS.drainPerSec * dt)
        lastDrainAt = now
        if stam <= 0.0 then blocked = true end
    elseif now - lastDrainAt >= cfgS.regenDelayMs then
        stam = math.min(cfgS.max, stam + cfgS.regenPerSec * dt)
    end

    if blocked and stam >= cfgS.minToSprint then
        blocked = false
    end

    BR.State.stamina = stam
end)

-- The block itself is per-frame: DisableControlAction lasts one frame.
BR.Loop.register(BR.Loop.FRAME, 'stamina.block', function()
    if blocked then
        DisableControlAction(0, 21, true)   -- INPUT_SPRINT
    end
end)
