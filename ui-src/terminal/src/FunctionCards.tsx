import { useEffect, useState, type ReactElement } from 'react'
import Badge from '@cloudscape-design/components/badge'
import Box from '@cloudscape-design/components/box'
import Button from '@cloudscape-design/components/button'
import Cards from '@cloudscape-design/components/cards'
import CollectionPreferences from '@cloudscape-design/components/collection-preferences'
import Header from '@cloudscape-design/components/header'
import Pagination from '@cloudscape-design/components/pagination'
import SpaceBetween from '@cloudscape-design/components/space-between'
import StatusIndicator from '@cloudscape-design/components/status-indicator'
import TextFilter from '@cloudscape-design/components/text-filter'
import type { FunctionDef, TerminalState } from './bridge'
import { fill, indicatorOf, matches, riskColor, statusOf, type Route, type Say } from './model'

/**
 * ONE CARD PER FUNCTION, as in Cloudscape's cards example: a text filter,
 * pagination and preferences (cards per page, what each card shows).
 *
 * Owner, 2026-10-05: "each card should be an action that the terminal can
 * perform, so the user can pick between them, navigate between them,
 * understand what they do". A card is the function's name (the way to its
 * page), its one-line summary, its category, its risk and whether it can run
 * here now -- available, used, not available at this terminal or not
 * available. Never how it helps: the summary says what it does, and nothing on
 * a card sells it.
 *
 * THE FUNCTIONS THIS PLAYER IS SHOWN (App.tsx, model.ts shownFunctions): in a
 * squad match all of them; outside one, not the squad-only ones, and Ghost
 * under its solo category.
 *
 * THE CARD'S TITLE IS LARGE (round 2: "the card titles should be larger font
 * size"): terminal.css's `.terminal-card-title`, 20 px, wrapping inside the
 * card rather than running past it.
 *
 * PREFERENCES ARE THIS OPENING'S ONLY. They live in React state and go with
 * the document when the app closes; the one thing remembered across openings
 * is the light/dark mode (mode.ts).
 */
const SECTIONS = ['summary', 'category', 'risk', 'status'] as const
const PAGE_SIZES = [6, 9, 18]

export function FunctionCards(props: {
  state: TerminalState
  functions: FunctionDef[]
  say: Say
  route: Extract<Route, { page: 'functions' }>
  onOpen: (id: string) => void
  onQuery: (query: string) => void
}): ReactElement {
  const { state, say, route } = props
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(9)
  const [visible, setVisible] = useState<readonly string[]>(SECTIONS)

  // A new filter or category starts on the first page.
  useEffect(() => setPage(1), [route.query, route.category])

  const byId = new Map(state.functions.map((f) => [f.id, f]))
  const items = props.functions.filter((f) =>
    (route.category === null || f.category === route.category) && matches(f, say, route.query))
  const pages = Math.max(1, Math.ceil(items.length / pageSize))
  const current = Math.min(page, pages)
  const shown = items.slice((current - 1) * pageSize, current * pageSize)

  const heading = route.category ? say(`category_${route.category}`) : say('functions_heading')

  return (
    <div className="terminal-cards">
      <Cards<FunctionDef>
        trackBy="id"
        items={shown}
        visibleSections={visible}
        cardsPerRow={[{ cards: 1 }, { minWidth: 560, cards: 2 }, { minWidth: 900, cards: 3 }]}
        cardDefinition={{
          header: (f) => (
            <span className="terminal-card-title">
              <Button variant="inline-link" onClick={() => props.onOpen(f.id)}>
                {say(`${f.id}_name`)}
              </Button>
            </span>
          ),
          sections: [
            { id: 'summary', content: (f) => say(`${f.id}_summary`) },
            { id: 'category', header: say('card_category'), content: (f) => say(`category_${f.category}`) },
            {
              id: 'risk',
              header: say('card_risk'),
              content: (f) => <Badge color={riskColor(f.risk)}>{say(`risk_${f.risk}`)}</Badge>,
            },
            {
              id: 'status',
              header: say('card_status'),
              content: (f) => {
                const s = statusOf(byId.get(f.id), f)
                return <StatusIndicator type={indicatorOf(s)}>{say(`status_${s}`)}</StatusIndicator>
              },
            },
          ],
        }}
        header={
          <Header variant="awsui-h1-sticky" counter={`(${items.length})`}>
            {heading}
          </Header>
        }
        filter={
          <TextFilter
            filteringText={route.query}
            filteringPlaceholder={say('filter_placeholder')}
            filteringAriaLabel={say('filter_placeholder')}
            countText={fill(say('filter_matches'), { count: items.length })}
            onChange={({ detail }) => props.onQuery(detail.filteringText)}
          />
        }
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
                <Button key="clear" onClick={() => props.onQuery('')}>{say('filter_clear')}</Button>,
              ]}
            </SpaceBetween>
          </Box>
        }
      />
    </div>
  )
}
