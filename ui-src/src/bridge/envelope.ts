/**
 * THE DOOR IN FRONT OF THE NUI DISPATCHER (#281).
 *
 * `window.addEventListener('message')` is not a private channel. Every page
 * this UI embeds can reach it with `parent.postMessage` or `top.postMessage`,
 * and this interface embeds two:
 *
 *   Help.tsx   -- the player manual, `allow-scripts allow-same-origin`
 *   Admin.tsx  -- the Ringmaster console, deliberately NOT sandboxed
 *
 * Until #281 the dispatcher took `ev.data` from any of them. A forged envelope
 * could raise a toast, rewrite match state, or -- the part that actually hurt --
 * carry `s: Number.MAX_SAFE_INTEGER`, which advanced `lastSeq` past anything Lua
 * would ever send and froze every real update for the rest of the session.
 *
 * WHY THIS IS A SEPARATE FILE FROM nui.ts. nui.ts touches `window` at module
 * load and imports values from types.ts, so it cannot be loaded outside a
 * browser. This file imports nothing at runtime -- the one import below is
 * `import type`, which is erased -- which is what lets
 * ui-src/scripts/test-envelope.mjs load it straight into node and drive the
 * SHIPPED decision rather than a copy of it. A guard whose only test is a
 * re-implementation of itself is not tested.
 *
 * ---------------------------------------------------------------------------
 * WHAT THIS DELIBERATELY DOES NOT DO
 * ---------------------------------------------------------------------------
 *
 * NO ALLOW-LIST ON `ev.source` OR `ev.origin`. The obvious fix is
 * `if (ev.source !== window) return`, and IT WOULD KILL THIS INTERFACE STONE
 * DEAD. A resource NUI page is not a top-level document. It is an iframe inside
 * FiveM's own root page, and `SendNUIMessage` reaches it as an ordinary
 * cross-frame post from that parent. The chain, read out of citizenfx/fivem:
 *
 *   ResourceUIScripting.cpp   SEND_NUI_MESSAGE -> nui::PostFrameMessage
 *   CefOverlay.cpp            -> a "pushEvent" process message to the ROOT window
 *   ext/ui-build/data/root.html
 *                             citFrames[frameName]?.contentWindow
 *                                 ?.postMessage(data, '*')
 *
 * So for a genuine envelope `ev.source` is `window.parent`, not `window`, and
 * `ev.origin` is the ROOT page's origin, not ours. Ours is
 * `https://cfx-nui-br_ui` -- br_ui declares `fx_version 'cerulean'`, and
 * ResourceUI.cpp picks the `https://cfx-nui-` prefix from exactly that. The
 * root page's is whatever `ui_rootUrl` resolves to, which defaults to
 * `nui://game/ui/root.html` in NUIInitialize.cpp and is a ConVar, so it is
 * not a constant anybody may hardcode. The same parent also posts
 * `{ type: 'poll' }` at this page, which is why "anything that arrives here is
 * ours" was never true.
 *
 * `ev.source === window.parent` therefore IS the correct allow-list, and it is
 * still not written here, because it has been established from FiveM's source
 * and from how Chromium behaves, and NOT measured on the build this server
 * runs -- two of the three links, and the missing one is the game. Getting it
 * wrong does not
 * produce a bug -- it produces a black interface over a healthy game, with
 * nothing in the console, which is the single worst failure this bridge has.
 * The measurement is one line in a live NUI page:
 *
 *   console.info('nui', ev.source === window.parent, ev.origin)
 *
 * Log that for a real envelope on the target build and the allow-list can
 * replace everything below, which is strictly better: it also refuses a SIBLING
 * resource's frame, and the deny-list cannot, because a sibling is neither our
 * descendant nor us.
 *
 * WHAT IS WRITTEN BELOW IS A DENY-LIST over the frames we ourselves put on the
 * page. It cannot refuse a genuine envelope, because a genuine envelope comes
 * from an ANCESTOR and this only ever refuses DESCENDANTS -- and descendants are
 * the entire reported vector: both of the frames named above are ours.
 *
 * NO PER-KIND PAYLOAD SCHEMAS. The audit asked for them. They were not written
 * because they buy nothing and can fail closed: the attacker who can post an
 * envelope can post a WELL-FORMED one, so a schema stops no forgery, while a
 * schema that disagrees with Lua about one optional field silently drops a real
 * envelope forever. types.ts already states the contract once; a second copy in
 * executable form is a drift hazard pointed at the freeze it is meant to fix.
 *
 * NO KIND ALLOW-LIST, for the same reason and a stronger one: the handler map
 * in nui.ts IS the allow-list. An unknown kind finds no handler and does
 * nothing. A hardcoded list beside it would add exactly one behavior -- a kind
 * added to types.ts and forgotten here would be dropped -- and that behavior is
 * a bug.
 */

