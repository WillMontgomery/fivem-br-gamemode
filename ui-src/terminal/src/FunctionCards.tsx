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
import type { Catalog, Copy, FunctionDef, TerminalState } from './bridge'
import { fill, indicatorOf, line, matches, riskColor, statusOf, type Route } from './model'

/**
 * ONE CARD PER FUNCTION, as in Cloudscape's cards example: a text filter,
 * pagination and preferences (cards per page, what each card shows).
 *
 * Owner, 2026-10-05: "each card should be an action that the terminal can
 * perform, so the user can pick between them, navigate between them,
 * understand what they do". A card is the function's name (the way to its
 * page), its one-line summary, its category, its risk and whether it can run
 * here now -- available, used, not here or offline. Never how it helps: the
 * summary says what it does, and nothing on a card sells it.
 *
 * PREFERENCES ARE THIS OPENING'S ONLY. They live in React state and go with
 * the document when the computer closes; the one thing remembered across
 * openings is the light/dark mode (mode.ts).
 */
const SECTIONS = ['summary', 'category', 'risk', 'status'] as const
const PAGE_SIZES = [6, 9, 18]

export function FunctionCards(props: {
  state: TerminalState
  catalog: Catalog
  copy: Copy
  route: Extract<Route, { page: 'functions' }>
  onOpen: (id: string) => void
  onQuery: (query: string) => void
}): ReactElement {
  const { state, catalog, copy, route } = props
  const L = (k: string) => line(copy, k)
  const [page, setPage] = useState(1)
  const [pageSize, setPageSize] = useState(9)
  const [visible, setVisible] = useState<readonly string[]>(SECTIONS)

  // A new filter or category starts on the first page.
  useEffect(() => setPage(1), [route.query, route.category])

  const byId = new Map(state.functions.map((f) => [f.id, f]))
  const items = catalog.functions.filter((f) =>
    (route.category === null || f.category === route.category) && matches(f, copy, route.query))
  const pages = Math.max(1, Math.ceil(items.length / pageSize))
  const current = Math.min(page, pages)
  const shown = items.slice((current - 1) * pageSize, current * pageSize)

  const heading = route.category ? L(`category_${route.category}`) : L('functions_heading')

  return (
    <Cards<FunctionDef>
      trackBy="id"
      items={shown}
      visibleSections={visible}
      cardsPerRow={[{ cards: 1 }, { minWidth: 560, cards: 2 }, { minWidth: 900, cards: 3 }]}
      cardDefinition={{
        header: (f) => (
          <Button variant="inline-link" onClick={() => props.onOpen(f.id)}>
            {L(`${f.id}_name`)}
          </Button>
        ),
        sections: [
          { id: 'summary', content: (f) => L(`${f.id}_summary`) },
          { id: 'category', header: L('card_category'), content: (f) => L(`category_${f.category}`) },
          {
            id: 'risk',
            header: L('card_risk'),
            content: (f) => <Badge color={riskColor(f.risk)}>{L(`risk_${f.risk}`)}</Badge>,
          },
          {
            id: 'status',
            header: L('card_status'),
            content: (f) => {
              const s = statusOf(byId.get(f.id), f)
              return <StatusIndicator type={indicatorOf(s)}>{L(`status_${s}`)}</StatusIndicator>
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
          filteringPlaceholder={L('filter_placeholder')}
          filteringAriaLabel={L('filter_placeholder')}
          countText={fill(L('filter_matches'), { count: items.length })}
          onChange={({ detail }) => props.onQuery(detail.filteringText)}
        />
      }
      pagination={
        <Pagination currentPageIndex={current} pagesCount={pages}
          onChange={({ detail }) => setPage(detail.currentPageIndex)} />
      }
      preferences={
        <CollectionPreferences
          title={L('pref_title')}
          confirmLabel={L('pref_confirm')}
          cancelLabel={L('pref_cancel')}
          preferences={{ pageSize, visibleContent: visible }}
          pageSizePreference={{
            title: L('pref_page_size'),
            options: PAGE_SIZES.map((n) => ({ value: n, label: fill(L('pref_page_option'), { count: n }) })),
          }}
          visibleContentPreference={{
            title: L('pref_visible'),
            options: [{
              label: L('pref_visible_group'),
              options: SECTIONS.map((id) => ({
                id,
                label: id === 'summary' ? L('what_heading') : L(`card_${id}`),
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
              <Box key="text" variant="p" color="inherit">{L('filter_empty')}</Box>,
              <Button key="clear" onClick={() => props.onQuery('')}>{L('filter_clear')}</Button>,
            ]}
          </SpaceBetween>
        </Box>
      }
    />
  )
}
