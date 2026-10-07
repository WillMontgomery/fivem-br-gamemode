import { useCallback, useEffect, useRef, useState } from 'react'
import Box from '@cloudscape-design/components/box'
import Button from '@cloudscape-design/components/button'
import Input, { type InputProps } from '@cloudscape-design/components/input'
import Modal from '@cloudscape-design/components/modal'
import SpaceBetween from '@cloudscape-design/components/space-between'
import { BTN, MODAL, deleteTitle, replaceTitle } from './copy'
import { filterName, nameOk } from './model'

/** The one dialog that can be up, and what it is about. */
export type ModalState =
  /** Name a new ped: "Upon clicking "Save" for any new ped creation, we should
   *  prompt them to name the ped" (owner, #28). */
  | { kind: 'name' }
  | { kind: 'rename'; id: string; name: string }
  /** "Replace existing should confirm before overwriting yes" (owner, #28). */
  | { kind: 'replace'; id: string; name: string }
  | { kind: 'delete'; id: string; name: string }
  /** "Clicking "back" should prompt the user about unsaved changes" (owner). */
  | { kind: 'discard' }

/**
 * LOCKER V2'S DIALOGS (#28), one at a time, rendered into the island.
 *
 * INTO THE ISLAND, NOT <body> (contract section 5, getModalRoot): there they
 * wear the island's zoom and theme and fade with the page. They take no NUI
 * focus of their own -- the locker already holds it -- and Escape closes the
 * dialog alone (LockerV2.tsx's key handler), never the screen behind it.
 */
export function LockerModal({ modal, root, onClose, onConfirm }: {
  modal: ModalState | null
  root: HTMLElement | null
  onClose: () => void
  /** The dialog's confirm, with the name typed when it asks for one. */
  onConfirm: (m: ModalState, name: string) => void
}) {
  const [name, setName] = useState('')
  const input = useRef<InputProps.Ref>(null)
  useEffect(() => {
    if (!modal) return
    setName(modal.kind === 'rename' ? filterName(modal.name) : '')
    if (modal.kind !== 'name' && modal.kind !== 'rename') return
    // THE NAME BOX TAKES THE KEYBOARD. The dialog's own focus trap puts focus
    // on its first control as it opens, which is its close button -- so a
    // name typed straight away went nowhere and Enter closed the dialog. Once
    // the trap has settled, the box takes it back, the old name selected.
    const t = window.setTimeout(() => {
      input.current?.focus()
      input.current?.select()
    }, 80)
    return () => window.clearTimeout(t)
  }, [modal])
  // The dialog keeps its words while it fades out, rather than emptying the
  // moment it is dismissed.
  const last = useRef<ModalState | null>(modal)
  if (modal) last.current = modal
  const m = last.current

  const getRoot = useCallback(async () => {
    if (!root) throw new Error('locker modal root missing')
    return root
  }, [root])
  const keepRoot = useCallback(() => { /* the island owns it */ }, [])

  if (!root) return null

  const asksName = m?.kind === 'name' || m?.kind === 'rename'
  const ready = !asksName || nameOk(name)
  const confirm = () => {
    if (!modal || !ready) return
    onConfirm(modal, name)
  }

  let title = ''
  let ok = ''
  let cancel: string = BTN.cancel
  switch (m?.kind) {
    case 'name': title = MODAL.name; ok = BTN.save; break
    case 'rename': title = MODAL.rename; ok = BTN.rename; break
    case 'replace': title = replaceTitle(m.name); ok = BTN.replace; break
    case 'delete': title = deleteTitle(m.name); ok = BTN.delete; break
    case 'discard': title = MODAL.discard; ok = BTN.discard; cancel = BTN.keepEditing; break
    default: break
  }

  return (
    <Modal
      visible={modal !== null}
      onDismiss={onClose}
      getModalRoot={getRoot}
      removeModalRoot={keepRoot}
      closeAriaLabel={cancel}
      size="small"
      disableContentPaddings={!asksName}
      header={title}
      footer={(
        <Box float="right">
          <SpaceBetween direction="horizontal" size="xs">
            <Button variant="link" onClick={onClose}>{cancel}</Button>
            <Button variant="primary" disabled={!ready} onClick={confirm}>{ok}</Button>
          </SpaceBetween>
        </Box>
      )}
    >
      {asksName && (
        <Input
          ref={input}
          value={name}
          autoFocus
          ariaLabel={title}
          onChange={({ detail }) => setName(filterName(detail.value))}
          onKeyDown={({ detail }) => { if (detail.key === 'Enter') confirm() }}
        />
      )}
    </Modal>
  )
}
