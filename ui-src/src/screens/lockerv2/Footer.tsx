import Button from '@cloudscape-design/components/button'
import ButtonDropdown from '@cloudscape-design/components/button-dropdown'
import SpaceBetween from '@cloudscape-design/components/space-between'
import { BTN, updateLabel } from './copy'
import type { SaveVariant } from './model'

/**
 * SAVE (#28): "If they're not editing a saved ped, but they have at least one
 * saved ped, the "Save" button should be a dropdown button which allows them to
 * create new or replace existing. Upon clicking "Save" for any new ped
 * creation, we should prompt them to name the ped." And, editing a saved ped:
 * "please show a dropdwon for that one and default it to update existing"
 * (owner). The shape is model.ts's saveVariant; this only draws it.
 *
 * THE MENU OPENS INSIDE THE ISLAND (expandToViewport false), never portalled
 * to <body>: it is placed from boxes measured in the island's zoomed px, and
 * the island's own `overflow: hidden` is the bound it measures against.
 */
function SaveButton({ v, busy, onName, onUpdate, onReplace }: {
  v: SaveVariant
  busy: boolean
  onName: () => void
  onUpdate: (id: string) => void
  onReplace: (id: string) => void
}) {
  const disabled = !v.enabled || busy
  if (v.kind === 'plain') {
    return <Button variant="primary" disabled={disabled} onClick={onName}>{BTN.save}</Button>
  }
  if (v.kind === 'menu') {
    return (
      <ButtonDropdown
        variant="primary"
        disabled={disabled}
        expandToViewport={false}
        items={[
          { id: 'new', text: BTN.createNew },
          { text: BTN.replaceExisting, items: v.replace.map((p) => ({ id: `r:${p.id}`, text: p.name })) },
        ]}
        onItemClick={({ detail }) => {
          if (detail.id === 'new') onName()
          else if (detail.id.startsWith('r:')) onReplace(detail.id.slice(2))
        }}
      >
        {BTN.save}
      </ButtonDropdown>
    )
  }
  return (
    <ButtonDropdown
      variant="primary"
      disabled={disabled}
      expandToViewport={false}
      ariaLabel={BTN.save}
      mainAction={{ text: BTN.save, disabled, onClick: () => onUpdate(v.id) }}
      items={[
        { id: 'update', text: updateLabel(v.name) },
        { id: 'new', text: BTN.saveAsNew },
      ]}
      onItemClick={({ detail }) => {
        if (detail.id === 'update') onUpdate(v.id)
        else if (detail.id === 'new') onName()
      }}
    />
  )
}

/**
 * THE PINNED FOOTER (contract section 5): Done where Season 1's sits, and on
 * the Custom tabs Reset and Save beside it -- "a pinned "Save" and "Reset" at
 * the bottom, in the same vertical position as our current "back" button"
 * (owner, #28).
 *
 * DONE'S TUTORIAL ANCHOR STEPS OUT OF THE ZOOM. The guided first run draws its
 * ring from `[data-tut="locker-done"]`'s box, and on CEF 103 a box inside a
 * zoomed element is reported in that element's px. So the anchor wears 1/z
 * inside the island -- a true zoom of 1 -- and the button inside it wears z
 * again, which draws it exactly as everything around it.
 */
export function Footer({ z, custom, dirty, busy, save, onDone, onReset, onName, onUpdate, onReplace }: {
  z: number
  custom: boolean
  dirty: boolean
  busy: boolean
  save: SaveVariant
  onDone: () => void
  onReset: () => void
  onName: () => void
  onUpdate: (id: string) => void
  onReplace: (id: string) => void
}) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', justifyContent: 'space-between',
      gap: '1em', paddingTop: '1.5em', flex: '0 0 auto',
    }}>
      <span data-tut="locker-done" style={{ display: 'inline-block', zoom: 1 / z }}>
        <span style={{ display: 'inline-block', zoom: z }}>
          <Button variant={custom ? 'normal' : 'primary'} onClick={onDone}>{BTN.done}</Button>
        </span>
      </span>
      {custom && (
        <SpaceBetween direction="horizontal" size="xs">
          <Button disabled={!dirty || busy} onClick={onReset}>{BTN.reset}</Button>
          <SaveButton v={save} busy={busy} onName={onName} onUpdate={onUpdate} onReplace={onReplace} />
        </SpaceBetween>
      )}
    </div>
  )
}
