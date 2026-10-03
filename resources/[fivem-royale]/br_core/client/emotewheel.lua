-- The emote wheel: hold Left Alt, ScaleformUI's RadialMenu, release to pick
-- (#215).
--
-- Owner, 2026-10-02 (#215, "Scope v2"): "HOLD LEFT ALT to open the wheel,
-- release to pick." Up to eight dances, one per segment, in the order the
-- Market put them on the wheel. "The wheel CANNOT open while the pause menu or
-- the big map is open", and opening it dismisses the screens it can be opened
-- over.
--
-- ═══ THE LIBRARY'S WHEEL, OUR KEY ═══
--
-- The vendored ScaleformUI RadialMenu draws the eight segments and moves the
-- highlight with the look axes, from its own thread. It knows nothing about
-- Alt: Enter (201) would select and Escape (202) goes back. Here the verb is
-- RELEASING ALT, so OnSegmentSelect does nothing and the release reads
-- whichever segment is highlighted. There is no cursor -- the library's
-- ProcessMouse is empty, and nothing here gives it one.
--
-- ═══ THE HIGHLIGHT TELLS THE TRUTH ═══
--
-- The radial has no "nothing selected" state: some segment is always lit. So
-- the wheel opens lit on the FIRST EMPTY segment, and a release that never
-- moved the highlight picks nothing. Only a wheel with all eight slots full
-- opens on segment 1 and plays it on an unmoved release (an owner question on
-- #215). A release within tapMs of the press is a tap, and cancels.
--
-- ═══ WHAT BLOCKS IT AND WHAT IT DISMISSES ═══
--
-- Blocked, silently: a keyboard-owning screen of ours (the pause menu,
-- players, chat, settings, the market -- Alt never reaches the game under
-- them), GTA's frontend, any map, and everything BR.Emotes.blocked() names.
-- Dismissed, in this order, before it shows: the inventory panel, the focus
-- stack, and every in-game BR.Menu menu. A focus change while it is open
-- closes it -- TAB still opens the inventory over it, and that is a close.

BR = BR or {}
BR.EmoteWheel = BR.EmoteWheel or {}

--- The RadialMenu, built on the first open and kept.
local w = nil
--- Is the wheel up, as far as this file knows. The frame pass reconciles it
--- with the library's own answer.
local open = false
--- GetGameTimer() at the open, for the tap window.
local openedAt = 0
--- [segment] = the dance id drawn there, '' for an empty segment.
local shown = {}

--- What the frame pass disables while the wheel is up: the character wheel
--- (19, Left Alt's own GTA control), attack and aim (24, 25), the weapon wheel
--- (37), melee (140-142, 257, 263, 264) and the pause keys (199, 200).
--- Movement is left alone: the wheel can be held on the move, and a pick made
--- on the move is refused by BR.Emotes.request.
local CONTROLS = { 19, 24, 25, 37, 140, 141, 142, 257, 263, 264, 199, 200 }

--- Build the radial once. nil when ScaleformUI is not on this box.
--- @return table|nil
local function build()
    local m = BR.Menu and BR.Menu.radial and BR.Menu.radial()
    if not m then return nil end
    m.OnMenuClose = function() open = false end
    -- Enter does nothing: releasing Alt is the pick.
    m.OnSegmentSelect = function() end
    m.OnSegmentHighlight = function() end
    return m
end

--- Is any map, or GTA's own frontend, on screen? The engine's answer for the
--- frontend, read on every call (keybinds.lua's FRONTEND_SWALLOWS says why it
--- must not be remembered), and BR.Native's flags for the three map routes
--- that are not the frontend.
--- @return boolean
local function frontendUp()
    if BR.NativeBool(IsPauseMenuActive()) or BR.NativeBool(IsPauseMenuRestarting()) then
        return true
    end
    local n = BR.Native
    return n ~= nil and (n.bigmap == true or n.frontendMap == true or n.fullscreenMap == true)
end

--- Take the wheel down. Through the library's own close-and-clear when the
--- wheel is its current menu, so no breadcrumb is left to keep its draw
--- thread running.
---
--- WHEN ANOTHER MENU IS CURRENT, ONLY THE WHEEL GOES (#215). The library's
--- RadialMenu:Visible(false) (ScaleformUI.lua:10634-10638) clears the
--- instructional buttons and sets MenuHandler.ableToDraw = false
--- unconditionally, and both belong to the CURRENT menu: an Interact-opened
--- gun shop over a held wheel would stay open, undrawn and deaf to input. So
--- the wheel is hidden by hand -- its flag and its movie -- and the draw flag
--- and buttons are left to the menu that owns them.
local function close()
    open = false
    if w == nil then return end
    if MenuHandler ~= nil and MenuHandler._currentMenu == w then
        pcall(MenuHandler.CloseAndClearHistory, MenuHandler)
    else
        w._visible = false
        pcall(function() ScaleformUI.Scaleforms._radialMenu:CallFunction('CLEAR_ALL') end)
    end
end

--- Is the wheel up?
--- @return boolean
function BR.EmoteWheel.isOpen()
    return open
end

BR.Keys.on('emoteWheel', function(pressed)
    if pressed then
        if open then return end
        if not BR.Emotes.enabled() then return end
        -- KEYBOARD-OWNING SCREENS BLOCK THE WHEEL AND ARE NOT DISMISSED. The
        -- hold already drops a press while a screen owns the keyboard; this
        -- says so here as well, and adds every screen but the inventory --
        -- the one screen that keeps game input, and the one the wheel closes.
        if BR.Keys.uiOwnsKeyboard then return end
        if BR.Keys.uiScreen ~= nil and BR.Keys.uiScreen ~= 'inventory' then return end
        if BR.Emotes.blocked() ~= nil then return end
        if frontendUp() then return end
        if not (BR.Menu and BR.Menu.available and BR.Menu.available()) then return end

        -- DISMISS, IN THIS ORDER, AND BEFORE THE WHEEL SHOWS. A UIMenu closing
        -- clears the library's current menu and its draw flag, so a menu
        -- closed after the wheel went up would take the wheel's drawing with
        -- it. Tutorial cards that take no focus are left where they are.
        if BR.Inv and BR.Inv.closePanel then BR.Inv.closePanel() end
        TriggerEvent('br:ui:clearFocus')
        if BR.Menu.closeAll then BR.Menu.closeAll(w) end

        w = w or build()
        if w == nil then return end

        -- REBUILT WHILE HIDDEN, EVERY OPEN. The library's item setters on a
        -- visible wheel write the wrong field, and RemoveItem removes nothing,
        -- so each segment's list is replaced wholesale while it is down.
        local ids = BR.Emotes.wheel()
        local sel = nil
        for k = 1, #w.Segments do
            local seg = w.Segments[k]
            seg.Items = {}
            seg.currentSelection = 1
            local id = ids[k] or ''
            local row = id ~= '' and BR.Emotes.row(id) or nil
            -- An id the catalogue does not know is drawn, and picked, as empty.
            shown[k] = row and id or ''
            if row then seg:AddItem(SegmentItem.New(row.name, '', '', '', 0, 0)) end
            if sel == nil and shown[k] == '' then sel = k end
        end

        -- THE HIGHLIGHT STARTS ON AN EMPTY SEGMENT WHENEVER THERE IS ONE. The
        -- library hands currentSelection to the movie as it builds, and
        -- oldAngle far out of range means the first real stick movement always
        -- moves it.
        w.currentSelection = sel or 1
        w.oldAngle = -360
        w.changed = false

        openedAt = GetGameTimer()
        local ok, err = pcall(w.Visible, w, true)
        if not ok then
            print(('[br_core] emote wheel: ScaleformUI refused to open it: %s'):format(tostring(err)))
            close()
            return
        end
        open = true
        return
    end

    if not open then return end
    -- A TAP IS NOT A PICK, and neither is a release a screen took the keyboard
    -- for. The tap window also absorbs the false release a focus change can
    -- put on a held key (keybinds.lua's resync note).
    local pick = nil
    if not BR.Keys.uiOwnsKeyboard and GetGameTimer() - openedAt >= BR.Config.Emotes.tapMs then
        local seen, k = pcall(w.CurrentSelection, w)
        local id = seen and shown[k] or nil
        if type(id) == 'string' and id ~= '' then pick = id end
    end
    close()
    if pick then BR.Emotes.request(pick) end
end)

-- ANY SCREEN PUSHED WHILE THE WHEEL IS UP CLOSES IT. TAB is the case that
-- matters: the inventory opens on the raw layer whatever the frame pass
-- disables. An EVENT rather than a polled uiScreen, so the wheel's own
-- clearFocus at open (which lands as 'none') cannot close it.
AddEventHandler('br:ui:focusChanged', function(screen)
    if open and screen ~= nil and screen ~= 'none' then close() end
end)

BR.Loop.register(BR.Loop.FRAME, 'emotes.wheel', function()
    if not open then return end
    -- THE LIBRARY CLOSED IT (Escape is its Back), so this file stops
    -- believing it is open.
    local seen, vis = pcall(w.Visible, w)
    if not (seen and vis == true) then
        open = false
        return
    end
    -- What would refuse an open closes an open wheel. blocked() covers a
    -- vehicle: the library leaves the enter control live.
    if not BR.Emotes.enabled() or BR.Emotes.blocked() ~= nil or frontendUp()
       or BR.Keys.uiOwnsKeyboard then
        close()
        return
    end
    for i = 1, #CONTROLS do DisableControlAction(0, CONTROLS[i], true) end
end)

AddEventHandler('onClientResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    close()
end)
