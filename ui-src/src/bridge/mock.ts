/**
 * Browser development harness.
 *
 * The entire UI runs in a normal browser via `npm run dev`, driven by the fake
 * envelopes below. This is the fastest iteration loop on the project and it is
 * worth keeping honest: build screens here, not by restarting a game client.
 *
 * Nothing in this file ships meaningfully -- isBrowser is false in game, so the
 * driver never starts and mockFetch is never imported.
 */

import { dispatch } from './nui'
import type {
  CallbackName, ChatMessage, Envelope, ScreenPayload, WireEnvelope,
} from './types'

let seq = 0

/** Push a fake envelope through the real dispatcher. */
export function emit<E extends Envelope>(env: E): void {
  dispatch({ t: 'br', v: 1, s: ++seq, ...env } as WireEnvelope)
}

/**
 * SYNTHETIC PROGRESSION AND CATALOGUE.
 *
 * Neither system exists server-side yet -- see screens/Progress.tsx and
 * screens/Market.tsx, which say so in full. This is what makes the screens
 * arguable before anybody writes the persistence half: real numbers, real
 * prices, real level costs, all invented here and nowhere else, so deleting
 * this block is the entire act of switching to the real thing.
 */
/**
 * A console origin for the harness, and it is deliberately not reachable.
 *
 * The point of mocking this is the CHROME -- that the tab appears, opens a
 * full-screen page, spins while it asks, shows a failure code and comes back to
 * the pause menu. None of that needs a real console, and pointing the browser at
 * somebody's actual deployment from a dev harness would be a worse default than
 * a frame that fails to load.
 */
const MOCK_CONSOLE = 'https://ringmaster.invalid'

/**
 * A stand-in invite for the harness.
 *
 * NOT THE REAL ONE, AND NOT PLAYER COPY. In game the address comes from
 * `br_discordUrl` and is the operator's; this exists only so the card can be
 * drawn and measured in `npm run dev`, where no Lua is running to send one. It
 * is `.invalid` for the same reason MOCK_CONSOLE above is -- a dev harness that
 * pointed at somebody's actual server is a worse default than one that visibly
 * goes nowhere -- but it is deliberately invite-SHAPED and roughly invite-LENGTH,
 * because the one thing this card's layout can get wrong is how much room the
 * printed address needs beside the reserved "Copied" slot.
 */
const MOCK_INVITE = 'https://discord.invalid/aBcDeFgHiJ'

/** Advances per mocked mint, so the screen sees a fresh answer each time. */
let mockMintSeq = 0

const MOCK_PROGRESS = { level: 14, xp: 2380, needed: 4000 }

const MOCK_MARKET = {
  balance: 7450,
  items: [
    { id: 'ped_juggalo',  name: 'Juggalo',    sub: 'Character',  kind: 'character' as const, price: 1500, rarity: 2 as const },
    { id: 'ped_clown',    name: 'Clown',      sub: 'Character',  kind: 'character' as const, price: 2500, rarity: 3 as const },
    { id: 'ped_trooper',  name: 'Trooper',    sub: 'Character',  kind: 'character' as const, price: 4000, rarity: 4 as const, owned: true },
    { id: 'ped_yeti',     name: 'Yeti',       sub: 'Character',  kind: 'character' as const, price: 9000, rarity: 5 as const },
    { id: 'ped_diver',    name: 'Diver',      sub: 'Character',  kind: 'character' as const, price: 1500, rarity: 2 as const },
    { id: 'ped_agent',    name: 'Agent',      sub: 'Character',  kind: 'character' as const, price: 3000, rarity: 3 as const },
    { id: 'trail_ember',  name: 'Ember',      sub: 'Chute trail', kind: 'trail' as const, price: 800,  rarity: 2 as const },
    { id: 'trail_void',   name: 'Void',       sub: 'Chute trail', kind: 'trail' as const, price: 2000, rarity: 4 as const },
    { id: 'trail_gold',   name: 'Bullion',    sub: 'Chute trail', kind: 'trail' as const, price: 6000, rarity: 5 as const },
    { id: 'ban_storm',    name: 'Stormchaser', sub: 'Banner',    kind: 'banner' as const, price: 1200, rarity: 3 as const },
    { id: 'ban_first',    name: 'Day One',    sub: 'Banner',     kind: 'banner' as const, price: 0,    rarity: 5 as const, owned: true },
    { id: 'vd_royale',    name: 'Victory Royale', sub: 'Verdict', kind: 'verdict' as const, price: 0, rarity: 1 as const, owned: true },
    { id: 'vd_lastone',   name: 'Last One Standing', sub: 'Verdict', kind: 'verdict' as const, price: 3500, rarity: 4 as const },
  ],
}

/** Mirrors br_lib/config/peds.lua closely enough to lay the screen out. */
const MOCK_PEDS = [
  { id: 'streetguy', name: 'Street' }, { id: 'streetgirl', name: 'Downtown' },
  { id: 'hiker', name: 'Hiker' },      { id: 'runner', name: 'Runner' },
  { id: 'biker', name: 'Biker' },      { id: 'mechanic', name: 'Mechanic' },
  { id: 'pilot', name: 'Pilot' },      { id: 'diver', name: 'Diver' },
  { id: 'trooper', name: 'Trooper' },  { id: 'agent', name: 'Agent' },
  { id: 'chef', name: 'Chef' },        { id: 'clown', name: 'Clown' },
  { id: 'juggalo', name: 'Juggalo' },  { id: 'surfer', name: 'Surfer' },
  { id: 'exec', name: 'Executive' },   { id: 'yeti', name: 'Yeti' },
]

