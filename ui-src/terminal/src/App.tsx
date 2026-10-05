import { useEffect, useMemo, useRef, useState, type ReactElement } from 'react'
import AppLayout from '@cloudscape-design/components/app-layout'
import Autosuggest from '@cloudscape-design/components/autosuggest'
import BreadcrumbGroup from '@cloudscape-design/components/breadcrumb-group'
import Flashbar, { type FlashbarProps } from '@cloudscape-design/components/flashbar'
import SideNavigation, { type SideNavigationProps } from '@cloudscape-design/components/side-navigation'
import SpaceBetween from '@cloudscape-design/components/space-between'
import TopNavigation, { type TopNavigationProps } from '@cloudscape-design/components/top-navigation'
import {
  connect, reload as askAgain, run, signOut,
  type Catalog, type Copy, type RunResult, type TerminalState,
} from './bridge'
import { Browser } from './Browser'
import { FunctionCards } from './FunctionCards'
import { FunctionPage } from './FunctionPage'
import { HowTo } from './HowTo'
import { Login } from './Login'
import { MatchPanel } from './MatchPanel'
import {
  HOME, addressOf, back, canBack, canForward, current, fill, forward, hrefOf, line, push, replace,
  routeOfHref, startHistory, type History, type Route,
} from './model'
import { loadMode, saveMode, showMode, type UiMode } from './mode'

/**
 * THE TERMINAL APP: a web page in a web browser (#396, owner, 2026-10-05).
 *
 *   the browser   Browser.tsx: back, forward and reload over THIS app's
 *                 history, and the address of the page it is on
 *   the top bar   TopNavigation: the app's name, a search across every
 *                 function (pick one to open its page; or search the cards),
 *                 the light/dark switch, and the player's gamertag as the
 *                 signed-in user (its menu: the how-to, or sign out, which
 *                 closes the computer)
 *   the layout    AppLayout with SideNavigation (Functions, How to, each
 *                 category) and a BreadcrumbGroup on every page; the server's
 *                 answer to a run is a Flashbar notification
 *   the pages     the functions (MatchPanel over FunctionCards), a function
 *                 (FunctionPage), the how-to (HowTo), and the login screen
 *                 (Login) when the computer opened without a Yubikey
 *
 * ═══ NOT ONE WORD IS WRITTEN HERE ═══
 *
 * Every player-facing line is a key into the copy br_core sends with the
 * state, out of the one block in br_lib/config/terminals.lua; the function
 * cards and pages are drawn from the registry (the catalog) that rides with
 * it. scripts/check-terminal.mjs fails a word written between two tags.
 *
 * ═══ NOTHING HERE DECIDES ═══
 *
 * `available` and `reason` are the server's; Run asks, and the server checks
 * the terminal, the key, the squad and the options again.
 *
 * ═══ CEF 103 (#385) ═══
 *
 * No Spinner and no `loading` anywhere: a waiting button is disabled instead.
 * Arrays, not Fragments, go into SpaceBetween (React 19). Dark mode on <body>
 * (mode.ts). AppLayout and SideNavigation are used inside this iframe, whose
 * opaque page is the browser's page -- not over the game, which is what #385
 * banned them for -- and SideNavigation never collapses (the opt-in that hides
 * icon-less groups only through :has). scripts/check-terminal.mjs holds these.
 */
