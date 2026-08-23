--[[
    br_ddb bundle fingerprint -- read once at boot, published, inert thereafter.

    dist/fingerprint.json is written by tools/br_ddb_fingerprint.sh and records
    which js-src/br_ddb source tree the committed dist/server.js was recorded
    against. tools/verify.sh checks it before a commit ever lands; this file
    makes the same fact readable on a RUNNING box, so that what a server is
    actually executing can be reported instead of assumed. Deploys rsync the
    resource whole, so the manifest travels with the bundle it describes.

    THIS GATES NOTHING. It does not refuse to start, does not compare anything,
    does not print and does not register a command. A missing, empty or
    unparseable manifest leaves the value nil, and nil is the honest answer --
    "this box cannot say" -- not an error worth taking a server down for.

    WHAT THE VALUE MEANS is exactly what tools/br_ddb_fingerprint.sh says it
    means, and no more:

      * it says the bundle corresponds to that source tree,
      * NOT that the bundle is correct -- nothing here or there compiles or
        reads a line of it,
      * and NOT that either file is untampered. Whoever can replace the bundle
        can replace this manifest sitting beside it in the same directory. It
        detects a forgotten rebuild. It is not a security property and must not
        be reported as one.

    A STATE BAG RATHER THAN AN EXPORT, deliberately. The moment this value is
    most interesting is the moment br_ddb is unhealthy, and calling an export on
    a resource that failed to start raises; reading a state bag that was never
    set returns nil. The reader wants an answer or a silence, not a stack trace.

      local fp = GlobalState.brDdbBundle
      -- nil, or { scheme=, source=, bundle=, bundleBytes=, files= }

    NOT REPLICATED. Build metadata is for the server and the console; game
    clients have no use for it and no business holding it.
]]

local function readManifest()
    local raw = LoadResourceFile(GetCurrentResourceName(), 'dist/fingerprint.json')
    if type(raw) ~= 'string' or raw == '' then return nil end

    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= 'table' then return nil end

    -- A manifest with no source hash is not a manifest. Publishing a half one
    -- would be worse than publishing nothing: a reader would show a blank
    -- fingerprint as though the box had answered.
    if type(decoded.source) ~= 'string' or decoded.source == '' then return nil end

    return {
        scheme      = decoded.scheme,
        source      = decoded.source,
        bundle      = decoded.bundle,
        bundleBytes = decoded.bundleBytes,
        files       = decoded.files,
    }
end

GlobalState:set('brDdbBundle', readManifest(), false)
