import type { ReactElement } from 'react'
import Popover from '@cloudscape-design/components/popover'
import type { Say } from './model'

/**
 * "SQUADS!" BESIDE THE TITLE OF A FUNCTION THAT REACHES THE WHOLE SQUAD.
 *
 * Owner, 2026-10-06 (round 4), verbatim: "Any tool that can impact the whole
 * squad should have a tooltip next to the card title (the blue text, see
 * attached) which should read "Squads!" upon clicking it, the new box should
 * read "This function will apply to your entire squad."" His screenshot is
 * the AWS console's blue, dotted "New" beside a navigation item: a Cloudscape
 * popover's text trigger. So a blue, dotted `squads_link` after the card's
 * title and the function page's, which opens a popover saying
 * `squads_popover` -- both his words, from the copy block.
 *
 * ON A `squadWide` ROW (br_lib/config/terminals.lua), AND ONLY IN A SQUAD
 * MATCH -- round 2's rule, no "squad" to a solo player. Twice over: the
 * caller draws it only then (model.ts `showsSquads`), and the lines' empty
 * `_solo` siblings make the speaker say nothing outside one, which draws
 * nothing.
 *
 * NOT A LINK. Cloudscape's Link is a real anchor (check-terminal T2); the
 * popover's own trigger is a button, so a click opens the box and nothing
 * else -- not the card, whose only way in is its title -- and the click goes
 * no further. The box renders over the page (a portal), so a card cannot
 * clip it, and Escape closes it before the computer (bridge.ts reads an open
 * dialog first).
 */
export function Squads(props: { say: Say }): ReactElement | null {
  const { say } = props
  const link = say('squads_link')
  const body = say('squads_popover')
  if (link === '' || body === '') return null
  return (
    <span className="terminal-squads" onClick={(e) => e.stopPropagation()}>
      <Popover
        triggerType="text"
        size="small"
        position="top"
        renderWithPortal
        dismissAriaLabel={say('aria_close')}
        content={body}
      >
        {link}
      </Popover>
    </span>
  )
}
