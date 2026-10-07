import type { ReactElement } from 'react'
import Box from '@cloudscape-design/components/box'
import Button, { type ButtonProps } from '@cloudscape-design/components/button'
import FormField from '@cloudscape-design/components/form-field'
import Modal from '@cloudscape-design/components/modal'
import RadioGroup from '@cloudscape-design/components/radio-group'
import Select, { type SelectProps } from '@cloudscape-design/components/select'
import SpaceBetween from '@cloudscape-design/components/space-between'
import type { FunctionDef, Mate, OptionDef, Rarity, Spot } from './bridge'
import {
  boxOptions, costFor, fill, needsSpot, orderedChoices, placeText, rarityOf, readyToRun, runChoices, tint, valueOf,
  type Say,
} from './model'
import { voltsLine } from './Volts'

/**
 * THE CONFIRM BOX: EVERY CHOICE A RUN NEEDS, AND RUN.
 *
 * Owner, 2026-10-07 (round 6): "We need to move all required options/inputs
 * to be part of the "confirm" modal. We should explain what options exist in
 * the description, but much like we do location selection today that should
 * be in the confirm modal. Also please add an icon to the "pick location"
 * button." So a tool's page says what it does (its description names the
 * options) and Run opens this box, which asks for everything the run carries:
 *
 *   the cost      confirm_body, or confirm_body_volts with THIS run's price --
 *                 the price of the choices made here (`costFor`, round 5's
 *                 `costBy`), so it follows them as they change
 *   the options   each option offered under the choices made so far, with
 *                 words for this player (model.ts `boxOptions`): radio buttons,
 *                 or a dropdown (`dropdown`) -- an item list, or the standing
 *                 teammates (`source = 'mates'`), live with every push. An
 *                 option with `when` appears only while it holds, here as on
 *                 the server (round 4: Time & weather's time OR weather)
 *   the spot      "Set location" (confirm_location, with the location-pin
 *                 icon Cloudscape ships), for a run at a spot (`needsSpot`:
 *                 always for Storm control, Airstrike and Supply drop, and for
 *                 Power outage only while its area is the spot the player
 *                 picks): it hides the computer and opens the big map, and the
 *                 box comes back showing the place picked
 *   Run           disabled until every choice is made (`readyToRun`: each
 *                 option it shows has a value, and the spot when one is
 *                 needed). The run carries the choices and -- only when it is
 *                 run at a spot -- the spot; the server checks all of it again
 *
 * GEAR UP'S ITEMS WEAR THEIR RARITY (round 6: "On the gear up tool - in the
 * dropdown list - on the right side of each item in the list, add it's rarity
 * with the colored font. Sorted by most rare at the top. Also hovering the
 * mouse over each row should show a colored tint matching it's rarity."): the
 * list is rarest first (`orderedChoices`), and each row is drawn through
 * Select's own `renderOption`, so the dropdown is still Cloudscape's -- its
 * keyboard, its filtering, its focus -- with the item on the left and its
 * rarity's name (rarity_<key>) on the right in the game's rarity color
 * (BR.RarityInfo, through the catalog), and a tint of that color on the row
 * Cloudscape highlights, by the pointer or the arrow keys.
 */

/**
 * RUN WEARS THE FUNCTION'S RISK (round 2: "the Run button - make it the risk
 * color instead"): the same color as its low, medium or high risk badge, in
 * both modes, with the badge's own text color -- terminal.css's
 * `--terminal-run-*` variables, which are the badge's tokens. The page's Run
 * and the box's.
 */
export function runStyle(risk: FunctionDef['risk']): ButtonProps.Style {
  const v = (part: string) => `var(--terminal-run-${risk}-${part})`
  const off = (part: string) => `var(--terminal-run-disabled-${part})`
  return {
    root: {
      background: { default: v('bg'), hover: v('bg-hover'), active: v('bg-active'), disabled: off('bg') },
      borderColor: { default: v('bg'), hover: v('bg-hover'), active: v('bg-active'), disabled: off('bg') },
      color: { default: v('text'), hover: v('text'), active: v('text'), disabled: off('text') },
    },
  }
}

/** How strong a highlighted row's rarity tint is, over the list's own surface. */
const TINT_ALPHA = 0.2

