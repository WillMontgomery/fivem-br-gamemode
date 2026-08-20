/**
 * Where an artifact lives -- on the box for a moment, and in the bucket after.
 *
 * PURE, AND SEPARATE FROM index.js FOR ONE REASON: everything in this file is a
 * decision about a NAME, and every one of those names is a security boundary.
 * The key decides which IAM statement applies; the file name decides what the
 * sweeper is willing to delete; and both are built from values that arrived from
 * Lua. A path assembled by string concatenation from a caller-supplied id is the
 * oldest bug in this shape of program, so the assembly happens here, once, and
 * is unit-tested.
 *
 * NOTHING FROM LUA IS EVER USED AS A PATH. The game side passes an incident id,
 * a frame number and an encoding. It never passes a file name, a directory or a
 * key, and there is no verb that accepts one -- so there is no traversal to
 * defend against rather than a defence to get right.
 */

/**
 * THE PREFIX IS THE GRANT. The game box's policy is `s3:PutObject` on
 * `arn:aws:s3:::royale-incidents-bucket/incidents/*` and nothing else, so a key
 * that does not start here is refused by IAM rather than by us. It is written
 * once, and the assembly below is the only thing that writes it.
 */
export const ARTIFACT_PREFIX = 'incidents/'

/**
 * The most frames one incident can have: three timed plus six corroboration
 * (owner, 2026-08-20). The game enforces the cap -- br_lib/shared/artifact_plan
 * -- and this bounds the NAMESPACE, which is a different job: it is what makes
 * `incidents/<id>/01..09` a complete enumeration of a case, so a reader with
 * GetObject and no ListBucket can find every frame without being told.
 */
export const ARTIFACT_MAX_INDEX = 9

/**
 * What the game may ask for, and what S3 is told the bytes are.
 *
 * THE CONTENT TYPE IS NOT COSMETIC. These objects are fetched by a browser
 * through a presigned GET and rendered in an `<img>`; an object stored as
 * `application/octet-stream` is offered as a download instead of drawn, and that
 * failure looks exactly like a screenshot that was never taken. So the type is
 * derived from the encoding here rather than defaulted anywhere.
 *
 * `webp` IS THE ONE IN USE (owner, 2026-08-20). The other two are here because
 * `screenshot-basic` supports them and switching is meant to be a one-constant
 * change on the Lua side -- not because anything asks for them today.
 */
const CONTENT_TYPE = {
  webp: 'image/webp',
  jpg: 'image/jpeg',
  png: 'image/png',
}

/**
 * The ids this resource mints, and only those.
 *
 * `randomUUID()` is what `putIncident` names a case with, so a v4 UUID is the
 * complete set of ids that can legitimately reach these verbs. Matching the
 * exact shape rather than "some safe characters" means the key cannot contain a
 * slash, a dot-dot, a space or a control character by construction.
 */
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

/** Two digits, so 01..09 sorts as capture order in any listing that ever sees it. */
const pad2 = (n) => String(n).padStart(2, '0')

/**
 * Resolve one frame to the names it needs.
 *
 * ONE FUNCTION FOR THE KEY AND THE LOCAL FILE, because the two verbs must agree
 * about both: `artifactBegin` hands the file name to the game, and
 * `artifactPut` re-derives it from the same three values rather than being told
 * it. If they were built in two places, a change to one would silently upload
 * the wrong file or upload nothing.
 *
 * @param {unknown} incidentId
 * @param {unknown} index  1..ARTIFACT_MAX_INDEX
 * @param {unknown} encoding  'webp' | 'jpg' | 'png'
 * @returns {{ key: string, file: string, contentType: string } | { error: string }}
 */
export function artifactNames(incidentId, index, encoding) {
  const id = typeof incidentId === 'string' ? incidentId : ''
  if (!UUID_RE.test(id)) return { error: 'bad incidentId' }

  const n = Number(index)
  if (!Number.isInteger(n) || n < 1 || n > ARTIFACT_MAX_INDEX) {
    return { error: 'bad index' }
  }

  const ext = typeof encoding === 'string' ? encoding : ''
  const contentType = CONTENT_TYPE[ext]
  if (!contentType) return { error: 'bad encoding' }

  return {
    key: `${ARTIFACT_PREFIX}${id}/${pad2(n)}.${ext}`,
    // FLAT ON DISK, NESTED IN THE BUCKET. The spool holds a file for seconds and
    // is swept by pattern, so a directory per incident would be a directory per
    // incident to remove -- and an empty one left behind is a leak that grows
    // exactly as fast as the feature is used.
    file: `${id}-${pad2(n)}.${ext}`,
    contentType,
  }
}

/**
 * Is this a file the sweeper is allowed to delete?
 *
 * ASKED RATHER THAN ASSUMED, and this is the whole reason the sweeper is safe.
 * The spool directory comes from a convar; a typo could point it at something
 * that matters. Deleting only names this module could have produced means the
 * worst a mis-set convar can do is fill a directory, not empty one.
 *
 * @param {string} name  a bare file name, no directory
 * @returns {boolean}
 */
export function isSpoolFile(name) {
  if (typeof name !== 'string') return false
  const m = /^([0-9a-f-]{36})-(\d{2})\.([a-z]+)$/.exec(name)
  if (!m) return false
  const names = artifactNames(m[1], Number(m[2]), m[3])
  return !names.error && names.file === name
}
