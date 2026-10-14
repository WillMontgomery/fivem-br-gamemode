-- The first action after an idle, and the switches to tell its causes apart
-- (#252, round 4). DEV MODE ONLY.
--
-- Owner, 2026-10-13: "I leave the page open on literally anything, wait a few
-- minutes, then select some element on the page ... The action it performs ...
-- happens and the sound plays instantly, as expected - but the UI reaction
-- itself ... takes several seconds. This gets worse the longer I let my PC sit
-- between actions."
--
-- Measured on his PC: across the lag neither browser process used CPU, and
-- the GPU process faulted in ~18 MB it let go of again ~10 s later. So the
-- browser waits on something, and this file prints where the wait went -- one
-- line per cold action:
--
--   [br_ui] cold <total>ms after <idle>s idle: input->handler A,
--     handler->commit B, commit->rAF C, rAF->next rAF D, msg arrival lag E
--     | by <input or push> | lua <stamps> | <the page's evidence>
--
-- The page measures A-D (ui-src/src/bridge/coldProbe.ts says what each mark
-- is; A + B + C + D = the total; the commit is the LAST change the action
-- made, not the first). This side adds what only Lua knows, on the game timer:
-- when the page's call arrived and when the push the reaction landed with was
-- sent, and so E -- the page's round trip to that push with Lua's own work in
-- between taken out: the two message legs alone. For a change Lua pushed with
-- no input, E is the push's transport and the report's together.
--
-- WHICH CALL: the page counts the calls of the same name it made after the one
-- it measured (`later`: a re-click, a drag's stream), and this side counts
-- back by it from the newest -- never "the latest call with that name", which
-- after a re-click is the second click. And WHICH PUSH: the page names it by
-- sequence, never "the first push after the call", which in the lobby is a
-- status envelope three times a second.
--
-- READING IT: E of seconds is the message path waking late; C or D of seconds
-- is the first frame after the idle (the compositor and GPU process); A or B
-- without E is the page's own JavaScript, and push->commit in the evidence is
-- its time from the push to the change. `commit->presented` is the frame's
-- presentation time -- past the last rAF -- and the self-test in `bruiidle`
-- says whether CEF reports it at all.
--
-- THE SWITCHES, each off by default, each a dev command below; the cold line
-- keeps printing with them on, which is the A/B:
--
--   bruipaint  a real frame every N ms, at three depths: raster (repaint a dot:
--              raster and draw in the GPU process), comp (a dot's opacity on
--              its own layer: draw, no raster), raf (a frame request: the
--              frame clock, no damage -- the clean control). raster and comp
--              both keep the GPU process's drawing context busy, so if both
--              take the lag away it is that process's idle cleanup, not raster
--              against draw.
--   bruiwarm   every N ms the page re-renders its whole tree with nothing
--              changed. Render functions only -- no handler, no dispatch, no
--              DOM change, no frame -- so a lag that stays with it on does not
--              clear cold JavaScript.
--
-- NO bruiping: the lobby already sends three envelopes a second while it sits
-- (the server's lobby.status twice, party and squad once), so a keep-alive
-- message would test a path the idle never lets go cold. E measures it instead.
--
-- NOTHING ON A PUBLIC BOX: the page arms nothing until a `diag` envelope says
-- so, and this file sends one only while BR.Dev.on(). Until then the stamps in
-- nui.lua are a nil check.

local send = BR.Ui.send
local callback = BR.Ui.callback

local PAINT_MODES = { raster = true, comp = true, raf = true }
local PAINT_DEFAULT_MS, PAINT_MIN_MS, PAINT_MAX_MS = 500, 100, 60000
local WARM_DEFAULT_MS, WARM_MIN_MS, WARM_MAX_MS = 5000, 500, 60000
--- Pushes remembered by sequence: the lobby alone sends three a second, and a
--- report can come 35 s after its push (15 s for the reaction, 15 s for
--- presentation, 5 s of quiet).
local SENT_RING = 256
--- Calls remembered per callback name, newest last: the page counts back from
--- the newest by `later`.
local CALLS_KEEP = 16
--- How long `bruiidle` waits for the page.
local ASK_MS = 3000
--- The page's COLD_IDLE_MS, for the command's own words.
local COLD_IDLE_S = 30

--- What the page should run. The cold line is the measurement itself, so it is
--- on wherever dev mode is; the switches are off until a command turns them on.
local diag = { cold = true, paint = nil, warm = nil }

--- The page has been armed by an envelope from here (so dev mode going away
--- must disarm it).
local armedPage = false

local function dev()
    return BR.Dev ~= nil and BR.Dev.on ~= nil and BR.Dev.on() == true
end

local function flat(v, cap)
    local text = (tostring(v):gsub('%c', ' '))
    if #text > cap then text = text:sub(1, cap) .. '...' end
    return text
end

-- ---------------------------------------------------------------- stamps ---

local stamps
local function freshStamps()
    stamps = {
        sent = {},     -- seq % SENT_RING -> { seq, at, kind }, reused in place
        calls = {},    -- callback name -> the game timers its calls arrived at, newest last
    }
end
freshStamps()

--- The page's own reports are not actions.
local OWN = { [BR.NuiCb.COLD] = true, [BR.NuiCb.IDLE] = true }

--- What nui.lua calls while the page's probe is armed, and only then.
local hook = {
    sent = function(s, kind)
        local slot = s % SENT_RING
        local r = stamps.sent[slot]
        if r then
            r.seq, r.at, r.kind = s, GetGameTimer(), kind
        else
            stamps.sent[slot] = { seq = s, at = GetGameTimer(), kind = kind }
        end
    end,
    cbIn = function(name)
        if OWN[name] then return end
        local list = stamps.calls[name]
        if not list then
            list = {}
            stamps.calls[name] = list
        end
        list[#list + 1] = GetGameTimer()
        if #list > CALLS_KEEP then table.remove(list, 1) end
    end,
}

--- For the tests: how many pushes and calls are stamped right now.
function BR.Ui.coldStamps()
    local n = 0
    for _ in pairs(stamps.sent) do n = n + 1 end
    local c = 0
    for _, list in pairs(stamps.calls) do c = c + #list end
    return n, c
end

-- ------------------------------------------------------------- the page ---

--- Tell the page what to run, and stamp only while its probe is armed.
--- @param ask integer|nil  a `bruiidle` request
--- @return boolean sent
local function sync(ask)
    if not dev() then
        BR.Ui.setColdHook(nil)
        freshStamps()
        if armedPage then
            -- Dev mode went away under an armed page: everything off.
            armedPage = false
            send(BR.Nui.DIAG, {})
        end
        return false
    end
    if diag.cold then
        BR.Ui.setColdHook(hook)
    else
        BR.Ui.setColdHook(nil)
        freshStamps()
    end
    armedPage = true
    send(BR.Nui.DIAG, { cold = diag.cold, paint = diag.paint, warm = diag.warm, ask = ask })
    return true
end

-- The page has loaded (br_ui's ENV callback), or this resource has started.
AddEventHandler('br:ui:ready', function() sync(nil) end)

-- Dev mode reaching this client after the page loaded. GUARDED, as season.lua
-- guards its own listener: one that will not register must not take this file
-- down -- any bru* command arms the page as well.
if type(AddConvarChangeListener) == 'function' then
    pcall(AddConvarChangeListener, 'br_devMode', function() sync(nil) end)
end

-- -------------------------------------------------------------- the line ---

local function ms(v)
    v = tonumber(v)
    if not v or v < 0 then return '-' end
    if v < 10 then return ('%.1f'):format(v) end
    return ('%d'):format(math.floor(v + 0.5))
end

--- A signed millisecond offset: +12, -3.
local function signed(v)
    v = math.floor(v + 0.5)
    return (v >= 0 and '+%d' or '%d'):format(v)
end

--- Lua's half of the line, and E narrowed by it.
--- @return string lua, number e
local function luaSide(d, now)
    local e = tonumber(d.e) or -1
    local cb = type(d.cb) == 'string' and d.cb or ''
    local cause = math.tointeger(tonumber(d.cause) or 0) or 0
    local age = tonumber(d.age) or -1
    local later = math.tointeger(tonumber(d.later) or 0) or 0

    if cause > 0 then
        -- A push with no input: when Lua sent it, and the report's arrival.
        local r = stamps.sent[cause % SENT_RING]
        if not (r and r.seq == cause) then
            return ('push #%d not stamped'):format(cause), -1
        end
        local since = now - r.at
        return ('push #%d (%s) sent at %d, report in at +%dms'):format(cause, flat(r.kind, 24), r.at, since),
            age >= 0 and math.max(0, since - age) or -1
    end
    if cb == '' then return 'no call to lua', -1 end

    -- The call the page measured: `later` calls of the same name came after it.
    local list = stamps.calls[cb]
    local at = list and later >= 0 and list[#list - later] or nil
    if not at then
        return ('%s not stamped (round trip shown)'):format(flat(cb, 48)), e
    end
    local head = ('%s in at %d%s'):format(flat(cb, 48), at,
        later > 0 and (' (%d more after it)'):format(later) or '')

    -- The push the reaction landed with, by the sequence the page names.
    local p = type(d.push) == 'table' and d.push or nil
    local ps = p and math.tointeger(tonumber(p.s) or -1) or -1
    local pt = p and tonumber(p.t) or nil
    if ps < 0 or not pt then
        return head .. (', no push before the change, report in at +%dms'):format(now - at), -1
    end
    local r = stamps.sent[ps % SENT_RING]
    if not (r and r.seq == ps) then
        return head .. (', push #%d not stamped (round trip shown), report in at +%dms'):format(ps, now - at), e
    end
    local work = r.at - at
    return head .. (', push #%d (%s) sent at %sms, report in at +%dms')
            :format(ps, flat(r.kind, 24), signed(work), now - at),
        math.max(0, pt - work)
end

--- The one line, from the page's report.
local function coldLine(d)
    local lua, e = luaSide(d, GetGameTimer())
    local total = ms(d.total)
    return ('cold %s after %ds idle: input->handler %s, handler->commit %s, commit->rAF %s,'
        .. ' rAF->next rAF %s, msg arrival lag %s | by %s | lua %s | %s'):format(
        total == '-' and '-' or (total .. 'ms'), math.floor(tonumber(d.idleS) or 0),
        ms(d.a), ms(d.b), ms(d.c), ms(d.d), ms(e),
        flat(d.by or '?', 40), lua, flat(d.detail or '', 900))
end

callback(BR.NuiCb.COLD, function(data)
    print('[br_ui] ' .. coldLine(type(data) == 'table' and data or {}))
    return { ok = true }
end)

-- --------------------------------------------------------- the inventory ---

local asks = 0
local waiting = nil

callback(BR.NuiCb.IDLE, function(data)
    waiting = nil
    print('[br_ui] idle: ' .. flat(type(data) == 'table' and data.text or '?', 700))
    return { ok = true }
end)

-- -------------------------------------------------------------- commands ---

local function paintText()
    return diag.paint and ('%s every %dms'):format(diag.paint.mode, diag.paint.ms) or 'off'
end
local function warmText()
    return diag.warm and ('every %dms'):format(diag.warm) or 'off'
end

--- One line when a switch changes, and the page told.
local function changed(what, text)
    local sent = sync(nil)
    print(('[br_ui] %s %s%s'):format(what, text, sent and '' or ' (not sent: dev mode is off)'))
end

--- `on [ms] [word]` / `off`: the period and the word, or nil and the reason.
local function parseOn(args, lo, hi, def, words)
    local period, word = def, nil
    for i = 2, #args do
        local a = args[i]
        local n = math.tointeger(tonumber(a))
        if n then
            if n < lo or n > hi then return nil, ('%s is outside %d-%d ms'):format(a, lo, hi) end
            period = n
        elseif words and words[a] then
            word = a
        else
            return nil, ('%s is not a period%s'):format(flat(a, 20), words and ' or a mode' or '')
        end
    end
    return period, word
end

RegisterCommand('bruicold', function(_, args)
    local a = args[1]
    if a == 'on' or a == 'off' then
        local on = a == 'on'
        if diag.cold == on then
            print(('[br_ui] bruicold already %s'):format(a))
            return
        end
        diag.cold = on
        changed('bruicold', on and ('on: one line per action after %ds idle'):format(COLD_IDLE_S) or 'off')
        return
    end
    if a ~= nil then
        print('[br_ui] usage: bruicold [on|off]')
        return
    end
    local stamped, cbs = BR.Ui.coldStamps()
    print(('[br_ui] bruicold %s (dev mode %s, page %s; %d pushes and %d callbacks stamped)')
        :format(diag.cold and 'on' or 'off', dev() and 'on' or 'off',
                armedPage and 'told' or 'not told', stamped, cbs))
end, false)

RegisterCommand('bruipaint', function(_, args)
    local a = args[1]
    if a == 'off' then
        if not diag.paint then print('[br_ui] bruipaint already off'); return end
        diag.paint = nil
        changed('bruipaint', 'off')
        return
    end
    if a == 'on' then
        local period, modeOrWhy = parseOn(args, PAINT_MIN_MS, PAINT_MAX_MS, PAINT_DEFAULT_MS, PAINT_MODES)
        if not period then
            print(('[br_ui] bruipaint: %s. usage: bruipaint on [ms] [raster|comp|raf] | off'):format(modeOrWhy))
            return
        end
        diag.paint = { ms = period, mode = modeOrWhy or 'raster' }
        changed('bruipaint', 'on: ' .. paintText())
        return
    end
    if a ~= nil then
        print('[br_ui] usage: bruipaint on [ms] [raster|comp|raf] | off')
        return
    end
    print('[br_ui] bruipaint ' .. paintText())
end, false)

RegisterCommand('bruiwarm', function(_, args)
    local a = args[1]
    if a == 'off' then
        if not diag.warm then print('[br_ui] bruiwarm already off'); return end
        diag.warm = nil
        changed('bruiwarm', 'off')
        return
    end
    if a == 'on' then
        local period, why = parseOn(args, WARM_MIN_MS, WARM_MAX_MS, WARM_DEFAULT_MS, nil)
        if not period then
            print(('[br_ui] bruiwarm: %s. usage: bruiwarm on [ms] | off'):format(why))
            return
        end
        diag.warm = period
        changed('bruiwarm', 'on: ' .. warmText())
        return
    end
    if a ~= nil then
        print('[br_ui] usage: bruiwarm on [ms] | off')
        return
    end
    print('[br_ui] bruiwarm ' .. warmText())
end, false)

RegisterCommand('bruiidle', function()
    asks = asks + 1
    if not sync(asks) then
        print('[br_ui] idle: dev mode is off, so the page is not asked')
        return
    end
    local n = asks
    waiting = n
    Citizen.SetTimeout(ASK_MS, function()
        if waiting == n then
            waiting = nil
            print(('[br_ui] idle: the page did not answer within %dms'):format(ASK_MS))
        end
    end)
end, false)
