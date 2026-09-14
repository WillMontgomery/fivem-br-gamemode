-- Which commit this box is serving, read out of the served clone's git metadata.
--
-- ═══ WHY IT READS FILES INSTEAD OF ASKING GIT ═══
--
-- tools/deploy.sh hard-resets a clone at $SERVER_ROOT/.gamemode-src and rsyncs
-- resources out of it with .git excluded, so the resources the server actually
-- loads carry no trace of the commit they came from. The clone still does, and
-- the three files git itself consults to answer "what is HEAD" are plain text:
-- .git/HEAD, the loose ref it names, and packed-refs. Reading them is a few lines
-- of Lua. Asking git instead would be io.popen -- a process spawned from inside
-- the game server on every boot, and one more way to fail without saying so.
--
-- NEITHER deploy.sh NOR dispatch.sh CHANGED FOR THIS. The deploy script runs from
-- a separate clone that tracks main, and dispatch.sh is bound by the
-- branch-switch invariant (docs/branch-switch.md), so a stamp file written at
-- deploy time would reach the boxes one main merge late. The metadata is already
-- on disk and is exactly as fresh as the tree the resources were synced from.
--
-- ═══ EVERY FAILURE IS nil, AND nil DRAWS NOTHING ═══
--
-- This is a dev-mode convenience under a lobby button. A server run straight
-- from a checkout, a ref name this file declines to turn into a path, an io
-- library the runtime withheld, a HEAD naming a branch with no sha anywhere: all
-- of them answer nil, and the lobby shows no hex rather than a wrong one or a
-- traceback at resource start.
--
-- PURE BUT FOR ONE FUNCTION. Everything takes a `read(path) -> string|nil`, so
-- tools/test_gitref.lua can hand it a fake filesystem. Only BR.GitRef.readFile
-- touches io, and it is the default.
--
-- SERVER-ONLY despite living in shared/, like evidence_buf.lua: a client has no
-- filesystem to read and is told the answer on LOBBY_STATUS instead.

BR = BR or {}
BR.GitRef = BR.GitRef or {}

--- deploy.sh's SRC_DIR, relative to the server root. BR_SRC_DIR can move it for
--- the deploy script, but nothing sets that on either box and the game server
--- cannot see the deploy unit's environment anyway.
local SRC = '.gamemode-src'

--- `git rev-parse --short` length, which is what deploy.sh prints as "commit".
local SHORT = 7

