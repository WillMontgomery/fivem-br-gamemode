-- Unit tests for the served-commit reader (br_lib/shared/gitref.lua).
--
-- WHAT IS WORTH TESTING HERE IS THE PARSE, because the box is where it runs and
-- the box is where a wrong answer is invisible. The lobby hex is dev-only and a
-- bad parse does not error: it shows a stale sha that looks exactly like a
-- right one, or shows nothing, which looks exactly like dev mode being off.
--
-- Git keeps HEAD three ways and a served clone can be in any of them over its
-- life. deploy.sh's symbolic-ref plus reset writes a LOOSE ref; an automatic gc
-- moves it into PACKED-REFS; a checkout by hand can leave HEAD DETACHED. Each is
-- a fake filesystem below, plus the UNREADABLE cases that must all come out nil.
--
-- NO REAL .git IS TOUCHED. Every case hands BR.GitRef a `read` function over a
-- table, so the suite runs the same on Windows and the box and spawns nothing.
-- The one io-backed function, readFile, is asked only about a file that exists
-- in this repository and one that does not.
--
-- Run via tools/verify.sh, or directly:  lua tools/test_gitref.lua

local realPrint = print

local chunk, err = loadfile('resources/[fivem-royale]/br_lib/shared/gitref.lua')
if not chunk then
    realPrint('\27[31mload error\27[0m gitref.lua: ' .. tostring(err))
    os.exit(1)
end
chunk()

-- ---------------------------------------------------------------- harness ---

local pass, fail = 0, 0
local group = ''

local function describe(name) group = name end

local function ok(cond, name, detail)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        realPrint(('\27[31mFAIL\27[0m %s > %s%s'):format(group, name,
            detail and ('\n       ' .. tostring(detail)) or ''))
    end
end

local function eq(got, want, name)
    ok(got == want, name, ('got %s, want %s'):format(tostring(got), tostring(want)))
end

