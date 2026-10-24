/*
 * datamosh.h — real-time datamosh core
 *
 * Portable C99. No dependencies, no platform headers. Builds on Linux, macOS,
 * iOS, Android, Windows. Callable from Swift, Kotlin/JNI, C++ or plain C.
 *
 * ---------------------------------------------------------------------------
 * WHAT DATAMOSHING ACTUALLY IS
 * ---------------------------------------------------------------------------
 *
 * Video codecs do not store every frame as a picture. They store two kinds:
 *
 *   I-frame  a complete picture, standing on its own.
 *
 *   P-frame  no picture at all. Two things only:
 *              - MOTION VECTORS: "move these 16x16 blocks by these amounts"
 *              - a RESIDUAL: the small correction left over once those blocks
 *                have been moved, i.e. everything the motion failed to predict
 *
 * A decoder rebuilds a P-frame as:
 *
 *     output = warp(reference, motion) + residual
 *
 * and `reference` is just whatever picture is in its buffer. Normally that is
 * the correct previous frame, the two terms cancel out to the truth, and you
 * see what was filmed.
 *
 * The classic datamosh deletes an I-frame. The P-frames that follow still
 * arrive with motion and residuals computed against a picture the decoder no
 * longer has, so `reference` holds the OLD scene while the data describes the
 * NEW one. Writing that out and rearranging:
 *
 *     output = warp(old, motion) + [new - warp(prev_new, motion)]
 *            = new + warp(old - prev_new, motion)
 *
 * which is the whole effect in one line, and worth reading twice:
 *
 *   - The new scene arrives INTACT. It is not destroyed, blurred or lost.
 *   - On top of it rides the DIFFERENCE between the two scenes at the cut.
 *   - That difference is dragged along by the new scene's motion, block by
 *     block, forever, because each frame warps what the last frame left.
 *
 * So the look is the old picture's colour and brightness smeared across the
 * new picture's structure. Not mush — a ghost with the live scene visible
 * through it.
 *
 * ---------------------------------------------------------------------------
 * DOING IT LIVE
 * ---------------------------------------------------------------------------
 *
 * A camera hands you finished pictures. There is no bitstream to cut, so this
 * reconstructs both halves of a P-frame from scratch:
 *
 *   1. MOTION. Compare this frame to the last one and search for each block's
 *      best match. This is the same block-matching an encoder runs.
 *
 *   2. RESIDUAL. Subtract the motion-compensated previous frame from the
 *      current one. That difference is, by definition, exactly what the
 *      encoder would have stored.
 *
 *   3. DECODE ONTO THE WRONG PICTURE. Apply that motion and that residual to
 *      the CANVAS — a held picture that is no longer the true previous frame.
 *
 * While the canvas equals the previous frame the two terms cancel and output
 * is bit-exact with the input: no effect at all. The effect begins the moment
 * they diverge, and they diverge when you delete a keyframe — dm_drop().
 *
 * ---------------------------------------------------------------------------
 * THE TWO CONTROLS THAT MATTER
 * ---------------------------------------------------------------------------
 *
 *   dm_drop()   Delete a keyframe. The canvas holds its picture while the
 *               world moves on, so a ghost is born and starts smearing.
 *               This is what starts a mosh.
 *
 *   dm_reset()  Let a keyframe through. The canvas snaps back to reality and
 *               the ghost is gone. This is what ends one.
 *
 * Cutting between two clips is one dm_drop() on the first frame after the cut.
 * That is the entire classic two-scene datamosh.
 *
 * ---------------------------------------------------------------------------
 * USING IT
 * ---------------------------------------------------------------------------
 *
 *     dm_config cfg = dm_default_config();
 *     dm_context *ctx = dm_create(width, height, &cfg);
 *
 *     dm_process(ctx, in_rgba, out_rgba);   // per frame
 *     dm_drop(ctx);                         // start moshing
 *     dm_reset(ctx);                        // stop moshing
 *     dm_destroy(ctx);
 *
 * Buffers are tightly packed, 4 bytes per pixel, width*height*4. `in` and
 * `out` may be the same pointer. dm_process does not allocate and does not
 * block, so it is safe to call from a capture callback.
 *
 * Single-threaded and not reentrant per context. One context per stream.
 */

#ifndef DATAMOSH_H
#define DATAMOSH_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DM_VERSION_MAJOR 2
#define DM_VERSION_MINOR 0