/** Stand-in for Lua callbacks while running in a browser. */
export async function mockFetch<Res>(name: CallbackName, data?: unknown): Promise<Res> {
  // eslint-disable-next-line no-console
  console.info('[mock] fetchNui', name, data)

  if (name === 'br/chat/send') {
    const d = data as { channel: ChatMessage['channel']; text: string }
    emit({
      k: 'chat',
      d: {
        channel: d.channel,
        from: 1,
        name: 'You',
        text: d.text,
        at: Date.now(),
      },
    })
  }

  // FOCUS IS LUA'S, so the harness has to play Lua. Settings is rendered off
  // `focus === 'settings'` rather than off a local flag, which means without
  // this the browser's Settings button would open nothing at all -- and the
  // difference between "the button is broken" and "the mock does not answer"
  // is not visible from the screen.
  const FOCUS_CB: Record<string, 'settings' | 'locker' | 'market' | 'pause' | 'admin'> = {
    'br/settings/focus': 'settings',
    'br/locker/focus': 'locker',
    'br/market/focus': 'market',
    'br/pause/focus': 'pause',
    'br/admin/focus': 'admin',
  }
  if (FOCUS_CB[name]) {
    const open = (data as { open?: boolean } | undefined)?.open === true
    // CLOSING ADMIN GOES BACK TO THE PAUSE MENU, not to the lobby, because that
    // is what Lua does: br_ui/client/pause.lua re-opens the menu before it pops
    // `admin`, so the admin lands back where they pressed the tab. A harness
    // that dropped them on the lobby instead would make the Back button look
    // like it did the wrong thing in the browser and the right thing in game,
    // which is worse than not mocking it at all.
    // ESCAPE TAKES EVERYTHING DOWN, and Lua agrees: ADMIN_FOCUS with `all`
    // pops 'admin' and then closes the pause menu outright. Mocked here
    // because a harness where Escape landed on the pause menu would make the
    // browser and the game disagree about the one key this screen rebinds.
    const all = (data as { all?: boolean } | undefined)?.all === true
    const back = name === 'br/admin/focus' ? (all ? 'lobby' : 'pause') : 'lobby'
    emit({ k: 'focus', d: { screen: open ? FOCUS_CB[name]! : back } })
    return { ok: true } as Res
  }

  // THE MINT. Answers the way the game server does -- asynchronously, on the
  // `admin` envelope -- so the indicator, the seq handling and the failure
  // branch are all reachable in a browser.
  //
  // IT ANSWERS WITH A FAILURE, DELIBERATELY. There is no console to mint
  // against here, and a fake success would point the frame at a URL that does
  // not exist -- a blank white rectangle, which is the one outcome that looks
  // identical to every real bug this screen can have. A named code is honest
  // and it is the branch worth being able to look at.
  if (name === 'br/admin/mint') {
    mockMintSeq += 1
    const seq = mockMintSeq
    window.setTimeout(() => {
      emit({ k: 'admin', d: { origin: MOCK_CONSOLE, mint: { seq, error: 'store' } } })
    }, 900)
    return { ok: true } as Res
  }

  // Picking a character has no ped to swap in a browser, so the harness does
  // the one part it CAN: echo the new roster. Without it the selection never
  // moves and the list looks like it is ignoring clicks -- which is exactly
  // the bug this screen would have if the Lua push were forgotten.
  if (name === 'br/locker/pick') {
    const id = String((data as { id?: string } | undefined)?.id ?? '')
    emit({ k: 'locker', d: { peds: MOCK_PEDS, chosen: id } })
    return { ok: true } as Res
  }

  // SETTINGS ECHO. Lua clamps and returns what it actually stored, and the
  // screen renders the echo rather than its own draft -- so a mock that
  // returns nothing would make the browser harness behave differently from
  // the game in exactly the place the design is subtle. The clamps here
  // mirror br_ui/client/settings.lua.
  if (name === 'br/settings/save') {
    const d = (data ?? {}) as Record<string, unknown>

    // A REFUSAL IS PART OF THE CONTRACT, so the harness has to be able to
    // produce one. The real rule is BR.ValidateName in br_lib -- shared by
    // the client and the server, and unit tested there. This is a stub of it
    // that exists only so the screen's error state is reachable in a browser;
    // it is deliberately crude, because duplicating the real list here would
    // create a second one to keep in step.
    const tag = String(d.gamertag ?? '').trim()
    const folded = tag.toLowerCase().replace(/[^a-z]/g, '')
    if (tag.length > 0 && tag.length < 3) {
      return { ok: false, field: 'gamertag', reason: 'Too short — 3 characters minimum.' } as Res
    }
    if (/fuck|shit|poop|admin/.test(folded)) {
      return { ok: false, field: 'gamertag', reason: 'That name is not available.' } as Res
    }

    const num = (k: string, lo: number, hi: number, dflt: number) => {
      const v = Number(d[k])
      return Number.isFinite(v) ? Math.max(lo, Math.min(hi, v)) : dflt
    }
    return {
      ok: true,
      settings: {
        uiScale: num('uiScale', 0.8, 1.3, 1),
        textScale: num('textScale', 0.9, 1.15, 1),
        colourblind: ['off', 'deuter', 'protan', 'tritan']
          .includes(String(d.colourblind)) ? d.colourblind : 'off',
        volUi: num('volUi', 0, 1, 0.7),
        volMusic: num('volMusic', 0, 1, 0.5),
        gamertag: String(d.gamertag ?? '').trim().slice(0, 20),
      },
    } as Res
  }

  return {} as Res
}