import type { WireEnvelope } from './types'

/**
 * As much of a Window as the frame walk needs.
 *
 * Indexed access and `length` are both on the cross-origin-allowed list, so
 * this works against a frame whose document we cannot otherwise touch. Typed
 * structurally rather than as `Window` so the test can hand it a plain object.
 */
export interface FrameHost {
  readonly length: number
  readonly parent?: unknown
  readonly [index: number]: unknown
}

/**
 * Is this window us, or one of the windows we sit inside?
 *
 * NOT AN ALLOW-LIST. Nothing is admitted because of this function; it only ever
 * answers "this is definitely not a page we embedded", which lets the frame walk
 * below stop before it starts. That distinction is the whole safety argument:
 * an allow-list here could refuse a real envelope on a build nobody measured,
 * and this cannot refuse anything at all.
 *
 * It earns its place by making the walk's scan cap safe. A genuine envelope
 * arrives from `window.parent` (see the header), so without this a hostile page
 * that created three hundred iframes could exhaust FRAME_SCAN_MAX on every
 * inbound message and have every REAL envelope refused with it -- the same
 * frozen interface #281 is about, reintroduced by its own fix.
 *
 * A missing or null source counts as not-embedded. A page cannot forge that: a
 * cross-document post always carries the calling window.
 */
export function isSelfOrAncestor(host: FrameHost, source: unknown): boolean {
  if (source === null || source === undefined) return true

  let w: FrameHost = host
  for (let i = 0; i <= FRAME_DEPTH_MAX; i++) {
    if (w === source) return true
    let up: unknown
    // `parent` is readable on a cross-origin window, but this walk leaves the
    // documents we control, so it is read defensively like every other one here.
    try {
      up = w.parent
    } catch {
      return false
    }
    if (up === undefined || up === null || up === w) return false
    w = up as FrameHost
  }
  return false
}

/**
 * How many windows the frame walk will look at before giving up.
 *
 * The real page has one frame, sometimes zero. The cap exists because the walk
 * descends into pages we do not control, and a hostile one could otherwise make
 * every inbound message cost a thousand comparisons.
 *
 * EXHAUSTING IT COUNTS AS A REJECT, and that is only safe because of
 * isSelfOrAncestor above: a genuine envelope comes from `window.parent` and is
 * answered before the walk begins, so nothing Lua sends can be caught by the
 * cap. Without that, a page could build three hundred frames and starve the
 * real interface using this very check.
 */
export const FRAME_SCAN_MAX = 256

/** How deep the walk goes. A frame inside a frame inside a frame is already
 *  further than anything here builds; the depth cap is belt and braces against
 *  a cycle the visited set somehow misses. */
export const FRAME_DEPTH_MAX = 8

/**
 * Did this message come from a page we embedded?
 *
 * DESCENDANTS, NOT JUST CHILDREN. `window.frames` lists direct children only,
 * and the Admin console is unsandboxed -- it can create an iframe of its own and
 * have THAT call `top.postMessage`, whose `ev.source` is a grandchild and would
 * miss a one-level check entirely. The walk is the whole reason this is not
 * three lines.
 *
 * MEASURED, NOT REASONED. Three cases were run in a real Chromium rather than
 * argued from the spec, because every claim in this file is about object
 * identity across frames and being wrong about it is a black screen:
 *
 *   child -> parent        source is in `window.frames`, and in the tree
 *   grandchild -> top      source is NOT in `window.frames`, but IS in the tree
 *   parent -> child        source === window.parent, and NOT === window
 *
 * The middle row is why the walk exists. The last row is why the obvious check
 * is not written above it.
 */
