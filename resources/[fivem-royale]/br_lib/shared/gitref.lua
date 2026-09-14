-- Which commit this box is serving.
--
-- ═══ THE GAME SERVER CANNOT READ THE SERVED CLONE ═══
--
-- tools/deploy.sh hard-resets a clone at $SERVER_ROOT/.gamemode-src and rsyncs
-- resources out of it with .git excluded, so the resources the server actually
-- loads carry no trace of the commit they came from. The first version of this
-- file read the clone's .git/HEAD with io.open, and on the dev box it drew
-- nothing: FXServer's Lua sandbox refuses io "in the server main folder" and
-- "outside resource folders", with error 13, Permission denied, and rejects `..`
-- and symlinks (docs.fivem.net/docs/developers/sandbox). $SERVER_ROOT/.gamemode-src
-- is exactly that path. Every test passed, because every test handed it a table
-- for a filesystem.
--
-- SO deploy.sh WRITES A STAMP INSIDE A RESOURCE. After its rsync it puts the full
-- sha in br_core/served-commit, and server/lobby.lua reads that with
-- LoadResourceFile, which reads inside the resource and is what the sandbox
-- permits. The rsync's --delete removes the stamp on every deploy, so a deploy
-- that dies before writing it leaves none rather than a stale one.
--
-- THE STAMP ARRIVES WITH deploy.sh, AND deploy.sh RUNS FROM THE OPS CHECKOUT.
-- royale-deploy.service runs /opt/misc/fivem-br-gamemode/tools/deploy.sh, which
-- tracks main and is pulled by hand, so a box deployed by an older deploy.sh has
-- no stamp. The git read below stays as the fallback for a server the sandbox
-- does not cover, and the boot banner says which answer it got, or why none.
--
-- ═══ EVERY FAILURE IS nil, AND nil DRAWS NOTHING ═══
--
-- This is a dev-mode convenience under a lobby button. A missing stamp, a ref
-- name this file declines to turn into a path, an io library the runtime
-- withheld or refused, a HEAD naming a branch with no sha anywhere: all of them
-- answer nil, and the lobby shows no hex rather than a wrong one or a traceback
-- at resource start. The second return value is the reason, for the console.
--
-- PURE BUT FOR ONE FUNCTION. Everything takes a `read(path) -> string|nil, err`,
-- so tools/test_gitref.lua can hand it a fake filesystem, and the stamp arrives
-- as a string the caller already read. Only BR.GitRef.readFile touches io, and it
-- is the default.
--
-- SERVER-ONLY despite living in shared/, like evidence_buf.lua: a client has no
-- filesystem to read and is told the answer on LOBBY_STATUS instead.

BR = BR or {}
BR.GitRef = BR.GitRef or {}

--- The stamp deploy.sh writes into br_core after its rsync: the full sha and a
--- newline. Read with LoadResourceFile(resource, BR.GitRef.STAMP).
BR.GitRef.STAMP = 'served-commit'

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

--- The sha in a stamp's contents, lower case, or nil.
---
--- A WHOLE SHA OR NOTHING. deploy.sh writes `git rev-parse HEAD`, so anything
--- else in the file is a partial write or a hand edit, and a short or garbled
--- value would print a hex that looks right and is not.
--- @param body any
--- @return string|nil
function BR.GitRef.fromStamp(body)
    if type(body) ~= 'string' then return nil end
    body = trim(body)
    return BR.GitRef.isSha(body) and body:lower() or nil
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

