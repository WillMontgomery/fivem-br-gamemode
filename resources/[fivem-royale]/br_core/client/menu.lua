-- GTA's colors on somebody else's menu library (#274).
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
-- IT IS DELIBERATELY TINY. Four HUD indices, three constructors, and three
-- one-line text marks. It is not a widget kit and must not become one: the moment
-- it starts deciding what items a menu has, it is a second menu library sitting
-- on top of the vendored one.
--
-- ═══ FONTS ARE NOT OURS AND CANNOT BE ═══
--
-- Scaleform fonts live inside the compiled .gfx movies that ScaleformUI_Assets
-- streams. There is no Lua entry point that can add one, so this file does not
-- try and nothing downstream should. The owner has said he will look at the gfx
-- himself.
--
-- ═══ THE PROJECT PALETTE IS NOT ON THIS SURFACE AT ALL, AND THAT IS THE RULE
--     NOW ═══
--
-- Owner, 2026-09-11, after a playtest: "No ScaleformUI should ever use our cyan
-- ever". And a moment later, asked whether that reached the gold too: "Same for
-- the gold, use GTA's gold everywhere".
--
-- So EVERY color a ScaleformUI menu draws is an index into the ENGINE'S OWN HUD
-- PALETTE -- common:/data/ui/hudcolor.dat, read at runtime -- and not one hex of
-- ours appears in this file or in any caller of it. tools/test_gunshop.lua reads
-- `--color-royale-accent` and `--color-volts` out of ui-src/src/index.css and
-- asserts that neither value is anywhere in this path, so the rule is a ratchet
-- rather than a paragraph.
--
-- ⚠ THE ONE EXCEPTION IS FLAGGED AND IS NOT A LOOPHOLE: BR.Menu.rarityColor
-- below still paints BR.RarityInfo's five loot colors. The argument for keeping
-- them, and the fact that it is his call and not ours, is on that function.
--
-- WHY HE IS RIGHT, BEYOND ITS BEING HIS CALL. He chose this library because it
-- "feels exactly like Rockstar's", and a Rockstar menu wearing two colors out of
-- a React HUD does not. The two surfaces are never on screen together either:
-- the menu replaces the HUD rather than sitting beside it.
--
-- ═══ AND IT RETIRES A PROBLEM THIS FILE ALREADY HAD ═══
--
-- client/dui.lua's rule is that colors are READ out of the document rather than
-- written down, because ui-src/src/index.css is the one place a color in this
-- game is authored. A DUI can obey that -- br_ui resolves a token with
-- getComputedStyle and sends the answer over `br:settings:palette`. A .gfx movie
-- has no cascade and no way to be told about one, so obeying it here was
-- impossible and this file held the only Lua copy of two hexes, kept in step
-- with index.css by a test.
--
-- THAT COPY IS NOW GONE. An index is not a color, it is a NAME for one the
-- engine owns, so there is nothing left to drift out of step with anything.

BR = BR or {}
BR.Menu = BR.Menu or {}

--- ═══ AN INDEX, NOT A HEX, AND NO HEX PARSER IS REACHED FROM HERE ANY MORE
---     ═══
---
--- GetHudColour(n) answers the r, g, b, a the engine holds for index n. The
--- vendored library wraps it as SColor.FromHudColor and builds its own ninety-odd
--- named colors with it at load -- SColor.HUD_White is FromHudColor(1) -- so this
--- is the library's own constructor rather than a route invented here.
---
--- ⚠ THE TRAP THAT IS NOW UNREACHABLE, WRITTEN DOWN BECAUSE ADDING A HEX BACK
--- WOULD REARM IT. SColor.FromHex asserts only that the string starts with `#`.
--- It then reads characters 2-3 as ALPHA, 4-5 as red, 6-7 as green and 8-9 as
--- blue. Handed a six-digit code it does not complain: "#22d3ee" parses as alpha
--- 0x22, red 0xd3, green 0xee and blue `tonumber("0x")`, which is nil -- so the
--- color is built, looks fine in a table dump, and throws several calls later
--- inside ToArgb with a message about arithmetic on a nil value. The fault is
--- nowhere near the line that caused it.

--- GTA'S BLUE, AND THE TWO PLACES IT IS SPENT.
---
--- Owner, 2026-09-11, told that a menu description takes a GTA text code rather
--- than an arbitrary color and so cannot be the project cyan: "Yes please use
--- GTA's blue instead of our cyan for that".
---
--- 9 IS HUD_COLOUR_BLUE, the nearest thing GTA has to #22d3ee: a mid-blue where
--- ours is a bright cyan. Visibly not our color, and that is the accepted state
--- of it rather than a thing to keep tuning -- the same settlement the price
--- already has at HUD_COLOUR_GOLD, which he accepted in the same words.
---
--- ═══ ONE INDEX, TWO MECHANISMS, WHICH IS WHY IT IS A CONSTANT ═══
---
---   THE SUBTITLE STRIP is drawn by prefixing the string with `~HC_<n>~` (see
---   UIMenu:SetMenuData in the vendored bundle). It could never have been ours
---   even before the rule: there is no route from a hex to an index and no native
---   that adds one. It matters little today -- the gun shop's subtitle is empty
---   and the strip carries only the item counter -- and is set so the first menu
---   with a subtitle inherits a decision rather than making a fresh one.
---
---   THE MARKED WORDS INSIDE A DESCRIPTION are a text token in the string, which
---   is a different mechanism entirely. Naming the same number is the only way the
---   two can be guaranteed to be the same blue.
local BLUE_HUD = 9

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
--- ═══ AND SINCE 2026-09-11 IT IS THE ONLY GOLD ON THIS SURFACE ═══
---
--- Owner: "The gun shop price doesn't have to be our exact color, just whatever
--- gold color the game has available", which closed this label. Then: "Same for
--- the gold, use GTA's gold everywhere" -- so the Volts COUNTER, which was
--- `#FFD9AE35` and is an SColor rather than a token, now reads its color from
--- this same index through BR.Menu.gold.
---
--- ONE NUMBER FOR BOTH, WHICH IS THE POINT. A token and an SColor are unrelated
--- mechanisms and the only way they can be made to agree exactly is by naming the
--- same index. The counter and the prices under it are now the same gold by
--- construction rather than by two people typing the same hex.
---
--- REPLACE_HUD_COLOUR_WITH_RGBA IS STILL NOT OURS TO CALL, and the owner has now
--- ruled on it directly: the global remap is "explicitly not wanted".
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

--- A RIGHT LABEL THAT IS NOT A PRICE, AND MUST NOT READ AS ONE.
---
--- Owner, 2026-09-11: "instead of a gold price text, we'll show a grey 'Out of
--- stock' text."
---
--- ═══ THE SAME ONE ROUTE, WHICH IS WHY IT IS A SECOND INDEX AND NOT A SECOND
---     MECHANISM ═══
---
--- Everything PRICE_HUD's block says applies here unchanged: a right label is
--- pushed as a GTA text command with no color argument, so a token inside the
--- string is the only route and the token names an index into the engine's own
--- HUD palette. 3 is HUD_COLOUR_GREY, the neutral mid-grey in
--- common:/data/ui/hudcolor.dat -- not GREYDARK (5), which is nearly the panel
--- it would be drawn on, and not GREYLIGHT (4), which is close enough to
--- HUD_COLOUR_WHITE to read as ordinary text rather than as stood-down text.
---
--- IT IS A CONTRAST DECISION AND IT IS THE DIAL. Nobody has compared these two
--- indices on a real row; if grey reads as invisible against the disabled
--- shading, this constant is the one thing to move.
local DIM_HUD = 3

--- The grey token, once. Same short form as PRICE_TOKEN above.
local DIM_TOKEN = ('~HC_%d~'):format(DIM_HUD)

--- The blue token, and the one that puts the color back.
---
--- `~s~` IS THE ENGINE'S "BACK TO STANDARD". PRICE_TOKEN and DIM_TOKEN mark a
--- whole right label and there is nothing after them to get wrong; a blue run
--- INSIDE a sentence has white on both sides of it, so it has to close.
local BLUE_TOKEN  = ('~HC_%d~'):format(BLUE_HUD)
local RESET_TOKEN = '~s~'

--- ═══════════════════════════════════════════════════════════════════════════
--- WHY A COLOR TOKEN IN A DESCRIPTION IS A COLOR AND NOT FOUR PRINTED
--- CHARACTERS
--- ═══════════════════════════════════════════════════════════════════════════
---
--- ⚠ ESTABLISHED OUT OF THE COMPILED MOVIE RATHER THAN ASSUMED, because a code
--- that prints literally is worse than no color at all, and a description does
--- NOT travel the route the price does.
---
--- THE PRICE'S ROUTE IS ALREADY PROVEN AND IS A DIFFERENT ONE. A right label
--- reaches the movie through BeginTextCommandScaleformString("CELL_EMAIL_BCON")
--- plus EndTextCommandScaleformString_2 -- the GAME formats the string and pushes
--- the finished thing in. The owner has seen `~HC_109~` come out gold that way.
---
--- A DESCRIPTION GOES THE OTHER WAY ROUND. UIMenuItem:Description calls
--- AddTextEntry("UIMenu_Current_Description", str) and then asks the movie to
--- redraw; the movie reads that GXT key ITSELF. So the question is what the movie
--- does with it, and the answer is in ScaleformUI_Assets/stream/ScaleformUI.gfx:
---
---   ITS UIMenu CLASS DRAWS `descText` THROUGH
---   com.rockstargames.ui.utils.Text.setTextWithIcons, whose body is
---   GameInterface.call(GENERIC_TYPE, "SET_FORMATTED_TEXT_WITH_ICONS", ...). That
---   hands the key back to THE GAME'S OWN FORMATTER -- the same one that resolves
---   every `~` token anywhere else in the game -- and the game writes the finished
---   markup into the field. A token in a description is resolved, not printed.
---
---   AND THE LIBRARY KNOWS `~HC_` BY NAME. Its own
---   com.rockstargames.ScaleformUI.utils.Functions carries a `notColours` array,
---   the sequences its `replaceRstarColorsWith` must NOT treat as a color it is
---   free to overwrite, and `~HUD_COLOUR` and `~HC_` are both in it. So is `~n`,
---   which is what makes a line break inside an owner-authored string survive.
---
--- ⚠ AND THIS IS WHY IT IS `~HC_9~` RATHER THAN `~b~`, WHICH WAS THE OTHER
--- CANDIDATE AND IS THE MORE OBVIOUS ONE. `~b~` appears NOWHERE in that movie. It
--- is not in `notColours`, which means it is exactly the shape
--- `replaceRstarColorsWith` is entitled to replace with the item's own color. One
--- of the two tokens is named and protected by the library and the other is not,
--- and that asymmetry is the whole argument -- not a preference between blues.

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

--- A RIGHT LABEL IN GREY, FOR A ROW THAT HAS NOTHING TO SELL.
---
--- THE CALLER STILL OWNS THE WORDS. This adds a color token and nothing else --
--- exactly as BR.Menu.priceGold does -- so the string it is handed is still
--- whichever config field the surface reads. See DIM_HUD above for the index.
--- @param text string|nil
--- @return string
function BR.Menu.dimmed(text)
    return DIM_TOKEN .. tostring(text or '')
end

--- A RUN OF WORDS INSIDE A SENTENCE, IN GTA'S BLUE.
---
--- Owner, 2026-09-11, on both of the gun shop's descriptions: "The {guntypes}
--- text should be blue, comma-separated, and everything else should remain white.
--- This is because the list is exhaustive to read through and we should make it so
--- they can skim, which is enabled by the colors." And on the weapon rows: "The
--- {ammotype} should be the same blue as we use above, and the number should be
--- blue as well."
---
--- IT CLOSES, WHICH priceGold AND dimmed DO NOT, and the reason is above
--- BLUE_TOKEN: those two mark a whole right label and this marks a fragment with
--- his own white words on either side of it. Without the reset, everything from
--- the marked words to the end of the description turns blue with them.
---
--- THE CALLER STILL OWNS THE WORDS, exactly as with the other two marks. This
--- adds two tokens and nothing else.
--- @param text string|nil
--- @return string
function BR.Menu.blue(text)
    return BLUE_TOKEN .. tostring(text or '') .. RESET_TOKEN
end

--- ONE HUD INDEX, AS AN SColor, WITHOUT LETTING THE LIBRARY'S ASSERT ESCAPE.
---
--- FromHudColor ASSERTS on a nil index rather than returning nil, and an assert
--- inside a keypress handler takes the whole handler with it. The constructor is
--- also checked for EXISTENCE rather than assumed: it is a vendored entry point,
--- a version bump could rename it, and losing a color has to cost a color rather
--- than a counter that will not open.
--- @param index integer
--- @return table|nil
local function hudColor(index)
    if not BR.Menu.available() then return nil end
    if type(SColor.FromHudColor) ~= 'function' then
        print('^3[br_core] menu: this ScaleformUI has no SColor.FromHudColor -- '
              .. 'menus will wear the library\'s own colors^7')
        return nil
    end
    local ok, c = pcall(SColor.FromHudColor, index)
    if not ok or type(c) ~= 'table' then return nil end
    return c
end

--- GTA's gold, as an SColor, from the same index the price token names.
---
--- IT IS STILL CALLED `gold` BECAUSE IT IS STILL THE GOLD. What changed on
--- 2026-09-11 is whose: it was `--color-volts` at `#FFD9AE35` and is now
--- HUD_COLOUR_GOLD. See PRICE_HUD above.
--- @return table|nil
function BR.Menu.gold() return hudColor(PRICE_HUD) end

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

--- How much of the shade a row the player cannot act on wears, and of what.
---
--- DECLARED HERE, BESIDE THE TINT IT REPLACES, and above every reader: a Lua
--- local is invisible above its own declaration, and BR.Menu.disabledColor sits
--- below BR.Menu.rarityColor for the same reason these two sit below
--- RARITY_TINT_A. The argument for the numbers is on that function.
local DISABLED_TINT_A   = 140
local DISABLED_TINT_RGB = { 24, 24, 24 }

--- A RARITY'S OWN COLOR, FROM THE ONE PLACE RARITY COLORS LIVE.
---
--- BR.RarityInfo is what the loot glow markers and the inventory borders are
--- both drawn from, so a menu that reads it is wearing the same five colors the
--- rest of the game already means by "rare" and "legendary". A sixth opinion
--- about what purple means is exactly the drift this project keeps paying for.
---
--- ═══ ⚠ AND IT IS THE ONE PALETTE ON THIS SURFACE THAT IS STILL OURS ═══
---
--- The rule of 2026-09-11 is that a ScaleformUI menu wears GTA's colors and never
--- the project's. These five are the project's. They are KEPT, and it is flagged
--- here rather than decided, because the reasons not to sweep them are reasons he
--- should get to overrule rather than ones we should act on:
---
---   THEY ARE NOT THE TWO HE NAMED. He banned the cyan and the gold, which are
---   brand chrome. These five are the game's own loot vocabulary, shared with the
---   markers and the bag, and a player reads them as "what kind of thing is this"
---   rather than as our styling.
---
---   GTA HAS NO INDEX THAT MEANS "EPIC". Replacing them means choosing five
---   palette entries, which is a decision of ours dressed as a lookup -- the
---   thing the ammunition separator block in client/gunshop.lua exists about.
---
---   AND DROPPING THEM TAKES THE GROUPING WITH THEM. He asked for the shelf to be
---   categorised with separators and has not complained about the row tints, so
---   removing all color from every row would be a regression filed against a
---   report he did not make.
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

--- HOW A ROW THE PLAYER CANNOT ACT ON IS SHADED.
---
--- Owner, 2026-09-11: "the row should be shaded differently like it's greyed
--- out/disabled."
---
--- ═══ THE PANEL IS THE ONLY LEVER, BECAUSE THE REAL ONE IS SPOKEN FOR ═══
---
--- The library has a disabled state and the movie draws it -- UIMenuItem:Enabled
--- is pushed as a bool on every redraw -- and it cannot be used for this. A
--- disabled row is unreachable: UIMenu:SelectItem returns on the Enabled check
--- BEFORE Item.Activated runs, so the refusal toast the owner asked for on an
--- unaffordable press could never be raised. The gun shop's refreshMenu has the
--- whole argument.
---
--- So "shaded like it's disabled" has to be the item's own panel rectangle,
--- which is the same `_mainColor` BR.Menu.rarityColor paints. A row carries one
--- or the other and never both: the rarity it is, or the fact that it cannot be
--- bought right now.
---
--- ═══ DARKER AND NEUTRAL, RATHER THAN A SIXTH TINT ═══
---
--- A grey at the rarity alpha would read as "a rarity we have no color for"
--- next to four rows that are tinted. Recessing it does the opposite: the row
--- goes back toward the menu's own dark ground while its neighbours stay
--- colored, which is the direction every greyed-out control in the game moves.
---
--- UNSEEN IN GAME, LIKE RARITY_TINT_A ABOVE, AND THESE TWO NUMBERS ARE THE
--- DIAL. If it comes out as a black bar, lower the alpha; if it is
--- indistinguishable from an affordable row, raise it.
--- @return table|nil
function BR.Menu.disabledColor()
    if not BR.Menu.available() then return nil end
    local ok, c = pcall(SColor.FromArgb, DISABLED_TINT_A,
                        DISABLED_TINT_RGB[1], DISABLED_TINT_RGB[2],
                        DISABLED_TINT_RGB[3])
    if not ok then return nil end
    return c
end

--- A UIMenu ALREADY WEARING OUR COLORS.
---
--- THE FOUR DECISIONS, MADE ONCE:
---
---   banner    NOTHING IS SET. See the block at the foot of this comment.
---   counter   GTA's gold, index 109 -- the same HUD_COLOUR_GOLD the price token
---             names. "3/30" in the subtitle strip.
---   subtitle  GTA's blue, index 9 (see BLUE_HUD above).
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
--- ═══ THE BANNER IS ART, AND NO COLOR IS PUT UNDER IT ANY MORE ═══
---
--- UIMenu.New takes the banner texture as arguments SIX AND SEVEN. This file
--- passed five and stopped, so the movie was handed two empty strings and drew
--- the bar with no art on it -- which is exactly what the owner saw. `banner` is
--- that pair.
---
--- SetBannerColor IS NO LONGER CALLED AT ALL. It used to paint the cyan, on the
--- branch where no sprite was supplied, and both halves of that are gone: the
--- cyan is out of this path, and the library's own default is SColor.HUD_None
--- (ARGB -1), which is its "do not tint" value.
---
--- IT WAS ALREADY MOOT FOR THE GUN SHOP AND IS SAID ANYWAY. That menu supplies
--- the Ammu-Nation sprite, and the movie TINTS a supplied sprite with the banner
--- color -- so a color here was never drawn as a bar there; it could only have
--- discolored the art, which is why the old code skipped it when a sprite was
--- set. A menu with no sprite now gets the library's own bar instead of a cyan
--- one. ⚠ UNSEEN IN GAME either way.
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

    local gold = BR.Menu.gold()
    -- EACH WRITE GUARDED SEPARATELY. These are setters on a vendored object and
    -- a version bump could rename any one of them; losing the counter's color is
    -- a cosmetic regression, and losing the menu is a counter that will not open.
    --
    -- `sprite` IS STILL READ, ONE LINE UP, and is deliberately not consulted
    -- here any more: there is no banner color to decide between art and a bar.
    if gold then pcall(menu.CounterColor, menu, gold) end
    pcall(menu.SubtitleColor, menu, BLUE_HUD)
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
--- ═══ THE HIGHLIGHT IS THE LIBRARY'S OWN, WHICH IS GTA'S WHITE ═══
---
--- Owner, 2026-09-11, having raised it twice: "The selected row is way too bright
--- blue, very harsh. Don't use that", then "What I'm referring to on the styling
--- is the selected row and separator rows being that obnoxious light blue still".
---
--- IT WAS BR.Menu.accent(), #22d3ee AT FULL OPACITY ACROSS A WHOLE ROW. The cyan
--- works as a thin element -- a 1px edge, a ring -- and does not work as a fill,
--- which is the complaint. Asked what to use instead he answered with a rule
--- rather than a color: "No ScaleformUI should ever use our cyan ever".
---
--- SO NOTHING IS PASSED AND THE LIBRARY'S DEFAULT STANDS. UIMenuItem.New falls
--- back to SColor.HUD_White, which is SColor.FromHudColor(1) -- HUD_COLOUR_WHITE
--- out of the engine's palette, and the same white the movie inverts a row's text
--- against. That is not a color chosen here: it is the one the ScaleformUI demo
--- wears, and the demo is what he said "feels exactly like Rockstar's".
---
--- nil IS PASSED EXPLICITLY rather than the argument being dropped, so that the
--- position cannot be silently occupied if the constructor grows a parameter.
---
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
                           mainColor, nil)
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

