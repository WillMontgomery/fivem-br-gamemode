import { useEffect, useRef } from 'react'
import { subscribe } from './nui'
import type { Envelope, EnvelopeKind } from './types'

/** Payload type for a given envelope kind. */
type PayloadOf<K extends EnvelopeKind> = Extract<Envelope, { k: K }>['d']

/**
 * Subscribe to one envelope kind for the lifetime of a component.
 *
 * The handler is held in a ref so that passing an inline arrow function does not
 * resubscribe on every render -- otherwise every parent re-render would tear
 * down and rebuild the subscription, which is both wasteful and racy.
 */
export function useNuiEvent<K extends EnvelopeKind>(
  kind: K,
  handler: (data: PayloadOf<K>) => void,
): void {
  const ref = useRef(handler)
  ref.current = handler

  useEffect(() => {
    return subscribe(kind, (data) => {
      ref.current(data as PayloadOf<K>)
    })
  }, [kind])
}