const NAMES = ['Kestrel', 'Vandal', 'Nyx', 'Rook', 'Ember', 'Halcyon', 'Wraith']

/** Seed a plausible mid-match state and keep it moving. */
/* ═══════════════════════════════════════════════════════════════════════════
   THE FAKE SCREEN

   This used to be one frozen envelope: `aspect: 16/9`, `mapW: 20.8`,
   `safeX: 2.2, safeY: 3.2`. Every number in it was wrong in a way that mattered
   (#231):

     - the aspect never moved, so the harness could not reproduce an ultrawide
       at all -- which is most of why an ultrawide bug reached a player;
     - mapW was 20.8vw when Lua sends 14.06vw on the very 16:9 screen this was
       claiming to be, so the minimap outline in the dev build was a third of a
       screen too wide and the bars were laid out against a map that does not
       exist anywhere;
     - safeX and safeY were different numbers while Lua published one inset for
       both, so the harness disagreed with the game on the one axis the old Lua
       was actually right about.

   A harness that lies is worse than no harness, because work gets signed off
   against it. So this DERIVES the payload the same way br_core/client/screen.lua
   does, from the window you are actually looking at, and re-sends it whenever
   that window changes shape -- drag the browser wide and the HUD relays out as
   it would on the corresponding monitor.

   ═══ WHAT IS A MODEL AND WHAT IS NOT ═══

   The radar rectangle and the per-edge safe zone are computed exactly as Lua
   computes them, from the same two constants. Those are not a model.

   The safe zone's own SHAPE is a model, and IT WAS THE WRONG ONE -- which is
   how a round got signed off here and shipped broken.

   In game Lua asks the engine where each corner landed (SetScriptGfxAlign +
   GetScriptGfxPosition); there is no engine here to ask. The previous version
   modelled that as the safe zone ALREADY being inset into the centred 16:9 box
   -- and under that model `mapLeft = safeL` is correct, every surface lined up
   on one left edge in the browser, and it went out. On the owner's real 32:9
   the minimap sat near the middle with the health bars hard against the
   panel's left edge and the inventory hard against the right, which is what a
   16:9-derived safe zone with no superwide offset in it looks like.

   THE ENGINE ARITHMETIC IS KNOWN, so this no longer has to guess at it.
   CHudTools::GetMinSafeZone (source/frontend/HudTools.cpp) builds the safe
   zone as `(1 - safeZoneSize) / 2` of EACH axis -- the same percentage, not
   the same physical distance, which is what this file used to have wrong on
   the horizontal -- and then, for script callers only, adds
   `(1 - (16/9) / aspect) * 0.5` to the left edge and subtracts it from the
   right whenever `aspect > 16/9`. That offset is reproduced below, exactly,
   and it is the whole of the difference between the two rectangles.

   WHAT IS STILL A MODEL: whether the reading Lua gets carries that offset.
   The gfx-align path should (it goes through the same function with the script
   flag set); the GetSafeZoneSize fallback provably cannot, because that native
   is the pause-menu slider and nothing else. `?safezone=viewport` (default)
   models the second, `?safezone=box` the first, and screen.lua's intoBox()
   handles either -- so both are worth being able to look at. The authority is
   still the machine: `/brprobe` prints the engine's real rectangle beside the
   offset, and a paste of that from an ultrawide beats anything here.
   ═══════════════════════════════════════════════════════════════════════════ */

/** The aspect past which the engine stops widening its layout box. */
const REF_ASPECT = 16 / 9

/** The radar's map area, as fractions of screen HEIGHT -- the same two numbers
 *  br_core/client/screen.lua carries, from glitchdetector/fivem-minimap-anchor.
 *  Duplicated here and nowhere else: this file is the stand-in for that one. */
const RADAR_W_FRAC = 0.25
const RADAR_H_FRAC = 1 / 5.674

/** Shapes a `?screen=` preset can force when the window cannot be dragged that
 *  wide -- a laptop panel, or a second monitor that is not there. */
const SCREEN_PRESETS: Record<string, [number, number]> = {
  '16x9':  [1920, 1080],
  '16x10': [1920, 1200],
  '21x9':  [2560, 1080],
  '32x9':  [3840, 1080],
}

/** GetSafeZoneSize, as the engine reports it: roughly 0.8..1.0, where 1.0 is
 *  the TOP of the player's slider and leaves no margin at all. The default is
 *  the value index.css has always assumed for its fallbacks -- a 3.2%-of-height
 *  inset -- so the harness and the stylesheet start out agreeing. */
