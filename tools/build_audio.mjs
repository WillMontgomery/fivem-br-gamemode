#!/usr/bin/env node
// Builds br_audio's native audio bank from the owner's Cargobob recording (#382).
//
//   node tools/build_audio.mjs              IMA-ADPCM, 32 kHz (the shipped build)
//   node tools/build_audio.mjs --pcm        16-bit PCM instead, about 4x the size
//   node tools/build_audio.mjs --out DIR    write under DIR, not into the repo
//
// IN:  assets/audio/cargobob.ogg (the owner's file, 60.2 s stereo Vorbis)
// OUT: resources/[fivem-royale]/br_audio/br_sfx/br_cargobob.awc
//      resources/[fivem-royale]/br_audio/data/br_airdrop_sounds.dat54.rel
//
// Needs Node and ffmpeg on PATH. ffmpeg runs once, single-threaded.
//
// ═══ WHAT GTA NEEDS, AND WHY IT IS TWO FILES ═══
//
// PlaySoundFromEntity cannot read an .ogg. It looks a sound up by (script name,
// soundset) in loaded sound data, and that sound points at a wave inside a wave
// container. So:
//
//   * the .awc is the wave container: ONE mono stream, looping from sample 0.
//   * the .dat54.rel is the sound data: one SimpleSound per variant (all on that
//     one wave, so a variant costs bytes, not audio), and a SoundSet mapping the
//     script names Lua passes to those SimpleSounds.
//
// Both formats are written here from their layout as CodeWalker's AwcFile.cs and
// RelFile.cs describe it. No CodeWalker code, and nothing from any other audio
// tool, is in this file. tools/test_audio.lua reads both outputs back.
//
// ═══ NAMES ═══
//
// Every name is lowercase, because the files store Jenkins hashes and the game
// hashes names it is given in lowercase. The AWC stores a stream's id as
// joaat(name) & 0x1FFFFFFF and the SimpleSound stores joaat(name) whole; the
// game compares them on the low 29 bits, so a mismatch plays silence with no
// error. The pack folder `br_sfx` is unique in its first 8 characters, which
// is how the game indexes wave packs.
//
// ═══ THE ADPCM LAYOUT (a correction to the research) ═══
//
// IMA-ADPCM in an .awc is cut into 2048-byte blocks. Each block opens with a
// 4-byte header (step index as int16, predictor as int16) and carries 2044
// bytes, 4088 samples, low nibble first. The sample count is trimmed to a whole
// number of blocks, so the data is exactly N * 2048 bytes.
//
// ═══ THE VARIANTS ARE THE OWNER'S TUNING LADDER ═══
//
// Owner, 2026-10-03: "I want to hear it from 300m away". VolumeCurveScale sets
// how far a sound carries, and its units are not documented anywhere; 100
// reading as 1.0x is inferred, and vanilla sirens use 300. So four variants
// bracket the target, and `/brairdrop rotor at 300` in game picks between them.
// Change a number here, rebuild, and tools/test_audio.lua says what to update.

import { spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');

// ---------------------------------------------------------------- the spec ---

const SPEC = {
    source: 'assets/audio/cargobob.ogg',
    // The file fades in over its first ~2 s and out over its last ~2 s, so the
    // steady middle is used. `crossfade` more is read past `trimEnd` and folded
    // into the start, so the loop has no seam.
    trimStart: 2.5,
    trimEnd: 57.5,
    crossfade: 0.5,
    rate: 32000,
    // +6 dB into a limiter at -1 dBFS: about +4 LU on this file. Distance has to
    // come from the sound data; the wave has little left to give.
    gainDb: 6,
    limit: 0.891,

    pack: 'br_sfx',
    container: 'br_cargobob',
    stream: 'br_cargobob_rotor',
    soundSet: 'br_airdrop_soundset',
    // In hundredths of a dB, as in every working custom bank this was checked
    // against.
    headroom: -100,
    relVersion: 7314721,

    // Volume in hundredths of a dB; AttackTime and ReleaseTime in ms.
    attackMs: 1000,
    releaseMs: 1500,
    // The aircraft is moved by coordinate writes, so its velocity is not to be
    // trusted with a pitch shift.
    doppler: 0,
    variants: [
        { script: 'cargobob_rotor',      sound: 'br_cargobob_rotor_sp',
          volume: 0,   category: 'scripted',        curveScale: 1000 },
        { script: 'cargobob_rotor_near', sound: 'br_cargobob_rotor_near_sp',
          volume: 0,   category: 'scripted',        curveScale: 300 },
        { script: 'cargobob_rotor_far',  sound: 'br_cargobob_rotor_far_sp',
          volume: 0,   category: 'scripted',        curveScale: 2500 },
        { script: 'cargobob_rotor_loud', sound: 'br_cargobob_rotor_loud_sp',
          volume: 600, category: 'scripted_louder', curveScale: 1000 },
    ],
};

// Header fields present: Volume (bit 2); AttackTime, ReleaseTime, DopplerFactor,
// Category (bits 12-15); VolumeCurveScale (bit 21).
const SIMPLE_FLAGS = 0x0020F004;
const NO_FIELDS = 0xAAAAAAAA;
const TYPE_SIMPLE = 12;
const TYPE_SOUNDSET = 32;

const BLOCK_BYTES = 2048;
const BLOCK_SAMPLES = (BLOCK_BYTES - 4) * 2;   // 4088
const PEAK_SPAN = 4096;

// ------------------------------------------------------------------ helpers ---

function die(msg) {
    console.error(`build_audio: ${msg}`);
    process.exit(1);
}

/** Jenkins one-at-a-time, as the game hashes names (callers pass lowercase). */
function joaat(s) {
    let h = 0;
    for (const c of Buffer.from(s, 'latin1')) {
        h = (h + c) >>> 0;
        h = (h + (h << 10)) >>> 0;
        h = (h ^ (h >>> 6)) >>> 0;
    }
    h = (h + (h << 3)) >>> 0;
    h = (h ^ (h >>> 11)) >>> 0;
    h = (h + (h << 15)) >>> 0;
    return h;
}

function lower(name) {
    if (name !== name.toLowerCase()) die(`"${name}" must be lowercase`);
    return name;
}

/** Little-endian byte writer that grows as it goes. */
class Bytes {
    constructor() { this.buf = Buffer.alloc(1 << 16); this.n = 0; }
    room(k) {
        if (this.n + k <= this.buf.length) return;
        const next = Buffer.alloc(Math.max(this.buf.length * 2, this.n + k));
        this.buf.copy(next, 0, 0, this.n);
        this.buf = next;
    }
    u8(v)  { this.room(1); this.buf.writeUInt8(v, this.n); this.n += 1; }
    i16(v) { this.room(2); this.buf.writeInt16LE(v, this.n); this.n += 2; }
    u16(v) { this.room(2); this.buf.writeUInt16LE(v, this.n); this.n += 2; }
    i32(v) { this.room(4); this.buf.writeInt32LE(v, this.n); this.n += 4; }
    u32(v) { this.room(4); this.buf.writeUInt32LE(v >>> 0, this.n); this.n += 4; }
    u64(v) { this.room(8); this.buf.writeBigUInt64LE(v, this.n); this.n += 8; }
    raw(b) { this.room(b.length); b.copy(this.buf, this.n); this.n += b.length; }
    pad(align) { while (this.n % align !== 0) this.u8(0); }
    done() { return this.buf.subarray(0, this.n); }
}

// The chunk-type byte is the low byte of joaat(chunk name). Checked against the
// three values CodeWalker records, so a broken hash stops the build here
// instead of producing a bank the game cannot read.
const CHUNK = {
    data:   joaat('data') & 0xFF,
    format: joaat('format') & 0xFF,
    peak:   joaat('peak') & 0xFF,
};
if (CHUNK.data !== 0x55 || CHUNK.format !== 0xFA || CHUNK.peak !== 0x36) {
    die('joaat disagrees with the known chunk-type hashes');
}

// ---------------------------------------------------------------- the audio ---

function runFfmpeg(srcPath) {
    const end = SPEC.trimEnd + SPEC.crossfade;
    const filter = [
        'pan=mono|c0=0.5*c0+0.5*c1',
        `atrim=start=${SPEC.trimStart}:end=${end}`,
        'asetpts=N/SR/TB',
        `aresample=${SPEC.rate}`,
        `volume=${SPEC.gainDb}dB`,
        `alimiter=limit=${SPEC.limit}:attack=2:release=60:level=0`,
    ].join(',');
    const args = [
        '-hide_banner', '-nostdin', '-v', 'error',
        '-threads', '1', '-filter_threads', '1',
        '-i', srcPath,
        '-af', filter,
        '-ac', '1', '-ar', String(SPEC.rate),
        '-map_metadata', '-1', '-fflags', '+bitexact', '-flags:a', '+bitexact',
        '-f', 's16le', '-c:a', 'pcm_s16le', 'pipe:1',
    ];
    const r = spawnSync('ffmpeg', args, { maxBuffer: 64 * 1024 * 1024 });
    if (r.error) die(`ffmpeg did not run: ${r.error.message}`);
    if (r.status !== 0) die(`ffmpeg failed:\n${r.stderr.toString()}`);
    const raw = r.stdout;
    return new Int16Array(raw.buffer.slice(raw.byteOffset,
                                           raw.byteOffset + raw.length));
}

function ffmpegVersion() {
    const r = spawnSync('ffmpeg', ['-hide_banner', '-version']);
    return r.status === 0 ? r.stdout.toString().split(/\r?\n/)[0] : 'unknown';
}

/**
 * The loop body: a whole number of ADPCM blocks, with the audio that follows
 * its end cross-faded into its start, so sample N-1 runs on into sample 0.
 * LINEAR, so the blend never exceeds the limiter's ceiling.
 */
function loopBody(a) {
    const n = Math.floor(((SPEC.trimEnd - SPEC.trimStart) * SPEC.rate)
                         / BLOCK_SAMPLES) * BLOCK_SAMPLES;
    const x = Math.round(SPEC.crossfade * SPEC.rate);
    if (a.length < n + x) die(`ffmpeg gave ${a.length} samples, need ${n + x}`);
    const out = new Int16Array(n);
    out.set(a.subarray(0, n));
    for (let i = 0; i < x; i++) {
        const w = i / x;
        out[i] = Math.round(a[i] * w + a[n + i] * (1 - w));
    }
    return out;
}

// --------------------------------------------------------------- IMA-ADPCM ---

// The standard IMA ADPCM tables.
const STEP = [
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230,
    253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
    1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024,
    3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493,
    10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086,
    29794, 32767,
];
const ADJUST = [-1, -1, -1, -1, 2, 4, 6, 8];

const clamp = (v, lo, hi) => (v < lo ? lo : v > hi ? hi : v);
const delta = (code, step) => ((((code & 7) << 1) + 1) * step) >> 3;

function adpcmBytes(samples) {
    const full = Math.floor(samples / BLOCK_SAMPLES);
    const rest = samples - full * BLOCK_SAMPLES;
    return full * BLOCK_BYTES + (rest > 0 ? 4 + Math.ceil(rest / 2) : 0);
}

/** Greedy per-sample encoder, using the same reconstruction as the decoder. */
function encodeAdpcm(pcm) {
    if (pcm.length % 2 !== 0) die('ADPCM needs an even sample count');
    const out = Buffer.alloc(adpcmBytes(pcm.length));
    let pred = pcm[0];
    let index = 0;
    const first = Math.abs(pcm[1] - pcm[0]);
    while (index < 88 && STEP[index] < first) index++;

    const nibble = (target) => {
        const step = STEP[index];
        let best = 0;
        let bestErr = Infinity;
        let bestPred = pred;
        for (let code = 0; code < 16; code++) {
            const d = delta(code, step);
            const p = (code & 8) ? pred - d : pred + d;
            if (p < -32768 || p > 32767) continue;
            const e = Math.abs(target - p);
            if (e < bestErr) { bestErr = e; best = code; bestPred = p; }
        }
        pred = bestPred;
        index = clamp(index + ADJUST[best & 7], 0, 88);
        return best;
    };

    let o = 0;
    for (let s = 0; s < pcm.length; s += BLOCK_SAMPLES) {
        out.writeInt16LE(index, o);
        out.writeInt16LE(pred, o + 2);
        o += 4;
        const end = Math.min(s + BLOCK_SAMPLES, pcm.length);
        for (let i = s; i < end; i += 2) {
            const lo = nibble(pcm[i]);
            const hi = nibble(pcm[i + 1]);
            out[o++] = lo | (hi << 4);
        }
    }
    return out;
}

function decodeAdpcm(buf, samples) {
    const out = new Int16Array(samples);
    let o = 0;
    let at = 0;
    while (o < samples) {
        let index = clamp(buf.readInt16LE(at) & 0xFF, 0, 88);
        let pred = buf.readInt16LE(at + 2);
        at += 4;
        const end = Math.min(o + BLOCK_SAMPLES, samples);
        while (o < end) {
            const b = buf[at++];
            for (const code of [b & 0x0F, b >> 4]) {
                if (o >= end) break;
                const d = delta(code, STEP[index]);
                pred = clamp((code & 8) ? pred - d : pred + d, -32768, 32767);
                index = clamp(index + ADJUST[code & 7], 0, 88);
                out[o++] = pred;
            }
        }
    }
    return out;
}

function snrDb(ref, got) {
    let sig = 0;
    let err = 0;
    for (let i = 0; i < ref.length; i++) {
        sig += ref[i] * ref[i];
        const e = ref[i] - got[i];
        err += e * e;
    }
    return 10 * Math.log10(sig / Math.max(err, 1));
}

/** Peak per 4096 samples as the .awc stores it: |sample| * 2, capped. */
function peakAt(pcm, start) {
    let p = 0;
    const end = Math.min(start + PEAK_SPAN, pcm.length);
    for (let i = start; i < end; i++) {
        const v = Math.min(Math.abs(pcm[i]) * 2, 65535);
        if (v > p) p = v;
    }
    return p;
}

// --------------------------------------------------------------------- .awc ---

function buildAwc(pcm, adpcm) {
    const samples = pcm.length;
    const data = adpcm ? encodeAdpcm(pcm) : Buffer.from(pcm.buffer, pcm.byteOffset,
                                                        pcm.byteLength);
    const heard = adpcm ? decodeAdpcm(data, samples) : pcm;

    const peaks = [];
    const extra = Math.floor((samples - PEAK_SPAN) / PEAK_SPAN);
    for (let k = 0; k < extra; k++) peaks.push(peakAt(heard, (k + 1) * PEAK_SPAN));

    const format = new Bytes();
    format.u32(samples);
    format.i32(0);                       // LoopPoint 0: loop until StopSound
    format.u16(SPEC.rate);
    format.i16(SPEC.headroom);
    format.u16(0);                       // LoopBegin
    format.u16(0);                       // LoopEnd
    format.u16(0);                       // PlayEnd
    format.u8(0);                        // PlayBegin
    format.u8(adpcm ? 4 : 0);            // codec: 4 ADPCM, 0 PCM
    format.u32(peakAt(heard, 0));        // peak of the first 4096; high half 0
    const formatBytes = format.done();

    const peak = new Bytes();
    for (const p of peaks) peak.u16(p);
    const peakBytes = peak.done();

    // Header: magic "ADAT", version 1, flags 0xFF01 (chunk indices present, no
    // encryption, single channel), one stream. Then the chunk-index table, the
    // stream info, and three chunk infos, after which the chunks themselves.
    const chunkCount = 3;
    const dataOffset = 16 + 2 + 4 + chunkCount * 8;
    const formatAt = dataOffset;
    const peakAt0 = formatAt + formatBytes.length;
    let dataAt = peakAt0 + peakBytes.length;
    dataAt += (16 - (dataAt % 16)) % 16;

    const info = (type, size, offset) => {
        if (size >= 1 << 28 || offset >= 1 << 28) die('chunk too large for an .awc');
        return (BigInt(type) << 56n) | (BigInt(size) << 28n) | BigInt(offset);
    };

    const w = new Bytes();
    w.u32(0x54414441);
    w.u16(1);
    w.u16(0xFF01);
    w.i32(1);
    w.i32(dataOffset);
    w.u16(0);                                            // stream 0's first chunk
    w.u32((joaat(lower(SPEC.stream)) & 0x1FFFFFFF) | (chunkCount << 29));
    w.u64(info(CHUNK.peak, peakBytes.length, peakAt0));
    w.u64(info(CHUNK.data, data.length, dataAt));
    w.u64(info(CHUNK.format, formatBytes.length, formatAt));
    w.raw(formatBytes);
    w.raw(peakBytes);
    w.pad(16);
    if (w.n !== dataAt) die('awc layout drifted');
    w.raw(data);

    return { bytes: w.done(), samples, snr: adpcm ? snrDb(pcm, heard) : Infinity };
}

// --------------------------------------------------------------------- .rel ---

function soundHeader(w, v) {
    w.u32(SIMPLE_FLAGS);
    w.i16(v.volume);
    w.u16(SPEC.attackMs);
    w.u16(SPEC.releaseMs);
    w.u16(SPEC.doppler);
    w.u32(joaat(lower(v.category)));
    w.i16(v.curveScale);
}

function buildRel() {
    const containerName = `${lower(SPEC.pack)}/${lower(SPEC.container)}`;
    const containerPath = `${SPEC.pack}\\${SPEC.container}`;

    // The data block: a version word, then the records back to back.
    const data = new Bytes();
    data.u32(SPEC.relVersion);
    const records = [];
    const hashFields = [];   // data-block offsets of SoundSet ChildSound fields
    const packFields = [];   // data-block offsets of SimpleSound ContainerName fields

    for (const v of SPEC.variants) {
        const at = data.n;
        data.u8(TYPE_SIMPLE);
        soundHeader(data, v);
        packFields.push(data.n);
        data.u32(joaat(containerName));
        data.u32(joaat(lower(SPEC.stream)));
        data.u8(0);                                   // WaveSlotIndex
        records.push({ name: lower(v.sound), at, len: data.n - at });
    }

    const items = SPEC.variants
        .map((v) => ({ script: joaat(lower(v.script)), child: joaat(v.sound) }))
        .sort((a, b) => a.script - b.script);
    const setAt = data.n;
    data.u8(TYPE_SOUNDSET);
    data.u32(NO_FIELDS);
    data.i32(items.length);
    for (const it of items) {
        data.u32(it.script);
        hashFields.push(data.n);
        data.u32(it.child);
    }
    records.push({ name: lower(SPEC.soundSet), at: setAt, len: data.n - setAt });

    const block = data.done();

    // The index is sorted by name hash rotated right by 8 bits.
    const rotr8 = (h) => ((h >>> 8) | (h << 24)) >>> 0;
    const index = records
        .map((r) => ({ ...r, hash: joaat(r.name) }))
        .sort((a, b) => rotr8(a.hash) - rotr8(b.hash));

    const w = new Bytes();
    w.u32(54);
    w.u32(block.length);
    w.raw(block);
    // The name table: one wave container path, backslash-separated.
    const nameBytes = Buffer.from(containerPath, 'latin1');
    w.u32(4 + 4 + nameBytes.length + 1);
    w.u32(1);
    w.u32(0);
    w.raw(nameBytes);
    w.u8(0);
    w.u32(index.length);
    for (const r of index) { w.u32(r.hash); w.u32(r.at); w.u32(r.len); }
    // Both fix-up tables hold FILE offsets: the data block starts 8 bytes in.
    w.u32(hashFields.length);
    for (const o of hashFields) w.u32(8 + o);
    w.u32(packFields.length);
    for (const o of packFields) w.u32(8 + o);
    return w.done();
}

// --------------------------------------------------------------------- main ---

function main() {
    const argv = process.argv.slice(2);
    const adpcm = !argv.includes('--pcm');
    const outFlag = argv.indexOf('--out');
    const outRoot = outFlag >= 0 ? resolve(argv[outFlag + 1] || die('--out needs a dir'))
                                 : ROOT;
    for (const a of argv) {
        if (a.startsWith('--') && a !== '--pcm' && a !== '--out') die(`unknown option ${a}`);
    }

    const src = join(ROOT, SPEC.source);
    if (!existsSync(src)) die(`missing ${SPEC.source}`);

    const pcm = loopBody(runFfmpeg(src));
    const awc = buildAwc(pcm, adpcm);
    const rel = buildRel();

    const res = join(outRoot, 'resources', '[fivem-royale]', 'br_audio');
    const awcPath = join(res, SPEC.pack, `${SPEC.container}.awc`);
    const relPath = join(res, 'data', 'br_airdrop_sounds.dat54.rel');
    mkdirSync(dirname(awcPath), { recursive: true });
    mkdirSync(dirname(relPath), { recursive: true });
    writeFileSync(awcPath, awc.bytes);
    writeFileSync(relPath, rel);

    const secs = awc.samples / SPEC.rate;
    console.log(`${ffmpegVersion()}`);
    console.log(`awc  ${awc.bytes.length} bytes  ${adpcm ? 'IMA-ADPCM' : 'PCM'} `
                + `${SPEC.rate} Hz mono, ${awc.samples} samples (${secs.toFixed(3)} s), `
                + `loop point 0${adpcm ? `, SNR ${awc.snr.toFixed(1)} dB` : ''}`);
    console.log(`rel  ${rel.length} bytes  soundset ${SPEC.soundSet}, bank `
                + `${SPEC.pack}/${SPEC.container}`);
    for (const v of SPEC.variants) {
        console.log(`     ${v.script.padEnd(20)} scale ${String(v.curveScale).padStart(4)}  `
                    + `${v.category.padEnd(15)} volume ${v.volume}`);
    }
}

main();
