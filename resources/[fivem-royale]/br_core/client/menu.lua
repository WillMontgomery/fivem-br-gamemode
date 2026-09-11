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

--- THE PRICE ON A ROW, AND THE SAME LIMIT ONE STEP WORSE.
---
--- Owner, 2026-09-09: "The item cost in the menu is white, not gold. it should
--- be gold."
---
--- ═══ A RIGHT LABEL HAS NO COLOR ARGUMENT AT ALL ═══
---
--- The subtitle above is at least a HUD index this file chooses. The right label
--- is not even that: UIMenu:SendItemToScaleform pushes an item's panel color and
--- highlight color as ARGB integers and then pushes the right label as a GTA
--- TEXT COMMAND (CELL_EMAIL_BCON). A text command carries no color, so the only
--- route to a colored price is a color TOKEN inside the string, and a token
--- names an index into the engine's own HUD palette.
---
--- 109 IS HUD_COLOUR_GOLD, which is the nearest thing GTA has to `--color-volts`
--- (#d9ae35). IT IS NOT THAT HEX AND CANNOT BE MADE INTO IT HERE: the RGB behind
--- an index comes from common:/data/ui/hudcolor.dat at runtime.
---
--- ═══ THERE IS ONE ESCAPE HATCH AND IT IS NOT AN AGENT'S TO TAKE ═══
---
--- REPLACE_HUD_COLOUR_WITH_RGBA(index, r, g, b, a) reassigns what an index
--- MEANS, and the movie resolves `~HC_n~` through GET_HUD_COLOUR at draw time,
--- so a remapped index really would render in our exact gold. The price is that
--- the remap is GLOBAL AND PERMANENT for the session -- every HUD element in the
--- game that uses that index changes with it. That is the owner's call, on an
--- index nothing else touches, and it is written down here rather than taken.
local PRICE_HUD = 109

--- The gold token, once. `~HC_109~` is the short form the movie's own string
--- table carries (`~HC_` and `~HUD_COLOUR` are both in it).
local PRICE_TOKEN = ('~HC_%d~'):format(PRICE_HUD)

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

--- A PRICE, IN GOLD, FOR A RIGHT LABEL. See PRICE_HUD above for what "gold"
--- can and cannot mean on this surface.
---
--- THE TOKEN IS APPLIED HERE AND NOWHERE ELSE, which is the same rule
--- BR.ShopSolve.priceLine states from the other end: priceLine formats "N Volts"
--- for BOTH this menu and the showroom's DUI, and a DUI renders raw text -- a
--- `~HC_109~` written into the formatter would print as those characters on the
--- warmup pad. So the formatter stays colorless and the SURFACE marks it.
--- @param text string|nil
--- @return string
function BR.Menu.priceGold(text)
    return PRICE_TOKEN .. tostring(text or '')
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

--- ONE OF THE LIBRARY'S OWN ICONS, BY NAME.
---
--- BadgeStyle is 191 entries of GTA's own sprite ids and it is a global the
--- vendored bundle exports. This is here rather than in a caller for the same
--- reason the two hexes are: a caller that wrote `BadgeStyle.LOCK` would be a
--- second file that stops working when the library is not deployed, and it
--- would be the file that has to remember that a missing global is nil-indexed
--- rather than absent.
---
--- NIL RATHER THAN 0 WHEN THERE IS NO SUCH BADGE. 0 is BadgeStyle.NONE, a real
--- instruction meaning "clear it", and a lookup miss must not be mistaken for
--- one.
--- @param name string  a BadgeStyle key: 'LOCK', 'GUN', 'AMMO'
--- @return integer|nil
function BR.Menu.badge(name)
    if type(BadgeStyle) ~= 'table' then return nil end
    local v = BadgeStyle[name]
    return type(v) == 'number' and v or nil
end

--- Put something in a row's ONE badge slot: a base game texture, or an enum.
---
--- ═══ THERE IS ONE SLOT AND TWO WAYS TO FILL IT, AND THEY DO NOT CLEAR EACH
---     OTHER ═══
---
--- ⚠ THE ORDERING BELOW IS THE WHOLE REASON THIS FUNCTION EXISTS. The library
--- keeps a badge TWICE on every item: `_leftBadge`, an integer, and
--- `customLeftIcon`, a { TXD, TXN } pair. CustomLeftBadge writes the pair AND
--- sets `_leftBadge` to -1 (BadgeStyle.CUSTOM); LeftBadge writes the integer and
--- LEAVES THE PAIR WHERE IT WAS. Both are pushed into the movie together on
--- every redraw.
---
--- So a row that wore a weapon icon and then became locked would push a padlock
--- id alongside a stale texture name, and which of the two the movie honours is
--- a question about a .gfx nobody here has opened. The gun shop flips rows
--- between those two states on every balance change, so this is not a corner:
--- it is the ordinary path. Clearing the pair first makes the answer the same
--- whichever way the movie resolves it.
---
--- SPELT OUT IN ONE PLACE rather than left to each caller to remember, for the
--- same reason BR.Menu.badge exists: a caller that wrote `item:CustomLeftBadge`
--- would be a second file that stops working when the library is not deployed,
--- and it would be the file that has to remember this ordering.
---
--- @param item table         a UIMenuItem
--- @param badge integer|nil  a BadgeStyle id, used when there is no texture
--- @param txd string|nil     a streamed texture dictionary, already loaded
--- @param txn string|nil     a texture name inside it
function BR.Menu.leftBadge(item, badge, txd, txn)
    if type(item) ~= 'table' then return end

    if type(txd) == 'string' and txd ~= ''
        and type(txn) == 'string' and txn ~= '' then
        pcall(item.CustomLeftBadge, item, txd, txn)
        return
    end

    -- THE CLEAR COMES FIRST, AND IT IS NOT OPTIONAL -- see the header. It also
    -- sets `_leftBadge` to -1 on its way past, which is exactly why the enum
    -- below cannot be written the other way round.
    pcall(item.CustomLeftBadge, item, '', '')

    -- A NUMBER, AND NOT `and/or`. BadgeStyle.NONE is 0 and 0 IS TRUTHY IN LUA,
    -- so a caller clearing a badge with 0 must reach the setter rather than be
    -- folded into "no badge" by an idiom that reads as if it would.
    if type(badge) == 'number' then
        pcall(item.LeftBadge, item, badge)
    end
end

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
---
--- ═══ NO MOUSE, AND NO INSTRUCTIONAL BUTTONS ═══
---
--- Owner, 2026-09-09: "The menus have a mouse for some reason" and "while the
--- menu is open, instructional buttons are shown. that is not necessary if it is
--- possible to remove them."
---
--- BOTH ARE THE LIBRARY'S DEFAULTS rather than anything this project asked for,
--- and both are turned off HERE rather than per menu, because a second menu that
--- came out with a cursor on it would be the same report a second time.
---
--- THE MOUSE IS A ONE-LINE SETTER AND THE BUTTONS ARE NOT, which is worth
--- writing down because the obvious call does nothing:
---
---   `MouseControlsEnabled(false)` WORKS. UIMenu:ProcessMouse returns on its
---   first guard when that flag is false, before SetMouseCursorActiveThisFrame
---   is ever reached. (Its own `ENABLE_MOUSE` movie call fires only when the
---   menu is already visible, and ScaleformUI.gfx does not export that function
---   anyway -- it is in RadialMenu.gfx and RadioMenu.gfx. Dead, harmless, and
---   not what does the work.)
---
---   `HasInstructionalButtons(false)` DOES NOTHING. It writes
---   Settings.InstructionalButtons, and in 5.8.1 that field is read by its own
---   getter and by nothing else in the 20,143-line bundle. UIMenu:Visible(true)
---   hands `self.InstructionalButtons` -- the LIST, a different field -- to the
---   shared ButtonsHandler unconditionally, and that handler's Draw and Update
---   both return immediately on an empty list. So EMPTYING THE LIST is the
---   mechanism, and it is a plain field write rather than a vendor patch.
---
--- WHAT WOULD PUT THEM BACK: `CanPlayerCloseMenu(...)` rebuilds the default list
--- from scratch, and `AddInstructionButton(...)` obviously repopulates it. No
--- menu built through here may call either.
---
--- ═══ THE BANNER IS ART OR IT IS A COLORED BAR, AND IT CANNOT BE BOTH HERE ═══
---
--- UIMenu.New takes the banner texture as arguments SIX AND SEVEN. This file
--- passed five and stopped, so the movie was handed two empty strings and drew
--- the bar with no art on it -- which is exactly what the owner saw. `banner` is
--- that pair, and when it is supplied THE BANNER COLOR IS LEFT ALONE: the movie
--- tints the sprite with it, and our cyan over a shop title texture is a cyan
--- Ammu-Nation sign. UNSEEN IN GAME either way; if the art comes out washed or
--- tinted, this branch is the one line to move.
--- @param title string
--- @param subtitle string|nil
--- @param banner table|nil  { txd = string, txn = string }, or nil for the bar
--- @return table|nil
function BR.Menu.new(title, subtitle, banner)
    if not BR.Menu.available() then return nil end

    local txd = type(banner) == 'table' and tostring(banner.txd or '') or ''
    local txn = type(banner) == 'table' and tostring(banner.txn or '') or ''
    local sprite = (txd ~= '' and txn ~= '')

    local ok, menu = pcall(UIMenu.New, tostring(title or ''),
                           tostring(subtitle or ''), 0, 0, false,
                           sprite and txd or nil, sprite and txn or nil)
    if not ok or type(menu) ~= 'table' then
        print('^3[br_core] menu: ScaleformUI refused to build a menu^7')
        return nil
    end

    local accent, gold = BR.Menu.accent(), BR.Menu.gold()
    -- EACH WRITE GUARDED SEPARATELY. These are setters on a vendored object and
    -- a version bump could rename any one of them; losing the counter's color is
    -- a cosmetic regression, and losing the menu is a counter that will not open.
    if accent and not sprite then pcall(menu.SetBannerColor, menu, accent) end
    if gold then pcall(menu.CounterColor, menu, gold) end
    pcall(menu.SubtitleColor, menu, SUBTITLE_HUD)
    pcall(menu.MouseControlsEnabled, menu, false)
    -- THE CAMERA SWING, WHICH IS A SEPARATE FLAG AND ALSO ON BY DEFAULT. With it
    -- set, ProcessMouse rotates the gameplay camera when the pointer nears a
    -- screen edge -- which is not something a player standing at a counter wants
    -- and would read as the menu fighting them.
    pcall(menu.MouseEdgeEnabled, menu, false)

    -- A PLAIN FIELD, NOT A SETTER. See the block above: the setter is a no-op in
    -- this version and emptying the list is what actually removes them.
    menu.InstructionalButtons = {}

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
--- ═══ THE DESCRIPTION AND THE BADGE ARE BOTH PER ITEM AND BOTH FOLLOW THE
---     HIGHLIGHT ═══
---
--- `description` is the strip under the list. It is a GTA text entry, so `~n~`
--- breaks a line and it word-wraps; the library re-asserts it on every selection
--- change. ONE TRAP, and it belongs to the caller rather than to this function:
--- `UIMenu_Current_Description` is a SINGLE SHARED GXT KEY, so setting a
--- description on a row that is not the highlighted one WHILE THE MENU IS OPEN
--- overwrites the text the player is reading until the next index change. Set
--- descriptions with the menu down, or re-assert the current selection after.
---
--- `badge` is a BadgeStyle id on the LEFT of the row. Left rather than right
--- because the right end of a row is where the price is, and how the movie lays
--- out a right badge and a right label together is not something this project
--- has seen on screen.
--- @param text string
--- @param rightLabel string|nil
--- @param mainColor table|nil   an SColor; nil takes the library's default panel
--- @param opts table|nil        { description = string, badge = integer }
--- @return table|nil
function BR.Menu.item(text, rightLabel, mainColor, opts)
    if not BR.Menu.available() then return nil end
    opts = type(opts) == 'table' and opts or {}

    local ok, item = pcall(UIMenuItem.New, tostring(text or ''),
                           tostring(opts.description or ''),
                           mainColor, BR.Menu.accent())
    if not ok or type(item) ~= 'table' then return nil end

    if rightLabel ~= nil then
        pcall(item.RightLabel, item, tostring(rightLabel))
    end
    -- A NUMBER, AND NOT `and/or`. BadgeStyle.NONE is 0 and 0 IS TRUTHY IN LUA,
    -- so a caller clearing a badge with 0 must reach the setter rather than be
    -- folded into "no badge" by an idiom that reads as if it would.
    if type(opts.badge) == 'number' then
        pcall(item.LeftBadge, item, opts.badge)
    end
    return item
end

--- A CATEGORY HEADER: A ROW THE ARROW KEYS CANNOT LAND ON.
---
--- Owner, 2026-09-09: "re-categorize it top-down with the top being the most
--- common weapon types they sell, and the bottom being legendary, with
--- separators in between that indicate the category".
---
--- ═══ IT IS A REAL ITEM TYPE, NOT A DISABLED ROW DRESSED UP AS ONE ═══
---
--- UIMenuSeparatorItem is ItemId 6, and GoUp and GoDown both loop past one while
--- its `Jumpable` is set, BuildMenu steps off one that lands at index 1, and a
--- mouse click on one plays the error sound and returns. A DISABLED UIMenuItem
--- would NOT do that -- Enabled(false) is not skipped by the arrow keys, only
--- ItemId 6 is -- so a fake header would be a row the player can sit on.
---
--- `jumpable` IS PASSED EXPLICITLY AND IS ALWAYS A BOOLEAN. The library stores
--- it raw and pushes it straight into PushScaleformMovieFunctionParameterBool,
--- so a nil there is a native call with a nil argument.
---
--- THE COLOR IS SET AFTERWARDS, ON PURPOSE. UIMenuSeparatorItem.New declares
--- mainColor, textColor and highlightedTextColor and then throws all three away:
--- its body reads the undefined globals `color` and `Description` instead of its
--- own parameters. The INHERITED MainColor setter is correct, so this calls that
--- and the vendored file stays untouched.
--- @param text string
--- @param mainColor table|nil
--- @return table|nil
function BR.Menu.separator(text, mainColor)
    if not BR.Menu.available() then return nil end
    if type(UIMenuSeparatorItem) ~= 'table' then return nil end

    local ok, sep = pcall(UIMenuSeparatorItem.New, tostring(text or ''), true)
    if not ok or type(sep) ~= 'table' then return nil end

    if mainColor then pcall(sep.MainColor, sep, mainColor) end
    return sep
end
