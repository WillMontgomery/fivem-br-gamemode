import { useEffect, useState, type ReactElement } from 'react'
import Badge from '@cloudscape-design/components/badge'
import Box from '@cloudscape-design/components/box'
import Button from '@cloudscape-design/components/button'
import Cards from '@cloudscape-design/components/cards'
import CollectionPreferences from '@cloudscape-design/components/collection-preferences'
import Header from '@cloudscape-design/components/header'
import Pagination from '@cloudscape-design/components/pagination'
import Select, { type SelectProps } from '@cloudscape-design/components/select'
import SpaceBetween from '@cloudscape-design/components/space-between'
import StatusIndicator from '@cloudscape-design/components/status-indicator'
import type { FunctionDef, TerminalState } from './bridge'
import {
  BOUNTIES, COSTS, NO_FILTERS, RISKS, STATUSES, bountyOf, cardsFor, costRange, fill, filtersOf, indicatorOf,
  narrowed, riskColor, showsSquads, statusOf, statusText, withFilters, type CardFilters, type Route, type Say,
} from './model'
import { Squads } from './Squads'
import { VoltsAmount, voltsLine } from './Volts'

/**
 * ONE CARD PER TOOL, as in Cloudscape's cards example: the filters,
 * pagination and preferences (cards per page, what each card shows). The
 * player calls them tools (owner, 2026-10-06, round 5: 'Rename the
 * "Functions" to "Tools"'); the registry and this code still say function.
 *
 * Owner, 2026-10-05: "each card should be an action that the terminal can
 * perform, so the user can pick between them, navigate between them,
 * understand what they do". A card is the function's name (the way to its
 * page), its one-line summary, its category, its risk, its cost and its
 * bounty (round 4: "The cards should show cost in volts and bounty") and
 * whether it can run now -- available, used, not available, or (round 6,
 * owner 2026-10-07: "Yes please say the real reason") the rule of the match
 * that stops it, in a few words (model.ts statusText); the Status filter
 * groups those as "not available now". Every terminal lists every tool. Never
 * how it helps: the summary says what it does, and nothing on a card sells it.
 *
 * THE FUNCTIONS THIS PLAYER IS SHOWN (App.tsx, model.ts shownFunctions): in a
 * squad match all of them; outside one, not the squad-only ones, and Ghost
 * under its solo category.
 *
 * THE CARD'S TITLE IS LARGE (round 2: "the card titles should be larger font
 * size"): terminal.css's `.terminal-card-title`, 20 px, wrapping inside the
 * card rather than running past it. "SQUADS!" FOLLOWS IT on a function whose
 * effect reaches the whole squad, in a squad match (Squads.tsx).
 *
 * A CARD'S COST is its Volts in the Volts style (Volts.tsx), or cost_free --
 * or, for one whose price depends on what is chosen and can be nothing
 * (round 5, Gear Up), cost_free_or with the most it can cost -- over the
 * choices THIS player is offered (model.ts costRange), so a solo player, who
 * is never offered Gear Up's whole squad, reads Free, as the Cost filter does;
 * its BOUNTY is its row's `bounty` in words (bounty_none / _runner / _target).
 *
 * THE FILTERS (round 4: "the "Functions" search should have filters available
 * for category, risk, Volts cost (free/paid), bounty, and availability
 * status"): five Selects, each labeled inside its own trigger, each "Any"
 * until set (model.ts "the filters"). They work together with pagination,
 * and with the top bar's search when it brought the player here (its text
 * rides in the route's `query`); while anything but the category narrows the
 * cards, the heading counts what is left of what there is. The category is
 * the page's own, the side navigation's.
 *
 * NO TEXT SEARCH OF ITS OWN (owner, 2026-10-06, round 5: "please remove the
 * search bar within the Functions (soon to be "Tools") section - we have a
 * search at the top anyway. Just the filters can remain."). The top bar's
 * search finds a tool (its page) or, with what was typed, the cards that
 * match it here.
 *
 * PREFERENCES ARE THIS OPENING'S ONLY. They live in React state and go with
 * the document when the app closes; the one thing remembered across openings
 * is the light/dark mode (mode.ts).
 */