--- The sha a git directory's HEAD resolves to, or nil and the reason.
---
--- GIT'S OWN ORDER: a detached HEAD is the sha itself; a symbolic HEAD names a
--- ref, and the loose file for that ref outranks packed-refs, which only holds
--- what `git pack-refs` or a gc moved out of refs/.
---
--- A LOOSE FILE THAT EXISTS AND IS NOT A SHA IS nil, NOT A FALL-THROUGH. Git
--- would call that ref broken rather than consult packed-refs, and the packed
--- line, if there is one, is older than whatever was being written.
---
--- THE REASON FOR AN UNREADABLE HEAD IS THE READER'S OWN when it gives one, which
--- for io.open is "<path>: Permission denied" under the sandbox. That string is
--- the whole diagnosis, so it is passed through rather than paraphrased.
--- @param gitDir string  the .git directory, no trailing slash
--- @param read function|nil  (path) -> string|nil, err; BR.GitRef.readFile by default
--- @return string|nil sha
--- @return string|nil why
function BR.GitRef.resolve(gitDir, read)
    if type(gitDir) ~= 'string' or gitDir == '' then return nil, 'no git directory' end
    read = read or BR.GitRef.readFile

    local headPath = gitDir .. '/HEAD'
    local head, err = read(headPath)
    if type(head) ~= 'string' then
        return nil, (type(err) == 'string' and err ~= '') and err or (headPath .. ': unreadable')
    end
    head = trim(head)

    if BR.GitRef.isSha(head) then return head:lower() end

    local ref = head:match('^ref:%s*(%S+)$')
    if not safeRef(ref) then return nil, headPath .. ': not a sha or a ref this will open' end

    local loose = read(gitDir .. '/' .. ref)
    if type(loose) == 'string' then
        loose = trim(loose)
        if BR.GitRef.isSha(loose) then return loose:lower() end
        return nil, gitDir .. '/' .. ref .. ': not a sha'
    end

    -- Header (`# pack-refs with: ...`) and peeled (`^<sha>`) lines match neither
    -- capture, so only `<sha> <name>` rows are compared. CR is split on as well:
    -- a clone written on Windows ends its lines with it.
    local packed = read(gitDir .. '/packed-refs')
    if type(packed) == 'string' then
        for line in packed:gmatch('[^\r\n]+') do
            local sha, name = line:match('^(%x+) (%S+)%s*$')
            if name == ref and BR.GitRef.isSha(sha) then return sha:lower() end
        end
    end
    return nil, headPath .. ': ' .. ref .. ' has no sha, loose or packed'
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

--- The short hex of the commit this box is serving, and where it came from; or
--- nil, and every reason nothing did.
---
--- THE STAMP FIRST, because it is the one source the sandbox lets the server
--- read. Then each root GetResourcePath implies, and then `.gamemode-src`
--- relative to the working directory, which royale.service sets to the server
--- root. The first that resolves wins. Each git attempt runs under pcall, so a
--- reader that throws costs that candidate and nothing else.
---
--- The second value on success is BR.GitRef.STAMP or the .git directory that
--- answered; on failure it is the reasons joined with "; ", one per source, in
--- the order they were tried.
--- @param resourcePath string|nil
--- @param read function|nil
--- @param stamp string|nil  the stamp's contents, or nil when there is none
--- @return string|nil hex
--- @return string from_or_why
function BR.GitRef.served(resourcePath, read, stamp)
    local stamped = BR.GitRef.fromStamp(stamp)
    if stamped then return BR.GitRef.short(stamped), BR.GitRef.STAMP end

    local why = {
        BR.GitRef.STAMP .. (stamp == nil and ' missing' or ' is not a sha'),
    }

    read = read or BR.GitRef.readFile
    local dirs = {}
    for _, root in ipairs(BR.GitRef.roots(resourcePath)) do
        dirs[#dirs + 1] = root .. '/' .. SRC .. '/.git'
    end
    dirs[#dirs + 1] = SRC .. '/.git'

    for _, dir in ipairs(dirs) do
        local okResolve, sha, reason = pcall(BR.GitRef.resolve, dir, read)
        if okResolve and sha then return BR.GitRef.short(sha), dir end
        if okResolve then
            why[#why + 1] = reason or (dir .. ': unreadable')
        else
            why[#why + 1] = dir .. ': ' .. tostring(sha)
        end
    end
    return nil, table.concat(why, '; ')
end

--- The default reader: a whole file, or nil and io's own message.
--- @param path string
--- @return string|nil body
--- @return string|nil err
function BR.GitRef.readFile(path)
    if type(io) ~= 'table' or type(io.open) ~= 'function' then
        return nil, 'no io library in this runtime'
    end
    local okOpen, fh, openErr = pcall(io.open, path, 'rb')
    if not okOpen then return nil, tostring(fh) end
    if not fh then return nil, openErr and tostring(openErr) or (path .. ': unreadable') end
    local okRead, body = pcall(fh.read, fh, '*a')
    pcall(fh.close, fh)
    if not okRead or type(body) ~= 'string' then return nil, path .. ': unreadable' end
    return body
end
