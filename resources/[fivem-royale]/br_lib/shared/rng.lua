-- Seeded pseudo-random number generator.
--
-- Deliberately NOT math.random: the server and client must be able to derive the
-- identical loot layout from a single shared seed, and Lua's built-in RNG is not
-- guaranteed identical across platforms or versions. This is xoshiro128**, which
-- is small, fast, and fully deterministic given the same seed.

BR = BR or {}

local band, bxor, lshift, rshift = nil, nil, nil, nil
do
    -- Lua 5.4 has native bitwise operators; wrap them so the intent reads clearly
    -- and so a 5.3 fallback would only need changing here.
    band   = function(a, b) return a & b end
    bxor   = function(a, b) return a ~ b end
    lshift = function(a, b) return (a << b) & 0xFFFFFFFF end
    rshift = function(a, b) return (a >> b) & 0xFFFFFFFF end
end

local function rotl(x, k)
    return band(lshift(x, k) | rshift(x, 32 - k), 0xFFFFFFFF)
end

local Rng = {}
Rng.__index = Rng

--- Create a deterministic generator from an integer seed.
--- @param seed integer
--- @return table
function BR.Rng(seed)
    seed = math.tointeger(seed) or 0

    -- SplitMix32 to expand a single seed into the four state words. Seeding all
    -- four from the raw value directly produces poor early output.
    local s = band(seed, 0xFFFFFFFF)
    local state = {}
    for i = 1, 4 do
        s = band(s + 0x9E3779B9, 0xFFFFFFFF)
        local z = s
        z = band(bxor(z, rshift(z, 16)) * 0x85EBCA6B, 0xFFFFFFFF)
        z = band(bxor(z, rshift(z, 13)) * 0xC2B2AE35, 0xFFFFFFFF)
        state[i] = band(bxor(z, rshift(z, 16)), 0xFFFFFFFF)
    end

    -- All-zero state would lock the generator at zero forever.
    if state[1] == 0 and state[2] == 0 and state[3] == 0 and state[4] == 0 then
        state[1] = 1
    end

    return setmetatable({ s = state }, Rng)
end

--- Next raw 32-bit value.
--- @return integer
function Rng:next()
    local s = self.s
    local result = band(rotl(band(s[2] * 5, 0xFFFFFFFF), 7) * 9, 0xFFFFFFFF)
    local t = lshift(s[2], 9)

    s[3] = bxor(s[3], s[1])
    s[4] = bxor(s[4], s[2])
    s[2] = bxor(s[2], s[3])
    s[1] = bxor(s[1], s[4])
    s[3] = bxor(s[3], t)
    s[4] = rotl(s[4], 11)

    return result
end

--- Uniform float in [0, 1).
--- @return number
function Rng:float()
    return self:next() / 4294967296.0
end

--- Uniform integer in [lo, hi] inclusive.
--- @param lo integer
--- @param hi integer
--- @return integer
function Rng:int(lo, hi)
    if hi <= lo then return lo end
    return lo + (self:next() % (hi - lo + 1))
end

--- Pick one element of an array uniformly.
--- @param arr table
--- @return any
function Rng:pick(arr)
    local n = #arr
    if n == 0 then return nil end
    return arr[self:int(1, n)]
end

--- Weighted pick. `entries` is an array of tables each carrying a `weight` field.
--- Returns the chosen entry, or nil if every weight is zero.
--- @param entries table
--- @return any
function Rng:weighted(entries)
    local total = 0.0
    for i = 1, #entries do
        total = total + (entries[i].weight or 0)
    end
    if total <= 0 then return nil end

    local roll = self:float() * total
    local acc  = 0.0
    for i = 1, #entries do
        acc = acc + (entries[i].weight or 0)
        if roll < acc then
            return entries[i]
        end
    end
    return entries[#entries]
end

--- Uniform point inside a disc of `radius` around (cx, cy).
---
--- The sqrt is not decoration. Without it, points cluster toward the centre and
--- every match's storm path ends up feeling the same.
--- @param cx number
--- @param cy number
--- @param radius number
--- @return number, number
function Rng:pointInDisc(cx, cy, radius)
    local theta = self:float() * 2.0 * math.pi
    local dist  = radius * math.sqrt(self:float())
    return cx + math.cos(theta) * dist, cy + math.sin(theta) * dist
end

--- Fisher-Yates, in place.
--- @param arr table
--- @return table
function Rng:shuffle(arr)
    for i = #arr, 2, -1 do
        local j = self:int(1, i)
        arr[i], arr[j] = arr[j], arr[i]
    end
    return arr
end
