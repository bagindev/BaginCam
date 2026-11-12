// HDRPlus.metal - align + robust merge burst Bayer RAW di GPU iPhone.
//
// Port dari pipeline PC (pc-lab/robust_merge.py) yang sudah diuji:
//   * align: piramida abu-abu (superpixel 2x2), tile 16 overlap 50%, cari +-2 per level,
//     coarse -> fine (sama dengan hdr-plus-pytorch, MIT)
//   * merge: spatial robust merge (logika hdr-plus-swift merge/spatial, GPL-3.0):
//     blur binomial-16 -> selisih per superpixel -> bobot clamp(1 - diff/maxDiff, 0, 1)
//
// Semua buffer linear (bukan texture) supaya tidak bergantung format CVPixelBuffer Bayer.

#include <metal_stdlib>
using namespace metal;

// ---------- piramida ----------
kernel void bayer_grey(device const ushort* raw    [[buffer(0)]],
                       device float*        grey   [[buffer(1)]],
                       constant uint2&      rawSize [[buffer(2)]],
                       uint2 gid [[thread_position_in_grid]])
{
    const uint gw = rawSize.x / 2, gh = rawSize.y / 2;
    if (gid.x >= gw || gid.y >= gh) return;
    const uint W = rawSize.x, x = gid.x * 2, y = gid.y * 2;
    const float s = float(raw[y * W + x]) + float(raw[y * W + x + 1])
                  + float(raw[(y + 1) * W + x]) + float(raw[(y + 1) * W + x + 1]);
    grey[gid.y * gw + gid.x] = 0.25f * s;
}

kernel void downsample2(device const float* src     [[buffer(0)]],
                        device float*       dst     [[buffer(1)]],
                        constant uint2&     srcSize [[buffer(2)]],
                        uint2 gid [[thread_position_in_grid]])
{
    const uint dw = srcSize.x / 2, dh = srcSize.y / 2;
    if (gid.x >= dw || gid.y >= dh) return;
    const uint w = srcSize.x, x = gid.x * 2, y = gid.y * 2;
    dst[gid.y * dw + gid.x] = 0.25f * (src[y * w + x] + src[y * w + x + 1]
                                     + src[(y + 1) * w + x] + src[(y + 1) * w + x + 1]);
}

// ---------- align ----------
struct AlignParams {
    uint w, h;          // ukuran layer
    uint ntx, nty;      // jumlah tile layer ini
    uint pntx, pnty;    // jumlah tile layer sebelumnya (0 = tidak ada)
    int  tile;          // ukuran tile (16)
    int  search;        // jarak cari (2)
    int  prevScale;     // faktor skala alignment dari layer sebelumnya (2)
};

kernel void align_level(device const float* ref       [[buffer(0)]],
                        device const float* comp      [[buffer(1)]],
                        device const int2*  prevAlign [[buffer(2)]],
                        device int2*        outAlign  [[buffer(3)]],
                        constant AlignParams& p       [[buffer(4)]],
                        uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.ntx || gid.y >= p.nty) return;
    int2 prev = int2(0);
    if (p.pntx > 0) {
        const uint px = min(gid.x * p.pntx / p.ntx, p.pntx - 1);
        const uint py = min(gid.y * p.pnty / p.nty, p.pnty - 1);
        prev = prevAlign[py * p.pntx + px] * p.prevScale;
    }
    const int x0 = p.ntx > 1 ? int(gid.x * (p.w - uint(p.tile)) / (p.ntx - 1)) : 0;
    const int y0 = p.nty > 1 ? int(gid.y * (p.h - uint(p.tile)) / (p.nty - 1)) : 0;
    const int W = int(p.w), H = int(p.h);

    float best = INFINITY;
    int2 bestD = int2(0);
    for (int dy = -p.search; dy <= p.search; dy++) {
        for (int dx = -p.search; dx <= p.search; dx++) {
            const int cx0 = x0 + prev.x + dx, cy0 = y0 + prev.y + dy;
            if (cx0 < 0 || cy0 < 0 || cx0 + p.tile > W || cy0 + p.tile > H) continue;
            float s = 0.0f;
            for (int ty = 0; ty < p.tile; ty++) {
                const int ro = (y0 + ty) * W + x0;
                const int co = (cy0 + ty) * W + cx0;
                for (int tx = 0; tx < p.tile; tx++) s += fabs(ref[ro + tx] - comp[co + tx]);
            }
            if (s < best) { best = s; bestD = int2(dx, dy); }
        }
    }
    outAlign[gid.y * p.ntx + gid.x] = prev + bestD;
}

