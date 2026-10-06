-- The festive calendar (#395, #399): is it the festive months, and has a dev
-- forced the answer? The months are br_lib/config/festive.lua; this file is the
-- only reader of them.
--
-- ═══ ONE ANSWER FOR THE CRATES AND THE SKY ═══
--
-- It used to be BR.Crates.festiveNow(), the crates' own. The owner's snow
-- (2026-10-05) is "on the same switch as the festive crates", so the answer
-- moved here and both ask it: server/loot.lua when a match's loot is laid out,
-- server/world.lua for the sky every client stands under. A forced answer from
-- `brfestive` therefore moves both at once, and neither feature owns the other.
--
-- ═══ SERVER ONLY, IN EFFECT ═══
--
-- A client has no `os` library and never asks: it reads `bf` off a crate, and
-- the festive sky arrives as one fact in the world payload (shared/world.lua).
--
-- THE DEV SWITCH: BR.Festive.override. nil (the default) follows the date;
-- true or false forces it. Written only by `brfestive` (br_core/server/loot.lua)
-- and never assigned here, so a second load of this file cannot quietly drop it.

BR = BR or {}
BR.Festive = BR.Festive or {}

--- Is this date in the festive months?
--- @param date table|nil  os.date('*t') shape; only `month` is read
--- @return boolean
function BR.Festive.date(date)
    local C = BR.Config and BR.Config.Festive
    local months = type(C) == 'table' and C.months or nil
    if type(date) ~= 'table' or type(months) ~= 'table' then return false end
    local m = math.tointeger(tonumber(date.month))
    return m ~= nil and months[m] == true
end

--- The festive answer right now: the dev switch if it is set, the date if not.
--- @param dateFn function|nil  os.date by default
--- @return boolean
function BR.Festive.now(dateFn)
    if BR.Festive.override ~= nil then return BR.Festive.override == true end
    dateFn = dateFn or (os and os.date)
    if not dateFn then return false end
    local ok, d = pcall(dateFn, '*t')
    if not ok then return false end
    return BR.Festive.date(d)
end