export function App(): ReactElement {
  const [state, setState] = useState<TerminalState | null>(null)
  const [copy, setCopy] = useState<Copy>({})
  const [catalog, setCatalog] = useState<Catalog>({ functions: [], categories: [] })
  const [signedIn, setSignedIn] = useState<boolean | null>(null)
  const [history, setHistory] = useState<History>(() => startHistory(HOME))
  const [pending, setPending] = useState<string | null>(null)
  const [flash, setFlash] = useState<RunResult | null>(null)
  const [mode, setMode] = useState<UiMode>('dark')
  const [search, setSearch] = useState('')
  const [reloads, setReloads] = useState(0)
  const confirmOpen = useRef(false)
  const player = useRef<string | null>(null)

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
        },
        result(next) {
          setFlash(next)
          setPending(null)
        },
        canEscape: () => !confirmOpen.current,
      }),
    [],
  )

  // A run whose answer never comes (a request the server dropped) must not
  // leave Run disabled for the rest of the opening.
  useEffect(() => {
    if (pending === null) return undefined
    const t = window.setTimeout(() => setPending(null), 8000)
    return () => window.clearTimeout(t)
  }, [pending])

  const L = (k: string | null | undefined) => line(copy, k)
  const route: Route = signedIn === false ? { page: 'login' } : current(history)

  // A run's answer belongs to the page it was asked on; going anywhere else
  // takes it down.
  const go = (next: Route) => {
    setHistory((h) => push(h, next))
    setFlash(null)
    window.scrollTo(0, 0)
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

  const fnById = useMemo(() => new Map((state?.functions ?? []).map((f) => [f.id, f])), [state])
  const defById = useMemo(() => new Map(catalog.functions.map((f) => [f.id, f])), [catalog])

  // ── the top bar ──────────────────────────────────────────────────────────
  const utilities: TopNavigationProps.Utility[] = [
    {
      type: 'button',
      iconName: 'light-dark',
      text: mode === 'dark' ? L('mode_light') : L('mode_dark'),
      onClick: toggleMode,
    },
  ]
  if (route.page !== 'login' && state?.player) {
    utilities.push({
      type: 'menu-dropdown',
      text: state.player,
      iconName: 'user-profile',
      items: [
        { id: 'howto', text: L('menu_howto') },
        { id: 'signout', text: L('menu_signout') },
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
      options={catalog.functions.map((f) => ({
        value: f.id,
        label: L(`${f.id}_name`),
        description: L(`${f.id}_summary`),
        tags: [L(`category_${f.category}`)],
      }))}
      filteringType="auto"
      placeholder={L('search_placeholder')}
      ariaLabel={L('search_placeholder')}
      enteredTextLabel={(value) => fill(L('search_use'), { value })}
      empty={L('search_empty')}
    />
  )

  // ── the breadcrumbs and the side navigation ──────────────────────────────
  const crumbs: { text: string; href: string }[] = [{ text: L('app_title'), href: hrefOf(HOME) }]
  if (route.page === 'functions' || route.page === 'function') {
    crumbs.push({ text: L('nav_functions'), href: hrefOf(HOME) })
  }
  if (route.page === 'functions' && route.category) {
    crumbs.push({ text: L(`category_${route.category}`), href: hrefOf(route) })
  }
  if (route.page === 'function') {
    const def = defById.get(route.id)
    if (def) crumbs.push({ text: L(`category_${def.category}`), href: hrefOf({ page: 'functions', category: def.category, query: '' }) })
    crumbs.push({ text: L(`${route.id}_name`), href: hrefOf(route) })
  }
  if (route.page === 'howto') crumbs.push({ text: L('nav_howto'), href: hrefOf(route) })

  const navItems: SideNavigationProps.Item[] = [
    { type: 'link', text: L('nav_functions'), href: hrefOf(HOME) },
    { type: 'link', text: L('nav_howto'), href: hrefOf({ page: 'howto' }) },
    { type: 'divider' },
    {
      type: 'section',
      text: L('nav_categories'),
      items: catalog.categories.map((c) => ({
        type: 'link' as const,
        text: L(`category_${c}`),
        href: hrefOf({ page: 'functions', category: c, query: '' }),
      })),
    },
  ]
  const activeHref = route.page === 'function'
    ? hrefOf({ page: 'functions', category: defById.get(route.id)?.category ?? null, query: '' })
    : hrefOf(route)

  // ── the answer to a run ──────────────────────────────────────────────────
  const notes: FlashbarProps.MessageDefinition[] = flash
    ? [{
      id: 'result',
      type: flash.ok ? 'success' : 'error',
      content: flash.ok ? L(`${flash.functionId}_done`) : (L(flash.code) || L('unavailable')),
      dismissible: true,
      dismissLabel: L('aria_close'),
      onDismiss: () => setFlash(null),
    }]
    : []

  // ── the page ─────────────────────────────────────────────────────────────
  let content: ReactElement | null = null
  if (state && route.page === 'login') {
    content = <Login copy={copy} />
  } else if (state && route.page === 'functions') {
    content = (
      <SpaceBetween size="l">
        {[
          <MatchPanel key="match" state={state} copy={copy} />,
          <FunctionCards
            key="cards"
            state={state}
            catalog={catalog}
            copy={copy}
            route={route}
            onOpen={(id) => go({ page: 'function', id })}
            onQuery={(query) => setHistory((h) => replace(h, { ...route, query }))}
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
          copy={copy}
          busy={pending !== null}
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
    content = <HowTo copy={copy} />
  }

  return (
    <div className="terminal" key={reloads}>
      <div id="terminal-header" className="terminal-header">
        <Browser
          address={addressOf(route, copy)}
          canBack={route.page !== 'login' && canBack(history)}
          canForward={route.page !== 'login' && canForward(history)}
          onBack={() => { setHistory(back); setFlash(null) }}
          onForward={() => { setHistory(forward); setFlash(null) }}
          onReload={() => {
            setReloads((n) => n + 1)
            askAgain()
          }}
          labels={{ back: L('aria_back'), forward: L('aria_forward'), reload: L('aria_reload'), address: L('aria_address') }}
        />
        <TopNavigation
          identity={{
            href: hrefOf(HOME),
            title: L('app_title'),
            logo: { src: '../../assets/images/terminal.png', alt: '' },
            onFollow: (e) => {
              e.preventDefault()
              if (route.page !== 'login') go(HOME)
            },
          }}
          search={searchBox}
          utilities={utilities}
        />
      </div>
      <AppLayout
        headerSelector="#terminal-header"
        navigationHide={route.page === 'login'}
        navigationWidth={240}
        toolsHide
        contentType={route.page === 'functions' ? 'cards' : 'default'}
        notifications={notes.length > 0 ? <Flashbar items={notes} /> : undefined}
        breadcrumbs={<BreadcrumbGroup items={crumbs} onFollow={follow} />}
        navigation={
          <SideNavigation
            header={{ text: L('app_title'), href: hrefOf(HOME) }}
            activeHref={activeHref}
            items={navItems}
            onFollow={follow}
          />
        }
        content={content}
      />
    </div>
  )
}
