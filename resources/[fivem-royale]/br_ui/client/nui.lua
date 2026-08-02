-- The NUI bridge.
--
-- This file is the ONLY place in the project that calls SetNuiFocus or
-- SendNUIMessage. Everything else asks it to.
--
-- Focus is the dangerous part. A leaked focus means the player cannot move,
-- cannot shoot, and cannot recover without reconnecting -- it is the single
-- worst non-crash bug this UI can produce. The defences, in order:
--
--   1. One owner. Only this file touches SetNuiFocus.
--   2. A focus STACK, not a boolean. Two screens opening and closing out of
--      order cannot leave focus half-held.
--   3. A watchdog. If focus is held with nothing on the stack, it is released.
--   4. Release on resource stop, so a reload never strands the player.

local RES = GetCurrentResourceName()

local seq = 0
local focusStack = {}   -- array of screen names, top of stack owns focus
local focusHeld = false
local chatChannel = BR.ChatChannel.GLOBAL  -- which channel a chat focus opens in

-- ---------------------------------------------------------------- sending ---

--- Send one envelope to the UI.
---
--- Lua 5.4 distinguishes integer 5 from float 5.0 and they serialise
--- differently through SendNUIMessage. Normalising here, once, is what stops the
--- UI receiving inconsistent types for the same field.
---
--- @param kind string   one of BR.Nui
--- @param data any
local function send(kind, data)
    seq = seq + 1
    SendNUIMessage({
        t = 'br',
        v = BR.NUI_ENVELOPE_VERSION,
        k = kind,
        d = BR.NuiNormalise(data or {}),
        s = seq,
    })
end

--- Public entry point for other resources (br_core) to reach the UI.
--- This is the documented cross-resource hop; it is throttled by the caller,
--- never used per frame.
RegisterNetEvent('br:ui:send')
AddEventHandler('br:ui:send', function(kind, data)
    send(kind, data)
end)

-- Same-client event, for br_core calling directly without a server round trip.
AddEventHandler('br:ui:sendLocal', function(kind, data)
    send(kind, data)
end)

exports('send', send)

-- ----------------------------------------------------------------- focus ---

