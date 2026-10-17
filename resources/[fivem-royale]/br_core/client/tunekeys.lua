-- The keys every manual-adjustment dev tool shares (#404).
--
-- "how about instead of so many commands and args, we use keyboard keys like
-- we've done for other things. ... Any manual adjustment commands must allow
-- keyboard input."                                    -- owner, 2026-10-11
--
-- /brplate (client/revivekey.lua) and /brrocket (client/terminalfx/airstrike.lua)
-- each built this shape on their own: a toggle, keys that nudge while it is on,
-- SHIFT for bigger steps, the numbers drawn on screen, the paste line printed
-- when it is put away. Five more tools needed it -- /brlabel, /brshine,
-- /brpropscale, /brgunplate, /brlobbycam -- and five more copies would be five
-- chances for one tool's tap to be two steps, or its hold to run at the frame
-- rate. So the mechanics are here once, on /brrocket's keys and numbers, and
-- each tool says only what its keys move.
--
-- THE KEYS. The arrows, PAGE UP / DOWN and DELETE are claimed while a tool is
-- on (BLOCKED, the list /brrocket claims); CTRL, ALT and SHIFT are read and
-- never claimed, and walking and the mouse stay the player's. A tap is one step
-- and a hold is a step every REPEAT_MS whatever the frame rate, so a number
-- measured today comes back tomorrow (/brplate's argument).
--
-- ON THE BEAT, NOT A FRAME LATE. A held key's next step is due REPEAT_MS after
-- the last one was DUE, not after the frame that took it. Counted from the
-- frame, every gap rounded up to whole frames: 16 steps a second at 60 fps and
-- at 30, 13 at 25, and twenty only where 50 ms divides into frames. Carrying
-- the deadline would pay a hitch back in a burst -- a second-long frame owes
-- twenty steps -- so a deadline already behind the clock starts again from
-- now. Below 20 fps that is one step a frame, never two.
--
-- ONE AT A TIME. Two tools on at once would both move on the same press, so
-- turning one on puts any other away first -- paste line and all, exactly as
-- if it had been turned off.
--
-- A MENU ON SCREEN HAS THE ARROWS. The gun shop's menu reads them through
-- IsDisabledControl*, which a claim does not reach, so while one of our list
-- menus is up (BR.Menu.hasArrows) the arrows move its cursor and nothing here.
-- The page keys and DELETE, which no menu reads, still work. Buy, close the
-- menu, then tune.
--
-- NOTHING PER FRAME WHILE OFF. A tool's frame callback is registered when it is
-- turned on and unregistered when it is put away, so a session that never types
-- one pays nothing, and the keys are the player's again on the very next frame:
-- DisableControlAction lasts one frame and simply stops being renewed. There is
-- no teardown to be skipped by an error.

BR = BR or {}
BR.TuneKeys = {}

--- A BOOL native may answer 1/0, and 0 is TRUE in Lua.
local isTrue = BR.NativeBool

--- The keys the tools read (GTA control ids, pad group 0).
local KEY = {
    UP = 172, DOWN = 173, LEFT = 174, RIGHT = 175,   -- INPUT_CELLPHONE_UP/DOWN/LEFT/RIGHT
    BIGGER = 10,    -- PAGE UP      INPUT_SCRIPTED_FLY_ZUP
    SMALLER = 11,   -- PAGE DOWN    INPUT_SCRIPTED_FLY_ZDOWN
    RESET = 178,    -- DELETE       INPUT_CELLPHONE_OPTION
    DEPTH = 36,     -- LEFT CTRL    INPUT_DUCK
    TURN = 19,      -- LEFT ALT     INPUT_CHARACTER_WHEEL
    COARSE = 21,    -- LEFT SHIFT   INPUT_SPRINT
}
BR.TuneKeys.KEY = KEY

--- Claimed while a tool is on. 27 is INPUT_PHONE, the up arrow's other
--- control: left live, a nudge upward opens the phone (/brplate's list).
local BLOCKED = { 27, 172, 173, 174, 175, 10, 11, 178 }
BR.TuneKeys.BLOCKED = BLOCKED

--- A held key steps this often: 20 a second at any frame rate from 20 up.
local REPEAT_MS = 50
BR.TuneKeys.REPEAT_MS = REPEAT_MS

--- Where the readout starts and how far apart its lines are (/brplate's).
local READ_X, READ_Y, READ_LINE = 0.015, 0.34, 0.026

--- Is this key down? IsDisabledControlPressed answers for a claimed key and a
--- free one alike, so one reader covers the arrows and the modifiers.
--- @param id number
--- @return boolean
local function held(id)
    return isTrue(IsDisabledControlPressed(0, id))
end
BR.TuneKeys.held = held

--- +1, -1 or 0 for a pair of keys (both held is 0).
local function axis(plus, minus)
    return (held(plus) and 1 or 0) - (held(minus) and 1 or 0)
end

--- @param v number
--- @param places number|nil  decimal places; 0 answers an integer
--- @return number
function BR.TuneKeys.round(v, places)
    if not places or places <= 0 then return math.floor(v + 0.5) end
    local k = 10 ^ places
    return math.floor(v * k + 0.5) / k
end

--- @return number
function BR.TuneKeys.clamp(v, lo, hi)
    if lo and v < lo then return lo end
    if hi and v > hi then return hi end
    return v
end

--- `v` moved `d` steps of a number's own size -- `fine`, or `coarse` with SHIFT
--- held -- rounded to its places, so twenty steps of 0.01 land on 0.20 and not
--- on 0.19999, and kept inside lo..hi.
---
--- A TURN HAS NO ENDS. A row with `wrap` is an angle in degrees and goes round
--- rather than stopping: a step past 180 comes back in at -179, kept in
--- -180..180 the way /brrocket's wrapDeg keeps its rotations, so a yaw held
--- for a full turn ends where it started instead of pinned against a limit.
--- @param v number
--- @param d number  how many steps, signed
--- @param coarse boolean
--- @param row table  { fine, coarse, places, lo, hi, wrap }
--- @return number
function BR.TuneKeys.nudged(v, d, coarse, row)
    local step = coarse and row.coarse or row.fine
    local n = BR.TuneKeys.round((tonumber(v) or 0.0) + d * step, row.places)
    -- Rounded again: 12.3 + 180 - 180 is 12.300000000000011 in a double.
    if row.wrap then return BR.TuneKeys.round((n + 180.0) % 360.0 - 180.0, row.places) end
    return BR.TuneKeys.clamp(n, row.lo, row.hi)
end

--- One line of the readout: /brplate's `text`, matched call for call.
--- Numbers and names only; the keys are printed on the console, once.
--- @param x number
--- @param y number
--- @param s string
function BR.TuneKeys.text(x, y, s)
    SetTextFont(4)
    SetTextScale(0.0, 0.34)
    SetTextColour(255, 255, 255, 235)
    SetTextDropshadow(0, 0, 0, 0, 255)
    SetTextEdge(1, 0, 0, 0, 205)
    SetTextDropShadow()
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(s)
    EndTextCommandDisplayText(x, y)
end

--- [name] = the tool that is on. One at a time (see the header).
local sessions = {}

--- One frame of a tool that is on.
---
--- What the keys are this frame goes to the tool as `k`: v (UP +1, DOWN -1),
--- h (RIGHT +1, LEFT -1), s (PAGE UP +1, PAGE DOWN -1), and depth (CTRL),
--- turn (ALT) and coarse (SHIFT) held.
local function frame(s)
    for i = 1, #BLOCKED do DisableControlAction(0, BLOCKED[i], true) end
    local spec = s.spec
    local k = {
        v = axis(KEY.UP, KEY.DOWN), h = axis(KEY.RIGHT, KEY.LEFT),
        s = axis(KEY.BIGGER, KEY.SMALLER),
        depth = held(KEY.DEPTH), turn = held(KEY.TURN), coarse = held(KEY.COARSE),
    }
    -- A MENU ON SCREEN HAS THE ARROWS (the header): read as let go, so neither
    -- a step nor a pick lands while its cursor is moving.
    if BR.Menu and BR.Menu.hasArrows and BR.Menu.hasArrows() then k.v, k.h = 0, 0 end

    -- DELETE, once a press however long it is held.
    local del = held(KEY.RESET)
    if del and not s.resetWas and spec.reset then
        spec.reset()
        s.moved = true
    end
    s.resetWas = del

    -- A TOOL WITH A LIST PICKS WITH LEFT / RIGHT, once a press, and they move
    -- nothing else: a pick that repeated at 20 a second would race past the
    -- row it was held for.
    if spec.pick then
        if k.h ~= 0 and not s.pickWas then spec.pick(k.h) end
        s.pickWas = k.h ~= 0
        k.h = 0
    end

    local lines = spec.lines(k)
    local x, y = spec.x or READ_X, spec.y or READ_Y
    for i = 1, #lines do
        BR.TuneKeys.text(x, y, lines[i])
        y = y + READ_LINE
    end

    if k.v == 0 and k.h == 0 and k.s == 0 then
        -- Let go: the next press lands at once, and a tool that only redraws
        -- once the number is settled (/brpropscale rebuilds props) hears it.
        s.nudgeAt = 0
        if s.moved and not del then
            s.moved = false
            if spec.settle then spec.settle() end
        end
        return
    end
    local now = GetGameTimer()
    if now < s.nudgeAt then return end
    -- From when this step was due (ON THE BEAT, the header), unless that is
    -- already past: the first press, or a hitch.
    s.nudgeAt = s.nudgeAt + REPEAT_MS
    if s.nudgeAt <= now then s.nudgeAt = now + REPEAT_MS end
    if spec.nudge(k) then s.moved = true end
end

--- Is this tool on?
--- @param name string
--- @return boolean
function BR.TuneKeys.on(name)
    return sessions[name] ~= nil
end

--- Put a tool away: its keys go back to the player on the next frame, a
--- number still moving is settled, and its `off` prints what to paste.
--- @param name string
--- @return boolean  false if it was not on
function BR.TuneKeys.stop(name)
    local s = sessions[name]
    if not s then return false end
    sessions[name] = nil
    BR.Loop.unregister(s.loop)
    if s.moved and s.spec.settle then s.spec.settle() end
    if s.spec.off then s.spec.off() end
    return true
end

--- Turn a tool's keys on. Any other tool that is on is put away first.
---
--- spec:
---   lines(k)  the readout, every frame: a list of strings
---   nudge(k)  once a step (a tap, or every REPEAT_MS held); true if it moved
---             anything
---   pick(d)   optional: LEFT / RIGHT pick, once a press (d = -1 or 1)
---   reset()   optional: DELETE, once a press
---   settle()  optional: once the keys come up after a change
---   off()     optional: put away -- print the paste line
---   x, y      optional: where the readout starts
--- @param name string  the command, e.g. 'brlabel'
--- @param spec table
--- @return boolean  false if it was already on
function BR.TuneKeys.start(name, spec)
    if sessions[name] then return false end
    for other in pairs(sessions) do BR.TuneKeys.stop(other) end
    local s = { spec = spec, nudgeAt = 0, resetWas = false, pickWas = false, moved = false }
    s.loop = BR.Loop.register(BR.Loop.FRAME, 'tunekeys.' .. name, function() frame(s) end)
    sessions[name] = s
    return true
end
