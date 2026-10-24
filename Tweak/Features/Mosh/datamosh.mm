/*
 * datamosh.c — real-time datamosh core
 * See datamosh.h for what this is doing and why.
 */

#include "datamosh.h"

#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#ifdef __APPLE__
#include <dispatch/dispatch.h>
#endif

enum { PEND_NONE = 0, PEND_RESET = 1, PEND_DROP = 2 };

struct dm_context {
    int w, h;              /* full resolution                                */
    int hw, hh;            /* half-res luma plane used for motion estimation */
    int bw, bh;            /* motion field dimensions, in blocks             */
    dm_config cfg;

    uint8_t *canvas;       /* the decoder's reference picture: w*h*4         */
    uint8_t *scratch;      /* reconstruction destination: w*h*4              */
    uint8_t *prev;         /* true previous source frame: w*h*4              */
    uint8_t *luma_prev;    /* hw*hh                                          */
    uint8_t *luma_cur;     /* hw*hh                                          */
    int16_t *mvx, *mvy;    /* bw*bh, in half-res pixels                      */
    int16_t *medx, *medy;  /* bw*bh, scratch for the median filter           */

    int started;
    int pending;
    int frames_since_key;
    float last_motion;
    float last_scene_change;
    float ghost;
};

/* ------------------------------------------------------------------ utils */

static int iclamp(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }
static float fclampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

dm_config dm_default_config(void)
{
    dm_config c;
    c.block               = 8;
    c.search              = 8;
    c.still_threshold     = 90;
    c.residual            = 1.0f;
    c.ghost_decay         = 0.0f;
    c.smooth_vectors      = 1;
    c.scene_cut_threshold = 0;
    c.drop_interval       = 0;
    c.pixel_order         = DM_PIXEL_RGBA;
    return c;
}

static void sanitize(dm_config *c)
{
    c->block               = iclamp(c->block, 4, 32);
    c->search              = iclamp(c->search, 1, 64);
    c->still_threshold     = iclamp(c->still_threshold, 0, 1 << 20);
    c->residual            = fclampf(c->residual, 0.0f, 1.0f);
    c->ghost_decay         = fclampf(c->ghost_decay, 0.0f, 1.0f);
    c->smooth_vectors      = c->smooth_vectors ? 1 : 0;
    c->scene_cut_threshold = iclamp(c->scene_cut_threshold, 0, 255);
    if (c->drop_interval < 0) c->drop_interval = 0;
    if (c->pixel_order != DM_PIXEL_BGRA && c->pixel_order != DM_PIXEL_YCBCR)
        c->pixel_order = DM_PIXEL_RGBA;
}

/* ------------------------------------------------------- luma downsample */

/*
 * Motion estimation only needs brightness, at half resolution: a 2x downscale
 * cuts the search cost by four and, because real motion is low-frequency,
 * costs almost nothing in vector quality. It also averages away sensor grain,
 * which is the main source of spurious vectors in flat areas.
 */
static void build_luma(const dm_context *ctx, const uint8_t *in, uint8_t *out)
{
    const int w = ctx->w, h = ctx->h, hw = ctx->hw, hh = ctx->hh;
    const int ri = (ctx->cfg.pixel_order == DM_PIXEL_BGRA) ? 2 : 0;
    const int bi = (ctx->cfg.pixel_order == DM_PIXEL_BGRA) ? 0 : 2;

    if (ctx->cfg.pixel_order == DM_PIXEL_YCBCR) {
        for (int y = 0; y < hh; ++y) {
            const int y0 = y * 2, y1 = (y0 + 1 < h) ? y0 + 1 : y0;
            const uint8_t *r0 = in + (size_t)y0 * w * 4;
            const uint8_t *r1 = in + (size_t)y1 * w * 4;
            uint8_t *dst = out + (size_t)y * hw;
            for (int x = 0; x < hw; ++x) {
                const int x0 = x * 2, x1 = (x0 + 1 < w) ? x0 + 1 : x0;
                dst[x] = (uint8_t)((r0[x0 * 4] + r0[x1 * 4] + r1[x0 * 4] + r1[x1 * 4]) >> 2);
            }
        }
        return;
    }

    for (int y = 0; y < hh; ++y) {
        const int y0 = y * 2, y1 = (y0 + 1 < h) ? y0 + 1 : y0;
        const uint8_t *r0 = in + (size_t)y0 * w * 4;
        const uint8_t *r1 = in + (size_t)y1 * w * 4;
        uint8_t *dst = out + (size_t)y * hw;

        for (int x = 0; x < hw; ++x) {
            const int x0 = x * 2, x1 = (x0 + 1 < w) ? x0 + 1 : x0;
            const uint8_t *a = r0 + (size_t)x0 * 4, *b = r0 + (size_t)x1 * 4;
            const uint8_t *c = r1 + (size_t)x0 * 4, *d = r1 + (size_t)x1 * 4;
            const int sum =
                (77 * a[ri] + 150 * a[1] + 29 * a[bi]) +
                (77 * b[ri] + 150 * b[1] + 29 * b[bi]) +
                (77 * c[ri] + 150 * c[1] + 29 * c[bi]) +
                (77 * d[ri] + 150 * d[1] + 29 * d[bi]);
            dst[x] = (uint8_t)(sum >> 10);   /* >>8 luma, >>2 for the 4 taps */
        }
    }
}