let mockSafe = 0.936

/** null = follow the window, which is the default and the honest one. */
let mockPreset: [number, number] | null = null

/** Which of the two readings of #2719 to model -- see the block above.
 *  `viewport` is the one the owner's 32:9 screenshot corroborates. */
let mockSafeZone: 'viewport' | 'box' = 'viewport'

function mockScreenPayload(): ScreenPayload {
  const [w, h] = mockPreset ?? [window.innerWidth, window.innerHeight]
  const aspect = h > 0 ? w / h : REF_ASPECT

  // The base safe zone: `(1 - safeZoneSize) / 2`, the SAME PERCENTAGE of each
  // axis. Not the same physical distance -- GetMinSafeZone divides the x offset
  // by width and the y offset by height, so on 16:9 all four edges are one
  // number and the previous version's 1.8%-of-width horizontal was wrong.
  const inset = Math.max(0, (1 - mockSafe) * 0.5) * 100

  // The engine's superwide offset, verbatim from GetMinSafeZone: applied to the
  // left and right edges only, and only past 16:9.
  const pillar = aspect > REF_ASPECT ? ((1 - REF_ASPECT / aspect) / 2) * 100 : 0

  // ...and whether the reading Lua gets already carries it. `box` is the
  // gfx-align path (script flag set, offset applied); `viewport` is the
  // GetSafeZoneSize fallback, which cannot carry it. See the block above.
  const safeL = mockSafeZone === 'box' ? inset + pillar : inset
  const safeR = safeL
  const safeT = inset
  const safeB = inset

  // The HUD's frame, derived the way br_core/client/screen.lua derives it --
  // including the "is the offset already in this number?" test, so the harness
  // exercises the branch rather than assuming one side of it.
  const hudL = safeL >= pillar ? safeL : pillar + safeL
  const hudR = safeR >= pillar ? safeR : pillar + safeR

  return {
    width: w,
    height: h,
    // safeX/safeY are the LEFT and TOP edges under their old names.
    safeX: safeL,
    safeY: safeT,
    safeL,
    safeT,
    safeR,
    safeB,
    hudL,
    hudR,
    // The radar hangs off the LAYOUT BOX's bottom-left corner -- its left is
    // the frame's, its bottom is the safe zone's, because only the horizontal
    // axis is stretched by a wide panel. Its width is a fraction of HEIGHT
    // turned into a fraction of WIDTH by the aspect.
    mapLeft: hudL,
    mapBottom: safeB,
    mapW: (RADAR_W_FRAC / aspect) * 100,
    mapH: RADAR_H_FRAC * 100,
    radarOn: true,
  }
}

/**
 * Publish the fake screen, and keep publishing it.
 *
 * DRIVEN FROM THE URL AND FROM THE CONSOLE, because the two things worth
 * reproducing are both settings a player owns and neither is reachable from the
 * page itself:
 *
 *   ?screen=32x9        force a shape the window cannot be dragged to
 *   ?safe=1.0           the safe-zone slider at its maximum, which is where the
 *                       health/shield strip runs off the bottom of the screen
 *   ?safezone=box       model the safe zone as being INSIDE the engine's 16:9
 *                       layout box instead of on the panel's edges. The other
 *                       reading of fivem#2719, and the one the previous round
 *                       assumed -- keep it reachable, because a `/brprobe`
 *                       paste is what decides between them and the HUD has to
 *                       be right under either.
 *   brScreen('21x9', 0.98)      both, live, from the F12 console
 *   brScreen('window')          back to following the window
 *   brSafeZone('box' | 'viewport')  switch the reading live
 *
 * The live form is the one that matters for #231's "re-evaluated, not decided
 * once" -- calling it repeatedly is a player dragging the slider mid-match, and
 * the strip has to change places under it without a reload.
 */
function startMockScreen(): void {
  const params = new URLSearchParams(window.location.search)

  const preset = params.get('screen')
  if (preset && SCREEN_PRESETS[preset]) mockPreset = SCREEN_PRESETS[preset]

  const safe = Number(params.get('safe'))
  if (Number.isFinite(safe) && safe > 0) mockSafe = Math.min(1, Math.max(0.5, safe))

  const zone = params.get('safezone')
  if (zone === 'box' || zone === 'viewport') mockSafeZone = zone

  const push = () => emit({ k: 'screen', d: mockScreenPayload() })

  push()
  // Only meaningful while following the window, but harmless otherwise and one
  // fewer branch to get wrong.
  window.addEventListener('resize', push)

  Object.assign(window, {
    brScreen(shape?: string, safeSize?: number) {
      if (shape === 'window') mockPreset = null
      else if (shape && SCREEN_PRESETS[shape]) mockPreset = SCREEN_PRESETS[shape]
      if (Number.isFinite(safeSize) && (safeSize as number) > 0) {
        mockSafe = Math.min(1, Math.max(0.5, safeSize as number))
      }
      push()
      // eslint-disable-next-line no-console
      console.info('[mock] screen', mockScreenPayload(), 'safeZoneSize', mockSafe,
        'safeZone', mockSafeZone,
        'shapes:', Object.keys(SCREEN_PRESETS).join(' '), 'window')
    },
    brSafeZone(which?: string) {
      if (which === 'box' || which === 'viewport') mockSafeZone = which
      push()
      // eslint-disable-next-line no-console
      console.info('[mock] safeZone', mockSafeZone, mockScreenPayload())
    },
  })
}

