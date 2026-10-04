-- Parse-back of br_audio's committed binaries (#382).
--
-- tools/build_audio.mjs writes the airdrop Cargobob's rotor recording as a GTA
-- wave container (.awc) and sound data (.dat54.rel). The game parses both, and
-- a wrong field does not raise an error anywhere: a name that does not match
-- plays silence, a broken chunk table can crash a client at load. So this
-- suite reads the COMMITTED files back with its own reader -- written here, not
-- shared with the builder -- and checks everything the game will look at:
--
--   * the .awc: one mono stream, its id, LoopPoint 0, 32 kHz, the codec, the
--     chunk table, the ADPCM blocks, and the peak data against the audio.
--   * the .rel: the soundset, each variant's distance and loudness, and that
--     every SimpleSound points at the one wave the .awc holds.
--   * the seams: the names br_core's config asks for, br_audio's manifest,
--     server.cfg's order, and the binary rule in .gitattributes.
--
-- WHAT THIS CANNOT TELL YOU: whether the game agrees. That is the owner's one
-- CodeWalker check and the dev box.
--
-- Run via tools/verify.sh, or directly:  lua tools/test_audio.lua

local realPrint = print
local ROOT = 'resources/[fivem-royale]/'
local AWC_PATH = ROOT .. 'br_audio/br_sfx/br_cargobob.awc'
local REL_PATH = ROOT .. 'br_audio/data/br_airdrop_sounds.dat54.rel'

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

local function slurp(path, mode)
    local fh = io.open(path, mode or 'rb')
    if not fh then return nil end
    local s = fh:read('a')
    fh:close()
    return s
end

--- Jenkins one-at-a-time over the bytes as given.
local function joaat(s)
    local h = 0
    for i = 1, #s do
        h = (h + s:byte(i)) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h = h ~ (h >> 6)
    end
    h = (h + (h << 3)) & 0xFFFFFFFF
    h = h ~ (h >> 11)
    h = (h + (h << 15)) & 0xFFFFFFFF
    return h
end

--- How the game hashes a name it is handed: lowercased, backslash as slash.
local function gameHash(s)
    return joaat((s:lower():gsub('\\', '/')))
end

local function hex(v) return ('0x%08X'):format(v or 0) end

-- ------------------------------------------------------------ the config ---

BR = BR or {}
for _, f in ipairs({ 'br_lib/shared/enums.lua', 'br_lib/shared/geo.lua',
                     'br_lib/config/weapons.lua',
                     'br_lib/config/loot.lua', 'br_lib/config/airdrop.lua' }) do
    local chunk, err = loadfile(ROOT .. f)
    if not chunk then
        realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
        os.exit(1)
    end
    chunk()
end
local A = BR.Config.Airdrop

-- ════ THE OWNER'S LADDER, PINNED ════
--
-- Owner, 2026-10-03: "I want to hear it from 300m away". VolumeCurveScale's
-- units are undocumented, so four variants of one wave bracket the target and
-- `/brairdrop rotor at 300` picks by ear. Changing a rung is a decision; it
-- changes here and in tools/build_audio.mjs together.
local LADDER = {
    { name = 'default', script = 'cargobob_rotor',      sound = 'br_cargobob_rotor_sp',
      curveScale = 1000, category = 'scripted',        volume = 0 },
    { name = 'near',    script = 'cargobob_rotor_near', sound = 'br_cargobob_rotor_near_sp',
      curveScale = 300,  category = 'scripted',        volume = 0 },
    { name = 'far',     script = 'cargobob_rotor_far',  sound = 'br_cargobob_rotor_far_sp',
      curveScale = 2500, category = 'scripted',        volume = 0 },
    { name = 'loud',    script = 'cargobob_rotor_loud', sound = 'br_cargobob_rotor_loud_sp',
      curveScale = 1000, category = 'scripted_louder', volume = 600 },
}
local PACK, CONTAINER = 'br_sfx', 'br_cargobob'
local STREAM = 'br_cargobob_rotor'
local SOUNDSET = 'br_airdrop_soundset'

local awc = slurp(AWC_PATH)
local rel = slurp(REL_PATH)
if not awc or not rel then
    realPrint('\27[31mmissing\27[0m the built bank -- run node tools/build_audio.mjs')
    os.exit(1)
end

-- ================================================================ the .awc ===