--- A DESCRIPTION, SET WITHOUT TRAMPLING THE ONE THE PLAYER IS READING.
---
--- ═══ THERE IS ONE GXT KEY FOR THE WHOLE MENU ═══
---
--- ⚠ UIMenuItem:Description writes AddTextEntry("UIMenu_Current_Description",
--- str) whenever the parent menu is VISIBLE, for whichever item it was called on.
--- `UIMenu_Current_Description` is a SINGLE SHARED KEY, so describing a row that
--- is not the highlighted one while the menu is up replaces the text under the
--- highlighted row with this row's -- and it stays wrong until the player moves
--- the cursor. BR.Menu.item's header has always named this trap and left it to the
--- caller; this is the caller's half, written once.
---
--- IT IS NOT A CORNER AT THE GUN COUNTER. Every row's description is rebuilt
--- whenever the stock or the balance moves, and a balance push is what arrives one
--- frame after a purchase -- which is exactly when a description carrying a round
--- count has to change, and exactly when the player is looking at it.
---
--- ═══ TWO GUARDS, IN THIS ORDER ═══
---
---   UNCHANGED TEXT IS NOT WRITTEN AT ALL. Most rows do not move on most passes,
---   and a write that changes nothing still takes the key. This alone removes the
---   whole hazard from every pass except the one that genuinely changed something.
---
---   AND AFTER A REAL WRITE, THE HIGHLIGHTED ROW RE-ASSERTS ITS OWN. Setting the
---   current item's description to the string it already holds puts the right text
---   back on the shared key, and UIMenu:UpdateDescription is the library's own call
---   for making the movie re-read it. Both are public entry points; nothing here
---   reaches into a vendored private field.
---
--- EVERY CALL IS pcall'd, for the reason the rest of this file gives: these are
--- setters on a vendored object, and losing a description must cost a description
--- rather than the keypress that was building it.
---
--- @param menu table|nil  the UIMenu the item belongs to, or nil while it is down
--- @param item table|nil
--- @param text string|nil
function BR.Menu.describe(menu, item, text)
    if type(item) ~= 'table' then return end
    local want = tostring(text or '')

    -- READ FIRST. `Description()` with no argument is the library's getter --
    -- `if tostring(str) and str ~= nil` falls to the else arm -- so this asks
    -- rather than writes.
    local seen, had = pcall(item.Description, item)
    if seen and tostring(had or '') == want then return end

    pcall(item.Description, item, want)

    -- ONLY WHEN THE MENU IS UP. With it down, Description never touched the
    -- shared key and there is no highlighted row whose text could have been
    -- replaced.
    if type(menu) ~= 'table' then return end
    local vis, up = pcall(menu.Visible, menu)
    if not vis or up ~= true then return end

    -- `cur ~= item` MATTERS. When the row we just wrote IS the highlighted one,
    -- the key already holds the right text and re-asserting it would be a second
    -- redraw for nothing.
    local got, cur = pcall(menu.CurrentItem, menu)
    if got and type(cur) == 'table' and cur ~= item then
        local read, mine = pcall(cur.Description, cur)
        if read then pcall(cur.Description, cur, tostring(mine or '')) end
    end
    pcall(menu.UpdateDescription, menu)
end