--- A filesystem that is a table. `reads` records every path asked for, so a
--- case can prove a file was NOT opened as well as what came back.
local function fs(files)
    local reads = {}
    local function read(path)
        reads[#reads + 1] = path
        return files[path]
    end
    return read, reads
end

local function wasRead(reads, path)
    for _, p in ipairs(reads) do if p == path then return true end end
    return false
end

local G = BR.GitRef
local DIR = '/srv/.gamemode-src/.git'
local SHA  = 'a6cbdab0123456789abcdef0123456789abcdef0'
local SHA2 = '0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c'

-- =========================================================================
-- loose ref
-- =========================================================================

describe('gitref.loose')
do
    -- WHAT deploy.sh LEAVES: symbolic-ref HEAD, then reset --hard writes the
    -- branch's loose file. The trailing newline is git's; it is not part of HEAD.
    local read = fs({
        [DIR .. '/HEAD'] = 'ref: refs/heads/dev\n',
        [DIR .. '/refs/heads/dev'] = SHA .. '\n',
    })
    eq(G.resolve(DIR, read), SHA, 'a symbolic HEAD resolves through its loose ref')
    eq(G.short(G.resolve(DIR, read)), 'a6cbdab', 'and shortens to seven hex')

    -- A BRANCH WITH A SLASH IN IT is a directory under refs/heads, and the path
    -- is built from the name as written.
    read = fs({
        [DIR .. '/HEAD'] = 'ref: refs/heads/feature/commit-hex\n',
        [DIR .. '/refs/heads/feature/commit-hex'] = SHA2 .. '\n',
    })
    eq(G.resolve(DIR, read), SHA2, 'a feature/ branch resolves too')

    -- WINDOWS LINE ENDINGS, from a clone written on the dev box.
    read = fs({
        [DIR .. '/HEAD'] = 'ref: refs/heads/dev\r\n',
        [DIR .. '/refs/heads/dev'] = SHA .. '\r\n',
    })
    eq(G.resolve(DIR, read), SHA, 'CRLF on both files is still read')

    -- LOOSE OUTRANKS PACKED, which is git's rule: packed-refs holds what was
    -- packed, and a later reset writes a fresh loose file over the top of it.
    read = fs({
        [DIR .. '/HEAD'] = 'ref: refs/heads/dev\n',
        [DIR .. '/refs/heads/dev'] = SHA .. '\n',
        [DIR .. '/packed-refs'] = SHA2 .. ' refs/heads/dev\n',
    })
    eq(G.resolve(DIR, read), SHA, 'a loose ref beats a stale packed line for the same name')
end

-- =========================================================================
-- packed-refs
-- =========================================================================

describe('gitref.packed')
do
    -- WHAT A GC LEAVES: no loose file, and the branch as one row among others,
    -- under a header and beside a peeled tag line.
    local packed = table.concat({
        '# pack-refs with: peeled fully-peeled sorted ',
        SHA2 .. ' refs/heads/dev-old',
        SHA  .. ' refs/heads/dev',
        SHA2 .. ' refs/remotes/origin/dev',
        SHA2 .. ' refs/tags/v1',
        '^' .. SHA2,
        '',
    }, '\n')
    local read, reads = fs({
        [DIR .. '/HEAD'] = 'ref: refs/heads/dev\n',
        [DIR .. '/packed-refs'] = packed,
    })
    eq(G.resolve(DIR, read), SHA, 'a packed branch resolves by its exact name')
    ok(wasRead(reads, DIR .. '/refs/heads/dev'), 'and the loose file was tried first')

    -- A NAME THAT PREFIXES ANOTHER is not a match for it: dev is not dev-old,
    -- and the header and peeled lines are not rows.
    read = fs({
        [DIR .. '/HEAD'] = 'ref: refs/heads/dev\n',
        [DIR .. '/packed-refs'] = '# pack-refs with: peeled\n'
            .. SHA2 .. ' refs/heads/dev-old\n^' .. SHA .. '\n',
    })
    eq(G.resolve(DIR, read), nil, 'a longer name and a peeled line are never taken for it')

    read = fs({
        [DIR .. '/HEAD'] = 'ref: refs/heads/dev\r\n',
        [DIR .. '/packed-refs'] = '# pack-refs with: peeled\r\n' .. SHA .. ' refs/heads/dev\r\n',
    })
    eq(G.resolve(DIR, read), SHA, 'CRLF packed-refs is still read')
end

-- =========================================================================
-- detached HEAD
-- =========================================================================

describe('gitref.detached')
do
    local read, reads = fs({ [DIR .. '/HEAD'] = SHA .. '\n' })
    eq(G.resolve(DIR, read), SHA, 'a detached HEAD is its own sha')
    eq(#reads, 1, 'and nothing past HEAD is opened')

    -- Upper case is legal on disk and would print differently from deploy.sh.
    read = fs({ [DIR .. '/HEAD'] = SHA:upper() .. '\n' })
    eq(G.short(G.resolve(DIR, read)), 'a6cbdab', 'upper-case hex comes out lower case')

    -- SHA-256 repositories name objects in 64 hex.
    local long = SHA .. '012345678901234567890123'
    read = fs({ [DIR .. '/HEAD'] = long })
    eq(G.resolve(DIR, read), long, 'a 64-hex object name is a sha too')
end

-- =========================================================================
-- unreadable
-- =========================================================================

describe('gitref.unreadable')
do
    eq(G.resolve(DIR, fs({})), nil, 'no HEAD at all is nil')
    eq(G.resolve(nil, fs({})), nil, 'no directory is nil')
    eq(G.resolve('', fs({})), nil, 'an empty directory name is nil')

    eq(G.resolve(DIR, fs({ [DIR .. '/HEAD'] = 'ref: refs/heads/dev\n' })), nil,
        'a branch with neither a loose file nor a packed line is nil')

    eq(G.resolve(DIR, fs({ [DIR .. '/HEAD'] = '' })), nil, 'an empty HEAD is nil')
    eq(G.resolve(DIR, fs({ [DIR .. '/HEAD'] = 'not a head\n' })), nil, 'a garbage HEAD is nil')
    eq(G.resolve(DIR, fs({ [DIR .. '/HEAD'] = SHA:sub(1, 39) })), nil,
        'a truncated sha is not a detached HEAD')

    -- A LOOSE FILE MID-WRITE is broken, not a reason to trust an older packed line.
    eq(G.resolve(DIR, fs({
        [DIR .. '/HEAD'] = 'ref: refs/heads/dev\n',
        [DIR .. '/refs/heads/dev'] = '',
        [DIR .. '/packed-refs'] = SHA2 .. ' refs/heads/dev\n',
    })), nil, 'an empty loose ref is nil rather than a fall-through to packed-refs')

    -- THE REF BECOMES A PATH, so a name that climbs out is refused before any
    -- file is opened for it.
    local read, reads = fs({ [DIR .. '/HEAD'] = 'ref: refs/../../../etc/passwd\n' })
    eq(G.resolve(DIR, read), nil, 'a ref name with .. is refused')
    eq(#reads, 1, 'and nothing but HEAD was opened')
    eq(G.resolve(DIR, fs({ [DIR .. '/HEAD'] = 'ref: /etc/passwd\n' })), nil,
        'a ref outside refs/ is refused')

    -- A READER THAT THROWS costs that candidate and nothing else.
    eq(G.served('/srv/resources/[gamemodes]/[fivem-royale]/br_core',
        function() error('permission denied') end), nil,
        'a throwing reader is nil, not a traceback at resource start')

    eq(G.short('a6cbdab'), nil, 'short() will not shorten something that is not a sha')
    eq(G.short(nil), nil, 'or nil')
end

-- =========================================================================
-- where the clone is
-- =========================================================================

describe('gitref.served')
do
    -- THE BOX, as GetResourcePath answers there and deploy.sh lays it out.
    local RES = '/opt/fivem-server-classic/resources/[gamemodes]/[fivem-royale]/br_core'
    local ROOTDIR = '/opt/fivem-server-classic/.gamemode-src/.git'
    local read = fs({
        [ROOTDIR .. '/HEAD'] = 'ref: refs/heads/dev\n',
        [ROOTDIR .. '/refs/heads/dev'] = SHA .. '\n',
    })
    eq(G.served(RES, read), 'a6cbdab', 'the served clone beside resources/ is found')

    -- A ROOT THAT ITSELF LIVES UNDER A resources DIRECTORY. The last
    -- `/resources/` is the server's own.
    local NESTED = '/home/x/resources/fx/resources/[gamemodes]/[fivem-royale]/br_core'
    read = fs({
        ['/home/x/resources/fx/.gamemode-src/.git/HEAD'] = SHA2 .. '\n',
    })
    eq(G.served(NESTED, read), '0f1e2d3', 'the innermost resources/ is tried first')

    -- A WINDOWS DEV SERVER.
    read = fs({ ['C:/fx/.gamemode-src/.git/HEAD'] = SHA .. '\n' })
    eq(G.served('C:\\fx\\resources\\[gamemodes]\\[fivem-royale]\\br_core', read), 'a6cbdab',
        'backslash paths resolve the same way')

    -- NO RESOURCE PATH: the working directory is the server root under
    -- royale.service, so the relative clone is the last resort.
    read = fs({ ['.gamemode-src/.git/HEAD'] = SHA .. '\n' })
    eq(G.served(nil, read), 'a6cbdab', 'with no resource path the relative clone is read')
    eq(G.served('/opt/x/br_core', read), 'a6cbdab',
        'and a path with no resources/ in it falls back to it too')

    eq(G.served(RES, fs({})), nil, 'no clone anywhere is nil')

    local roots = G.roots(RES)
    eq(#roots, 1, 'one resources/ in the path is one candidate root')
    eq(roots[1], '/opt/fivem-server-classic', 'and it is the server root')
end

-- =========================================================================
-- the deploy stamp
-- =========================================================================

describe('gitref.stamp')
do
    local RES = '/opt/fivem-server-classic/resources/[gamemodes]/[fivem-royale]/br_core'
    local ROOTDIR = '/opt/fivem-server-classic/.gamemode-src/.git'

    -- WHAT deploy.sh WRITES into br_core after its rsync: `git rev-parse HEAD`
    -- and a newline.
    eq(G.STAMP, 'served-commit', 'the stamp has the name deploy.sh writes')
    eq(G.fromStamp(SHA .. '\n'), SHA, 'a stamp is its sha')
    eq(G.fromStamp(SHA:upper() .. '\r\n'), SHA, 'CRLF and upper case read as the same sha')
    eq(G.fromStamp('a6cbdab\n'), nil, 'a short hex is not a stamp')
    eq(G.fromStamp(''), nil, 'an empty stamp is nil')
    eq(G.fromStamp(nil), nil, 'no stamp is nil')

    -- THE STAMP WINS, AND NOTHING ELSE IS OPENED. It is the one source the
    -- sandbox lets the server read; a clone the sandbox refuses is not asked when
    -- the answer is already in hand.
    local read, reads = fs({})
    local hex, from = G.served(RES, read, SHA .. '\n')
    eq(hex, 'a6cbdab', 'a stamp answers the served commit')
    eq(from, 'served-commit', 'and says it came from the stamp')
    eq(#reads, 0, 'without a single file read')

    -- A GARBLED STAMP falls through to the clone rather than printing garbage.
    read = fs({ [ROOTDIR .. '/HEAD'] = SHA2 .. '\n' })
    hex, from = G.served(RES, read, 'not a sha\n')
    eq(hex, '0f1e2d3', 'a stamp that is not a sha falls through to the clone')
    eq(from, ROOTDIR, 'and names the .git that answered')
end

-- =========================================================================
-- the sandbox, and the reasons the console prints
-- =========================================================================

describe('gitref.sandbox')
do
    local RES = '/opt/fivem-server-classic/resources/[gamemodes]/[fivem-royale]/br_core'
    local ROOTDIR = '/opt/fivem-server-classic/.gamemode-src/.git'

    -- THE DEV BOX AS IT WAS: no stamp, and every path in the server root answered
    -- the way FXServer's Lua sandbox answers io.open there. Nothing resolves, and
    -- the reason is the whole diagnosis -- the stamp, then each path, then io's
    -- own words for each.
    local function denied(path) return nil, path .. ': Permission denied' end
    local hex, why = G.served(RES, denied, nil)
    eq(hex, nil, 'no stamp and a refused clone is nil')
    eq(why, 'served-commit missing; '
        .. ROOTDIR .. '/HEAD: Permission denied; '
        .. '.gamemode-src/.git/HEAD: Permission denied',
        'and the reason names the stamp and every path the sandbox refused')

    -- A READER THAT GIVES NO REASON still leaves the path it could not read.
    hex, why = G.served(nil, fs({}), nil)
    eq(why, 'served-commit missing; .gamemode-src/.git/HEAD: unreadable',
        'a reader with no message still names the path')

    -- A THROWING READER costs its candidate, and says what it threw.
    hex, why = G.served(RES, function() error('boom', 0) end, nil)
    eq(hex, nil, 'a throwing reader is nil')
    ok(type(why) == 'string' and why:find(ROOTDIR .. ': boom', 1, true) ~= nil,
        'and the reason carries what it threw, beside the path', why)

    -- resolve's own reasons, one per way a HEAD can fail to become a sha.
    local _, r = G.resolve(DIR, fs({ [DIR .. '/HEAD'] = 'ref: refs/heads/dev\n' }))
    eq(r, DIR .. '/HEAD: refs/heads/dev has no sha, loose or packed',
        'a branch with no sha says which branch')
    _, r = G.resolve(DIR, fs({ [DIR .. '/HEAD'] = 'not a head\n' }))
    eq(r, DIR .. '/HEAD: not a sha or a ref this will open', 'a garbage HEAD says so')
    _, r = G.resolve(DIR, fs({
        [DIR .. '/HEAD'] = 'ref: refs/heads/dev\n',
        [DIR .. '/refs/heads/dev'] = '',
    }))
    eq(r, DIR .. '/refs/heads/dev: not a sha', 'a broken loose ref names its file')
end

-- =========================================================================
-- the one io-backed function
-- =========================================================================

describe('gitref.readFile')
do
    local body = G.readFile('tools/test_gitref.lua')
    ok(type(body) == 'string' and body:find('gitref.readFile', 1, true) ~= nil,
        'an existing file comes back whole')
    local missing, msg = G.readFile('tools/no-such-dir/HEAD')
    eq(missing, nil, 'a missing file is nil, not an error')
    ok(type(msg) == 'string' and msg:find('no-such-dir', 1, true) ~= nil,
        "and io's own message comes with it, path included", msg)
end

-- ------------------------------------------------------------------ done ---

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