/* Byte order of the 4-channel buffers you pass in. Affects only how luma is
 * computed for motion estimation.
 *   DM_PIXEL_RGBA  Android, OpenGL, most Linux paths
 *   DM_PIXEL_BGRA  iOS/macOS CVPixelBuffer kCVPixelFormatType_32BGRA */
typedef enum {
    DM_PIXEL_RGBA = 0,
    DM_PIXEL_BGRA = 1,
    /* Channel 0 is luma (Y), 1-2 chroma, 3 unused. Camera YUV frames packed
     * to 4 bytes per pixel by the caller. */
    DM_PIXEL_YCBCR = 2
} dm_pixel_order;

typedef struct {
    /* Motion estimation runs on a half-resolution luma plane, so a block of 8
     * here covers 16 pixels of real image — the same macroblock a codec uses.
     * Fixed at create time. */
    int block;              /* default 8,   range 4..32  */

    /* How far a block may be matched from, in half-res pixels. Raise for fast
     * motion; cost grows with log of this, not linearly. */
    int search;             /* default 8,   range 1..64  */

    /* Blocks matching this well where they already sit are treated as still.
     * Stops sensor noise inventing motion across flat walls and sky. */
    int still_threshold;    /* default 90,  SAD units    */

    /* How much of the residual to apply.
     *   1.0  true P-frame decode. The live scene comes through intact under
     *        the ghost. This is real datamosh and the correct default.
     *   0.0  motion only. The canvas is pushed around with nothing painted
     *        back in, so it degrades to coloured mush within a second or two.
     * Values in between thin the live scene out. Below ~0.6 it stops reading
     * as a mosh and starts reading as a smear filter. */
    float residual;         /* default 1.0, range 0..1   */

    /* Per-frame pull of the canvas back toward reality, fading the ghost.
     * 0.0 keeps it forever, which is the classic behaviour. 0.01-0.05 gives a
     * mosh that heals over a few seconds. */
    float ghost_decay;      /* default 0.0, range 0..1   */

    /* 3x3 median over the motion field. Costs little, removes the lone wrong
     * vectors that read as sparkle once a ghost is smeared. */
    int smooth_vectors;     /* default 1                 */

    /* Mean luma jump, 0..255, that counts as a cut and triggers an automatic
     * dm_drop(). This is what makes concatenated clips mosh at their joins
     * with no manual marking. 0 disables it. */
    int scene_cut_threshold;/* default 0, try 14         */

    /* Drop a keyframe every N frames, for a rhythmic pulsing mosh.
     * 0 disables. */
    int drop_interval;      /* default 0                 */

    dm_pixel_order pixel_order;  /* default DM_PIXEL_RGBA */
} dm_config;

typedef struct dm_context dm_context;

dm_config dm_default_config(void);

/* NULL on bad dimensions or allocation failure. `cfg` may be NULL for
 * defaults; it is copied. */
dm_context *dm_create(int width, int height, const dm_config *cfg);
void dm_destroy(dm_context *ctx);

/* One frame. `in` and `out` are width*height*4 bytes and may alias. */
void dm_process(dm_context *ctx, const uint8_t *in, uint8_t *out);

/* Delete a keyframe: the canvas holds while the world moves on. Starts a mosh.
 * Takes effect on the next dm_process. */
void dm_drop(dm_context *ctx);

/* Let a keyframe through: the canvas snaps back to the live picture. Ends a
 * mosh. Takes effect on the next dm_process. */
void dm_reset(dm_context *ctx);

/* Live tuning. `block` is fixed at create time and ignored here. */
void dm_set_config(dm_context *ctx, const dm_config *cfg);
dm_config dm_get_config(const dm_context *ctx);

/* Mean motion-vector magnitude of the last frame, in full-resolution pixels. */
float dm_last_motion(const dm_context *ctx);

/* Mean absolute luma change between the last two frames, 0..255. This is what
 * scene_cut_threshold is compared against — read it on known footage to pick
 * a threshold. */
float dm_last_scene_change(const dm_context *ctx);

/* How far the canvas has drifted from reality: mean absolute difference per
 * channel, 0..255. Zero means no mosh is active. Drives an auto-reset, or a
 * UI meter showing how moshed the picture is. */
float dm_ghost_strength(const dm_context *ctx);

/* Frames processed since the last drop or reset. */
int dm_frames_since_keyframe(const dm_context *ctx);

#ifdef __cplusplus
}
#endif

#endif /* DATAMOSH_H */
