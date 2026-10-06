import { useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactElement } from 'react'
import AppLayout from '@cloudscape-design/components/app-layout'
import Autosuggest from '@cloudscape-design/components/autosuggest'
import BreadcrumbGroup from '@cloudscape-design/components/breadcrumb-group'
import Flashbar, { type FlashbarProps } from '@cloudscape-design/components/flashbar'
import ProgressBar from '@cloudscape-design/components/progress-bar'
import SideNavigation, { type SideNavigationProps } from '@cloudscape-design/components/side-navigation'
import SpaceBetween from '@cloudscape-design/components/space-between'
import TopNavigation, { type TopNavigationProps } from '@cloudscape-design/components/top-navigation'
import {
  connect, reload as askAgain, run, signOut, tellTab,
  type Catalog, type Copy, type RunResult, type TerminalState,
} from './bridge'
import { Browser } from './Browser'
import { FunctionCards } from './FunctionCards'
import { FunctionPage } from './FunctionPage'
import { HowTo } from './HowTo'
import { Login } from './Login'
import { MatchPanel } from './MatchPanel'
import {
  HOME, addressOf, arrive, canBack, canForward, current, fill, hrefOf, loadMs, navigate, progressAfter, rewrite,
  routeOfHref, shownCategories, shownFunctions, speaker, startBrowsing, step, voltsText,
  type Browsing, type NavTarget, type Progress, type Route,
} from './model'
import { loadMode, saveMode, showMode, type UiMode } from './mode'

/**
 * THE TERMINAL APP, "Control Tower": a web page in a web browser (#396, owner,
 * 2026-10-05).
 *
 *   the browser   Browser.tsx: back, forward and reload over THIS app's
 *                 history, and the address of the page it is on -- the same
 *                 look in both modes. Every navigation but back and forward
 *                 LOADS for a random 1-3 s (owner, 2026-10-06; model.ts's
 *                 "page loads"), the window's tab showing it
 *   the top bar   TopNavigation: the app's name (the one place in the app it
 *                 is written), a search across every function (pick one to
 *                 open its page; or search the cards), the player's Volts, the
 *                 light/dark switch, and the player's gamertag as the
 *                 signed-in user (its menu: the how-to, or sign out, which
 *                 closes the computer)
 *   the layout    AppLayout with SideNavigation (Functions, How to, each
 *                 category with something in it) and a BreadcrumbGroup on
 *                 every page but the login screen; a run's progress and its
 *                 answer are Flashbar notifications
 *   the pages     the functions ("Match stats" over FunctionCards), a function
 *                 (FunctionPage), the how-to (HowTo), and the login screen
 *                 (Login) when the computer opened without a Yubikey
 *
 * ═══ NOT ONE WORD IS WRITTEN HERE ═══
 *
 * Every player-facing line is a key into the copy br_core sends with the
 * state, out of the one block in br_lib/config/terminals.lua, read through
 * ONE speaker (model.ts) that picks a line's `_solo` sibling whenever the
 * server says the player is not in a squad match (round 2: "the mention of
 * 'squad' in the terminal should only be mentioned if the player is actively
 * in a squad match"). The function cards and pages are drawn from the
 * registry (the catalog) that rides with it. scripts/check-terminal.mjs fails
 * a word written between two tags, and a component reading the copy without
 * the speaker.
 *
 * ═══ NOTHING HERE DECIDES ═══
 *
 * `available` and `reason` are the server's; Run asks, and the server checks
 * the terminal, the key, the squad, the options and the Volts again. A run
 * the server accepts LOADS for as long as the server says (runMs, 3 to 5
 * seconds, round 2): a bar fills over it, Run stays disabled, and the answer
 * that ends it is the server's -- done, with the new balance when it cost
 * Volts, or why it could not happen.
 *
 * ═══ CEF 103 (#385) ═══
 *
 * No Spinner and no `loading` anywhere: a waiting button is disabled, and a
 * loading run is a determinate ProgressBar that fills over the server's
 * duration and stops (#385's rule is against an indicator that animates
 * forever, repainting the NUI every frame; this one moves ten times a second
 * for at most a few seconds, then is gone). Arrays, not Fragments, go into
 * SpaceBetween (React 19). The mode on <body> (mode.ts). AppLayout and
 * SideNavigation are used inside this iframe, whose opaque page is the
 * browser's page -- not over the game, which is what #385 banned them for --
 * and SideNavigation never collapses (the opt-in that hides icon-less groups
 * only through :has). scripts/check-terminal.mjs holds these.
 */