static float mean_luma_change(const dm_context *ctx)
{
    const size_t n = (size_t)ctx->hw * ctx->hh;
    unsigned long total = 0;
    for (size_t i = 0; i < n; ++i) {
        const int d = (int)ctx->luma_cur[i] - (int)ctx->luma_prev[i];
        total += (unsigned long)(d < 0 ? -d : d);
    }
    return n ? (float)total / (float)n : 0.0f;
}

/* -------------------------------------------------- motion estimation */

static int sad(const uint8_t *cur, const uint8_t *prev, int stride,
               int x0, int y0, int bw, int bh, int dx, int dy,
               int planeW, int planeH, int best)
{
    const int sx = x0 + dx, sy = y0 + dy;
    if (sx < 0 || sy < 0 || sx + bw > planeW || sy + bh > planeH) return INT_MAX;

    int total = 0;
    for (int y = 0; y < bh; ++y) {
        const uint8_t *a = cur  + (size_t)(y0 + y) * stride + x0;
        const uint8_t *b = prev + (size_t)(sy + y) * stride + sx;
        for (int x = 0; x < bw; ++x) {
            const int d = (int)a[x] - (int)b[x];
            total += d < 0 ? -d : d;
        }
        if (total >= best) return total;      /* already lost */
    }
    return total;
}

/*
 * Three-step search: test the 8 neighbours at a coarse step, move to the
 * winner, halve the step, repeat. Finds large motion in ~25 comparisons where
 * exhausting the same radius needs ~289, and on real video the two almost
 * always agree.
 */
static void search_block(const dm_context *ctx, int bx, int by, int *out_x, int *out_y)
{
    const dm_config *cfg = &ctx->cfg;
    const int B = cfg->block, R = cfg->search;
    const int x0 = bx * B, y0 = by * B;
    const int bw = (x0 + B <= ctx->hw) ? B : ctx->hw - x0;
    const int bh = (y0 + B <= ctx->hh) ? B : ctx->hh - y0;

    int vx = 0, vy = 0;
    int best = sad(ctx->luma_cur, ctx->luma_prev, ctx->hw, x0, y0, bw, bh,
                   0, 0, ctx->hw, ctx->hh, INT_MAX);

    /* A block already matching where it sits is not moving, and chasing
     * sensor noise around a flat wall is what makes a still camera crawl. */
    if (best <= cfg->still_threshold) { *out_x = 0; *out_y = 0; return; }

    int step = 1;
    while (step * 2 <= R) step *= 2;

    static const int OX[8] = { -1, 0, 1, -1, 1, -1, 0, 1 };
    static const int OY[8] = { -1, -1, -1, 0, 0, 1, 1, 1 };

    while (step >= 1) {
        int nx = vx, ny = vy;
        for (int i = 0; i < 8; ++i) {
            const int cx = vx + OX[i] * step, cy = vy + OY[i] * step;
            if (cx < -R || cx > R || cy < -R || cy > R) continue;
            const int s = sad(ctx->luma_cur, ctx->luma_prev, ctx->hw,
                              x0, y0, bw, bh, cx, cy, ctx->hw, ctx->hh, best);
            if (s < best) { best = s; nx = cx; ny = cy; }
        }
        vx = nx; vy = ny;
        step >>= 1;
    }
    *out_x = vx; *out_y = vy;
}

static int16_t median9(int16_t *v)
{
    for (int i = 1; i < 9; ++i) {
        const int16_t k = v[i];
        int j = i - 1;
        while (j >= 0 && v[j] > k) { v[j + 1] = v[j]; --j; }
        v[j + 1] = k;
    }
    return v[4];
}