local CHUNK = { peak = joaat('peak') & 0xFF, data = joaat('data') & 0xFF,
                format = joaat('format') & 0xFF }
local fmt = {}
local chunks = {}
local streamId, chunkCount

describe('the .awc: one mono stream that loops, laid out as the game reads it')
do
    -- The hash is checked against the three values CodeWalker records, so a
    -- broken joaat here cannot agree with a broken one in the builder.
    eq(CHUNK.data, 0x55, 'chunk type "data" is 0x55')
    eq(CHUNK.format, 0xFA, 'chunk type "format" is 0xFA')
    eq(CHUNK.peak, 0x36, 'chunk type "peak" is 0x36')

    local magic, version, flags, streams, dataOffset, pos =
        string.unpack('<I4I2I2i4i4', awc)
    eq(magic, 0x54414441, 'magic "ADAT"')
    eq(version, 1, 'version 1')
    eq(flags >> 8, 0xFF, 'flags high byte 0xFF, as every vanilla file has')
    eq(flags & 1, 1, 'the chunk-index table is present')
    eq(flags & 2, 0, 'not encrypted')
    eq(flags & 4, 0, 'not multi-channel: ONE channel, mono')
    eq(flags & 8, 0, 'and no multi-channel encryption')
    eq(streams, 1, 'one stream')

    local firstChunk
    firstChunk, pos = string.unpack('<I2', awc, pos)
    eq(firstChunk, 0, 'stream 0 starts at chunk 0')
    local info
    info, pos = string.unpack('<I4', awc, pos)
    streamId, chunkCount = info & 0x1FFFFFFF, info >> 29
    eq(streamId, joaat(STREAM) & 0x1FFFFFFF,
        'the stream id is joaat("br_cargobob_rotor") on 29 bits')
    eq(chunkCount, 3, 'three chunks: format, peak, data')

    for _ = 1, chunkCount do
        local raw
        raw, pos = string.unpack('<I8', awc, pos)
        chunks[#chunks + 1] = { type = (raw >> 56) & 0xFF,
                                size = (raw >> 28) & 0x0FFFFFFF,
                                offset = raw & 0x0FFFFFFF }
    end
    eq(dataOffset, pos - 1, 'DataOffset is where the header ends')

    local byType = {}
    for _, c in ipairs(chunks) do byType[c.type] = (byType[c.type] or 0) + 1 end
    eq(byType[CHUNK.format], 1, 'one format chunk')
    eq(byType[CHUNK.data], 1, 'one data chunk')
    eq(byType[CHUNK.peak], 1, 'one peak chunk')

    -- Inside the file, past the header, and not overlapping.
    table.sort(chunks, function(a, b) return a.offset < b.offset end)
    local cursor = dataOffset
    for _, c in ipairs(chunks) do
        ok(c.offset >= cursor, ('chunk 0x%02X starts after what precedes it'):format(c.type))
        ok(c.offset + c.size <= #awc, ('chunk 0x%02X ends inside the file'):format(c.type))
        cursor = c.offset + c.size
        if c.type == CHUNK.data then
            eq(c.offset % 16, 0, 'the data chunk is 16-byte aligned')
        end
        chunks[c.type] = c
    end
    eq(cursor, #awc, 'and the file ends where the last chunk does')

    local f = chunks[CHUNK.format]
    eq(f.size, 24, 'a 24-byte format chunk, with a peak')
    fmt.samples, fmt.loopPoint, fmt.rate, fmt.headroom, fmt.loopBegin,
    fmt.loopEnd, fmt.playEnd, fmt.playBegin, fmt.codec, fmt.peak =
        string.unpack('<I4i4I2i2I2I2I2BBI4', awc, f.offset + 1)
    eq(fmt.loopPoint, 0, 'LoopPoint 0: it loops from the start until StopSound')
    eq(fmt.rate, 32000, '32 kHz')
    eq(fmt.headroom, -100, 'headroom -100, as in the working custom banks')
    eq(fmt.loopBegin, 0, 'LoopBegin 0')
    eq(fmt.loopEnd, 0, 'LoopEnd 0')
    eq(fmt.playEnd, 0, 'PlayEnd 0')
    eq(fmt.playBegin, 0, 'PlayBegin 0')
    -- THE SHIPPED CODEC. `node tools/build_audio.mjs --pcm` is the fallback if
    -- ADPCM ever sounds wrong in game; shipping it is a change to this line.
    eq(fmt.codec, 4, 'IMA-ADPCM (4), the shipped build')
    eq(fmt.peak >> 16, 0, 'the peak word\'s upper half is 0')

    local secs = fmt.samples / fmt.rate
    ok(secs > 50.0 and secs < 57.5, 'about 55 seconds of the steady middle',
        ('%.3f s'):format(secs))
    eq(fmt.samples % 4088, 0, 'a whole number of 4088-sample ADPCM blocks')
    local blocks = fmt.samples // 4088
    eq(chunks[CHUNK.data].size, blocks * 2048, 'so the data is exactly 2048 bytes a block')
end

-- ======================================================= the audio itself ===

describe('the .awc\'s audio decodes, and its peak data describes it')
do
    local STEP = {
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41,
        45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190,
        209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724,
        796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272,
        2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132,
        7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500,
        20350, 22385, 24623, 27086, 29794, 32767,
    }
    local ADJ = { [0] = -1, -1, -1, -1, 2, 4, 6, 8 }

    -- 2048-byte blocks: int16 step index, int16 predictor, then 4088 samples
    -- low nibble first.
    local d = chunks[CHUNK.data]
    local n = fmt.samples
    local pcm = {}
    local badHeader = 0
    local o = 0
    local at = d.offset + 1
    while o < n do
        local index, pred = string.unpack('<i2i2', awc, at)
        if index < 0 or index > 88 then badHeader = badHeader + 1 end
        index = math.max(0, math.min(88, index))
        at = at + 4
        local stop = math.min(o + 4088, n)
        while o < stop do
            local b = awc:byte(at)
            at = at + 1
            for k = 0, 1 do
                local code = (k == 0) and (b & 0x0F) or (b >> 4)
                local step = STEP[index + 1]
                local diff = (((code & 7) * 2 + 1) * step) >> 3
                if code & 8 ~= 0 then pred = pred - diff else pred = pred + diff end
                if pred > 32767 then pred = 32767 elseif pred < -32768 then pred = -32768 end
                index = index + ADJ[code & 7]
                if index < 0 then index = 0 elseif index > 88 then index = 88 end
                o = o + 1
                pcm[o] = pred
            end
        end
    end
    eq(badHeader, 0, 'every block header carries a step index from 0 to 88')
    eq(#pcm, n, 'every sample decodes')

    -- LOUD ENOUGH AND NOT CLIPPED. The builder limits to -1 dBFS after +6 dB;
    -- ADPCM adds a little error on top (the shipped build peaks at 0.93), so
    -- the line drawn is the rails themselves: a sample pinned there is a clip.
    local sum, peakAbs = 0, 0
    for i = 1, n do
        local v = pcm[i]
        sum = sum + v * v
        if v < 0 then v = -v end
        if v > peakAbs then peakAbs = v end
    end
    local rmsDb = 10 * math.log(sum / n / (32768 * 32768), 10)
    ok(rmsDb > -24 and rmsDb < -6, 'the level is the normalized rotor, not silence',
        ('%.1f dBFS RMS'):format(rmsDb))
    ok(peakAbs < 32767, 'and nothing reaches full scale',
        ('peak %d'):format(peakAbs))

    -- THE PEAKS: the first 4096 samples in the format chunk, one per 4096 after
    -- in the peak chunk, each the largest |sample| * 2 in its span.
    local function peakAt(start)
        local p = 0
        for i = start + 1, math.min(start + 4096, n) do
            local v = pcm[i]
            if v < 0 then v = -v end
            v = math.min(v * 2, 65535)
            if v > p then p = v end
        end
        return p
    end
    eq(fmt.peak & 0xFFFF, peakAt(0), 'the format chunk\'s peak is the first span\'s')
    local pc = chunks[CHUNK.peak]
    local count = (n - 4096) // 4096
    eq(pc.size, count * 2, 'one peak per further 4096 samples')
    local wrong = 0
    for k = 0, count - 1 do
        local v = string.unpack('<I2', awc, pc.offset + 1 + k * 2)
        if v ~= peakAt((k + 1) * 4096) then wrong = wrong + 1 end
    end
    eq(wrong, 0, 'and every one matches the audio')

    -- THE LOOP HAS NO SEAM. The last sample runs on into the first the way any
    -- two neighbors do, because the audio past the loop end is folded into the
    -- start. A plain cut would jump between two unrelated points of the wave.
    -- A counting histogram rather than a sort: 1.7M steps, one pass.
    local hist = {}
    for i = 2, n do
        local s = math.abs(pcm[i] - pcm[i - 1])
        hist[s] = (hist[s] or 0) + 1
    end
    local want, seen, p99 = math.floor((n - 1) * 0.99), 0, 0
    for s = 0, 65535 do
        seen = seen + (hist[s] or 0)
        if seen >= want then
            p99 = s
            break
        end
    end
    local seam = math.abs(pcm[1] - pcm[n])
    ok(seam <= p99, 'the wrap from the last sample to the first is an ordinary step',
        ('seam %d, 99th percentile step %d'):format(seam, p99))
end

-- ================================================================ the .rel ===

--- One sound header, read the way the game reads it: a 32-bit flags word, and
--- per byte either 0xAA (no fields in that group) or one bit per field.
local FIELDS = {
    [0] = { 'Flags2', 'I4' }, { 'MaxHeaderSize', 'I2' }, { 'Volume', 'i2' },
    { 'VolumeVariance', 'I2' }, { 'Pitch', 'i2' }, { 'PitchVariance', 'I2' },
    { 'Pan', 'I2' }, { 'PanVariance', 'I2' }, { 'PreDelay', 'i2' },
    { 'PreDelayVariance', 'I2' }, { 'StartOffset', 'i4' },
    { 'StartOffsetVariance', 'i4' }, { 'AttackTime', 'I2' },
    { 'ReleaseTime', 'I2' }, { 'DopplerFactor', 'I2' }, { 'Category', 'I4' },
    { 'LPFCutoff', 'I2' }, { 'LPFCutoffVariance', 'I2' }, { 'HPFCutoff', 'I2' },
    { 'HPFCutoffVariance', 'I2' }, { 'VolumeCurve', 'I4' },
    { 'VolumeCurveScale', 'i2' }, { 'VolumeCurvePlateau', 'B' },
    { 'SpeakerMask', 'B' }, { 'EffectRoute', 'B' }, { 'PreDelayVariable', 'I4' },
    { 'StartOffsetVariable', 'I4' }, { 'SmallReverbSend', 'I2' },
    { 'MediumReverbSend', 'I2' }, { 'LargeReverbSend', 'I2' }, { 'Unk25', 'I2' },
    { 'Unk26', 'I2' },
}

local function readHeader(s, pos)
    local h = {}
    local flags
    flags, pos = string.unpack('<I4', s, pos)
    h.Flags = flags
    for group = 0, 3 do
        if ((flags >> (group * 8)) & 0xFF) ~= 0xAA then
            for bit = group * 8, group * 8 + 7 do
                if (flags >> bit) & 1 == 1 then
                    local f = FIELDS[bit]
                    h[f[1]], pos = string.unpack('<' .. f[2], s, pos)
                end
            end
        end
    end
    return h, pos
end

local records = {}         -- [nameHash] = { at (data-block offset), len, ... }
local dataLen

describe('the .rel: a soundset, four variants, one wave between them')
do
    local relType, pos
    relType, dataLen, pos = string.unpack('<I4I4', rel)
    eq(relType, 54, 'sound data (dat54)')
    local version = string.unpack('<I4', rel, pos)
    eq(version, 7314721, 'the version word of the working custom banks')
    local dataStart = pos              -- 1-based position of the data block
    pos = pos + dataLen

    -- THE NAME TABLE: the one wave container these sounds point into.
    local ntLen, ntCount
    ntLen, ntCount, pos = string.unpack('<I4I4', rel, pos)
    eq(ntCount, 1, 'one container path')
    local ntOffset
    ntOffset, pos = string.unpack('<I4', rel, pos)
    eq(ntOffset, 0, 'at offset 0')
    local path
    path, pos = string.unpack('z', rel, pos)
    eq(path, PACK .. '\\' .. CONTAINER, 'br_sfx\\br_cargobob, backslash-separated')
    eq(ntLen, 4 + 4 + #path + 1, 'and the table\'s length counts it exactly')

    -- THE INDEX, sorted by name hash rotated right 8 bits.
    local count
    count, pos = string.unpack('<I4', rel, pos)
    eq(count, #LADDER + 1, 'five entries: four SimpleSounds and the SoundSet')
    local prev = -1
    local sorted = true
    local covered = 4
    for _ = 1, count do
        local hash, at, len
        hash, at, len, pos = string.unpack('<I4I4I4', rel, pos)
        local key = ((hash >> 8) | (hash << 24)) & 0xFFFFFFFF
        if key <= prev then sorted = false end
        prev = key
        records[hash] = { at = at, len = len }
        ok(at >= 4 and at + len <= dataLen, ('%s lies inside the data block'):format(hex(hash)))
        covered = covered + len
    end
    ok(sorted, 'the index is sorted by rotated hash')
    eq(covered, dataLen, 'the records fill the data block exactly')

    -- THE SIMPLESOUNDS: each variant's numbers, and the one wave.
    local packWant, hashWant = {}, {}
    for _, v in ipairs(LADDER) do
        local r = records[joaat(v.sound)]
        ok(r ~= nil, ('%s is in the index'):format(v.sound))
        if r then
            local p = dataStart + r.at
            local typ
            typ, p = string.unpack('B', rel, p)
            eq(typ, 12, v.sound .. ' is a SimpleSound')
            local h
            h, p = readHeader(rel, p)
            eq(h.Flags, 0x0020F004, v.sound .. ' carries volume, envelope, '
               .. 'doppler, category and curve scale')
            eq(h.VolumeCurveScale, v.curveScale,
               ('%s: VolumeCurveScale %d'):format(v.name, v.curveScale))
            eq(h.Category, joaat(v.category),
               ('%s: category %s'):format(v.name, v.category))
            eq(h.Volume, v.volume, ('%s: volume %d'):format(v.name, v.volume))
            eq(h.AttackTime, 1000, v.name .. ': a one-second fade in')
            eq(h.ReleaseTime, 1500, v.name .. ': a 1.5-second fade out on stop')
            eq(h.DopplerFactor, 0, v.name .. ': no doppler on a teleported aircraft')
            eq(h.VolumeCurve, nil, v.name .. ': the default curve, stretched')
            packWant[#packWant + 1] = p - dataStart + 8      -- file offset, 0-based
            local container, file, slot
            container, file, slot, p = string.unpack('<I4I4B', rel, p)
            eq(container, joaat(PACK .. '/' .. CONTAINER),
               v.name .. ': ContainerName is the bank br_audio mounts')
            eq(container, gameHash(path),
               v.name .. ': and the name table\'s path, as the game hashes it')
            eq(file, joaat(STREAM), v.name .. ': FileName is the stream\'s name')
            -- THE ONE THAT PLAYS SILENCE IF IT IS WRONG.
            eq(file & 0x1FFFFFFF, streamId,
               v.name .. ': and matches the .awc\'s stream id on 29 bits')
            eq(slot, 0, v.name .. ': wave slot 0')
            eq(p - dataStart, r.at + r.len, v.name .. ': and nothing is left over')
        end
    end

    -- THE SOUNDSET: script name -> SimpleSound, sorted by script-name hash.
    local s = records[joaat(SOUNDSET)]
    ok(s ~= nil, 'br_airdrop_soundset is in the index')
    if s then
        local p = dataStart + s.at
        local typ
        typ, p = string.unpack('B', rel, p)
        eq(typ, 32, 'a SoundSet')
        local h
        h, p = readHeader(rel, p)
        eq(h.Flags, 0xAAAAAAAA, 'with no header fields')
        local n
        n, p = string.unpack('<i4', rel, p)
        eq(n, #LADDER, 'four entries')
        local byScript = {}
        local last = -1
        local inOrder = true
        for _ = 1, n do
            hashWant[#hashWant + 1] = p - dataStart + 8 + 4
            local script, child
            script, child, p = string.unpack('<I4I4', rel, p)
            if script <= last then inOrder = false end
            last = script
            byScript[script] = child
            ok(records[child] ~= nil, ('%s plays a sound in this file'):format(hex(script)))
        end
        ok(inOrder, 'sorted by script-name hash')
        eq(p - dataStart, s.at + s.len, 'and nothing is left over')
        for _, v in ipairs(LADDER) do
            eq(byScript[joaat(v.script)], joaat(v.sound),
               ('"%s" plays %s'):format(v.script, v.sound))
        end
    end

    -- THE FIX-UP TABLES, as file offsets: every SoundSet child for the hash
    -- table, every SimpleSound container for the pack table.
    local function readTable()
        local k
        k, pos = string.unpack('<I4', rel, pos)
        local out = {}
        for i = 1, k do out[i], pos = string.unpack('<I4', rel, pos) end
        return out
    end
    local hashTable = readTable()
    local packTable = readTable()
    eq(#hashTable, #hashWant, 'one hash-table entry per soundset child')
    for i, off in ipairs(hashTable) do
        eq(off, hashWant[i], ('hash-table entry %d points at child %d'):format(i, i))
    end
    eq(#packTable, #packWant, 'one pack-table entry per SimpleSound')
    for i, off in ipairs(packTable) do
        eq(off, packWant[i], ('pack-table entry %d points at a ContainerName'):format(i))
    end
    eq(pos - 1, #rel, 'and the file ends after the pack table')
end

-- ============================================================== the seams ===

describe('the client asks for exactly what the bank holds')
do
    eq(A.rotorBank, PACK .. '/' .. CONTAINER, 'the bank name br_core requests')
    eq(A.rotorSoundSet, SOUNDSET, 'the soundset br_core plays from')
    eq(A.rotorSound, 'cargobob_rotor', 'the default variant')
    eq(#A.rotorVariants, #LADDER, 'one config variant per rung')
    for i, v in ipairs(LADDER) do
        local c = A.rotorVariants[i] or {}
        eq(c.name, v.name, ('rung %d is named %s'):format(i, v.name))
        eq(c.sound, v.script, ('and plays "%s"'):format(v.script))
    end
    local all = { A.rotorBank, A.rotorSoundSet, STREAM, PACK, CONTAINER }
    for _, v in ipairs(LADDER) do
        all[#all + 1] = v.script
        all[#all + 1] = v.sound
        all[#all + 1] = v.category
    end
    local upper = {}
    for _, s in ipairs(all) do
        if s ~= s:lower() then upper[#upper + 1] = s end
    end
    eq(#upper, 0, 'every name is lowercase (hashes are case-sensitive)',
       table.concat(upper, ', '))
end

describe('br_audio ships the bank, above br_core, and deploys leave it alone')
do
    local man = slurp(ROOT .. 'br_audio/fxmanifest.lua', 'r') or ''
    local code = man:gsub('%-%-[^\n]*', '')
    ok(code:find("'br_sfx/br_cargobob.awc'", 1, true) ~= nil,
        'the .awc is in files {}, so clients download it')
    ok(code:find("'data/br_airdrop_sounds.dat54.rel'", 1, true) ~= nil,
        'and so is the .rel')
    ok(code:find("data_file 'AUDIO_WAVEPACK' 'br_sfx'", 1, true) ~= nil,
        'the wave pack is the br_sfx folder')
    ok(code:find("data_file 'AUDIO_SOUNDDATA' 'data/br_airdrop_sounds.dat'", 1, true) ~= nil,
        'the sound data is named without its 54.rel, which the game adds')

    local cfg = slurp('server.cfg.example', 'r') or ''
    local audioAt = cfg:find('\nensure br_audio', 1, true)
    local coreAt = cfg:find('\nensure br_core', 1, true)
    ok(audioAt ~= nil and coreAt ~= nil and audioAt < coreAt,
        'server.cfg.example ensures br_audio above br_core')

    local deploy = slurp('tools/deploy.sh', 'r') or ''
    ok(deploy ~= '' and deploy:find('restart br_audio', 1, true) == nil,
        'a deploy never restarts br_audio: unmounting game data mid-session can '
        .. 'crash clients')

    local attrs = slurp('.gitattributes', 'r') or ''
    ok(attrs:find('\n%*%.awc%s+binary') ~= nil, '.gitattributes keeps .awc binary')
    ok(attrs:find('\n%*%.rel%s+binary') ~= nil, 'and .rel')
end

-- ----------------------------------------------------------------- result ---

io.write(('%s%d passed%s'):format('\27[32m', pass, '\27[0m'))
if fail > 0 then
    io.write(('  %s%d failed%s\n'):format('\27[31m', fail, '\27[0m'))
    os.exit(1)
end
io.write('\n')