// ---------- warp ke 4 plane (R, G1, G2, B) per superpixel ----------
struct WarpParams { uint W, H, ntx, nty; };   // ukuran raw + jumlah tile layer 0

kernel void warp_planes(device const ushort* raw    [[buffer(0)]],
                        device const int2*   align  [[buffer(1)]],
                        device float4*       planes [[buffer(2)]],
                        constant WarpParams& p      [[buffer(3)]],
                        uint2 gid [[thread_position_in_grid]])
{
    const uint pw = p.W / 2, ph = p.H / 2;
    if (gid.x >= pw || gid.y >= ph) return;
    // tile terdekat (nearest, sama seperti F.interpolate di hdr-plus-pytorch)
    const uint tx = min(gid.x * 2 * p.ntx / p.W, p.ntx - 1);
    const uint ty = min(gid.y * 2 * p.nty / p.H, p.nty - 1);
    const int2 a = align[ty * p.ntx + tx];               // satuan superpixel
    const uint sx = uint(clamp(int(gid.x) + a.x, 0, int(pw) - 1));
    const uint sy = uint(clamp(int(gid.y) + a.y, 0, int(ph) - 1));
    const uint x = sx * 2, y = sy * 2, W = p.W;
    planes[gid.y * pw + gid.x] = float4(float(raw[y * W + x]), float(raw[y * W + x + 1]),
                                        float(raw[(y + 1) * W + x]), float(raw[(y + 1) * W + x + 1]));
}

// ---------- blur binomial 16 (17 tap), reflect padding ----------
constant float BINOM16[17] = {
    1.0f / 65536, 16.0f / 65536, 120.0f / 65536, 560.0f / 65536, 1820.0f / 65536, 4368.0f / 65536,
    8008.0f / 65536, 11440.0f / 65536, 12870.0f / 65536, 11440.0f / 65536, 8008.0f / 65536,
    4368.0f / 65536, 1820.0f / 65536, 560.0f / 65536, 120.0f / 65536, 16.0f / 65536, 1.0f / 65536 };

inline int reflect_idx(int i, int n) { return i < 0 ? -i : (i >= n ? 2 * n - 2 - i : i); }

kernel void blur_h(device const float4* src  [[buffer(0)]],
                   device float4*       dst  [[buffer(1)]],
                   constant uint2&      size [[buffer(2)]],
                   uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= size.x || gid.y >= size.y) return;
    float4 s = float4(0.0f);
    const uint row = gid.y * size.x;
    for (int k = -8; k <= 8; k++)
        s += BINOM16[k + 8] * src[row + uint(reflect_idx(int(gid.x) + k, int(size.x)))];
    dst[row + gid.x] = s;
}

kernel void blur_v(device const float4* src  [[buffer(0)]],
                   device float4*       dst  [[buffer(1)]],
                   constant uint2&      size [[buffer(2)]],
                   uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= size.x || gid.y >= size.y) return;
    float4 s = float4(0.0f);
    for (int k = -8; k <= 8; k++)
        s += BINOM16[k + 8] * src[uint(reflect_idx(int(gid.y) + k, int(size.y))) * size.x + gid.x];
    dst[gid.y * size.x + gid.x] = s;
}

// ---------- robust merge ----------
struct MergeParams { uint count; float maxDiff; float invN; };