--- @param s string @return string
local function trim(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

--- Is this a whole object name? 40 hex for SHA-1, 64 for SHA-256.
--- @param s any
--- @return boolean
function BR.GitRef.isSha(s)
    if type(s) ~= 'string' then return false end
    return (#s == 40 or #s == 64) and s:match('^%x+$') ~= nil
end

--- The short form, lower case, or nil for anything that is not a whole sha.
--- @param sha any
--- @return string|nil
function BR.GitRef.short(sha)
    if not BR.GitRef.isSha(sha) then return nil end
    return sha:sub(1, SHORT):lower()
end

--- A ref name HEAD may point at, before it is joined onto a path.
---
--- ONLY UNDER refs/, ONLY PLAIN CHARACTERS, NEVER `..`. The name comes out of a
--- file and becomes part of a path this process opens, so it is held to the
--- shape dispatch.sh's branch names already have rather than to everything git
--- would accept. A branch outside that shape shows no hex, which is the failure
--- this whole file is allowed to have.
--- @param ref any
--- @return boolean
local function safeRef(ref)
    if type(ref) ~= 'string' or ref:sub(1, 5) ~= 'refs/' then return false end
    if ref:find('..', 1, true) then return false end
    return ref:match('^[%w%-%._/]+$') ~= nil
end

--- The sha a git directory's HEAD resolves to, or nil.
---
--- GIT'S OWN ORDER: a detached HEAD is the sha itself; a symbolic HEAD names a
--- ref, and the loose file for that ref outranks packed-refs, which only holds
--- what `git pack-refs` or a gc moved out of refs/.
---
--- A LOOSE FILE THAT EXISTS AND IS NOT A SHA IS nil, NOT A FALL-THROUGH. Git
--- would call that ref broken rather than consult packed-refs, and the packed
--- line, if there is one, is older than whatever was being written.
--- @param gitDir string  the .git directory, no trailing slash
--- @param read function|nil  (path) -> string|nil; BR.GitRef.readFile by default
--- @return string|nil
function BR.GitRef.resolve(gitDir, read)
    if type(gitDir) ~= 'string' or gitDir == '' then return nil end
    read = read or BR.GitRef.readFile

    local head = read(gitDir .. '/HEAD')
    if type(head) ~= 'string' then return nil end
    head = trim(head)

    if BR.GitRef.isSha(head) then return head:lower() end

    local ref = head:match('^ref:%s*(%S+)$')
    if not safeRef(ref) then return nil end

    local loose = read(gitDir .. '/' .. ref)
    if type(loose) == 'string' then
        loose = trim(loose)
        return BR.GitRef.isSha(loose) and loose:lower() or nil
    end

    -- Header (`# pack-refs with: ...`) and peeled (`^<sha>`) lines match neither
    -- capture, so only `<sha> <name>` rows are compared. CR is split on as well:
    -- a clone written on Windows ends its lines with it.
    local packed = read(gitDir .. '/packed-refs')
    if type(packed) ~= 'string' then return nil end
    for line in packed:gmatch('[^\r\n]+') do
        local sha, name = line:match('^(%x+) (%S+)%s*$')
        if name == ref and BR.GitRef.isSha(sha) then return sha:lower() end
    end
    return nil
end

--- Where the server root might be, given this resource's own path.
---
--- GetResourcePath answers something like
--- /opt/fivem-server-classic/resources/[gamemodes]/[fivem-royale]/br_core, and
--- the root is everything before `/resources/`. LAST OCCURRENCE FIRST: a root
--- that itself sits under a directory called resources is possible, a category
--- called that is not -- ours are all bracketed. Backslashes are normalized so a
--- Windows dev server takes the same path through.
--- @param resourcePath any
--- @return string[]
function BR.GitRef.roots(resourcePath)
    local out = {}
    if type(resourcePath) ~= 'string' or resourcePath == '' then return out end
    local p = resourcePath:gsub('\\', '/')
    local at, from = {}, 1
    while true do
        local s = p:find('/resources/', from, true)
        if not s then break end
        at[#at + 1] = s
        from = s + 1
    end
    for k = #at, 1, -1 do out[#out + 1] = p:sub(1, at[k] - 1) end
    return out
end

--- The short hex of the commit the served clone is on, or nil.
---
--- Each root GetResourcePath implies is tried, and then `.gamemode-src` relative
--- to the working directory, which royale.service sets to the server root. The
--- first that resolves wins. Each attempt runs under pcall, so a reader that
--- throws costs that candidate and nothing else.
--- @param resourcePath string|nil
--- @param read function|nil
--- @return string|nil
function BR.GitRef.served(resourcePath, read)
    read = read or BR.GitRef.readFile
    local dirs = {}
    for _, root in ipairs(BR.GitRef.roots(resourcePath)) do
        dirs[#dirs + 1] = root .. '/' .. SRC .. '/.git'
    end
    dirs[#dirs + 1] = SRC .. '/.git'

    for _, dir in ipairs(dirs) do
        local okResolve, sha = pcall(BR.GitRef.resolve, dir, read)
        if okResolve and sha then return BR.GitRef.short(sha) end
    end
    return nil
end

--- The default reader: a whole file, or nil for any reason at all.
--- @param path string
--- @return string|nil
function BR.GitRef.readFile(path)
    if type(io) ~= 'table' or type(io.open) ~= 'function' then return nil end
    local okOpen, fh = pcall(io.open, path, 'rb')
    if not okOpen or not fh then return nil end
    local okRead, body = pcall(fh.read, fh, '*a')
    pcall(fh.close, fh)
    if not okRead or type(body) ~= 'string' then return nil end
    return body
end