/*
 * A 3x3 median over the motion field. Block matching gets a few blocks badly
 * wrong every frame — a patch of sky matching some unrelated patch of sky —
 * and once a ghost is riding on those vectors the errors read as sparkle. A
 * median removes them without rounding off real motion edges the way a blur
 * would.
 */
static void smooth_field(dm_context *ctx)
{
    const int bw = ctx->bw, bh = ctx->bh;
    for (int y = 0; y < bh; ++y) {
        for (int x = 0; x < bw; ++x) {
            int16_t wx[9], wy[9];
            int n = 0;
            for (int dy = -1; dy <= 1; ++dy) {
                for (int dx = -1; dx <= 1; ++dx) {
                    const int sx = iclamp(x + dx, 0, bw - 1);
                    const int sy = iclamp(y + dy, 0, bh - 1);
                    wx[n] = ctx->mvx[sy * bw + sx];
                    wy[n] = ctx->mvy[sy * bw + sx];
                    ++n;
                }
            }
            ctx->medx[y * bw + x] = median9(wx);
            ctx->medy[y * bw + x] = median9(wy);
        }
    }
    memcpy(ctx->mvx, ctx->medx, (size_t)bw * bh * sizeof(int16_t));
    memcpy(ctx->mvy, ctx->medy, (size_t)bw * bh * sizeof(int16_t));
}

/* ------------------------------------------------------------ the mosh */

/*
 * One P-frame, decoded onto the wrong reference picture:
 *
 *     out = warp(canvas, mv) + residual * [ cur - warp(prev, mv) ]
 *
 * Both warps use the SAME vectors and the SAME clamping, which is what makes
 * the two terms cancel exactly while canvas == prev. Any asymmetry between
 * them would leak a permanent error into the picture even with no mosh
 * running, so the two reads are done together, pixel by pixel, rather than in
 * separate passes.
 */
static void reconstruct_row(dm_context *ctx, const uint8_t *cur, int by)
{
    const int w = ctx->w, h = ctx->h;
    const int B2 = ctx->cfg.block * 2;             /* block size, full-res */
    const int k = (int)(ctx->cfg.residual * 256.0f + 0.5f);
    const uint8_t *canvas = ctx->canvas, *prev = ctx->prev;
    uint8_t *dst = ctx->scratch;

    {
        const int y0 = by * B2;
        const int y1 = (y0 + B2 < h) ? y0 + B2 : h;
        for (int bx = 0; bx < ctx->bw; ++bx) {
            const int x0 = bx * B2;
            const int x1 = (x0 + B2 < w) ? x0 + B2 : w;

            /* half-res vectors describe full-res motion of twice the size */
            const int fx = ctx->mvx[by * ctx->bw + bx] * 2;
            const int fy = ctx->mvy[by * ctx->bw + bx] * 2;

            for (int y = y0; y < y1; ++y) {
                const int sy = iclamp(y + fy, 0, h - 1);
                const uint8_t *crow = canvas + (size_t)sy * w * 4;
                const uint8_t *prow = prev   + (size_t)sy * w * 4;
                const uint8_t *urow = cur    + (size_t)y  * w * 4;
                uint8_t *drow = dst + (size_t)y * w * 4;

                for (int x = x0; x < x1; ++x) {
                    const int sx = iclamp(x + fx, 0, w - 1);
                    const uint8_t *cp = crow + (size_t)sx * 4;
                    const uint8_t *pp = prow + (size_t)sx * 4;
                    const uint8_t *up = urow + (size_t)x * 4;
                    uint8_t *dp = drow + (size_t)x * 4;

                    for (int c = 0; c < 3; ++c) {
                        const int resid = ((int)up[c] - (int)pp[c]) * k / 256;
                        const int v = (int)cp[c] + resid;
                        dp[c] = (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v));
                    }
                    dp[3] = 255;
                }
            }
        }
    }
}

/* Each block row writes its own rows of `scratch`, so rows run in parallel. */
static void reconstruct(dm_context *ctx, const uint8_t *cur)
{
#ifdef __APPLE__
    dispatch_apply((size_t)ctx->bh, DISPATCH_APPLY_AUTO, ^(size_t by) {
        reconstruct_row(ctx, cur, (int)by);
    });
#else
    for (int by = 0; by < ctx->bh; ++by) reconstruct_row(ctx, cur, by);
#endif
}

/* Pull the canvas back toward reality, fading the ghost. */
static void decay_ghost(dm_context *ctx, const uint8_t *cur)
{
    const float g = ctx->cfg.ghost_decay;
    if (g <= 0.0f) return;
    const int k = (int)(g * 256.0f + 0.5f);
    if (k <= 0) return;
    const size_t n = (size_t)ctx->w * ctx->h * 4;
    uint8_t *c = ctx->scratch;
    for (size_t i = 0; i < n; ++i)
        c[i] = (uint8_t)((c[i] * (256 - k) + cur[i] * k) >> 8);
}