const SECTIONS = ['summary', 'category', 'risk', 'cost', 'bounty', 'status'] as const
const PAGE_SIZES = [6, 9, 18]

export function FunctionCards(props: {
  state: TerminalState
  functions: FunctionDef[]
  categories: string[]
  say: Say
  currency: string
  route: Extract<Route, { page: 'functions' }>
  onOpen: (id: string) => void
  onRoute: (route: Route) => void
}): ReactElement {
  const { state, say, route, currency } = props
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(9)
  const [visible, setVisible] = useState<readonly string[]>(SECTIONS)
  const filters = filtersOf(route)

  // A new search, category or filter starts on the first page.
  const filterKey = JSON.stringify(filters)
  useEffect(() => setPage(1), [route.query, route.category, filterKey])

  const byId = new Map(state.functions.map((f) => [f.id, f]))
  const { items, all } = cardsFor(route, props.functions, byId, say)
  const pages = Math.max(1, Math.ceil(items.length / pageSize))
  const current = Math.min(page, pages)
  const shown = items.slice((current - 1) * pageSize, current * pageSize)

  const heading = route.category ? say(`category_${route.category}`) : say('tools_heading')
  // WHAT IS LEFT OF WHAT THERE IS, while the search or a filter narrows the
  // cards beyond their category: "(3/18)", as Cloudscape's filtered
  // collections count.
  const counter = narrowed({ ...route, category: null }) ? `(${items.length}/${all})` : `(${items.length})`

  // ── the filters ──────────────────────────────────────────────────────────
  const any: SelectProps.Option = { value: '', label: say('filter_any') }
  const setFilter = (key: keyof CardFilters, value: string) => {
    props.onRoute(withFilters(route, { ...filters, [key]: value === '' ? null : value } as CardFilters))
  }
  const select = (id: string, label: string, value: string | null, options: SelectProps.Option[],
    onPick: (value: string) => void) => {
    const choices = [any, ...options]
    return (
      <div key={id} className="terminal-filter-select" data-filter={id}>
        <Select
          inlineLabelText={label}
          selectedOption={choices.find((o) => o.value === (value ?? '')) ?? any}
          options={choices}
          expandToViewport
          onChange={({ detail }) => onPick(detail.selectedOption.value ?? '')}
        />
      </div>
    )
  }
  const filterRow = (
    <div className="terminal-filters">
      {[
        select('category', say('card_category'), route.category,
          props.categories.map((c) => ({ value: c, label: say(`category_${c}`) })),
          (v) => props.onRoute({ ...route, category: v === '' ? null : v })),
        select('risk', say('card_risk'), filters.risk,
          RISKS.map((r) => ({ value: r, label: say(`risk_${r}`) })), (v) => setFilter('risk', v)),
        select('cost', say('card_cost'), filters.cost,
          COSTS.map((c) => ({ value: c, label: say(`cost_${c}`) })), (v) => setFilter('cost', v)),
        select('bounty', say('card_bounty'), filters.bounty,
          BOUNTIES.map((b) => ({ value: b, label: say(`bounty_${b}`) })), (v) => setFilter('bounty', v)),
        select('status', say('card_status'), filters.status,
          STATUSES.map((s) => ({ value: s, label: say(`status_${s}`) })), (v) => setFilter('status', v)),
      ]}
    </div>
  )

  return (
    <div className="terminal-cards">
      <Cards<FunctionDef>
        trackBy="id"
        items={shown}
        visibleSections={visible}
        cardsPerRow={[{ cards: 1 }, { minWidth: 560, cards: 2 }, { minWidth: 900, cards: 3 }]}
        cardDefinition={{
          header: (f) => (
            <div className="terminal-card-head">
              <span className="terminal-card-title">
                <Button variant="inline-link" onClick={() => props.onOpen(f.id)}>
                  {say(`${f.id}_name`)}
                </Button>
              </span>
              {showsSquads(f, state.squadMatch) ? <Squads say={say} /> : null}
            </div>
          ),
          // TWO COLUMNS (owner, 2026-10-06: "is it possible to make the bounty and
          // status move to a 2nd column here?"). Cloudscape lays a card's sections
          // out in order and wraps them by `width`, so at 50 each they pair up row
          // by row: Category | Bounty, Risk | Status, then Cost -- the left column
          // reads Category, Risk, Cost and the right Bounty, Status. A section the
          // preferences hide just lets the rest close up.
          sections: [
            { id: 'summary', content: (f) => voltsLine(say(`${f.id}_summary`), currency) },
            { id: 'category', width: 50, header: say('card_category'), content: (f) => say(`category_${f.category}`) },
            { id: 'bounty', width: 50, header: say('card_bounty'), content: (f) => say(`bounty_${bountyOf(f)}`) },
            {
              id: 'risk',
              width: 50,
              header: say('card_risk'),
              content: (f) => <Badge color={riskColor(f.risk)}>{say(`risk_${f.risk}`)}</Badge>,
            },
            {
              id: 'status',
              width: 50,
              header: say('card_status'),
              content: (f) => {
                const fn = byId.get(f.id)
                return <StatusIndicator type={indicatorOf(statusOf(fn, f))}>{statusText(fn, f, say)}</StatusIndicator>
              },
            },
            {
              id: 'cost',
              width: 50,
              header: say('card_cost'),
              // IN BOLD (round 7: "Please bold the cost text inside the cards"):
              // Free, Free or the most, or the Volts -- in their own color.
              content: (f) => {
                const r = costRange(f, say)
                const cost = r.max <= 0
                  ? say('cost_free')
                  : r.min <= 0
                    ? voltsLine(say('cost_free_or'), currency, { volts: r.max })
                    : <VoltsAmount n={r.max} currency={currency} />
                return <span className="terminal-cost">{cost}</span>
              },
            },
          ],
        }}
        header={
          <Header variant="awsui-h1-sticky" counter={counter}>
            {heading}
          </Header>
        }
        filter={filterRow}
        pagination={
          <Pagination currentPageIndex={current} pagesCount={pages}
            onChange={({ detail }) => setPage(detail.currentPageIndex)} />
        }
        preferences={
          <CollectionPreferences
            title={say('pref_title')}
            confirmLabel={say('pref_confirm')}
            cancelLabel={say('pref_cancel')}
            preferences={{ pageSize, visibleContent: visible }}
            pageSizePreference={{
              title: say('pref_page_size'),
              options: PAGE_SIZES.map((n) => ({ value: n, label: fill(say('pref_page_option'), { count: n }) })),
            }}
            visibleContentPreference={{
              title: say('pref_visible'),
              options: [{
                label: say('pref_visible_group'),
                options: SECTIONS.map((id) => ({
                  id,
                  label: id === 'summary' ? say('what_heading') : say(`card_${id}`),
                })),
              }],
            }}
            onConfirm={({ detail }) => {
              if (typeof detail.pageSize === 'number') setPageSize(detail.pageSize)
              if (detail.visibleContent) setVisible(detail.visibleContent)
            }}
          />
        }
        empty={
          <Box textAlign="center" color="inherit">
            <SpaceBetween size="m">
              {[
                <Box key="text" variant="p" color="inherit">{say('filter_empty')}</Box>,
                <Button key="clear"
                  onClick={() => props.onRoute(withFilters({ ...route, category: null, query: '' }, NO_FILTERS))}>
                  {say('filter_clear')}
                </Button>,
              ]}
            </SpaceBetween>
          </Box>
        }
      />
    </div>
  )
}