export function startMockDriver(): void {
  const now = Date.now()

  // Lua pushes this on br:ui:ready, and the lobby hides its Character button
  // until it arrives -- so a harness that never sends it is a harness where
  // the locker cannot be opened at all.
  emit({ k: 'locker', d: { peds: MOCK_PEDS, chosen: 'streetguy' } })
  emit({ k: 'progress', d: MOCK_PROGRESS })
  // THE HARNESS IS ALWAYS AN ADMIN, which is the opposite of the in-game
  // default and is right here: the browser is where the screen gets built, and
  // a tab you cannot make appear is a screen you cannot work on. In game this
  // envelope arrives only for a license the server has cleared.
  emit({ k: 'admin', d: { origin: MOCK_CONSOLE } })
  // AND THE HARNESS ALWAYS HAS A DISCORD, for the same reason it is always an
  // admin: in game this arrives on br:ready from br_core/server/community.lua,
  // and a harness that never sent it is a harness where the card cannot be
  // built, positioned or measured at all. An unconfigured server sends `{}`
  // instead and the card is simply absent.
  emit({ k: 'community', d: { invite: MOCK_INVITE } })
  // Mirrors br_ui/client/keybinds.lua's ACTIONS table. Without it the
  // controls tab renders its empty state, which is a different screen from
  // the one that ships.
  emit({
    k: 'keybinds',
    d: {
      actions: [
        { group: 'Movement', command: 'brdeploy', label: 'Jump / deploy glider', key: 'Space', default: 'SPACE' },
        // The market's Trails tab names this row -- it is the key the descent
        // prompt offers once the glider is open -- so a harness without it
        // renders that help text one sentence short.
        { group: 'Movement', command: 'brtrail', label: 'Toggle smoke trail', key: 'B', default: 'B' },
        { group: 'Combat', command: 'brinventory', label: 'Inventory', key: 'TAB', default: 'TAB' },
        { group: 'Combat', command: 'brslot1', label: 'Slot 1', key: '1', default: '1' },
        { group: 'Combat', command: 'brslot2', label: 'Slot 2', key: '2', default: '2' },
        { group: 'World', command: 'brinteract', label: 'Interact / loot', key: 'E', default: 'E', custom: true },
        // `brping` on Z, NOT `brmarker` on B. The wrong name was hand-typed
        // here from the same bad list that had bindings written against
        // commands nobody registered (keybinds.lua tells that story in full),
        // and it stayed harmless only until something real wanted B: the
        // harness then drew two rows on one key and looked like a conflict
        // this project does not have.
        { group: 'World', command: 'brping', label: 'Place a marker', key: 'Z', default: 'Z' },
        // THE SPECTATE ARROWS, which the bottom-centre hint reads BY COMMAND
        // NAME. Without these two rows that hint draws a dash for both keys --
        // a real state (a player can rebind something else onto an arrow and
        // leave this one unbound) but not the one being reviewed, and the
        // difference is invisible unless the harness can show both.
        { group: 'Map', command: 'brspecnext', label: 'Spectate next player', key: 'Right', default: 'RIGHT' },
        { group: 'Map', command: 'brspecprev', label: 'Spectate previous player', key: 'Left', default: 'LEFT' },
        { group: 'Social', command: 'brchat', label: 'Chat', key: 'T', default: 'T' },
        // PUSH TO TALK, which is the row #209 was reported against: the
        // once-a-session voice notice and the settings detail both name it,
        // and both now do so with a `{key:brptt}` token that ui/KeyCap.tsx
        // resolves through THIS list. Without the row the harness draws the
        // unbound dash for a key the game has bound by default, which is a
        // real state but not the one being reviewed.
        { group: 'Comms', command: 'brptt', label: 'Push to talk', key: 'N', default: 'N' },
        { group: 'Interface', command: 'brpausemenu', label: 'Pause menu', key: 'Escape', default: 'F1' },
        { group: 'Interface', command: 'brleave', label: 'Leave the match', key: '', default: '' },
      ],
    },
  })
  emit({ k: 'market', d: MOCK_MARKET })

  emit({
    k: 'snapshot',
    d: {
      match: { state: 'playing', mode: 'squad', endsAt: now + 95_000, serverNow: now },
      hud: { hp: 82, armour: 45, alive: 23, squadsAlive: 8, kills: 3, state: 'alive' },
      squad: {
        id: 'sq_1',
        // `you` IS NOT DECORATION HERE ANY MORE. The squad panel's voice mark
        // draws the "no voice at all" glyph on the VIEWER'S OWN ROW and on no
        // other, so a harness that omitted this would render a panel with that
        // half of the feature permanently invisible -- which is how the mark
        // would end up reviewed only in the source.
        you: 1,
        // `level` IS SQUAD-ONLY AND IT SPANS THE DIGIT WIDTHS ON PURPOSE.
        // 7, 42 and 100 are one, two and three figures, which is the whole
        // range the row has to hold without the name's truncation moving --
        // a harness where every mate was level 12 would never show that.
        //
        // AND ONE MATE HAS NO LEVEL AT ALL. `Nyx` omits the field, because
        // "the profile has not come back from the database yet" is a real
        // state the panel has a rule for -- it draws nothing -- and a mock
        // that always sent a number would leave that rule reviewable only in
        // the source. Same argument as `you` and `bleedEndsAt` below.
        members: [
          { src: 1, name: 'You',     state: 'alive', hp: 82,  armour: 45, colour: '#6EE7F9', level: 42 },
          { src: 2, name: 'Kestrel', state: 'alive', hp: 100, armour: 80, colour: '#2DD4BF', level: 100 },
          // `bleedEndsAt` rides along on the downed mate, because the squad
          // panel's timer is unbuildable without it and the harness is where
          // it gets built. It is a SERVER timestamp everywhere else, and
          // `serverNow` above is `now`, so `now + n` is the honest shape here.
          { src: 3, name: 'Vandal',  state: 'dbno',  hp: 12,  armour: 0,  colour: '#FBBF24',
            bleedEndsAt: now + 40_000, level: 7 },
          // NYX IS OUT AND HER KEY IS HELD, which is the state the owner
          // reported blind on 2026-08-30 ("no way to know I still have their
          // key"). The re-push below alternates it with `false` -- a key that
          // exists and has not been fetched -- because the panel draws two
          // different marks and a harness that only ever sent one would leave
          // the other reviewable in the source. Same argument as `level`.
          { src: 4, name: 'Nyx',     state: 'dead',  hp: 0,   armour: 0,  colour: '#F472B6',
            reviveKey: true },
        ],
      },
      inv: {
        // `false` rather than null in the empty slot, and `pool` on the
        // weapons: this mirrors what Lua actually puts on the wire, so the
        // store's normalisation is exercised in the browser rather than only
        // in the game (an earlier mock that sent the already-clean shape is
        // exactly how a boundary bug reaches production).
        slots: [
          { id: 'carbinerifle', label: 'Carbine Rifle', kind: 'weapon', rarity: 3, count: 1, clip: 24, pool: 'medium' },
          { id: 'pumpshotgun',  label: 'Pump Shotgun',  kind: 'weapon', rarity: 2, count: 1, clip: 6, pool: 'shells' },
          { id: 'heavysniper',  label: 'Heavy Sniper',  kind: 'weapon', rarity: 5, count: 1, clip: 4, pool: 'heavy' },
          { id: 'shield',       label: 'Shield Potion', kind: 'consumable', rarity: 3, count: 2 },
          false,
        ],
        ammo: { light: 84, smg: 0, medium: 172, shells: 22, heavy: 9 },
        active: 1,
        using: null,
      },
      storm: {
        phase: 4, phaseState: 'shrinking', endsAt: now + 42_000,
        radius: 520, edgeDistance: -180, bearing: 214, dps: 8,
      },
      chat: [
        { channel: 'system', from: 0, name: 'System', text: 'Storm closing in 30s', at: now - 30_000 },
        { channel: 'global', from: 7, name: 'Halcyon', text: 'gg that drop was rough', at: now - 20_000 },
        { channel: 'squad',  from: 2, name: 'Kestrel', text: 'rotating north, need meds', at: now - 8_000 },
      ],
    },
  })

  // Screen metrics, DERIVED FROM THE WINDOW rather than frozen at 16:9.
  // Re-sent whenever the window changes shape, so dragging the browser wide
  // reproduces an ultrawide -- see mockScreen below.
  startMockScreen()

  // Vitals drift, so the bars and their transitions can be seen working.
  let hp = 82, armour = 45, kills = 3, alive = 23
  window.setInterval(() => {
    hp = Math.max(6, Math.min(100, hp + (Math.random() * 18 - 9)))
    armour = Math.max(0, Math.min(100, armour + (Math.random() * 14 - 8)))
    if (Math.random() < 0.12) { alive = Math.max(1, alive - 1) }
    if (Math.random() < 0.05) { kills += 1 }
    emit({ k: 'hud', d: { hp, armour, alive, squadsAlive: Math.ceil(alive / 3), kills, state: 'alive' } })
  }, 900)

  // THE SQUAD RE-PUSH, at the SLOW rate br_core/client/state.lua drives
  // pushSquadOrParty at. Two things only this can exercise: a downed mate's
  // bleed deadline actually counting down (and re-arming, so the panel is not
  // stuck on 0s for the rest of the session), and the panel surviving a
  // payload landing on it several times a second without flickering.
  let knockAt = now
  window.setInterval(() => {
    const t = Date.now()
    // Re-knock once the last bleed has run out, so the countdown loops.
    if (t > knockAt + 40_000) knockAt = t
    // NYX'S KEY FLIPS BETWEEN THE TWO MARKS, on a cycle slow enough to read.
    // `false` is a key that exists and the squad has not fetched, `true` is one
    // they hold; they are drawn in different colours and the fade on the plate
    // is the same either way, all of which is only reviewable if both arrive.
    const held = Math.floor(t / 8_000) % 2 === 1
    emit({
      k: 'squad',
      d: {
        id: 'sq_1',
        you: 1,
        // THE LEVELS REPEAT HERE, and they have to. This push lands once a
        // second and REPLACES the snapshot's member list, so a re-push that
        // dropped the field would blank every level a second into the session
        // -- which is both wrong and the exact flicker the panel is supposed
        // to be proof against. Nyx stays level-less on both, for the same
        // reason she is level-less above.
        members: [
          { src: 1, name: 'You',     state: 'alive', hp: Math.round(hp), armour: Math.round(armour), colour: '#6EE7F9', level: 42 },
          { src: 2, name: 'Kestrel', state: 'alive', hp: 100, armour: 80, colour: '#2DD4BF', level: 100 },
          { src: 3, name: 'Vandal',  state: 'dbno',  hp: 12,  armour: 0,  colour: '#FBBF24',
            bleedEndsAt: knockAt + 40_000, level: 7 },
          { src: 4, name: 'Nyx',     state: 'dead',  hp: 0,   armour: 0,  colour: '#F472B6',
            reviveKey: held },
        ],
      },
    })
  }, 1000)

  // WHO IS SPEAKING. Nothing drove this channel before, so TalkingBar rendered
  // nothing at all in the harness -- which is how a bottom-centre element ends
  // up being reviewed only in the source. Names AND ids, because the squad
  // panel's dots read the ids and the bar reads the names.
  const VOICE = [
    { talking: [2], names: ['Kestrel'] },
    { talking: [2, 4], names: ['Kestrel', 'Nyx'] },
    { talking: [], names: [] },
    // A CROWD, because proximity voice carries anyone in the match and the
    // 46% cap is only ever exercised by a line long enough to hit it.
    { talking: [4, 2, 3, 9, 11, 12, 13],
      names: ['Nyx', 'Kestrel', 'Vandal', 'Halcyon', 'Rook', 'Marrow', 'Quillon'] },
    // AND THE TWO STATES THAT ARE WHY VoiceNotice EXISTS. Both were invisible
    // in the game and both read as "voice is broken" (#157). They are in the
    // rotation rather than behind a flag because a component that renders
    // nothing 95% of the time is a component nobody sees in the harness --
    // which is how the bottom-centre bar itself went unreviewed.
    { talking: [], names: [],
      mode: 'squad' as const, radio: null, joined: 0, mates: 0,
      status: 'nosquad', silent: true, chosen: false,
      headline: 'Squad voice: you have no squad',
      detail: 'Squad voice carries your squad and nobody else, so with no '
            + 'squad it carries nobody -- you cannot hear anyone and nobody '
            + 'can hear you. Solo matches have no squads. Switch to Nearby '
            + 'under Settings, Voice to hear the players around you.' },
    // A CHOSEN SILENCE, WHICH IS WHAT A SPECTATOR IS ON. BR.Voice.mode()
    // answers 'off' for the length of a spectate session, so this is also the
    // envelope a dead player watching their squad gets -- and it is the one
    // that puts the squad panel's "no voice" glyph on the viewer's own row.
    // NO HEADLINE, deliberately: 'off' has sent none since 2026-08-20 and the
    // spectate rule sends none either, so a mock that carried one here would
    // draw a bottom-centre line the game does not.
    { talking: [], names: [],
      mode: 'off' as const, radio: 30703, joined: 0, mates: 3,
      status: 'silenced', silent: true, chosen: true,
      detail: 'You are not transmitting and not listening. Change it under '
            + 'Settings, Voice.' },
    // AND THE ROW THAT WAS 'alone'. It used to carry "Squad voice: nobody else
    // on your squad radio yet" and no longer carries anything at all (owner,
    // 2026-08-22) -- the squad panel says who is on the radio. It is kept in
    // the rotation precisely because it now draws NOTHING: a row whose whole
    // content is an absence is one a harness has to be able to show.
    { talking: [], names: [],
      mode: 'squad' as const, radio: 30703, joined: 30703, mates: 0,
      status: 'alone', silent: false, chosen: false,
      // THE KEY IS A TOKEN, NOT AN N. Lua composes these two `detail` strings
      // with BR.KeyToken (br_core/client/voice.lua) so the settings screen can
      // draw the binding as a plate rather than a letter of prose -- #209. A
      // harness that kept the letter would render the one thing that issue was
      // about and look correct doing it.
      detail: 'You are on squad radio 30703 and you are the only one on it. '
            + 'Hold {key:brptt} to speak once a squadmate joins.' },
    // THE WORKING ROW CARRIES NO HEADLINE, and that is the shape being
    // mocked rather than an omission -- VoiceNotice draws any headline it is
    // given, so a working mode that sent one would sit across the bottom of
    // the screen all match. Lua stopped sending it (BR.Voice.statusFor); this
    // mock has to agree or the harness renders a line the game does not.
    { talking: [4], names: ['Nyx'],
      mode: 'squad' as const, radio: 30703, joined: 30703, mates: 3,
      status: 'radio', silent: false, chosen: false,
      detail: 'Squad voice is a radio: it reaches your squad at any distance '
            + 'and nobody else, however close they are. Hold {key:brptt} to '
            + "talk. The key is this game's -- rebind it in Settings, "
            + 'Controls, under Comms.' },
  ]
  let voiceAt = 0
  window.setInterval(() => {
    emit({ k: 'voice', d: VOICE[voiceAt++ % VOICE.length]! })
  }, 4000)

  // SPECTATING, ON A SLOW ROTATION. Same argument the voice rows above make:
  // the hint renders nothing unless a session is running, so without a driver
  // for this channel a bottom-centre element could only be reviewed by reading
  // it -- and its whole specification is about WHERE it sits relative to two
  // other bottom-centre surfaces.
  //
  // THE TARGET CHANGES so the name is visibly the server's rather than a
  // constant, and the off state is in the rotation so the stack can be seen
  // collapsing back to just the talking line.
  const SPECTATE = [
    { active: false, admin: false },
    { active: true, admin: false, name: 'Kestrel' },
    { active: true, admin: false, name: 'Vandal' },
    // An admin session, which draws identically -- `admin` only decides
    // whether the pause menu offers the exit.
    { active: true, admin: true, name: 'Quillon' },
  ]
  let specAt = 0
  window.setInterval(() => {
    emit({ k: 'spectate', d: SPECTATE[specAt++ % SPECTATE.length]! })
  }, 6000)

  // YOUR OWN DEATH, THE WORD ONLY. Lua owns the ~10s window in the real thing;
  // here it is driven on a shorter cycle so the surface can be looked at.
  //
  // THE CAUSES ARE ROTATED because the word is chosen from them, and the LONG
  // one is in the list on purpose: 'COOKED BY THE STORM' is what exercises the
  // text-6xl step, and a harness that only ever showed ELIMINATED would review
  // the one case that cannot overflow.
  //
  // The no-cause row is real rather than filler -- the kill feed and the roster
  // delta have no ordering between them, so a death genuinely can be drawn
  // before its cause is known, and WASTED is what the player sees then.
  const DEATHS = [
    { show: false },
    { show: true, byPlayer: true, cause: null },
    { show: false },
    { show: true, byPlayer: false, cause: 'storm' },
    { show: false },
    { show: true, byPlayer: false, cause: null },
  ]
  let deathAt = 0
  window.setInterval(() => {
    emit({ k: 'death', d: DEATHS[deathAt++ % DEATHS.length]! })
  }, 3500)

  // Storm ticks at the same 4 Hz the server would use.
  let radius = 520, edge = -180
  window.setInterval(() => {
    radius = Math.max(40, radius - 1.5)
    edge += Math.random() * 12 - 5
    emit({
      k: 'storm',
      d: {
        phase: 4, phaseState: 'shrinking', endsAt: Date.now() + 42_000,
        radius, edgeDistance: edge, bearing: (Date.now() / 90) % 360, dps: 8,
      },
    })
  }, 250)

  // THE CAR, so the three vehicle bars can be looked at in the dev harness at
  // all. The loop deliberately drains the tank, tops it back up quickly the way
  // a refuel does, and lets condition decay -- both of the animations the bars
  // exist to show, without needing a game.
  let vFuel = 100, vHealth = 92, vFilling = false
  // THE BOOST BAR AT ITS REAL RATES, because it is the only one of the three
  // that moves fast enough for the timing to be part of the look: four seconds
  // to empty and six to refill, at this loop's 250ms cadence. Getting those two
  // numbers wrong in the harness would make the bar read correctly and animate
  // like nothing in the game.
  let vBoost = 100, vBoosting = false
  window.setInterval(() => {
    if (vFilling) {
      vFuel = Math.min(100, vFuel + 2.5)
      vHealth = Math.min(100, vHealth + 2.5)
      if (vFuel >= 100) vFilling = false
    } else {
      vFuel = Math.max(0, vFuel - 0.8)
      vHealth = Math.max(0, vHealth - 0.15)
      if (vFuel <= 0) vFilling = true
    }
    if (vBoosting) {
      vBoost = Math.max(0, vBoost - (100 / 4000) * 250)
      if (vBoost <= 0) vBoosting = false
    } else {
      vBoost = Math.min(100, vBoost + (100 / 6000) * 250)
      if (vBoost >= 100) vBoosting = true
    }
    emit({
      k: 'vehicle',
      d: {
        show: true,
        health: Math.round(vHealth),
        fuel: Math.round(vFuel),
        boost: Math.round(vBoost),
      },
    })
  }, 250)

  // Kill feed and chat traffic.
  let feedId = 0
  window.setInterval(() => {
    const a = NAMES[Math.floor(Math.random() * NAMES.length)]!
    const b = NAMES[Math.floor(Math.random() * NAMES.length)]!
    if (a === b) return
    emit({
      k: 'feed',
      d: {
        id: ++feedId, killer: a, victim: b,
        weapon: 'Carbine Rifle',
        headshot: Math.random() < 0.3,
        mine: Math.random() < 0.2,
      },
    })
  }, 3200)

  window.setInterval(() => {
    const who = NAMES[Math.floor(Math.random() * NAMES.length)]!
    emit({
      k: 'chat',
      d: {
        channel: Math.random() < 0.5 ? 'global' : 'squad',
        from: 9, name: who,
        text: ['pushing east', 'need shields', 'sniper on the ridge', 'nice shot'][
          Math.floor(Math.random() * 4)
        ]!,
        at: Date.now(),
      },
    })
  }, 5000)
}
