/**
 * THE LAYOUT DRIVER: how check-layout.mjs puts a screen up, run IN the page.
 * Evaluated as one expression; defines `window.__br`. Everything goes through
 * the browser mock's own door -- `brEmit` sends an envelope exactly as Lua
 * would, and a control is pressed with a click -- so a screen is measured in
 * a state the game can reach, not one assembled for the check. The two
 * exceptions are what the page raises for itself and no envelope carries,
 * set through `brStore`: the chat line the in-match walkthrough waits for
 * (`noteChatSent`) and the lobby's decline card.
 */
(() => {
  const norm = (s) => (s || '').replace(/\s+/g, ' ').trim().toLowerCase()
  const shown = (e) => e.getClientRects().length > 0
    && (!e.checkVisibility || e.checkVisibility({ opacityProperty: true, visibilityProperty: true }))
  const now = () => Date.now()

  const SETTINGS = {
    uiScale: 1, textScale: 1, colourblind: 'off', volUi: 0.7, volMusic: 0.5, // wire names: spelling-ok
    voiceModeSolo: 'nearby', voiceModeSquad: 'nearby', gamertag: '',
  }

  const PLAYERS = [
    { src: 2, name: 'Kestrel', inParty: false, queued: false },
    { src: 3, name: 'Vandal', inParty: false, queued: true },
    { src: 4, name: 'Nyx', inParty: true, queued: false },
    { src: 5, name: 'Halcyon', inParty: false, queued: false, leader: true },
    { src: 6, name: 'Rook', inParty: false, queued: false, inMatch: true },
    { src: 7, name: 'Marrow', inParty: false, queued: false, leader: true },
    { src: 8, name: 'Quillon_the_Longest_Name', inParty: false, queued: false },
  ]

  const br = {
    SETTINGS,
    emit(k, d) { window.brEmit({ k, d }) },

    /** The first shown element matching `sel` (and its text, if given). */
    find(sel, text) {
      const all = [...document.querySelectorAll(sel)]
      const hit = text == null ? all : all.filter((e) => norm(e.textContent) === norm(text)
        || norm(e.getAttribute('aria-label')) === norm(text))
      return hit.find(shown) || null
    },

    click(sel, text) {
      const e = br.find(sel, text)
      if (!e) throw new Error(`nothing to press: ${sel}${text != null ? ` "${text}"` : ''}`)
      e.click()
    },

    /** Press the innermost shown element under `within` whose text is `text`. */
    clickText(text, within = 'body') {
      const root = document.querySelector(within)
      const hits = root ? [...root.querySelectorAll('*')].filter((e) => norm(e.textContent) === norm(text) && shown(e)) : []
      const inner = hits.find((e) => !hits.some((o) => o !== e && e.contains(o)))
      if (!inner) throw new Error(`nothing reads "${text}" in ${within}`)
      inner.click()
    },

    /** Has `text` appeared under `within`? */
    has(text, within = 'body') {
      const root = document.querySelector(within)
      return !!root && norm(root.textContent).includes(norm(text))
    },

    key(key) {
      for (const type of ['keydown', 'keyup']) {
        window.dispatchEvent(new KeyboardEvent(type, { key, code: key, bubbles: true, cancelable: true }))
      }
    },

    /** Resolves once `fn()` is truthy; throws after `ms`. */
    async until(fn, ms = 4000, what = 'the screen') {
      const end = now() + ms
      for (;;) {
        let v = null
        try { v = fn() } catch { /* not yet */ }
        if (v) return v
        if (now() > end) throw new Error(`timed out waiting for ${what}`)
        await new Promise((r) => setTimeout(r, 25))
      }
    },

    wait(ms) { return new Promise((r) => setTimeout(r, ms)) },

    /** The lobby, waiting for a match: the screen a player stands on between them. */
    lobby({ mode = 'solo', party = false, players = PLAYERS } = {}) {
      const t = now()
      br.emit('state', { state: 'waiting', mode, endsAt: t + 60000, serverNow: t })
      br.emit('hud', { hp: 100, armour: 0, alive: 0, squadsAlive: 0, kills: 0, state: 'lobby' }) // wire names: spelling-ok
      const members = party
        ? [
          { src: 1, name: 'You', state: 'lobby', hp: 100, armour: 0, colour: '#6EE7F9', leader: true }, // wire names: spelling-ok
          { src: 2, name: 'Kestrel', state: 'lobby', hp: 100, armour: 0, colour: '#2DD4BF' }, // wire names: spelling-ok
          { src: 3, name: 'Vandal', state: 'lobby', hp: 100, armour: 0, colour: '#FBBF24' }, // wire names: spelling-ok
          { src: 4, name: 'Quillon_the_Longest_Name', state: 'lobby', hp: 100, armour: 0, colour: '#F472B6' }, // wire names: spelling-ok
        ]
        : [{ src: 1, name: 'You', state: 'lobby', hp: 100, armour: 0, colour: '#6EE7F9', leader: true }] // wire names: spelling-ok
      const sq = { id: party ? 'p_1' : null, leader: 1, you: 1, members }
      br.emit('squad', sq)
      br.emit('party', sq)
      br.emit('lobby', {
        queued: 3, needed: 8, connected: 12, mode, you: false, players,
        party: party ? { ready: 1, size: 4 } : undefined,
      })
      br.emit('focus', { screen: 'lobby' })
    },

    /** A match in play, this player alive in it (the mock's seed, made explicit). */
    match(over = {}) {
      const t = now()
      br.emit('state', { state: 'playing', mode: 'squad', endsAt: t + 95000, serverNow: t, participant: true })
      br.emit('hud', { hp: 82, armour: 45, alive: 23, squadsAlive: 8, kills: 3, state: 'alive', ...over }) // wire names: spelling-ok
      br.emit('focus', { screen: 'none' })
    },

    /** Locker v2's step through its tabs and modals needs its mock's pushes. */
    async lockerV2() {
      br.lobby()
      br.emit('focus', { screen: 'locker' })
      await br.until(() => document.querySelector('[data-page=locker] [class*="awsui_"]'), 8000, 'Locker v2')
    },

    /** The card on screen now, as text, or '' when none is. */
    card() {
      const c = document.querySelector('.tut-card:not(.tut-card--leaving)')
      return c ? c.textContent : ''
    },

    /** Did the card change (or go) within `ms`? */
    async moved(before, ms) {
      try {
        await br.until(() => br.card() !== before, ms, 'the next card')
        return true
      } catch { return false }
    },

    /**
     * Walk a running walkthrough one card further, as a player would: its
     * Next or Dismiss, or a press of the control its ring is around. For the
     * in-match half, whose cards take no clicks, `advanceGame` does it.
     */
    async advance() {
      const card = document.querySelector('.tut-card:not(.tut-card--leaving)')
      if (!card) return false
      // The in-match half takes no clicks at all.
      if (window.brStore && window.brStore.getState().tutorialGameRun) return br.advanceGame()
      const before = br.card()
      const next = [...card.querySelectorAll('.tut-acts button')].reverse()
        .find((b) => !/^previous$/.test(norm(b.textContent)))
      if (next) {
        next.click()
        return br.moved(before, 3000)
      }
      // The control the ring is drawn around: the anchor whose box it is, 4 px out.
      const ring = document.querySelector('.tut-ring')
      if (!ring) return false
      const rr = ring.getBoundingClientRect()
      const target = [...document.querySelectorAll('[data-tut]')].reverse().find((e) => {
        const r = e.getBoundingClientRect()
        return Math.abs(r.left - (rr.left + 4)) < 2 && Math.abs(r.top - (rr.top + 4)) < 2
          && Math.abs(r.width - (rr.width - 8)) < 2 && r.width > 0
      })
      if (!target) return false
      const press = target.matches('button') ? target : (target.querySelector('button') || target)
      press.click()
      return br.moved(before, 3000)
    },

    /**
     * The in-match half moves on the arrow keys Lua relays, and on what the
     * player does in the world, which Lua counts and sends (br_core's
     * client/tutorial.lua). Each card that waits on the world gets the one
     * thing it waits for, the way Lua would send it; every other card gets
     * the right arrow.
     */
    async advanceGame() {
      const before = br.card()
      const st = window.brStore
      const step = st ? st.getState().tutorialGameStep : null
      br.count = br.count || { crates: 0, waypoints: 0, slots: 0 }
      const world = {
        'game-chat': () => br.emit('focus', { screen: 'chat', channel: 'global' }),
        'game-chat-send': () => { st.setState({ chatSent: (st.getState().chatSent || 0) + 1 }); br.emit('focus', { screen: 'none' }) },
        'game-players': () => br.emit('focus', { screen: 'players' }),
        'game-crates': () => br.emit('tutorial', { run: false, game: true, crates: br.count.crates += 4 }),
        // Two things picked up, which is what the card asks for.
        'game-pickup': () => br.emit('inv', {
          slots: [
            { id: 'carbinerifle', label: 'Carbine Rifle', kind: 'weapon', rarity: 3, count: 1, clip: 24, pool: 'medium' },
            { id: 'pumpshotgun', label: 'Pump Shotgun', kind: 'weapon', rarity: 2, count: 1, clip: 6, pool: 'shells' },
            { id: 'heavysniper', label: 'Heavy Sniper', kind: 'weapon', rarity: 5, count: 1, clip: 4, pool: 'heavy' },
            { id: 'medkit', label: 'Med Kit', kind: 'consumable', rarity: 2, count: 1 },
            { id: 'bandage', label: 'Bandage', kind: 'consumable', rarity: 1, count: 3 },
          ],
          ammo: { light: 84, smg: 0, medium: 172, shells: 22, heavy: 9, lmg: 30 },
          active: 1,
          using: null,
        }),
        'game-inventory': () => br.emit('tutorial', { run: false, game: true, slots: br.count.slots += 1 }),
        'game-invpanel': () => br.emit('focus', { screen: 'inventory' }),
        'game-map': () => br.emit('frontend', { up: true, reason: 'map' }),
        'game-map-waypoint': () => br.emit('tutorial', { run: false, game: true, waypoints: br.count.waypoints += 1 }),
        'game-map-close': () => br.emit('frontend', { up: false }),
      }
      // Over a screen that has the cursor (the player list) the arrows are the
      // page's own keys; over the bare HUD Lua reads them and relays them.
      if (world[step]) world[step]()
      else if (st && st.getState().focus !== 'none') br.key('ArrowRight')
      else {
        br.navSeq = (br.navSeq || 0) + 1
        br.emit('tutorialnav', { dir: 'next', seq: br.navSeq })
      }
      return br.moved(before, 3000)
    },

    /**
     * The next card, landed (its words in). A card that waits for a screen
     * the player is not on yet is put back over the HUD by leaving it, the
     * way the player would. False when the walkthrough is over.
     */
    async nextCard(ms = 5000) {
      const landed = () => document.querySelector('.tut-card:not(.tut-card--leaving) .tut-title.tut-in')
      try {
        await br.until(landed, ms, 'a card')
        return true
      } catch { /* none yet */ }
      const st = window.brStore
      if (st && st.getState().focus !== 'none' && st.getState().tutorialGameRun) {
        br.emit('focus', { screen: 'none' })
        try { await br.until(landed, ms, 'a card'); return true } catch { /* over */ }
      }
      return false
    },
  }

  window.__br = br
})()