kernel void merge_accumulate(device const float4* refP   [[buffer(0)]],
                             device const float4* refB   [[buffer(1)]],
                             device const float4* compP  [[buffer(2)]],
                             device const float4* compB  [[buffer(3)]],
                             device float4*       acc    [[buffer(4)]],
                             device atomic_uint*  wsum   [[buffer(5)]],
                             constant MergeParams& p     [[buffer(6)]],
                             uint gid [[thread_position_in_grid]])
{
    if (gid >= p.count) return;
    const float4 d = fabs(refB[gid] - compB[gid]);
    const float diff = d.x + d.y + d.z + d.w;
    const float w = p.maxDiff > 0.0f ? clamp(1.0f - diff / p.maxDiff, 0.0f, 1.0f) : 1.0f;
    acc[gid] += (refP[gid] * (1.0f - w) + compP[gid] * w) * p.invN;
    // statistik bobot (dibulatkan 0..255) untuk log
    atomic_fetch_add_explicit(wsum, uint(w * 255.0f + 0.5f), memory_order_relaxed);
}

kernel void planes_to_bayer(device const float4* acc     [[buffer(0)]],
                            device ushort*       raw     [[buffer(1)]],
                            constant uint2&      rawSize [[buffer(2)]],
                            uint2 gid [[thread_position_in_grid]])
{
    const uint pw = rawSize.x / 2, ph = rawSize.y / 2;
    if (gid.x >= pw || gid.y >= ph) return;
    const float4 v = clamp(round(acc[gid.y * pw + gid.x]), 0.0f, 65535.0f);
    const uint W = rawSize.x, x = gid.x * 2, y = gid.y * 2;
    raw[y * W + x] = ushort(v.x);
    raw[y * W + x + 1] = ushort(v.y);
    raw[(y + 1) * W + x] = ushort(v.z);
    raw[(y + 1) * W + x + 1] = ushort(v.w);
}


// =====================================================================================
// Merge domain frekuensi (Wiener per tile) - Hasinoff et al. 2016 / hdr-plus-swift frequency.
// Prototipe & validasi: pc-lab/freq_merge.py (lebih tahan gerak dari spatial merge, sesi 15).
// Tile 16x16 di koordinat plane (superpixel), stride 8, jendela raised-cosine (jumlah = 1),
// diproses per pita baris tile. 1 threadgroup = 1 tile, 16x16 thread = 1 koefisien.
// =====================================================================================

constant float TW_COS[16] = { 1.0f, 0.9238795f, 0.7071068f, 0.3826834f, 0.0f, -0.3826834f, -0.7071068f, -0.9238795f,
                              -1.0f, -0.9238795f, -0.7071068f, -0.3826834f, 0.0f, 0.3826834f, 0.7071068f, 0.9238795f };
constant float TW_SIN[16] = { 0.0f, 0.3826834f, 0.7071068f, 0.9238795f, 1.0f, 0.9238795f, 0.7071068f, 0.3826834f,
                              0.0f, -0.3826834f, -0.7071068f, -0.9238795f, -1.0f, -0.9238795f, -0.7071068f, -0.3826834f };

inline float hann16(uint i) { return 0.5f - 0.5f * cos(2.0f * M_PI_F * (float(i) + 0.5f) / 16.0f); }

struct FreqParams {
    uint W, H;            // ukuran raw
    uint ntx;             // jumlah tile frekuensi per baris (dengan pad 8)
    uint row0, rows;      // pita: baris tile awal & jumlah baris
    uint antx, anty;      // grid alignment layer 0
    float black, range;   // black & rentang data (satuan piksel buffer)
    float noiseS, noiseO; // NoiseProfile DNG (ternormalisasi)
    float c;              // kekuatan Wiener (besar = merge lebih agresif)
    float invN;           // 1 / jumlah frame
};

// baca nilai plane `ch` di (px,py) dari raw, digeser alignment superpixel (a), clamp ke batas
inline float plane_sample(device const ushort* raw, uint W, uint H, int px, int py, int2 a, uint ch) {
    const int pw = int(W / 2), ph = int(H / 2);
    const int sx = clamp(px + a.x, 0, pw - 1), sy = clamp(py + a.y, 0, ph - 1);
    const uint x = uint(sx) * 2 + (ch & 1u), y = uint(sy) * 2 + (ch >> 1);
    return float(raw[y * W + x]);
}