/* Mean absolute canvas-vs-reality difference, sampled. Zero when no mosh is
 * running, which is a useful invariant to be able to assert. */
static void measure_ghost(dm_context *ctx)
{
    const size_t n = (size_t)ctx->w * ctx->h * 4;
    unsigned long total = 0; size_t count = 0;
    for (size_t i = 0; i < n; i += 32) {          /* every 8th pixel */
        const int d = (int)ctx->canvas[i] - (int)ctx->prev[i];
        total += (unsigned long)(d < 0 ? -d : d);
        ++count;
    }
    ctx->ghost = count ? (float)total / (float)count : 0.0f;
}

/* --------------------------------------------------------------- public */

dm_context *dm_create(int width, int height, const dm_config *cfg)
{
    if (width < 8 || height < 8) return NULL;
    if (width > 16384 || height > 16384) return NULL;

    dm_context *ctx = (dm_context *)calloc(1, sizeof(*ctx));
    if (!ctx) return NULL;

    ctx->cfg = cfg ? *cfg : dm_default_config();
    sanitize(&ctx->cfg);

    ctx->w = width;  ctx->h = height;
    ctx->hw = width / 2;  ctx->hh = height / 2;
    if (ctx->hw < 1) ctx->hw = 1;
    if (ctx->hh < 1) ctx->hh = 1;
    ctx->bw = (ctx->hw + ctx->cfg.block - 1) / ctx->cfg.block;
    ctx->bh = (ctx->hh + ctx->cfg.block - 1) / ctx->cfg.block;

    const size_t frame = (size_t)width * height * 4;
    const size_t luma  = (size_t)ctx->hw * ctx->hh;
    const size_t field = (size_t)ctx->bw * ctx->bh * sizeof(int16_t);

    ctx->canvas    = (uint8_t *)calloc(1, frame);
    ctx->scratch   = (uint8_t *)calloc(1, frame);
    ctx->prev      = (uint8_t *)calloc(1, frame);
    ctx->luma_prev = (uint8_t *)calloc(1, luma);
    ctx->luma_cur  = (uint8_t *)calloc(1, luma);
    ctx->mvx       = (int16_t *)calloc(1, field);
    ctx->mvy       = (int16_t *)calloc(1, field);
    ctx->medx      = (int16_t *)calloc(1, field);
    ctx->medy      = (int16_t *)calloc(1, field);

    if (!ctx->canvas || !ctx->scratch || !ctx->prev || !ctx->luma_prev ||
        !ctx->luma_cur || !ctx->mvx || !ctx->mvy || !ctx->medx || !ctx->medy) {
        dm_destroy(ctx);
        return NULL;
    }
    return ctx;
}

void dm_destroy(dm_context *ctx)
{
    if (!ctx) return;
    free(ctx->canvas); free(ctx->scratch); free(ctx->prev);
    free(ctx->luma_prev); free(ctx->luma_cur);
    free(ctx->mvx); free(ctx->mvy);
    free(ctx->medx); free(ctx->medy);
    free(ctx);
}

void dm_reset(dm_context *ctx) { if (ctx) ctx->pending = PEND_RESET; }
void dm_drop(dm_context *ctx)  { if (ctx) ctx->pending = PEND_DROP;  }

void dm_set_config(dm_context *ctx, const dm_config *cfg)
{
    if (!ctx || !cfg) return;
    const int block = ctx->cfg.block;        /* fixed at create time */
    ctx->cfg = *cfg;
    ctx->cfg.block = block;
    sanitize(&ctx->cfg);
}

dm_config dm_get_config(const dm_context *ctx)
{
    return ctx ? ctx->cfg : dm_default_config();
}

float dm_last_motion(const dm_context *ctx) { return ctx ? ctx->last_motion : 0.0f; }
float dm_last_scene_change(const dm_context *ctx) { return ctx ? ctx->last_scene_change : 0.0f; }
float dm_ghost_strength(const dm_context *ctx) { return ctx ? ctx->ghost : 0.0f; }
int dm_frames_since_keyframe(const dm_context *ctx) { return ctx ? ctx->frames_since_key : 0; }