export function isEmbeddedFrame(host: FrameHost, source: unknown): boolean {
  // ANSWERED BEFORE THE WALK, and this is what makes the cap-exhaustion reject
  // above safe to state: the shape a genuine envelope arrives in -- from
  // `window.parent` -- never reaches the loop below and so can never be caught
  // by its cap. A window cannot be both above us and below us.
  if (isSelfOrAncestor(host, source)) return false

  let seen = 0
  const visited = new Set<unknown>([host])
  const queue: Array<{ w: FrameHost; depth: number }> = [{ w: host, depth: 0 }]

  while (queue.length > 0) {
    const { w, depth } = queue.shift()!
    if (depth >= FRAME_DEPTH_MAX) continue

    // `length` on a cross-origin window is readable but not trustworthy, so
    // every read is defensive: a throwing or nonsense value must not take the
    // message listener down with it.
    let n = 0
    try {
      n = typeof w.length === 'number' && w.length > 0 ? w.length : 0
    } catch {
      continue
    }

    for (let i = 0; i < n; i++) {
      if (++seen > FRAME_SCAN_MAX) return true

      let child: unknown
      try {
        child = w[i]
      } catch {
        continue
      }
      if (child === undefined || child === null) continue
      if (child === source) return true
      if (visited.has(child)) continue
      visited.add(child)
      queue.push({ w: child as FrameHost, depth: depth + 1 })
    }
  }

  return false
}

/**
 * The largest sequence number Lua could plausibly reach.
 *
 * `seq` in br_ui/client/nui.lua starts at 1 and rises by one per envelope, per
 * resource start. At fifty envelopes a second -- far above what this UI does --
 * a day-long session reaches four million. Two billion is a thousand times the
 * headroom and still refuses `Number.MAX_SAFE_INTEGER`.
 *
 * THIS IS HYGIENE, NOT THE FIX. A forged `s` of 2147483646 passes it and would
 * still freeze the session; what actually prevents that is the stale run in
 * createSeqGate below. The range check is here to keep `NaN`, `Infinity` and a
 * float out of the comparison, not to stop an attacker.
 */
export const SEQ_MAX = 2 ** 31 - 1

/** Why an envelope was turned away. Reported, never thrown. */
export type Refusal =
  | 'embedded-frame'
  | 'not-an-envelope'
  | 'bad-kind'
  | 'bad-seq'

export type Verdict =
  | { ok: true; env: WireEnvelope }
  | { ok: false; why: Refusal }

/**
 * Decide whether one inbound `message` event may reach the dispatcher.
 *
 * The frame test runs FIRST, before a single field of `data` is read -- the same
 * discipline Admin.tsx's own listener states in its comment. Everything after
 * it is structural: is this the envelope shape Lua sends, and is the sequence
 * number a number Lua could have produced.
 */
