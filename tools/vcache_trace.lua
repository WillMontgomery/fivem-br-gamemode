-- tools/vcache_trace.lua -- runs one Lua suite or gate and writes down what it
-- READ, for verify.sh's pass cache (tools/vcache.py, docs/testing.md).
--
--   lua tools/vcache_trace.lua <trace-file> <script> [args...]
--
-- The script runs exactly as `lua <script> [args...]` would: the same `arg`
-- table, the same `...`, the same exit status. Before it loads, the ways a Lua
-- script can reach the disk or the machine are wrapped, and each one notes what
-- it touched:
--
--   io.open, io.lines, io.input   a path read (or, opened for writing, a path
--                                 this run produced, whose later reads are not
--                                 inputs)
--   dofile, loadfile              a path read
--   require                       every package.path / package.cpath candidate
--                                 up to the one that loaded, so a new file that
--                                 would shadow it later is a change
--   io.popen                      the command, its exit code and its output
--                                 (vcache.py runs it again to compare)
--   os.getenv                     the variable and whether/what it was
--   os.execute, popen for writing a command whose effect cannot be compared:
--                                 the run is marked uncacheable
--   os.remove, os.rename,         paths this run produced or consumed
--   os.tmpname, io.output
--
-- For each path the FIRST read records whether it existed and its size; the
-- hash is taken afterwards by vcache.py commit, which refuses the entry if the
-- file now differs in existence or size or was modified after the suite
-- started. A failed suite never gets that far: the trace's last line is written
-- only when the script finished, and verify.sh commits only a zero exit.
--
-- THIS FILE IS PART OF EVERY CACHE KEY. Editing it invalidates every entry.

local TRACE, SCRIPT = arg[1], arg[2]
if not TRACE or not SCRIPT then
    io.stderr:write('usage: lua tools/vcache_trace.lua <trace-file> <script> [args...]\n')
    os.exit(2)
end

local real = {
    open = io.open, lines = io.lines, input = io.input, output = io.output,
    popen = io.popen, dofile = dofile, loadfile = loadfile, require = require,
    getenv = os.getenv, execute = os.execute, exit = os.exit,
    remove = os.remove, rename = os.rename, tmpname = os.tmpname,
}
local type, tostring, select, concat = type, tostring, select, table.concat

local events = {}           -- trace lines, in order
local seenRaw = {}          -- raw path string -> true (fast path, no allocation)
local seen = {}             -- normalized path -> true
local produced = {}         -- normalized path -> true: written or created by this run
local envSeen = {}
local nCmd = 0

local function esc(s)
    return (tostring(s):gsub('[%%\t\r\n]', function(c)
        return ('%%%02X'):format(c:byte())
    end))
end

