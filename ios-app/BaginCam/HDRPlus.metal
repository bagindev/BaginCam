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