export function admit(host: FrameHost, source: unknown, data: unknown): Verdict {
  if (isEmbeddedFrame(host, source)) return { ok: false, why: 'embedded-frame' }

  if (data === null || typeof data !== 'object') return { ok: false, why: 'not-an-envelope' }

  // READ AS AN UNKNOWN RECORD, NOT AS A Partial<WireEnvelope>. The typed view
  // would have TypeScript narrow `k` to the kind union and then refuse to
  // compare it against `''` as a comparison with no overlap -- which is exactly
  // backwards here. Nothing about this value is known yet; that is the point of
  // the function.
  const msg = data as Record<string, unknown>
  if (msg.t !== 'br') return { ok: false, why: 'not-an-envelope' }

  // A kind must be a usable Map key and nothing more. See the header: the
  // handler map is the list of kinds that mean anything, and a second copy of
  // it here would be a way to lose one.
  if (typeof msg.k !== 'string' || msg.k === '') return { ok: false, why: 'bad-kind' }

  // `d` MAY BE ANYTHING, INCLUDING ABSENT. Lua sends `BR.NuiNormalise(data or
  // {})`, which is a table for every caller today, but a payload check that
  // insisted on that would be a per-kind schema by another name.

  // A MISSING `s` IS STILL ALLOWED, and that is not an oversight. The
  // dispatcher has always treated an unsequenced envelope as "deliver it, do
  // not touch the sequence", and tightening that here would change behavior
  // for real envelopes in exchange for nothing: an attacker who wants past the
  // sequence logic simply omits `s` today and is stopped by the frame test
  // above, not by this line. What IS checked is a PRESENT `s` that is not a
  // number Lua could have sent, because that value goes on to poison a
  // comparison that every later envelope depends on.
  if (msg.s !== undefined) {
    if (
      typeof msg.s !== 'number'
      || !Number.isInteger(msg.s)
      || msg.s < 0
      || msg.s > SEQ_MAX
    ) {
      return { ok: false, why: 'bad-seq' }
    }
  }

  return { ok: true, env: msg as WireEnvelope }
}

/**
 * How many envelopes in a row may be refused as stale before the gate concludes
 * its own sequence is wrong and re-seeds.
 *
 * IN NORMAL OPERATION THIS RUN NEVER STARTS, and that is measured rather than
 * assumed. Driven through this module: five hundred envelopes of an ordinary
 * monotonic stream peak at a run of ZERO, and a stream in which every envelope
 * arrives TWICE peaks at ONE, because the duplicate is refused and the next real
 * one clears the run again. Lua's `seq` only rises and NUI delivers in order, so
 * a stale envelope is not something the transport produces.
 *
 * Two things produce one: a forged `s` far in the future from a window the
 * deny-list above does not cover, and Lua's counter going back to 1 without a
 * snapshot behind it. Both present identically -- the interface stops updating
 * and stays stopped -- and both are fixed by noticing that "everything is stale"
 * is not a statement about the messages, it is a statement about us.
 *
 * EIGHT, NOT ONE. One would make the stale check meaningless.
 */
export const STALE_RUN_LIMIT = 8

/**
 * ...and how long that run must have gone on for.
 *
 * ═══ A COUNT ON ITS OWN IS FREE TO PRODUCE ═══
 *
 * Eight postMessages from one `for` loop land in a single task-queue drain,
 * inside a millisecond. So a count alone lets any window that can reach the
 * dispatcher at all decide, for nothing, that the gate is wrong about itself.
 * What the run actually claims is that a CONDITION HAS PERSISTED, and a
 * condition that has persisted has a duration; requiring one is not a second
 * guard bolted on, it is the test finally matching the claim.
 *
 * A QUARTER SECOND: longer than any synchronous flood, shorter than a player
 * notices. The two conditions are a MAXIMUM and not a choice between them, which
 * is what keeps both bounded -- a quiet screen re-seeds when the count lands, a
 * busy one when the clock does, and neither can wait forever.
 */
export const STALE_RUN_MS = 250

export interface SeqGate {
  /** Highest sequence delivered. Readable so the guard test can assert it is
   *  untouched by a message that was turned away. */
  readonly last: number
  /** Consecutive stale refusals. Readable for the same reason. */
  readonly staleRun: number
  /** A snapshot re-seeds everything, so it sets the sequence rather than being
   *  measured against it -- otherwise a resource restart leaves the UI frozen. */
  reseed(s: number | undefined): void
  /** Is this envelope still ahead of what has been delivered? NEVER true for a
   *  sequence at or behind `last`; see the body. */
  fresh(s: number | undefined): boolean
  /** Record a delivery. Called only once the envelope has a listener. */
  commit(s: number | undefined): void
}