void dm_process(dm_context *ctx, const uint8_t *in, uint8_t *out)
{
    if (!ctx || !in || !out) return;
    const size_t frame = (size_t)ctx->w * ctx->h * 4;
    const size_t luma  = (size_t)ctx->hw * ctx->hh;

    /* First frame has nothing to predict from: it is a keyframe by force. */
    if (!ctx->started) ctx->pending = PEND_RESET;

    build_luma(ctx, in, ctx->luma_cur);
    ctx->last_scene_change = ctx->started ? mean_luma_change(ctx) : 0.0f;

    if (ctx->started && ctx->pending == PEND_NONE) {
        if (ctx->cfg.scene_cut_threshold > 0 &&
            ctx->last_scene_change >= (float)ctx->cfg.scene_cut_threshold)
            ctx->pending = PEND_DROP;
        else if (ctx->cfg.drop_interval > 0 &&
                 ctx->frames_since_key >= ctx->cfg.drop_interval)
            ctx->pending = PEND_DROP;
    }

    /* A keyframe let through: the canvas becomes reality and the ghost dies. */
    if (ctx->pending == PEND_RESET) {
        memcpy(ctx->canvas, in, frame);
        memcpy(ctx->prev, in, frame);
        memcpy(ctx->luma_prev, ctx->luma_cur, luma);
        memset(ctx->mvx, 0, (size_t)ctx->bw * ctx->bh * sizeof(int16_t));
        memset(ctx->mvy, 0, (size_t)ctx->bw * ctx->bh * sizeof(int16_t));
        ctx->pending = PEND_NONE;
        ctx->started = 1;
        ctx->frames_since_key = 0;
        ctx->last_motion = 0.0f;
        ctx->ghost = 0.0f;
        memmove(out, ctx->canvas, frame);
        return;
    }

    /* A keyframe DELETED: the reference holds its picture while the world
     * moves on. From here the two diverge, and that difference is the mosh. */
    if (ctx->pending == PEND_DROP) {
        memcpy(ctx->prev, in, frame);
        memcpy(ctx->luma_prev, ctx->luma_cur, luma);
        memset(ctx->mvx, 0, (size_t)ctx->bw * ctx->bh * sizeof(int16_t));
        memset(ctx->mvy, 0, (size_t)ctx->bw * ctx->bh * sizeof(int16_t));
        ctx->pending = PEND_NONE;
        ctx->frames_since_key = 0;
        ctx->last_motion = 0.0f;
        measure_ghost(ctx);
        memmove(out, ctx->canvas, frame);
        return;
    }

    /* Ordinary P-frame. Every block is searched independently, so on Apple
     * platforms the rows are spread across cores. */
    double motion = 0.0;
#ifdef __APPLE__
    double *row_motion = (double *)calloc((size_t)ctx->bh, sizeof(double));
    if (row_motion != NULL) {
        dispatch_apply((size_t)ctx->bh, DISPATCH_APPLY_AUTO, ^(size_t row) {
            const int by = (int)row;
            double sum = 0.0;
            for (int bx = 0; bx < ctx->bw; ++bx) {
                int vx, vy;
                search_block(ctx, bx, by, &vx, &vy);
                ctx->mvx[by * ctx->bw + bx] = (int16_t)vx;
                ctx->mvy[by * ctx->bw + bx] = (int16_t)vy;
                sum += sqrt((double)(vx * vx + vy * vy));
            }
            row_motion[row] = sum;
        });
        for (int by = 0; by < ctx->bh; ++by) motion += row_motion[by];
        free(row_motion);
    } else
#endif
    for (int by = 0; by < ctx->bh; ++by) {
        for (int bx = 0; bx < ctx->bw; ++bx) {
            int vx, vy;
            search_block(ctx, bx, by, &vx, &vy);
            ctx->mvx[by * ctx->bw + bx] = (int16_t)vx;
            ctx->mvy[by * ctx->bw + bx] = (int16_t)vy;
            motion += sqrt((double)(vx * vx + vy * vy));
        }
    }
    ctx->last_motion = (float)(motion / (ctx->bw * ctx->bh) * 2.0);

    if (ctx->cfg.smooth_vectors) smooth_field(ctx);

    reconstruct(ctx, in);
    decay_ghost(ctx, in);

    /* scratch holds the new reference picture; swap rather than copy */
    uint8_t *t = ctx->canvas; ctx->canvas = ctx->scratch; ctx->scratch = t;

    memcpy(ctx->prev, in, frame);            /* read of `in` finishes here */
    t = ctx->luma_prev; ctx->luma_prev = ctx->luma_cur; ctx->luma_cur = t;

    ctx->frames_since_key++;
    measure_ghost(ctx);
    memmove(out, ctx->canvas, frame);        /* memmove: in and out may alias */
}