inline int2 tile_alignment(device const int2* align, constant FreqParams& p, int cx, int cy) {
    // tile alignment terdekat (sama dengan warp_planes): posisi full-res = 2 * posisi plane
    const uint ax = min(uint(max(cx, 0)) * 2 * p.antx / p.W, p.antx - 1);
    const uint ay = min(uint(max(cy, 0)) * 2 * p.anty / p.H, p.anty - 1);
    return align[ay * p.antx + ax];
}

/// DFT 2D 16x16 (maju) dari tile berjendela di threadgroup memory; koefisien (u,v) = thread (tid.x, tid.y)
inline float2 dft16x16(threadgroup float* tileIn, threadgroup float2* rowTmp, uint2 tid) {
    float2 s = float2(0.0f);
    for (uint x = 0; x < 16; x++) {
        const uint k = (tid.x * x) & 15u;
        const float v = tileIn[tid.y * 16 + x];
        s += float2(v * TW_COS[k], -v * TW_SIN[k]);
    }
    rowTmp[tid.y * 16 + tid.x] = s;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float2 f = float2(0.0f);
    for (uint y = 0; y < 16; y++) {
        const uint k = (tid.y * y) & 15u;
        const float2 r = rowTmp[y * 16 + tid.x];
        const float cs = TW_COS[k], sn = TW_SIN[k];
        f += float2(r.x * cs + r.y * sn, r.y * cs - r.x * sn);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    return f;
}

/// spektrum referensi -> specRef & acc (= specRef * invN), plus varians noise per tile
kernel void freq_ref(device const ushort* raw      [[buffer(0)]],
                     device float2*       specRef  [[buffer(1)]],
                     device float2*       acc      [[buffer(2)]],
                     device float*        noiseVar [[buffer(3)]],
                     constant FreqParams& p        [[buffer(4)]],
                     uint2 tg  [[threadgroup_position_in_grid]],
                     uint2 tid [[thread_position_in_threadgroup]])
{
    threadgroup float tileIn[256];
    threadgroup float2 rowTmp[256];
    threadgroup float meanSum[256];
    const bool active = tg.y < p.rows && tg.x < p.ntx;
    const uint ty = p.row0 + tg.y, tx = tg.x;
    const int ox = int(tx) * 8 - 8, oy = int(ty) * 8 - 8;
    const float w = hann16(tid.x) * hann16(tid.y);
    const uint base = ((tg.y * p.ntx + tx) * 4) * 256 + tid.y * 16 + tid.x;
    float mean4 = 0.0f;
    for (uint ch = 0; ch < 4; ch++) {
        const float v = active ? plane_sample(raw, p.W, p.H, ox + int(tid.x), oy + int(tid.y), int2(0), ch) : 0.0f;
        mean4 += v;
        tileIn[tid.y * 16 + tid.x] = v * w;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        const float2 F = dft16x16(tileIn, rowTmp, tid);
        if (active) {
            specRef[base + ch * 256] = F;
            acc[base + ch * 256] = F * p.invN;
        }
    }
    meanSum[tid.y * 16 + tid.x] = mean4 * 0.25f;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (active && tid.x == 0 && tid.y == 0) {
        float m = 0.0f;
        for (uint i = 0; i < 256; i++) m += meanSum[i];
        m /= 256.0f;
        const float x = clamp((m - p.black) / p.range, 0.0f, 1.0f);
        noiseVar[tg.y * p.ntx + tx] = (p.noiseS * x + p.noiseO) * p.range * p.range;
    }
}

/// tambah 1 frame: acc += invN * (Fz + A * (Fref - Fz)),  A = |D|^2 / (|D|^2 + c * sigma^2 * sum(w^2))
kernel void freq_add_frame(device const ushort* raw      [[buffer(0)]],
                           device const int2*   align    [[buffer(1)]],
                           device const float2* specRef  [[buffer(2)]],
                           device float2*       acc      [[buffer(3)]],
                           device const float*  noiseVar [[buffer(4)]],
                           constant FreqParams& p        [[buffer(5)]],
                           uint2 tg  [[threadgroup_position_in_grid]],
                           uint2 tid [[thread_position_in_threadgroup]])
{
    threadgroup float tileIn[256];
    threadgroup float2 rowTmp[256];
    const bool active = tg.y < p.rows && tg.x < p.ntx;
    const uint ty = p.row0 + tg.y, tx = tg.x;
    const int ox = int(tx) * 8 - 8, oy = int(ty) * 8 - 8;
    const int2 a = active ? tile_alignment(align, p, ox + 8, oy + 8) : int2(0);
    const float w = hann16(tid.x) * hann16(tid.y);
    // sum(w^2) Hann 16x16 = 6^2 = 36
    const float denomNoise = active ? p.c * noiseVar[tg.y * p.ntx + tx] * 36.0f : 1.0f;
    const uint base = ((tg.y * p.ntx + tx) * 4) * 256 + tid.y * 16 + tid.x;
    for (uint ch = 0; ch < 4; ch++) {
        tileIn[tid.y * 16 + tid.x] = active ? plane_sample(raw, p.W, p.H, ox + int(tid.x), oy + int(tid.y), a, ch) * w : 0.0f;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        const float2 Fz = dft16x16(tileIn, rowTmp, tid);
        if (active) {
            const float2 D = specRef[base + ch * 256] - Fz;
            const float d2 = dot(D, D);
            const float A = d2 / (d2 + denomNoise + 1e-6f);
            acc[base + ch * 256] += (Fz + A * D) * p.invN;
        }
    }
}

/// IDFT + overlap-add ke plane (float4 = 4 plane). Dipanggil 4x (paritas tile) supaya tile yang
/// ditulis bersamaan tidak tumpang tindih (stride 8, ukuran 16).
kernel void freq_inverse(device const float2* acc    [[buffer(0)]],
                         device float4*       planes [[buffer(1)]],
                         constant FreqParams& p      [[buffer(2)]],
                         constant uint2&      parity [[buffer(3)]],
                         uint2 tg  [[threadgroup_position_in_grid]],
                         uint2 tid [[thread_position_in_threadgroup]])
{
    threadgroup float2 spec[256];
    threadgroup float2 colTmp[256];
    const uint tyl = tg.y * 2 + parity.y, tx = tg.x * 2 + parity.x;   // tile lokal di pita
    const bool active = tyl < p.rows && tx < p.ntx;
    const uint ty = p.row0 + tyl;
    const int ox = int(tx) * 8 - 8, oy = int(ty) * 8 - 8;
    const int px = ox + int(tid.x), py = oy + int(tid.y);
    const int pw = int(p.W / 2), ph = int(p.H / 2);
    const uint base = ((tyl * p.ntx + tx) * 4) * 256;
    float4 outv = float4(0.0f);
    for (uint ch = 0; ch < 4; ch++) {
        spec[tid.y * 16 + tid.x] = active ? acc[base + ch * 256 + tid.y * 16 + tid.x] : float2(0.0f);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        float2 s = float2(0.0f);
        for (uint v = 0; v < 16; v++) {
            const uint k = (tid.y * v) & 15u;
            const float2 f = spec[v * 16 + tid.x];
            const float cs = TW_COS[k], sn = TW_SIN[k];
            s += float2(f.x * cs - f.y * sn, f.y * cs + f.x * sn);
        }
        colTmp[tid.y * 16 + tid.x] = s;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        float r = 0.0f;
        for (uint u = 0; u < 16; u++) {
            const uint k = (tid.x * u) & 15u;
            const float2 c2 = colTmp[tid.y * 16 + u];
            r += c2.x * TW_COS[k] - c2.y * TW_SIN[k];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        outv[ch] = r / 256.0f;
    }
    if (active && px >= 0 && py >= 0 && px < pw && py < ph) planes[uint(py) * uint(pw) + uint(px)] += outv;
}