export function RunBox(props: {
  def: FunctionDef
  say: Say
  currency: string
  visible: boolean
  /** May the box's controls and Run be used: the tool available, and no run of this player's waiting. */
  enabled: boolean
  /** The choices made, the player's own; an option not in it carries its default. */
  choice: Readonly<Record<string, string>>
  onChoice: (next: Record<string, string>) => void
  /** The standing teammates an option may name (round 5). */
  mates: Mate[]
  /** The loot rarities, as the game colors them (round 6). */
  rarities: Rarity[]
  /** The spot picked on the big map this opening, and the game's name for it. */
  spot: { at: Spot; place: string } | null
  /** "Set location": pick a spot on the big map. */
  onPick: () => void
  onRun: (options: Record<string, string>, at: Spot | null) => void
  onCancel: () => void
}): ReactElement {
  const { def, say, choice, mates } = props
  const id = def.id
  const currency = props.currency
  const name = say(`${id}_name`)
  // THE PRICE OF THESE CHOICES, in the Volts style (check-terminal T12: the
  // amounts written inside the voltsLine call).
  const price = costFor(def, choice)
  const body = price > 0
    ? voltsLine(say('confirm_body_volts'), currency, { volts: price })
    : voltsLine(say('confirm_body'), currency)
  const atSpot = needsSpot(def, choice, mates)
  const ready = readyToRun(def, choice, say, mates, props.spot !== null)

  // A ROW OF A LIST WHOSE CHOICES CARRY A RARITY: the item, and on the right
  // its rarity in the rarity's color, tinted while Cloudscape highlights it.
  // Anything else (the trigger, a choice with no rarity) is Cloudscape's own.
  const rarityRow = (o: OptionDef): SelectProps.SelectOptionItemRenderer => ({ item }) => {
    if (item.type !== 'item') return null
    const r = rarityOf(o, item.option.value ?? '', props.rarities)
    if (!r) return null
    return (
      <div className="terminal-rarity-row"
        style={item.highlighted ? { backgroundColor: tint(r.hex, TINT_ALPHA) } : undefined}>
        <span className="terminal-rarity-item">{item.option.label}</span>
        <span className="terminal-rarity-tier" style={{ color: r.hex }}>{say(`rarity_${r.key}`)}</span>
      </div>
    )
  }

  const control = (o: OptionDef): ReactElement => {
    const value = valueOf(o, choice, mates)
    const items = orderedChoices(def, o, say, mates)
    const set = (v: string) => props.onChoice({ ...choice, [o.id]: v })
    if (o.dropdown) {
      const options: SelectProps.Option[] = items.map((c) => ({ value: c.value, label: c.label }))
      return (
        <Select
          selectedOption={options.find((c) => c.value === value) ?? null}
          options={options}
          disabled={!props.enabled}
          expandToViewport
          renderOption={o.rarity ? rarityRow(o) : undefined}
          onChange={({ detail }) => set(detail.selectedOption.value ?? '')}
        />
      )
    }
    return (
      <RadioGroup
        value={value}
        onChange={({ detail }) => set(detail.value)}
        items={items.map((c) => ({
          value: c.value,
          label: c.label,
          description: say(`${id}_opt_${o.id}_${c.value}_desc`) || undefined,
          disabled: !props.enabled,
        }))}
      />
    )
  }

  const parts: ReactElement[] = [<Box key="body">{body}</Box>]
  for (const o of boxOptions(def, choice, say)) {
    parts.push(
      <FormField key={o.id} label={say(`${id}_opt_${o.id}`)}>
        {control(o)}
      </FormField>,
    )
  }
  if (atSpot) {
    parts.push(
      <SpaceBetween key="pick" direction="horizontal" size="s" alignItems="center">
        {[
          <Button key="set" iconName="location-pin" disabled={!props.enabled} onClick={props.onPick}>
            {say('confirm_location')}
          </Button>,
          ...(props.spot ? [<Box key="place">{placeText(props.spot.at, props.spot.place)}</Box>] : []),
        ]}
      </SpaceBetween>,
    )
  }

  return (
    <Modal
      visible={props.visible}
      onDismiss={props.onCancel}
      closeAriaLabel={say('aria_close')}
      header={fill(say('confirm_title'), { name })}
      footer={
        <Box float="right">
          <SpaceBetween direction="horizontal" size="xs">
            {[
              <Button key="no" variant="link" onClick={props.onCancel}>{say('confirm_no')}</Button>,
              <Button key="yes" variant="primary" style={runStyle(def.risk)}
                disabled={!props.enabled || !ready}
                onClick={() => props.onRun(runChoices(def, choice, mates), atSpot && props.spot ? props.spot.at : null)}>
                {say('confirm_yes')}
              </Button>,
            ]}
          </SpaceBetween>
        </Box>
      }
    >
      <SpaceBetween size="m">{parts}</SpaceBetween>
    </Modal>
  )
}