local function applyFocus()
    local want = #focusStack > 0
    if want == focusHeld then return end

    focusHeld = want
    SetNuiFocus(want, want)

    -- Keeping game input alive while a screen is focused means chat and the
    -- inventory do not freeze the player in place mid-fight.
    if want then
        SetNuiFocusKeepInput(focusStack[#focusStack] ~= 'lobby')
    else
        SetNuiFocusKeepInput(false)
    end

    send(BR.Nui.FOCUS, {
        screen  = want and focusStack[#focusStack] or 'none',
        channel = chatChannel,
    })
end

--- Take focus for a screen. Idempotent per screen.
--- @param screen string
local function pushFocus(screen)
    for _, s in ipairs(focusStack) do
        if s == screen then return end
    end
    focusStack[#focusStack + 1] = screen
    applyFocus()
end

--- Release focus for a screen. Safe to call when it does not hold focus.
--- @param screen string
local function popFocus(screen)
    for i = #focusStack, 1, -1 do
        if focusStack[i] == screen then
            table.remove(focusStack, i)
        end
    end
    applyFocus()
end

local function clearFocus()
    focusStack = {}
    applyFocus()
end

exports('pushFocus', pushFocus)
exports('popFocus', popFocus)
exports('clearFocus', clearFocus)

--- Focus diagnostics.
---
--- "I have no mouse" is a symptom with no error attached to it, and the cause is
--- always one of a small number of things -- nothing pushed focus, something
--- popped it, or the push arrived before this resource was listening. Printing
--- the stack answers that in one command instead of by inference.
RegisterCommand('brfocus', function(_, args)
    if args[1] == 'lobby' or args[1] == 'chat' then
        pushFocus(args[1])
        print(('[br_ui] forced focus: %s'):format(args[1]))
        return
    end
    if args[1] == 'clear' then
        clearFocus()
        print('[br_ui] focus cleared')
        return
    end

    print('=== br_ui focus ===')
    print(('  SetNuiFocus held : %s'):format(tostring(focusHeld)))
    print(('  stack depth      : %d'):format(#focusStack))
    for i, s in ipairs(focusStack) do
        print(('    %d. %s%s'):format(i, s, i == #focusStack and '   <- owns focus' or ''))
    end
    if #focusStack == 0 then
        print('    (empty -- no screen has asked for focus)')
    end
    print(('  chat channel     : %s'):format(tostring(chatChannel)))
    print('  usage: brfocus [lobby|chat|clear]')
end, false)

AddEventHandler('br:ui:pushFocus', pushFocus)
AddEventHandler('br:ui:popFocus', popFocus)
AddEventHandler('br:ui:clearFocus', clearFocus)

-- Chat is opened by a keybind in br_core, but focus belongs to this resource,
-- so br_core asks rather than calling SetNuiFocus itself. The channel rides
-- along on the focus envelope instead of needing its own message kind.
AddEventHandler('br:ui:openChat', function(channel)
    chatChannel = channel or BR.ChatChannel.GLOBAL
    pushFocus('chat')
end)

-- ------------------------------------------------------------- callbacks ---

--- Register a callback that ALWAYS resolves.
---
--- A RegisterNUICallback that fails to call its resolve function leaves the
--- corresponding fetch() in the UI pending forever. That presents as a control
--- that silently stops working, with nothing in any console. Wrapping every
--- callback here means no individual handler can cause it.
---
--- @param name string
--- @param fn function  receives (data); may return a table
local function callback(name, fn)
    RegisterNUICallback(name, function(data, cb)
        local ok, res = pcall(fn, data or {})
        if ok then
            cb(res or { ok = true })
        else
            print(('[br_ui] callback "%s" errored: %s'):format(name, tostring(res)))
            cb({ ok = false, error = tostring(res) })
        end
    end)
end

callback(BR.NuiCb.CLOSE, function()
    clearFocus()
    return { ok = true }
end)

callback(BR.NuiCb.CHAT_FOCUS, function(data)
    if data.open then
        pushFocus('chat')
    else
        popFocus('chat')
    end
    return { ok = true }
end)

callback(BR.NuiCb.CHAT_SEND, function(data)
    local text = tostring(data.text or ''):sub(1, BR.ChatLimits.maxLength)
    if #text > 0 then
        TriggerServerEvent(BR.Net.CHAT_SEND, {
            channel = data.channel or BR.ChatChannel.GLOBAL,
            text    = text,
        })
    end
    popFocus('chat')
    return { ok = true }
end)

-- Gameplay callbacks are forwarded to br_core, which owns the decisions.
for _, name in ipairs({
    BR.NuiCb.QUEUE, BR.NuiCb.QUEUE_LEAVE,
    BR.NuiCb.SQUAD_INVITE, BR.NuiCb.SQUAD_LEAVE,
    BR.NuiCb.INV_SWAP, BR.NuiCb.INV_DROP, BR.NuiCb.INV_USE, BR.NuiCb.INV_SELECT,
}) do
    callback(name, function(data)
        TriggerEvent('br:ui:action', name, data)
        return { ok = true }
    end)
end

--- CEF capability report.
---
--- Printed at startup because a stylesheet that is perfectly correct will still
--- render as nothing if this CEF build cannot parse its colour functions -- and
--- that failure looks identical to "the CSS did not load". Knowing the Chrome
--- version turns an afternoon of guessing into one line of output.
callback(BR.NuiCb.ENV, function(data)
    local css = data.css or {}
    print('[br_ui] ---- CEF environment ----')
    -- Printed first and deliberately prominent: this is how you tell "the fix
    -- did not work" apart from "the fix never reached the client".
    print(('[br_ui]   BUILD      %s'):format(tostring(data.build)))
    print(('[br_ui]   chrome     %s'):format(tostring(data.chromeVersion)))
    print(('[br_ui]   viewport   %sx%s @ %sx'):format(
        tostring(data.viewport and data.viewport.w),
        tostring(data.viewport and data.viewport.h),
        tostring(data.viewport and data.viewport.dpr)))

    local order = {
        'oklch', 'oklab', 'lch', 'colorMix', 'colorMixSrgb',
        'has', 'nesting', 'atProperty', 'containerType', 'backdropFilter',
    }
    local missing = {}
    for _, k in ipairs(order) do
        local v = css[k]
        print(('[br_ui]   %-15s %s'):format(k, v and 'yes' or 'NO'))
        if not v then missing[#missing + 1] = k end
    end

    -- Tailwind v4 and HeroUI v3 emit oklch/oklab/color-mix throughout their
    -- colour system. Without them, components render with no colour at all.
    if not css.oklch or not css.colorMix then
        print('[br_ui]   note: no modern colour functions on this build -- expected.')
        print('[br_ui]   The stack is pinned to HeroUI 2 + Tailwind 3 for exactly')
        print('[br_ui]   this reason, and check-css enforces it at build time.')
    end
    print(('[br_ui] ---- %d unsupported ----'):format(#missing))
    return { ok = true }
end)

--- The error sink. Without this, a CEF exception is a blank screen and there is
--- nowhere to look for the cause.
callback(BR.NuiCb.ERROR, function(data)
    print(('[br_ui] UI error in %s: %s'):format(
        tostring(data.context), tostring(data.message)))
    if data.stack and #tostring(data.stack) > 0 then
        print('[br_ui]   ' .. tostring(data.stack))
    end
    return { ok = true }
end)

-- ------------------------------------------------------------- watchdog ---

-- Focus held with an empty stack means something released a screen without
-- telling us, or a handler threw between push and pop. Rather than leave the
-- player stuck, take it back.
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(1000)
        if focusHeld and #focusStack == 0 then
            print('[br_ui] focus held with an empty stack -- releasing (watchdog)')
            applyFocus()
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= RES then return end
    -- Never strand the player because the UI resource restarted.
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
end)

AddEventHandler('onClientResourceStart', function(res)
    if res ~= RES then return end
    SetNuiFocus(false, false)
    print('[br_ui] bridge ready')
    -- Ask br_core for a full snapshot; it may have started first.
    TriggerEvent('br:ui:ready')
end)