/**
 * The high-water mark, and the way out of a wrong one.
 *
 * ═══ THE TWO PROPERTIES, WHICH PULL AGAINST EACH OTHER ═══
 *
 *   1. A STALE ENVELOPE NEVER REACHES A HANDLER.
 *   2. A FORGED OR RESTARTED SEQUENCE NEVER FREEZES THE SESSION.
 *
 * The first shipped version of the re-seed bought (2) by selling (1): after a
 * run of stale refusals it dropped `last` to -1 and RETURNED TRUE FOR THE
 * ENVELOPE THAT TRIPPED THE RUN. That envelope is by definition a stale one, so
 * the recovery rendered an old payload and left the next real envelope to
 * correct it -- an interface that flicks to a wrong number and snaps back, which
 * is the worse half of both failures rather than a compromise between them. It
 * was worse again when the tripping envelope had no handler yet: `commit` never
 * ran, so the gate sat at -1 with no high-water mark at all for the rest of the
 * session.
 *
 * ═══ WHAT SATISFIES BOTH ═══
 *
 * The run is still what detects a wrong `last`. What changed is what it does
 * about it: it ADOPTS THE NEWEST SEQUENCE THE SENDER HAS ACTUALLY BEEN SEEN TO
 * USE, and refuses the envelope that tripped it like every other one in the run.
 * Nothing at or below a sequence already seen can ever render, so (1) holds by
 * construction -- there is exactly one `return true` for a number below, and
 * `s > last` guards it. And the sender's NEXT envelope is above everything in
 * the run, so it lands, which is (2). The freeze costs one envelope more than
 * the old rule did and no wrong frame at all.
 *
 * ═══ WHAT THIS STILL DOES NOT CLOSE, said plainly ═══
 *
 * A window outside the deny-list -- a SIBLING resource's frame, which the header
 * states this file cannot refuse -- can post stale envelopes during a run and
 * drag the adopted sequence wherever it likes. That is not a hole this function
 * can close, and it is not the interesting one: the same window can simply post
 * a high `s` and be committed, which is the freeze itself. The allow-list the
 * header describes is what closes both, and it needs the measurement it names.
 *
 * @param limit  consecutive stale refusals before the gate re-seeds
 * @param minMs  ...and how long that run must have gone on for
 * @param now    the clock, injectable so the suite can drive a run without
 *               sleeping through it. `Date.now` is a global rather than an
 *               import, so this file still has no runtime imports and node can
 *               go on loading it as-is.
 */
export function createSeqGate(
  limit: number = STALE_RUN_LIMIT,
  minMs: number = STALE_RUN_MS,
  now: () => number = Date.now,
): SeqGate {
  let last = -1
  let staleRun = 0
  /** The highest sequence seen among the refusals in the CURRENT run. This is
   *  what a re-seed adopts: it is the closest thing to "where the sender's
   *  counter actually is" that a gate which has never believed the sender has. */
  let staleMax = -1
  /** When this run's first refusal arrived, by `now`. */
  let staleSince = 0

  const clearRun = () => {
    staleRun = 0
    staleMax = -1
    staleSince = 0
  }

  return {
    get last() { return last },
    get staleRun() { return staleRun },

    reseed(s) {
      last = typeof s === 'number' ? s : 0
      clearRun()
    },

    fresh(s) {
      if (typeof s !== 'number') return true

      // THE ONLY WAY A SEQUENCED ENVELOPE IS EVER ADMITTED. Property (1) above
      // is this line and nothing else, which is why the re-seed below is
      // written as an assignment to `last` and not as a second exit.
      if (s > last) {
        clearRun()
        return true
      }

      const at = now()
      if (staleRun === 0) staleSince = at
      staleRun += 1
      if (s > staleMax) staleMax = s

      if (staleRun >= limit && at - staleSince >= minMs) {
        // Long enough, and often enough, that `last` is not a number this
        // sender is going to exceed. Stop measuring against it and measure
        // against the sender instead -- the newest sequence it has been seen
        // to use. Everything in the run stays refused, this one included.
        last = staleMax
        clearRun()
      }

      return false
    },

    commit(s) {
      if (typeof s === 'number' && s > last) last = s
    },
  }
}