-- Repo-relative paths stay relative (verify.sh runs from the root); `\` is `/`;
-- `.` and `x/..` segments fold, so the same file read two ways is one input.
local function norm(p)
    p = p:gsub('\\', '/')
    local abs, rest = p:match('^(%a:/)(.*)$')
    if not abs then
        abs, rest = p:match('^(/)(.*)$')
    end
    if not abs then abs, rest = '', p end
    local out = {}
    for seg in rest:gmatch('[^/]+') do
        if seg == '..' then
            if #out > 0 and out[#out] ~= '..' then
                out[#out] = nil
            else
                out[#out + 1] = seg
            end
        elseif seg ~= '.' then
            out[#out + 1] = seg
        end
    end
    return abs .. concat(out, '/')
end

local function mark(p)
    if type(p) ~= 'string' then return end
    produced[norm(p)] = true
end

-- The first read of a path: did it exist, and how big was it.
local function probe(p)
    local fh = real.open(p, 'rb')
    if not fh then return 0, -1 end
    local size = fh:seek('end') or -1
    fh:close()
    return 1, size
end

local function read(p)
    if type(p) ~= 'string' or seenRaw[p] then return end
    seenRaw[p] = true
    local n = norm(p)
    if seen[n] or produced[n] then return end
    seen[n] = true
    local exists, size = probe(p)
    events[#events + 1] = 'F\t' .. exists .. '\t' .. size .. '\t' .. esc(n)
end

local function uncacheable(why)
    events[#events + 1] = 'X\t' .. esc(why)
end

local function isWriteMode(mode)
    return type(mode) == 'string' and mode:find('[wa+]') ~= nil
end

io.open = function(p, mode, ...)
    if type(p) == 'string' then
        if isWriteMode(mode) then
            -- r+ reads what was there first; w and a do not.
            if mode:find('r', 1, true) then read(p) end
            mark(p)
        else
            read(p)
        end
    end
    return real.open(p, mode, ...)
end

io.lines = function(p, ...)
    read(p)
    return real.lines(p, ...)
end

io.input = function(p, ...)
    read(p)
    return real.input(p, ...)
end

io.output = function(p, ...)
    if type(p) == 'string' then mark(p) end
    return real.output(p, ...)
end

dofile = function(...)
    local p = ...
    read(p)
    return real.dofile(...)
end

loadfile = function(...)
    local p = ...
    read(p)
    return real.loadfile(...)
end

-- Every candidate the searchers would try, in their order, up to the one that
-- exists: those before it are recorded ABSENT, so a file appearing earlier on
-- the path later is a change.
local function searchRecord(name, path)
    local sub = name:gsub('%.', '/')
    for template in path:gmatch('[^;]+') do
        local cand = template:gsub('%?', sub)
        read(cand)
        local fh = real.open(cand, 'rb')
        if fh then fh:close(); return true end
    end
    return false
end

require = function(name, ...)
    if type(name) == 'string' and package.loaded[name] == nil and package.preload[name] == nil then
        if not searchRecord(name, package.path) then
            searchRecord(name, package.cpath)
        end
    end
    return real.require(name, ...)
end

-- A popen'd command's output is read here, saved beside the trace, and served
-- to the script from that copy, so what it read is exactly what is recorded.
local Pipe = {}
Pipe.__index = Pipe
function Pipe:read(...) return self.fh:read(...) end
function Pipe:lines(...) return self.fh:lines(...) end
function Pipe:seek(...) return self.fh:seek(...) end
function Pipe:setvbuf() return true end
function Pipe:write() return nil, 'pipe opened for reading' end
function Pipe:flush() return self end
function Pipe:close()
    self.fh:close()
    return self.ok, self.how, self.code
end

io.popen = function(cmd, mode, ...)
    mode = mode or 'r'
    if type(cmd) ~= 'string' or isWriteMode(mode) then
        uncacheable('io.popen for writing: ' .. tostring(cmd))
        return real.popen(cmd, mode, ...)
    end
    local p, err = real.popen(cmd, mode, ...)
    if not p then
        uncacheable('io.popen failed: ' .. tostring(cmd))
        return p, err
    end
    local out = p:read('a') or ''
    local ok, how, code = p:close()
    nCmd = nCmd + 1
    local side = TRACE .. '.out' .. nCmd
    local w = real.open(side, 'wb')
    if not w then
        uncacheable('could not save the output of: ' .. cmd)
        local again = real.popen(cmd, mode)
        return again
    end
    w:write(out)
    w:close()
    events[#events + 1] = 'C\t' .. tostring(code) .. '\t' .. esc(side) .. '\t' .. esc(cmd)
    local fh = real.open(side, 'rb')
    return setmetatable({ fh = fh, ok = ok, how = how, code = code }, Pipe)
end

os.getenv = function(name, ...)
    local v = real.getenv(name, ...)
    if type(name) == 'string' and not envSeen[name] then
        envSeen[name] = true
        if v == nil then
            events[#events + 1] = 'E\t' .. esc(name) .. '\t0\t'
        else
            events[#events + 1] = 'E\t' .. esc(name) .. '\t1\t' .. esc(v)
        end
    end
    return v
end

os.execute = function(cmd, ...)
    if cmd ~= nil then uncacheable('os.execute: ' .. tostring(cmd)) end
    return real.execute(cmd, ...)
end

os.remove = function(p, ...)
    mark(p)
    return real.remove(p, ...)
end

os.rename = function(a, b, ...)
    mark(a); mark(b)
    return real.rename(a, b, ...)
end

os.tmpname = function(...)
    local p = real.tmpname(...)
    mark(p)
    return p
end

local function writeTrace(status)
    local fh = real.open(TRACE, 'wb')
    if not fh then return end
    fh:write('V1\n')
    for i = 1, #events do fh:write(events[i], '\n') end
    fh:write('END\t', tostring(status), '\n')
    fh:close()
end

-- os.exit is how almost every suite ends. Only a success is worth a trace;
-- anything else ends with no END line, which vcache.py treats as no pass.
os.exit = function(code, close)
    local status = code
    if code == nil or code == true then status = 0 elseif code == false then status = 1 end
    if status == 0 then writeTrace(0) end
    return real.exit(code, close)
end

-- The script's own `arg`: its name at 0, the interpreter at -1, then its args.
local nargs = select('#', ...) - 2
local sargs = {}
local newArg = { [-1] = arg[-1], [0] = SCRIPT }
for i = 1, nargs do
    newArg[i] = arg[i + 2]
    sargs[i] = arg[i + 2]
end
arg = newArg

read(SCRIPT)
local chunk, err = real.loadfile(SCRIPT)
if not chunk then
    io.stderr:write('lua: ', tostring(err), '\n')
    real.exit(1)
end

local function handler(e)
    if type(e) ~= 'string' then
        local mt = getmetatable(e)
        if mt and mt.__tostring then e = tostring(e)
        else e = ('(error object is a %s value)'):format(type(e)) end
    end
    return debug.traceback(e, 2)
end

local ok, msg = xpcall(chunk, handler, table.unpack(sargs, 1, nargs))
if not ok then
    io.stderr:write('lua: ', msg, '\n')
    real.exit(1)
end
writeTrace(0)
