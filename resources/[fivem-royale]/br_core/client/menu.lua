-- Our colors on somebody else's menu library (#274).
--
-- ═══════════════════════════════════════════════════════════════════════════
-- THIS IS THE FIRST SCALEFORMUI MENU IN THE PROJECT, SO THIS FILE IS THE
-- PATTERN
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Owner, 2026-09-08: "I've tested out ScaleformUI_Lua's demo menu and I like the
-- UI - feels exactly like Rockstar's." And: "Make them our colors for now - I'll
-- figure out the gfx for fonts later."
--
-- ScaleformUI takes its colors PER MENU, AT CONSTRUCTION -- there is no palette
-- inside the library to change, which resources/[scaleformui]/ScaleformUI_Lua/
-- VENDOR.json records under `untouched_on_purpose`. So without this file every
-- menu we ever write repeats four color decisions, and the fifth one gets one of
-- them wrong in a way nobody notices until two menus are open side by side.
--
-- IT IS DELIBERATELY TINY. Two colors, one HUD index, three constructors. It is
-- not a widget kit and must not become one: the moment it starts deciding what
-- items a menu has, it is a second menu library sitting on top of the vendored
-- one.
--
-- ═══ FONTS ARE NOT OURS AND CANNOT BE ═══
--
-- Scaleform fonts live inside the compiled .gfx movies that ScaleformUI_Assets
-- streams. There is no Lua entry point that can add one, so this file does not
-- try and nothing downstream should. The owner has said he will look at the gfx
-- himself.
--
-- ═══ WHY THE TWO HEXES ARE WRITTEN HERE AND NOT READ FROM THE INTERFACE ═══
--
-- client/dui.lua is the project's rule for this and it says colors are read out
-- of the document rather than written down, because ui-src/src/index.css is the
-- one place a color in this game is authored. That rule is right and it does not
-- reach here, for two reasons:
--
--   A SCALEFORM IS NOT A DOCUMENT. A DUI is a CEF page with a cascade, so
--   br_ui can resolve a token with getComputedStyle and send the answer
--   (`br:settings:palette`, consumed by BR.Dui.hp and BR.Dui.volts). A .gfx
--   movie has no cascade and no way to be told about one; every color it draws
--   arrives from Lua as an ARGB integer.
--
--   AND THAT EVENT DOES NOT CARRY THESE TWO ANYWAY. It carries `hp` and
--   `volts` -- and its `volts` is `--color-royale-accent2` (#facc15, the
--   victory yellow the Store screen paints prices with), not `--color-volts`
--   (#d9ae35, the signature gold). Neither `--color-royale-accent` nor
--   `--color-volts` is on that wire today. Widening it is an edit to ui-src/
--   and a rebuilt bundle, which is a different round's work.
--
-- SO THIS IS THE ONE PLACE IN THE LUA TREE THOSE TWO ARE SPELLED, and
-- tools/test_gunshop.lua asserts they still equal index.css. When somebody
-- widens `br:settings:palette`, the fix is to read them from there and delete
-- the literals.

BR = BR or {}
BR.Menu = BR.Menu or {}

--- ═══ EIGHT DIGITS, ALPHA FIRST, AND SIX IS SILENTLY WRONG ═══
---
--- SColor.FromHex asserts only that the string starts with `#`. It then reads
--- characters 2-3 as ALPHA, 4-5 as red, 6-7 as green and 8-9 as blue. Handed a
--- six-digit code it does not complain: "#22d3ee" parses as alpha 0x22, red
--- 0xd3, green 0xee and blue `tonumber("0x")`, which is nil -- so the color is
--- built, looks fine in a table dump, and throws several calls later inside
--- ToArgb with a message about arithmetic on a nil value. The fault is nowhere
--- near the line that caused it.
---
--- FF IS FULLY OPAQUE. Both of these are chrome -- a banner and a counter -- and
--- neither wants to be see-through.
---
--- `--color-royale-accent` (#22d3ee) is the interface's cyan: the boost bar, the
--- loading ring, every focused control. `--color-volts` (#d9ae35) is the
--- signature gold, and index.css holds it deliberately BELOW
--- `--color-royale-accent2` so that the currency and a victory do not read as
--- the same event.
local ACCENT_HEX = '#FF22D3EE'   -- --color-royale-accent, opaque
local GOLD_HEX   = '#FFD9AE35'   -- --color-volts, opaque

--- THE ONE ELEMENT THAT CANNOT BE BRAND-MATCHED, AND WHY.
---
--- Every other color on a UIMenu is an ARGB integer. The SUBTITLE is not: it is
--- drawn by prefixing the string with a GTA text token, `~HC_<n>~` (see
--- UIMenu:SetMenuData in the vendored bundle), and that `n` is an index into the
--- ENGINE'S OWN HUD PALETTE. There is no route from a hex to an index and no
--- native that adds one, so the subtitle can only ever be one of GTA's colors.
---
--- 9 IS HUD_COLOUR_BLUE, which is the nearest thing GTA has to #22d3ee -- a
--- mid-blue where ours is a bright cyan. It is visibly not our color and that is
--- the honest state of it rather than a thing to keep tuning.
---
--- IT DOES NOT MATTER MUCH TODAY, because the gun shop's subtitle is empty and
--- the strip carries only the item counter, which IS brand-matched (that one is
--- an SColor). It is set anyway so that the first menu with a subtitle inherits
--- a decision rather than making a fresh one.
local SUBTITLE_HUD = 9

--- IS THE LIBRARY IN THIS LUA STATE?
---
--- ═══ ASKED AT CALL TIME, EVERY TIME, AND NOT CACHED ═══
---
--- ScaleformUI reaches br_core by way of `@ScaleformUI_Lua/ScaleformUI.lua` in
--- the manifest -- upstream's own integration route, because a resource cannot
--- see another resource's globals and this library exports nothing. So it is
--- present or absent depending on whether that vendored resource is deployed,
--- which is a property of the BOX rather than of the code.
---
--- A CACHED ANSWER WOULD BE WRONG ACROSS A RESTART of either side, and the cost
--- of asking is three table lookups on a path that runs when a player presses a
--- key. Everything downstream must treat `false` as "no menu, say so on the
--- console, carry on" rather than as an error: a server without the library is a
--- server where the counters do not open, not one that throws.
--- @return boolean
function BR.Menu.available()
    return type(UIMenu) == 'table' and type(SColor) == 'table'
        and type(UIMenuItem) == 'table' and type(MenuHandler) == 'table'
end

--- One hex through the library's parser, without letting its assert escape.
---
--- FromHex ASSERTS rather than returning nil, and an assert inside a keypress
--- handler takes the whole handler with it. pcall here means a mistyped constant
--- costs the color and not the menu.
--- @param hex string
--- @return table|nil
local function hexColor(hex)
    if not BR.Menu.available() then return nil end
    local ok, c = pcall(SColor.FromHex, hex)
    if not ok then
        print(('^3[br_core] menu: "%s" is not a color ScaleformUI can read -- '
               .. 'it wants eight digits, alpha first^7'):format(tostring(hex)))
        return nil
    end
    return c
end

--- The interface's cyan, as an SColor. nil when the library is absent.
--- @return table|nil
function BR.Menu.accent() return hexColor(ACCENT_HEX) end

--- The signature gold, as an SColor. nil when the library is absent.
--- @return table|nil
function BR.Menu.gold() return hexColor(GOLD_HEX) end

--- How much of a rarity's color a menu row wears. See the note below.
local RARITY_TINT_A = 70

--- A RARITY'S OWN COLOR, FROM THE ONE PLACE RARITY COLORS LIVE.
---
--- BR.RarityInfo is what the loot glow markers and the inventory borders are
--- both drawn from, so a menu that reads it is wearing the same five colors the
--- rest of the game already means by "rare" and "legendary". A sixth opinion
--- about what purple means is exactly the drift this project keeps paying for.
---
--- ═══ AN ALPHA, AND THE ALPHA IS THE WHOLE JUDGEMENT ═══
---
--- `_mainColor` is the item's own rectangle -- the library's default for it is
--- HUD_Panel_light, a dark panel -- so a rarity at full opacity would be thirty
--- solid color blocks stacked down the screen, which is a loot filter, not a
--- shop. At a low alpha it is a tint on the panel and the white label still
--- reads over it.
---
--- UNSEEN IN GAME. Nothing in this repository has ever drawn a ScaleformUI menu,
--- so how 70 reads on a real screen -- and whether the movie honors the alpha
--- byte at all -- is a playtest question. If it comes out loud, this constant is
--- the dial; if the movie ignores alpha entirely, the fallback is to pass no
--- color at all and let every row take the library's default panel, which is one
--- argument at the call site.
--- @param rarity integer|nil
--- @return table|nil
function BR.Menu.rarityColor(rarity)
    if not BR.Menu.available() then return nil end
    local info = BR.RarityInfo and BR.RarityInfo[rarity]
    local rgb = info and info.rgb
    if type(rgb) ~= 'table' or #rgb < 3 then return nil end
    local ok, c = pcall(SColor.FromArgb, RARITY_TINT_A, rgb[1], rgb[2], rgb[3])
    if not ok then return nil end
    return c
end

--- A UIMenu ALREADY WEARING OUR COLORS.
---
--- THE FOUR DECISIONS, MADE ONCE:
---
---   banner    the cyan. The big brand element, and the one thing a player sees
---             before they read anything.
---   counter   the gold. "3/30" in the subtitle strip.
---   subtitle  the nearest HUD index (see SUBTITLE_HUD above).
---   position  the library's own default corner, untouched. Where a menu sits
---             is a per-menu decision and this file has no opinion.
---
--- GLARE IS OFF. It is the animated sheen behind Rockstar's pause menu and it
--- costs a second scaleform movie plus a per-frame camera-rotation read
--- (UIMenu:Draw). The framerate investigation on 2026-09-07 is why that is not a
--- default here; a menu that wants it can turn it on.
---
--- NIL WHEN THE LIBRARY IS ABSENT, rather than a stub object. A caller that gets
--- nil must say so and do nothing -- a fake menu that silently swallows a
--- keypress is worse than a counter that visibly does not open.
--- @param title string
--- @param subtitle string|nil
--- @return table|nil
function BR.Menu.new(title, subtitle)
    if not BR.Menu.available() then return nil end

    local ok, menu = pcall(UIMenu.New, tostring(title or ''),
                           tostring(subtitle or ''), 0, 0, false)
    if not ok or type(menu) ~= 'table' then
        print('^3[br_core] menu: ScaleformUI refused to build a menu^7')
        return nil
    end

    local accent, gold = BR.Menu.accent(), BR.Menu.gold()
    -- EACH WRITE GUARDED SEPARATELY. These are setters on a vendored object and
    -- a version bump could rename any one of them; losing the counter's color is
    -- a cosmetic regression, and losing the menu is a counter that will not open.
    if accent then pcall(menu.SetBannerColor, menu, accent) end
    if gold then pcall(menu.CounterColor, menu, gold) end
    pcall(menu.SubtitleColor, menu, SUBTITLE_HUD)

    return menu
end

--- One row: a label, a right-hand label, and a color for its panel.
---
--- THE RIGHT LABEL IS WHERE A PRICE GOES, which is the library's own convention
--- for it and the one Rockstar uses in every shop in the base game.
---
--- THE HIGHLIGHT IS ALWAYS OUR CYAN, on every item, in every menu built through
--- here. The selected row is the one thing a player is looking at, so it is the
--- one place the brand color is unambiguously worth spending.
--- @param text string
--- @param rightLabel string|nil
--- @param mainColor table|nil   an SColor; nil takes the library's default panel
--- @return table|nil
function BR.Menu.item(text, rightLabel, mainColor)
    if not BR.Menu.available() then return nil end

    local ok, item = pcall(UIMenuItem.New, tostring(text or ''), '',
                           mainColor, BR.Menu.accent())
    if not ok or type(item) ~= 'table' then return nil end

    if rightLabel ~= nil then
        pcall(item.RightLabel, item, tostring(rightLabel))
    end
    return item
end