/** How often a loading run's bar moves: ten times a second, for 3-5 s. */
const PROGRESS_STEP_MS = 100

export function App(): ReactElement {
  const [state, setState] = useState<TerminalState | null>(null)
  const [copy, setCopy] = useState<Copy>({})
  const [catalog, setCatalog] = useState<Catalog>({ functions: [], categories: [], currency: '', pageLoad: null })
  const [signedIn, setSignedIn] = useState<boolean | null>(null)
  // THE BROWSER: its history and the page load under way. The ref is the one
  // every handler and timer reads, so two clicks inside one render, or a load
  // ending as another starts, never step from a stale copy.
  const [browsing, setBrowsingState] = useState<Browsing>(() => startBrowsing(HOME))
  const browsingRef = useRef(browsing)
  const setBrowsing = (b: Browsing) => {
    browsingRef.current = b
    setBrowsingState(b)
  }
  const [pending, setPending] = useState<string | null>(null)
  const [progress, setProgress] = useState<Progress | null>(null)
  const [now, setNow] = useState(() => Date.now())
  const [flash, setFlash] = useState<RunResult | null>(null)
  const [mode, setMode] = useState<UiMode>('light')
  const [search, setSearch] = useState('')
  const [reloads, setReloads] = useState(0)
  // "Match stats" starts collapsed every time the app opens, and stays as the
  // player leaves it while they move between pages.
  const [statsOpen, setStatsOpen] = useState(false)
  const confirmOpen = useRef(false)
  const player = useRef<string | null>(null)
  // The fixed header's height, which its placeholder in the page keeps
  // (terminal.css says why the header is fixed rather than sticky).
  const [headerHeight, setHeaderHeight] = useState(0)
  useLayoutEffect(() => {
    const el = document.getElementById('terminal-header')
    if (!el) return undefined
    const measure = () => setHeaderHeight(Math.ceil(el.getBoundingClientRect().height))
    measure()
    const ro = new ResizeObserver(measure)
    ro.observe(el)
    return () => ro.disconnect()
  }, [reloads])

  useEffect(
    () =>
      connect({
        state(next, nextCopy, nextCatalog) {
          setState(next)
          if (nextCopy) setCopy(nextCopy)
          if (nextCatalog) setCatalog(nextCatalog)
          // SIGNED IN BY THE KEY THE COMPUTER OPENED WITH. A run spends the
          // key, and the page that ran it must stay up to show the answer, so
          // only an opening without one is the login screen.
          setSignedIn((was) => (was === true ? true : next.keyHeld))
          if (player.current !== next.player) {
            player.current = next.player
            const m = loadMode(next.player)
            setMode(m)
            showMode(m)
          }
          // A RUN THE SERVER SAYS IS LOADING -- this app opened again while
          // it loads -- shows the same bar, at the same place; and none
          // when the server says nothing is (model.ts progressAfter).
          const running = next.running
          setProgress((was) => progressAfter(was, running, Date.now()))
        },
        result(next) {
          if (next.code === 'running' && next.ok) {
            setPending(null)
            setFlash(null)
            setProgress({ functionId: next.functionId, runMs: next.runMs ?? 0, startedAt: Date.now() })
            return
          }
          setFlash(next)
          setPending(null)
          setProgress(null)
        },
        canEscape: () => !confirmOpen.current,
      }),
    [],
  )

  // A run whose answer never comes (a request the server dropped) must not
  // leave Run disabled for the rest of the opening: the first answer within
  // the charge's round trip, the last within the loading and a margin.
  useEffect(() => {
    if (pending === null) return undefined
    const t = window.setTimeout(() => setPending(null), 8000)
    return () => window.clearTimeout(t)
  }, [pending])
  useEffect(() => {
    if (progress === null) return undefined
    const t = window.setTimeout(() => setProgress(null), progress.runMs + 10000)
    return () => window.clearTimeout(t)
  }, [progress])

  // THE BAR MOVES while the run loads, and stops when it is full.
  useEffect(() => {
    if (progress === null) return undefined
    setNow(Date.now())
    const t = window.setInterval(() => {
      const at = Date.now()
      setNow(at)
      if (at - progress.startedAt >= progress.runMs) window.clearInterval(t)
    }, PROGRESS_STEP_MS)
    return () => window.clearInterval(t)
  }, [progress])

  // A PAGE LOAD ENDS: its page shows (a reload: the page again, asked for
  // afresh and remounted), and the tab is itself again. A load replaced or
  // dropped since has no page to show, and its timer is cleared anyway.
  const loadSeq = browsing.load ? browsing.load.seq : null
  const loadFor = browsing.load ? browsing.load.ms : 0
  useEffect(() => {
    if (loadSeq === null) return undefined
    const t = window.setTimeout(() => {
      const r = arrive(browsingRef.current, loadSeq)
      if (!r.shown) return
      setBrowsing(r.browsing)
      tellTab(r.tab)
      window.scrollTo(0, 0)
      if (r.reload) {
        setReloads((n) => n + 1)
        setStatsOpen(false)
        askAgain()
      }
    }, loadFor)
    return () => window.clearTimeout(t)
  }, [loadSeq])

  const squadMatch = state?.squadMatch === true
  const say = useMemo(() => speaker(copy, squadMatch), [copy, squadMatch])
  const currency = catalog.currency
  const route: Route = signedIn === false ? { page: 'login' } : current(browsing.history)

  // A NAVIGATION LOADS: the page on screen stays while a fresh pick in the
  // catalog's range runs, the tab shows a loading symbol, and a newer
  // navigation replaces it. A run's answer belongs to the page it was asked
  // on; asking to go anywhere else takes it down (a reload keeps it, as it
  // always did). A link to the page already on screen loads nothing, and
  // only does what it always did.
  const nav = (target: NavTarget) => {
    const r = navigate(browsingRef.current, target, loadMs(catalog.pageLoad, Math.random))
    if (target.kind === 'page') setFlash(null)
    if (r.tab === null) {
      window.scrollTo(0, 0)
      return
    }
    setBrowsing(r.browsing)
    tellTab(r.tab)
  }
  const go = (next: Route) => nav({ kind: 'page', route: next })
  // BACK AND FORWARD ARE INSTANT (the owner's exception), and drop a load
  // under way.
  const browse = (dir: 'back' | 'forward') => {
    const r = step(browsingRef.current, dir)
    setBrowsing(r.browsing)
    tellTab(r.tab)
    setFlash(null)
  }
  const follow = (e: CustomEvent<{ href?: string }>) => {
    e.preventDefault()
    const next = routeOfHref(e.detail.href ?? '')
    if (next) go(next)
  }

  const toggleMode = () => {
    const next: UiMode = mode === 'dark' ? 'light' : 'dark'
    setMode(next)
    showMode(next)
    saveMode(player.current, next)
  }

  // THE FUNCTIONS THIS PLAYER IS SHOWN: outside a squad match, not the
  // squad-only ones, and Ghost under its solo category (the server lists and
  // runs the same set).
  const shown = useMemo(() => shownFunctions(catalog, squadMatch), [catalog, squadMatch])
  const categories = useMemo(() => shownCategories(catalog, shown), [catalog, shown])
  const fnById = useMemo(() => new Map((state?.functions ?? []).map((f) => [f.id, f])), [state])
  const defById = useMemo(() => new Map(shown.map((f) => [f.id, f])), [shown])

  // ── the top bar ──────────────────────────────────────────────────────────
  // THE PLAYER'S VOLTS, BESIDE THE GAMERTAG (round 2: "we need a way for them
  // to see their balance"), the figure every other Volts display shows,
  // pushed again with every state.
  const utilities: TopNavigationProps.Utility[] = []
  if (route.page !== 'login' && state && state.volts !== null) {
    utilities.push({ type: 'button', text: voltsText(state.volts, currency), disableUtilityCollapse: true })
  }
  utilities.push({
    type: 'button',
    iconName: 'light-dark',
    text: mode === 'dark' ? say('mode_light') : say('mode_dark'),
    onClick: toggleMode,
  })
  if (route.page !== 'login' && state?.player) {
    utilities.push({
      type: 'menu-dropdown',
      text: state.player,
      iconName: 'user-profile',
      items: [
        { id: 'howto', text: say('menu_howto') },
        { id: 'signout', text: say('menu_signout') },
      ],
      onItemClick: ({ detail }) => {
        if (detail.id === 'howto') go({ page: 'howto' })
        else if (detail.id === 'signout') signOut()
      },
    })
  }

  const searchBox = route.page === 'login' ? undefined : (
    <Autosuggest
      value={search}
      onChange={({ detail }) => setSearch(detail.value)}
      onSelect={({ detail }) => {
        setSearch('')
        if (detail.selectedOption && defById.has(detail.value)) {
          go({ page: 'function', id: detail.value })
        } else if (detail.value.trim() !== '') {
          go({ page: 'functions', category: null, query: detail.value.trim() })
        }
      }}
      options={shown.map((f) => ({
        value: f.id,
        label: say(`${f.id}_name`),
        description: say(`${f.id}_summary`),
        tags: [say(`category_${f.category}`)],
      }))}
      filteringType="auto"
      placeholder={say('search_placeholder')}
      ariaLabel={say('search_placeholder')}
      enteredTextLabel={(value) => fill(say('search_use'), { value })}
      empty={say('search_empty')}
    />
  )

  // ── the breadcrumbs and the side navigation ──────────────────────────────
  // THE APP'S NAME IS IN THE TOP BAR ONLY (round 2: "remove the 'Blitz
  // Terminal' text from the top of the sidebar - it should only remain in the
  // top bar"): the side navigation has no header, the trail starts at the
  // page's section, and the login screen -- where the name alone was the
  // "random text" near the top left -- has no trail at all.
  const crumbs: { text: string; href: string }[] = []
  if (route.page === 'functions' || route.page === 'function') {
    crumbs.push({ text: say('nav_functions'), href: hrefOf(HOME) })
  }
  if (route.page === 'functions' && route.category) {
    crumbs.push({ text: say(`category_${route.category}`), href: hrefOf(route) })
  }
  if (route.page === 'function') {
    const def = defById.get(route.id)
    if (def) crumbs.push({ text: say(`category_${def.category}`), href: hrefOf({ page: 'functions', category: def.category, query: '' }) })
    crumbs.push({ text: say(`${route.id}_name`), href: hrefOf(route) })
  }
  if (route.page === 'howto') crumbs.push({ text: say('nav_howto'), href: hrefOf(route) })

  const navItems: SideNavigationProps.Item[] = [
    { type: 'link', text: say('nav_functions'), href: hrefOf(HOME) },
    { type: 'link', text: say('nav_howto'), href: hrefOf({ page: 'howto' }) },
    { type: 'divider' },
    {
      type: 'section',
      text: say('nav_categories'),
      items: categories.map((c) => ({
        type: 'link' as const,
        text: say(`category_${c}`),
        href: hrefOf({ page: 'functions', category: c, query: '' }),
      })),
    },
  ]
  const activeHref = route.page === 'function'
    ? hrefOf({ page: 'functions', category: defById.get(route.id)?.category ?? null, query: '' })
    : hrefOf(route)

  // ── a run loading, and its answer ────────────────────────────────────────
  const notes: FlashbarProps.MessageDefinition[] = []
  if (progress) {
    const pct = progress.runMs > 0 ? Math.min(100, ((now - progress.startedAt) / progress.runMs) * 100) : 100
    notes.push({
      id: 'running',
      type: 'info',
      content: (
        <ProgressBar
          variant="flash"
          value={pct}
          label={fill(say('running'), { name: say(`${progress.functionId}_name`) })}
        />
      ),
    })
  }
  if (flash) {
    let text: string
    if (flash.ok) {
      text = say(`${flash.functionId}_done`)
      if (flash.balance !== null) {
        const b = fill(say('balance_new'), { volts: voltsText(flash.balance, currency) })
        text = text !== '' ? `${text} ${b}` : b
      }
    } else if (flash.code === 'no_volts') {
      text = fill(say('no_volts'), {
        cost: voltsText(flash.cost ?? 0, currency),
        balance: voltsText(flash.balance ?? 0, currency),
      })
    } else {
      text = say(flash.code) || say('unavailable')
    }
    notes.push({
      id: 'result',
      type: flash.ok ? 'success' : 'error',
      content: text,
      dismissible: true,
      dismissLabel: say('aria_close'),
      onDismiss: () => setFlash(null),
    })
  }

  // ── the page ─────────────────────────────────────────────────────────────
  let content: ReactElement | null = null
  if (state && route.page === 'login') {
    content = <Login say={say} />
  } else if (state && route.page === 'functions') {
    content = (
      <SpaceBetween size="l">
        {[
          <MatchPanel key="match" state={state} say={say} expanded={statsOpen} onExpand={setStatsOpen} />,
          <FunctionCards
            key="cards"
            state={state}
            functions={shown}
            say={say}
            route={route}
            onOpen={(id) => go({ page: 'function', id })}
            onQuery={(query) => setBrowsing(rewrite(browsingRef.current, { ...route, query }))}
          />,
        ]}
      </SpaceBetween>
    )
  } else if (state && route.page === 'function') {
    const def = defById.get(route.id)
    if (def) {
      content = (
        <FunctionPage
          key={route.id}
          def={def}
          fn={fnById.get(route.id)}
          say={say}
          currency={currency}
          busy={pending !== null || progress !== null}
          onConfirmChange={(open) => { confirmOpen.current = open }}
          onRun={(id, options) => {
            setPending(id)
            setFlash(null)
            run(id, options)
          }}
        />
      )
    }
  } else if (state && route.page === 'howto') {
    content = <HowTo say={say} />
  }

  return (
    <div className="terminal" key={reloads}>
      <div id="terminal-header" className="terminal-header">
        <Browser
          address={addressOf(route, say)}
          canBack={route.page !== 'login' && canBack(browsing.history)}
          canForward={route.page !== 'login' && canForward(browsing.history)}
          onBack={() => browse('back')}
          onForward={() => browse('forward')}
          onReload={() => nav({ kind: 'reload' })}
          labels={{ back: say('aria_back'), forward: say('aria_forward'), reload: say('aria_reload'), address: say('aria_address') }}
        />
        <div className="terminal-topnav">
          <TopNavigation
            identity={{
              href: hrefOf(HOME),
              title: say('app_title'),
              logo: { src: '../../assets/images/terminal.svg', alt: '' },
              onFollow: (e) => {
                e.preventDefault()
                if (route.page !== 'login') go(HOME)
              },
            }}
            search={searchBox}
            utilities={utilities}
          />
        </div>
      </div>
      <div className="terminal-header-space" aria-hidden="true" style={{ height: headerHeight }} />
      <AppLayout
        headerSelector="#terminal-header"
        navigationHide={route.page === 'login'}
        navigationWidth={240}
        toolsHide
        contentType={route.page === 'functions' ? 'cards' : 'default'}
        notifications={notes.length > 0 ? <Flashbar items={notes} /> : undefined}
        breadcrumbs={crumbs.length > 0 ? <BreadcrumbGroup items={crumbs} onFollow={follow} /> : undefined}
        navigation={
          <div className="terminal-nav">
            <SideNavigation
              activeHref={activeHref}
              items={navItems}
              onFollow={follow}
            />
          </div>
        }
        content={content}
      />
    </div>
  )
}
