//! Startup splash: the wordmark "Metask Lab" condenses out of a particle
//! brightness field, drawn only with the letters of "Metask Lab".
//!
//! The technique follows chenglou.me/pretext/variable-typographic-ascii:
//! particles pulled by two drifting attractors splat soft stamps into a
//! decaying brightness field, and every cell picks a glyph by ink density and
//! weight plus a colour tier for its brightness. A terminal is monospace, so
//! the page's width × weight × italic palette becomes SGR here: bold carries
//! ink, italic marks a cell whose light is still in flight.
//!
//! The wordmark is a monoline geometric face written as capsule strokes in em
//! units and rasterised through its distance field, so it scales with the
//! terminal width and keeps anti-aliased edges and a faint halo.
//!
//! Pure: no terminal I/O and no clock. `splash_player.zig` owns timing, the
//! skip key and the tty. Everything here is a function of (layout, seed, t).

const std = @import("std");

pub const ColorMode = enum { none, basic_16, extended_256, truecolor };
pub const Background = enum { dark, light };
pub const Style = struct { mode: ColorMode, bg: Background };

/// Seconds from the first frame to the settled wordmark.
pub const duration: f32 = 1.5;
/// Target frame interval for the player.
pub const frame_ns: u64 = 33 * std.time.ns_per_ms;

const sim_dt: f32 = 1.0 / 60.0;

// Timeline, in seconds. Particles leave the two orbs left to right, the
// strokes ink in behind them, then a glint runs along the letters.
const gather_start: f32 = 0.30;
const stagger: f32 = 0.35;
const gather_dur: f32 = 0.50;
const ink_lag: f32 = 0.25;
const ink_dur: f32 = 0.35;
const glint_start: f32 = 1.05;
const glint_dur: f32 = 0.40;

// ── Wordmark geometry (em units: baseline y=0, up positive, cap height 1) ──

pub const wordmark = "Metask Lab";

const x_height: f32 = 0.70;
const stroke_r: f32 = 0.085;
const tracking: f32 = 0.13;

const Pt = [2]f32;
const Arc = struct { cx: f32, cy: f32, rx: f32, ry: f32, a0: f32, a1: f32 };
const Prim = union(enum) { poly: []const Pt, arc: Arc };
const GlyphDef = struct { width: f32, prims: []const Prim };

fn glyphDef(ch: u8) GlyphDef {
    const xh = x_height;
    return switch (ch) {
        'M' => .{ .width = 0.78, .prims = &.{
            .{ .poly = &.{ .{ 0, 0 }, .{ 0, 1 } } },
            .{ .poly = &.{ .{ 0, 1 }, .{ 0.39, 0.38 }, .{ 0.78, 1 } } },
            .{ .poly = &.{ .{ 0.78, 1 }, .{ 0.78, 0 } } },
        } },
        'e' => .{ .width = 0.60, .prims = &.{
            .{ .poly = &.{ .{ 0, xh / 2 }, .{ 0.60, xh / 2 } } },
            .{ .arc = .{ .cx = 0.30, .cy = xh / 2, .rx = 0.30, .ry = xh / 2, .a0 = 0, .a1 = 318 } },
        } },
        't' => .{ .width = 0.42, .prims = &.{
            .{ .poly = &.{ .{ 0.16, 0.95 }, .{ 0.16, 0.14 } } },
            .{ .arc = .{ .cx = 0.32, .cy = 0.14, .rx = 0.16, .ry = 0.14, .a0 = 180, .a1 = 280 } },
            .{ .poly = &.{ .{ 0, xh }, .{ 0.40, xh } } },
        } },
        'a' => .{ .width = 0.58, .prims = &.{
            .{ .arc = .{ .cx = 0.29, .cy = xh / 2, .rx = 0.29, .ry = xh / 2, .a0 = 0, .a1 = 360 } },
            .{ .poly = &.{ .{ 0.58, xh }, .{ 0.58, 0 } } },
        } },
        's' => .{ .width = 0.50, .prims = &.{
            .{ .arc = .{ .cx = 0.25, .cy = xh * 0.74, .rx = 0.25, .ry = xh * 0.26, .a0 = 25, .a1 = 270 } },
            .{ .arc = .{ .cx = 0.25, .cy = xh * 0.26, .rx = 0.25, .ry = xh * 0.26, .a0 = 90, .a1 = -155 } },
        } },
        'k' => .{ .width = 0.50, .prims = &.{
            .{ .poly = &.{ .{ 0, 0 }, .{ 0, 1 } } },
            .{ .poly = &.{ .{ 0.50, xh }, .{ 0.02, xh * 0.36 } } },
            .{ .poly = &.{ .{ 0.17, xh * 0.5 }, .{ 0.50, 0 } } },
        } },
        'L' => .{ .width = 0.48, .prims = &.{
            .{ .poly = &.{ .{ 0, 1 }, .{ 0, 0 }, .{ 0.48, 0 } } },
        } },
        'b' => .{ .width = 0.58, .prims = &.{
            .{ .poly = &.{ .{ 0, 1 }, .{ 0, 0 } } },
            .{ .arc = .{ .cx = 0.29, .cy = xh / 2, .rx = 0.29, .ry = xh / 2, .a0 = 0, .a1 = 360 } },
        } },
        ' ' => .{ .width = 0.18, .prims = &.{} },
        else => unreachable,
    };
}

/// Ink extent of the wordmark in em, from the left edge of the first stroke
/// to the right edge of the last.
fn wordWidthEm() f32 {
    var x: f32 = stroke_r;
    for (wordmark) |ch| x += glyphDef(ch).width + 2 * stroke_r + tracking;
    return x - tracking - stroke_r;
}

// ── Layout ──
//
// A unit is one column wide and half a row tall, so the units are close to
// square on common terminal fonts (cells are about twice as tall as wide).

pub const Layout = struct {
    cols: u16,
    rows: u16,
    /// Units per em, i.e. the cap height in units.
    scale: f32,
    /// Units from the region's left edge to em x=0.
    origin_x: f32,
    /// Units from the region's top edge down to the baseline.
    baseline: f32,
};

/// Smallest cap height that keeps the bowls of e/a/s/b open: four rows.
pub const min_scale: f32 = 8;
const max_scale: f32 = 16;
const margin_cols: u16 = 2;

/// Fit the wordmark to a terminal. `null` when it cannot be drawn legibly,
/// or when the region plus a spare row would not fit on screen (a cursor-up
/// redraw cannot reach rows that scrolled away).
pub fn layoutFor(term_cols: u16, term_rows: u16) ?Layout {
    const width_em = wordWidthEm();
    const avail_cols: f32 = @floatFromInt(term_cols -| 2 * margin_cols);
    // rows = cap rows + a halo row above and below; the screen must also hold
    // the line the cursor waits on below the region, plus one spare.
    const max_cap_rows: f32 = @floatFromInt(term_rows -| 4);
    const scale = @min(@min(avail_cols / width_em, max_scale), 2 * max_cap_rows);
    if (!(scale >= min_scale)) return null;
    const cap_rows: u16 = @intFromFloat(@ceil(scale / 2));
    const rows = cap_rows + 2;
    const cols_f: f32 = @floatFromInt(term_cols);
    const cap_top = 2 + (@as(f32, @floatFromInt(cap_rows)) * 2 - scale) / 2;
    return .{
        .cols = term_cols,
        .rows = rows,
        .scale = scale,
        .origin_x = @round((cols_f - width_em * scale) / 2),
        .baseline = cap_top + scale,
    };
}

// ── Glyph palette ──
//
// Ink coverage of the letters of "Metask Lab" at regular and bold weight,
// measured the way the pretext page measures its palette (alpha summed off a
// canvas) and averaged over Menlo, Monaco, SF Mono, Courier New, Andale Mono
// and PT Mono, each normalised to its bold M. Italic did not move any value by
// more than 2%, so style stays free to signal motion.

const Variant = struct { ch: u8, bold: bool, ink: f32 };

const ramp_raw = [_]Variant{
    .{ .ch = 'L', .bold = false, .ink = 0.391 },
    .{ .ch = 't', .bold = false, .ink = 0.392 },
    .{ .ch = 's', .bold = false, .ink = 0.440 },
    .{ .ch = 'e', .bold = false, .ink = 0.510 },
    .{ .ch = 'a', .bold = false, .ink = 0.517 },
    .{ .ch = 'k', .bold = false, .ink = 0.525 },
    .{ .ch = 'L', .bold = true, .ink = 0.534 },
    .{ .ch = 't', .bold = true, .ink = 0.536 },
    .{ .ch = 's', .bold = true, .ink = 0.579 },
    .{ .ch = 'b', .bold = false, .ink = 0.597 },
    .{ .ch = 'a', .bold = true, .ink = 0.663 },
    .{ .ch = 'e', .bold = true, .ink = 0.665 },
    .{ .ch = 'k', .bold = true, .ink = 0.700 },
    .{ .ch = 'b', .bold = true, .ink = 0.774 },
    .{ .ch = 'M', .bold = false, .ink = 0.784 },
    .{ .ch = 'M', .bold = true, .ink = 1.000 },
};

/// The ramp rescaled so the lightest variant sits at 0 and bold M at 1.
const ramp = blk: {
    var out = ramp_raw;
    const lo = ramp_raw[0].ink;
    for (&out) |*v| v.ink = (v.ink - lo) / (1 - lo);
    break :blk out;
};

/// How far either side of the target ink a variant may sit and still be
/// picked; the hash spreads neighbours so a stroke does not repeat one letter.
const ink_tolerance: f32 = 0.07;

/// The brightest cells spell the wordmark in reading order instead of taking
/// the densest glyph, so a stroke reads "MetaskLab…" up close while the cell
/// colours draw the big letters.
const core_at: f32 = 0.85;
const spelled = "MetaskLab";

fn pickVariant(b: f32, h: u32) Variant {
    const target = std.math.clamp((b - blank_below) / (1 - blank_below), 0, 1);
    var nearest: usize = 0;
    for (ramp, 0..) |v, i| {
        if (@abs(v.ink - target) < @abs(ramp[nearest].ink - target)) nearest = i;
    }
    var picks: [ramp.len]usize = undefined;
    var n: usize = 0;
    for (ramp, 0..) |v, i| {
        if (@abs(v.ink - target) <= ink_tolerance) {
            picks[n] = i;
            n += 1;
        }
    }
    if (n == 0) return ramp[nearest];
    return ramp[picks[h % n]];
}

// ── Colour tiers ──

pub const tiers: u8 = 12;
/// Below this brightness a cell stays blank (the page's 0.03 cut, a touch
/// higher because a terminal cell is much larger than the page's).
const blank_below: f32 = 0.045;
/// Without colour, faint tiers would print at full strength; keep the halo out.
const mono_min_tier: u8 = 5;

const Rgb = [3]u8;
const Stop = struct { at: f32, rgb: [3]f32 };

const gradient_dark = [_]Stop{
    .{ .at = 0.00, .rgb = .{ 16, 22, 46 } },
    .{ .at = 0.22, .rgb = .{ 26, 44, 98 } },
    .{ .at = 0.45, .rgb = .{ 38, 124, 196 } },
    .{ .at = 0.70, .rgb = .{ 58, 202, 226 } },
    .{ .at = 0.88, .rgb = .{ 172, 238, 246 } },
    .{ .at = 1.00, .rgb = .{ 250, 253, 255 } },
};
const gradient_light = [_]Stop{
    .{ .at = 0.00, .rgb = .{ 206, 214, 230 } },
    .{ .at = 0.22, .rgb = .{ 160, 182, 214 } },
    .{ .at = 0.45, .rgb = .{ 70, 124, 186 } },
    .{ .at = 0.70, .rgb = .{ 26, 86, 152 } },
    .{ .at = 0.88, .rgb = .{ 14, 54, 104 } },
    .{ .at = 1.00, .rgb = .{ 6, 26, 56 } },
};

fn sampleGradient(stops: []const Stop, x: f32) Rgb {
    var i: usize = 1;
    while (i < stops.len - 1 and stops[i].at < x) i += 1;
    const a = stops[i - 1];
    const b = stops[i];
    const f = std.math.clamp((x - a.at) / (b.at - a.at), 0, 1);
    var out: Rgb = undefined;
    for (0..3) |c| out[c] = @intFromFloat(@round(a.rgb[c] + (b.rgb[c] - a.rgb[c]) * f));
    return out;
}

/// xterm-256 index nearest to an RGB colour (6×6×6 cube or the grey ramp).
fn nearest256(rgb: Rgb) u8 {
    const levels = [_]i32{ 0, 95, 135, 175, 215, 255 };
    var best: u8 = 16;
    var best_d: i32 = std.math.maxInt(i32);
    for (0..6) |r| for (0..6) |g| for (0..6) |b| {
        const d = sq(levels[r] - rgb[0]) + sq(levels[g] - rgb[1]) + sq(levels[b] - rgb[2]);
        if (d < best_d) {
            best_d = d;
            best = @intCast(16 + 36 * r + 6 * g + b);
        }
    };
    for (0..24) |i| {
        const v: i32 = @intCast(8 + 10 * i);
        const d = sq(v - rgb[0]) + sq(v - rgb[1]) + sq(v - rgb[2]);
        if (d < best_d) {
            best_d = d;
            best = @intCast(232 + i);
        }
    }
    return best;
}

fn sq(x: i32) i32 {
    return x * x;
}

const TierColors = struct { rgb: [tiers + 1]Rgb, idx256: [tiers + 1]u8 };

fn buildTierColors(stops: []const Stop) TierColors {
    @setEvalBranchQuota(200_000);
    var out: TierColors = undefined;
    out.rgb[0] = .{ 0, 0, 0 };
    out.idx256[0] = 0;
    for (1..tiers + 1) |t| {
        const x = (@as(f32, @floatFromInt(t)) - 0.5) / @as(f32, @floatFromInt(tiers));
        out.rgb[t] = sampleGradient(stops, x);
        out.idx256[t] = nearest256(out.rgb[t]);
    }
    return out;
}

const tier_colors = [2]TierColors{ buildTierColors(&gradient_dark), buildTierColors(&gradient_light) };

/// SGR body for a tier on a 16-colour terminal: (dim, colour code).
fn basicTier(bg: Background, tier: u8) struct { dim: bool, code: u8 } {
    return switch (bg) {
        .dark => if (tier <= 2) .{ .dim = true, .code = 34 } else if (tier <= 4) .{ .dim = false, .code = 34 } else if (tier <= 7) .{ .dim = false, .code = 36 } else if (tier <= 10) .{ .dim = false, .code = 96 } else .{ .dim = false, .code = 97 },
        .light => if (tier <= 2) .{ .dim = true, .code = 36 } else if (tier <= 5) .{ .dim = false, .code = 36 } else if (tier <= 9) .{ .dim = false, .code = 34 } else .{ .dim = false, .code = 30 },
    };
}

// ── Simulation ──

pub const Ink = struct {
    ch: u8,
    /// 1..tiers.
    tier: u8,
    bold: bool,
    italic: bool,
};

const Particle = struct {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
    tx: f32,
    ty: f32,
    /// Second at which this particle starts leaving its orb for its target.
    start: f32,
    /// Where the particle was drawn on the previous step (field splats).
    px: f32,
    py: f32,
};

const Seg = struct { x0: f32, y0: f32, x1: f32, y1: f32 };
const Box = struct { x0: f32, y0: f32, x1: f32, y1: f32, first: usize, end: usize };

// Field samples: 2 per column, 4 per row, so 0.5 units apart both ways.
const sx_per_col = 2;
const sy_per_row = 4;
const sample_step: f32 = 0.5;

const halo_amp: f32 = 0.16;
const halo_width: f32 = 0.7;
const halo_reach: f32 = 4.0;
const target_spacing: f32 = 0.85;
const max_particles = 900;
const stamp_radius: f32 = 1.4;
const stamp_amp: f32 = 0.42;
const field_decay: f32 = 0.80;

pub const Splash = struct {
    gpa: std.mem.Allocator,
    layout: Layout,
    style: Style,
    fw: usize,
    fh: usize,
    /// Distance from each field sample to the nearest stroke centreline, units.
    dist: []f32,
    /// Particle brightness, decays every step.
    field: []f32,
    particles: []Particle,
    cells: []?Ink,
    prng: std.Random.DefaultPrng,
    steps: u32 = 0,
    word_left: f32,
    word_width: f32,

    pub fn init(gpa: std.mem.Allocator, layout: Layout, style: Style, seed: u64) !Splash {
        const fw = @as(usize, layout.cols) * sx_per_col;
        const fh = @as(usize, layout.rows) * sy_per_row;

        var segs: std.ArrayList(Seg) = .empty;
        defer segs.deinit(gpa);
        var boxes: std.ArrayList(Box) = .empty;
        defer boxes.deinit(gpa);
        try buildSegments(gpa, layout, &segs, &boxes);

        const dist = try gpa.alloc(f32, fw * fh);
        errdefer gpa.free(dist);
        fillDistance(dist, fw, fh, segs.items, boxes.items);

        const field = try gpa.alloc(f32, fw * fh);
        errdefer gpa.free(field);
        @memset(field, 0);

        const cells = try gpa.alloc(?Ink, @as(usize, layout.cols) * layout.rows);
        errdefer gpa.free(cells);
        @memset(cells, null);

        var self: Splash = .{
            .gpa = gpa,
            .layout = layout,
            .style = style,
            .fw = fw,
            .fh = fh,
            .dist = dist,
            .field = field,
            .particles = &.{},
            .cells = cells,
            .prng = std.Random.DefaultPrng.init(seed),
            .word_left = layout.origin_x,
            .word_width = wordWidthEm() * layout.scale,
        };
        self.particles = try self.spawnParticles(segs.items);
        // Light the orbs before the first step so frame 0 is not blank: a
        // few rounds of splat-and-decay at rest approach the field's steady
        // brightness around the starting positions.
        for (0..4) |_| {
            for (self.field) |*v| v.* *= field_decay;
            for (self.particles) |p| self.splat(p.x, p.y, 1);
        }
        return self;
    }

    pub fn deinit(self: *Splash) void {
        self.gpa.free(self.particles);
        self.gpa.free(self.cells);
        self.gpa.free(self.field);
        self.gpa.free(self.dist);
        self.* = undefined;
    }

    fn regionH(self: *const Splash) f32 {
        return @as(f32, @floatFromInt(self.layout.rows)) * 2;
    }

    /// The two drifting attractors (the page's Lissajous pair), in units.
    fn attractor(self: *const Splash, which: u1, t: f32) Pt {
        const cx = self.word_left + self.word_width / 2;
        const cy = self.regionH() / 2;
        const w = self.word_width;
        const h = self.regionH();
        return switch (which) {
            0 => .{ cx - 0.24 * w + 0.07 * w * @cos(2.3 * t), cy + 0.26 * h * @sin(3.1 * t) },
            1 => .{ cx + 0.24 * w + 0.07 * w * @cos(2.7 * t + std.math.pi), cy + 0.26 * h * @sin(2.2 * t + std.math.pi) },
        };
    }

    fn spawnParticles(self: *Splash, segs: []const Seg) ![]Particle {
        var total: f32 = 0;
        for (segs) |s| total += segLen(s);
        const spacing = @max(target_spacing, total / @as(f32, @floatFromInt(max_particles)));

        var list: std.ArrayList(Particle) = .empty;
        errdefer list.deinit(self.gpa);
        const rand = self.prng.random();
        for (segs) |s| {
            const n: usize = @max(1, @as(usize, @intFromFloat(@round(segLen(s) / spacing))));
            for (0..n) |k| {
                if (list.items.len >= max_particles) break;
                const f = (@as(f32, @floatFromInt(k)) + 0.5) / @as(f32, @floatFromInt(n));
                const tx = s.x0 + (s.x1 - s.x0) * f;
                const ty = s.y0 + (s.y1 - s.y0) * f;
                const u = std.math.clamp((tx - self.word_left) / self.word_width, 0, 1);
                const orb: u1 = if (u < 0.5) 0 else 1;
                const home = self.attractor(orb, 0);
                const ang = rand.float(f32) * std.math.tau;
                const rad = @sqrt(rand.float(f32));
                const x = home[0] + @cos(ang) * rad * 0.07 * self.word_width;
                const y = home[1] + @sin(ang) * rad * 0.28 * self.regionH();
                try list.append(self.gpa, .{
                    .x = x,
                    .y = y,
                    .vx = (rand.float(f32) - 0.5) * 0.8,
                    .vy = (rand.float(f32) - 0.5) * 0.8,
                    .tx = tx,
                    .ty = ty,
                    .start = gather_start + u * stagger + rand.float(f32) * 0.06,
                    .px = x,
                    .py = y,
                });
            }
        }
        return list.toOwnedSlice(self.gpa);
    }

    /// Run fixed 60 Hz steps until the simulation has reached `t` seconds.
    pub fn advanceTo(self: *Splash, t: f32) void {
        const target_steps: u32 = @intFromFloat(@max(0, @floor(t / sim_dt)));
        while (self.steps < target_steps) self.step();
    }

    fn step(self: *Splash) void {
        self.steps += 1;
        const t = @as(f32, @floatFromInt(self.steps)) * sim_dt;
        const a0 = self.attractor(0, t);
        const a1 = self.attractor(1, t);
        const rand = self.prng.random();
        const h = self.regionH();

        for (self.field) |*v| v.* *= field_decay;

        for (self.particles) |*p| {
            // Free flight: pulled by the nearer attractor, the far one weaker.
            const d0x = a0[0] - p.x;
            const d0y = a0[1] - p.y;
            const d1x = a1[0] - p.x;
            const d1y = a1[1] - p.y;
            const n0 = d0x * d0x + d0y * d0y;
            const n1 = d1x * d1x + d1y * d1y;
            const near0 = n0 < n1;
            const dx = if (near0) d0x else d1x;
            const dy = if (near0) d0y else d1y;
            const d = @sqrt(@min(n0, n1)) + 1;
            const force: f32 = if (near0) 0.20 else 0.14;
            p.vx += dx / d * force + (rand.float(f32) - 0.5) * 0.30;
            p.vy += dy / d * force * 0.6 + (rand.float(f32) - 0.5) * 0.18;
            p.vx *= 0.94;
            p.vy *= 0.94;
            p.x += p.vx;
            p.y = std.math.clamp(p.y + p.vy, -1, h + 1);

            // Drawn position: eased from the free flight onto the target.
            const e = easeInOut(std.math.clamp((t - p.start) / gather_dur, 0, 1));
            const x = p.x + (p.tx - p.x) * e;
            const y = p.y + (p.ty - p.y) * e;
            // Stamp the segment walked this step so fast particles leave
            // streaks instead of dotted lines.
            const len = @min(@sqrt((x - p.px) * (x - p.px) + (y - p.py) * (y - p.py)), 5 * stamp_radius);
            const n: usize = @as(usize, @intFromFloat(@ceil(len / stamp_radius))) + 1;
            for (0..n) |k| {
                const f = (@as(f32, @floatFromInt(k)) + 1) / @as(f32, @floatFromInt(n));
                self.splat(p.px + (x - p.px) * f, p.py + (y - p.py) * f, 1 / @as(f32, @floatFromInt(n)));
            }
            p.px = x;
            p.py = y;
        }
    }

    /// Add one soft stamp (the page's sprite profile) centred at (x, y) units.
    fn splat(self: *Splash, x: f32, y: f32, weight: f32) void {
        // Off the field (or not a number) leaves no light; checking first also
        // keeps the index conversions below in range.
        const w_units = @as(f32, @floatFromInt(self.fw)) * sample_step;
        const h_units = @as(f32, @floatFromInt(self.fh)) * sample_step;
        if (!(x > -stamp_radius and x < w_units + stamp_radius and y > -stamp_radius and y < h_units + stamp_radius)) return;
        const r_samples = stamp_radius / sample_step;
        const ci: i32 = @intFromFloat(@floor(x / sample_step));
        const cj: i32 = @intFromFloat(@floor(y / sample_step));
        const reach: i32 = @intFromFloat(@ceil(r_samples));
        var j = cj - reach;
        while (j <= cj + reach) : (j += 1) {
            if (j < 0 or j >= @as(i32, @intCast(self.fh))) continue;
            var i = ci - reach;
            while (i <= ci + reach) : (i += 1) {
                if (i < 0 or i >= @as(i32, @intCast(self.fw))) continue;
                const sxp = (@as(f32, @floatFromInt(i)) + 0.5) * sample_step;
                const syp = (@as(f32, @floatFromInt(j)) + 0.5) * sample_step;
                const nd = @sqrt((sxp - x) * (sxp - x) + (syp - y) * (syp - y)) / stamp_radius;
                const a = spriteAlpha(nd) * stamp_amp * weight;
                if (a == 0) continue;
                const idx = @as(usize, @intCast(j)) * self.fw + @as(usize, @intCast(i));
                self.field[idx] = @min(1, self.field[idx] + a);
            }
        }
    }

    /// Ink-in progress for a column at time `t`, 0..1, following the same
    /// left-to-right stagger as the particles.
    fn inkAt(self: *const Splash, x: f32, t: f32) f32 {
        const u = std.math.clamp((x - self.word_left) / self.word_width, 0, 1);
        const begin = gather_start + u * stagger + ink_lag;
        return smoothstep(std.math.clamp((t - begin) / ink_dur, 0, 1));
    }

    /// Fill `cells` for time `t`. `frame` salts the glyph choice so in-flight
    /// texture shimmers; the settled frame uses `composeFinal`.
    pub fn compose(self: *Splash, t: f32, frame: u32) void {
        self.composeInner(t, frame, false);
    }

    /// The settled wordmark. Depends on the layout only, never on the seed or
    /// on when the animation was skipped.
    pub fn composeFinal(self: *Splash) void {
        self.composeInner(duration, 0, true);
    }

    fn composeInner(self: *Splash, t: f32, frame: u32, settled: bool) void {
        const cols: usize = self.layout.cols;
        const r_units = stroke_r * self.layout.scale;
        const glint_on = !settled and t >= glint_start and t < glint_start + glint_dur;
        const glint_x = self.word_left - 6 + (self.word_width + 12) * ((t - glint_start) / glint_dur);
        const mid_y = self.layout.baseline - self.layout.scale / 2;
        const salt: u32 = if (settled) 0 else frame;

        for (0..self.layout.rows) |row| {
            for (0..cols) |col| {
                var cover_sum: f32 = 0;
                var halo_sum: f32 = 0;
                var flight_sum: f32 = 0;
                const cx = (@as(f32, @floatFromInt(col)) + 0.5);
                for (0..sy_per_row) |sj| {
                    const j = row * sy_per_row + sj;
                    for (0..sx_per_col) |si| {
                        const idx = j * self.fw + col * sx_per_col + si;
                        const edge = self.dist[idx] - r_units;
                        cover_sum += std.math.clamp(0.5 - edge, 0, 1);
                        if (edge > 0) halo_sum += halo_amp * @exp(-edge / halo_width);
                        flight_sum += self.field[idx];
                    }
                }
                const per: f32 = sx_per_col * sy_per_row;
                const cover = cover_sum / per;
                const ink = if (settled) 1 else self.inkAt(cx, t);
                // Sharpen the cell's coverage so a stroke edge lands either in
                // or out of the letter: at four rows of cap height a soft edge
                // fills the counters of e/a/b.
                const glyph = @max(sharpen(cover), halo_sum / per) * ink;
                const flight = if (settled) 0 else @min(1, flight_sum / per) * (1 - 0.8 * ink);
                var b = 1 - (1 - glyph) * (1 - flight);
                var glint = false;
                if (glint_on and cover > 0.35) {
                    const cy = (@as(f32, @floatFromInt(row)) + 0.5) * 2;
                    const q = (cx - glint_x + (cy - mid_y) * 0.6) / 2.2;
                    const shine = @exp(-q * q);
                    if (shine > 0.45) glint = true;
                    b = @max(b, shine);
                }
                const out = &self.cells[row * cols + col];
                if (b < blank_below) {
                    out.* = null;
                    continue;
                }
                const h = hash3(@intCast(col), @intCast(row), salt);
                // Without colour, ink density is the only brightness channel
                // left, so the core keeps the densest glyphs.
                const v: Variant = if (b >= core_at and self.style.mode != .none)
                    .{ .ch = spelled[(col + row * 4) % spelled.len], .bold = true, .ink = 1 }
                else
                    pickVariant(b, h);
                const tier: u8 = @intFromFloat(std.math.clamp(@ceil(b * @as(f32, @floatFromInt(tiers))), 1, @as(f32, @floatFromInt(tiers))));
                out.* = .{
                    .ch = v.ch,
                    .tier = if (glint) tiers else tier,
                    .bold = v.bold or glint,
                    .italic = flight > glyph,
                };
            }
        }
    }

    pub const FrameKind = enum {
        /// Reserves the region below the cursor and hides the cursor.
        first,
        /// Redraws the region in place.
        next,
        /// Redraws in place and restores the cursor and attributes.
        last,
    };

    /// Append the current `cells` as one terminal frame. Rows are written
    /// with `\r` … `\x1b[K\r\n`, so after any frame the cursor sits on the
    /// line below the region, which is where the next frame's cursor-up
    /// starts from.
    pub fn writeFrame(self: *const Splash, gpa: std.mem.Allocator, out: *std.ArrayList(u8), kind: FrameKind) !void {
        const cols: usize = self.layout.cols;
        const mode = self.style.mode;
        if (kind == .first) try out.appendSlice(gpa, "\x1b[?25l");
        try out.appendSlice(gpa, "\x1b[?2026h");
        if (kind != .first) try out.print(gpa, "\x1b[{d}A", .{self.layout.rows});
        for (0..self.layout.rows) |row| {
            try out.append(gpa, '\r');
            const line = self.cells[row * cols ..][0..cols];
            // Never touch the last column: writing it leaves the cursor in the
            // pending-wrap state on some terminals.
            var end: usize = 0;
            for (line[0 .. cols - 1], 0..) |c, i| {
                if (visible(c, mode)) end = i + 1;
            }
            // Last SGR written on this row; blanks never change it.
            var pen: ?Ink = null;
            for (line[0..end]) |c| {
                if (!visible(c, mode)) {
                    try out.append(gpa, ' ');
                    continue;
                }
                const ink = c.?;
                if (mode != .none and (pen == null or !sameStyle(pen.?, ink))) {
                    try writeSgr(gpa, out, self.style, ink);
                    pen = ink;
                }
                try out.append(gpa, ink.ch);
            }
            if (pen != null) try out.appendSlice(gpa, "\x1b[0m");
            try out.appendSlice(gpa, "\x1b[K\r\n");
        }
        if (kind == .last) try out.appendSlice(gpa, if (mode == .none) "\x1b[?25h" else "\x1b[0m\x1b[?25h");
        try out.appendSlice(gpa, "\x1b[?2026l");
    }
};

fn visible(c: ?Ink, mode: ColorMode) bool {
    const ink = c orelse return false;
    return mode != .none or ink.tier >= mono_min_tier;
}

fn sameStyle(a: Ink, b: Ink) bool {
    return a.tier == b.tier and a.bold == b.bold and a.italic == b.italic;
}

fn writeSgr(gpa: std.mem.Allocator, out: *std.ArrayList(u8), style: Style, ink: Ink) !void {
    const bg = style.bg;
    try out.appendSlice(gpa, "\x1b[0");
    if (ink.bold) try out.appendSlice(gpa, ";1");
    if (ink.italic) try out.appendSlice(gpa, ";3");
    const colors = &tier_colors[@intFromEnum(bg)];
    switch (style.mode) {
        .none => unreachable,
        .truecolor => {
            const c = colors.rgb[ink.tier];
            try out.print(gpa, ";38;2;{d};{d};{d}m", .{ c[0], c[1], c[2] });
        },
        .extended_256 => try out.print(gpa, ";38;5;{d}m", .{colors.idx256[ink.tier]}),
        .basic_16 => {
            const t = basicTier(bg, ink.tier);
            if (t.dim and !ink.bold) try out.appendSlice(gpa, ";2");
            try out.print(gpa, ";{d}m", .{t.code});
        },
    }
}

// ── Geometry helpers ──

fn buildSegments(gpa: std.mem.Allocator, layout: Layout, segs: *std.ArrayList(Seg), boxes: *std.ArrayList(Box)) !void {
    const s = layout.scale;
    var pen: f32 = stroke_r;
    for (wordmark) |ch| {
        const g = glyphDef(ch);
        const first = segs.items.len;
        for (g.prims) |prim| switch (prim) {
            .poly => |pts| {
                for (pts[0 .. pts.len - 1], pts[1..]) |p0, p1| {
                    try segs.append(gpa, toUnits(layout, pen, p0, p1));
                }
            },
            .arc => |a| {
                const sweep = a.a1 - a.a0;
                const n: usize = @max(4, @as(usize, @intFromFloat(@ceil(@abs(sweep) / 12))));
                var prev = arcPoint(a, a.a0);
                for (1..n + 1) |k| {
                    const cur = arcPoint(a, a.a0 + sweep * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n)));
                    try segs.append(gpa, toUnits(layout, pen, prev, cur));
                    prev = cur;
                }
            },
        };
        if (segs.items.len > first) {
            try boxes.append(gpa, .{
                .x0 = layout.origin_x + (pen - stroke_r) * s - halo_reach,
                .x1 = layout.origin_x + (pen + g.width + stroke_r) * s + halo_reach,
                .y0 = layout.baseline - (1 + stroke_r) * s - halo_reach,
                .y1 = layout.baseline + stroke_r * s + halo_reach,
                .first = first,
                .end = segs.items.len,
            });
        }
        pen += g.width + 2 * stroke_r + tracking;
    }
}

fn arcPoint(a: Arc, deg: f32) Pt {
    const r = deg * std.math.pi / 180;
    return .{ a.cx + a.rx * @cos(r), a.cy + a.ry * @sin(r) };
}

fn toUnits(layout: Layout, pen: f32, p0: Pt, p1: Pt) Seg {
    const s = layout.scale;
    return .{
        .x0 = layout.origin_x + (pen + p0[0]) * s,
        .y0 = layout.baseline - p0[1] * s,
        .x1 = layout.origin_x + (pen + p1[0]) * s,
        .y1 = layout.baseline - p1[1] * s,
    };
}

fn fillDistance(dist: []f32, fw: usize, fh: usize, segs: []const Seg, boxes: []const Box) void {
    for (0..fh) |j| {
        const y = (@as(f32, @floatFromInt(j)) + 0.5) * sample_step;
        for (0..fw) |i| {
            const x = (@as(f32, @floatFromInt(i)) + 0.5) * sample_step;
            var best: f32 = std.math.inf(f32);
            for (boxes) |bx| {
                if (x < bx.x0 or x > bx.x1 or y < bx.y0 or y > bx.y1) continue;
                for (segs[bx.first..bx.end]) |sg| best = @min(best, segDist(x, y, sg));
            }
            dist[j * fw + i] = best;
        }
    }
}

fn segLen(s: Seg) f32 {
    return @sqrt((s.x1 - s.x0) * (s.x1 - s.x0) + (s.y1 - s.y0) * (s.y1 - s.y0));
}

fn segDist(px: f32, py: f32, s: Seg) f32 {
    const dx = s.x1 - s.x0;
    const dy = s.y1 - s.y0;
    const l2 = dx * dx + dy * dy;
    const f = if (l2 == 0) 0 else std.math.clamp(((px - s.x0) * dx + (py - s.y0) * dy) / l2, 0, 1);
    const qx = s.x0 + f * dx - px;
    const qy = s.y0 + f * dy - py;
    return @sqrt(qx * qx + qy * qy);
}

/// The page's radial sprite: 0.45 at the centre, 0.15 at 35% radius, 0 at the rim.
fn spriteAlpha(nd: f32) f32 {
    if (nd >= 1) return 0;
    if (nd <= 0.35) return 0.45 + (0.15 - 0.45) * (nd / 0.35);
    return 0.15 * (1 - (nd - 0.35) / 0.65);
}

fn sharpen(cover: f32) f32 {
    return smoothstep(std.math.clamp((cover - 0.18) / 0.55, 0, 1));
}

fn smoothstep(x: f32) f32 {
    return x * x * (3 - 2 * x);
}

fn easeInOut(x: f32) f32 {
    return if (x < 0.5) 4 * x * x * x else 1 - std.math.pow(f32, -2 * x + 2, 3) / 2;
}

fn hash3(a: u32, b: u32, c: u32) u32 {
    var h = (a *% 0x9E3779B1) ^ (b *% 0x85EBCA77) ^ (c *% 0xC2B2AE3D);
    h ^= h >> 15;
    h *%= 0x2C1B3C6D;
    h ^= h >> 12;
    h *%= 0x297A2D39;
    h ^= h >> 15;
    return h;
}

// ── Tests ──

const testing = std.testing;
const test_style: Style = .{ .mode = .truecolor, .bg = .dark };

test "layoutFor: fits the wordmark inside the margins and leaves a spare row" {
    var cols: u16 = 40;
    while (cols <= 320) : (cols += 7) {
        var rows: u16 = 4;
        while (rows <= 80) : (rows += 5) {
            const l = layoutFor(cols, rows) orelse continue;
            try testing.expect(l.scale >= min_scale and l.scale <= max_scale);
            try testing.expect(l.rows + 2 <= rows);
            try testing.expect(l.origin_x >= margin_cols - 1);
            try testing.expect(l.origin_x + wordWidthEm() * l.scale <= @as(f32, @floatFromInt(cols - margin_cols + 1)));
            // Cap top and baseline inside the region, with the halo rows outside the letters.
            try testing.expect(l.baseline - l.scale >= 1.5);
            try testing.expect(l.baseline <= @as(f32, @floatFromInt(l.rows)) * 2 - 1.5);
        }
    }
    try testing.expect(layoutFor(80, 24) != null);
    try testing.expectEqual(max_scale, layoutFor(300, 60).?.scale);
    try testing.expect(layoutFor(60, 40) == null); // too narrow for open bowls
    try testing.expect(layoutFor(120, 7) == null); // too short to redraw in place
}

fn expectCellsEqual(a: []const ?Ink, b: []const ?Ink) !void {
    try testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| {
        try testing.expectEqual(x == null, y == null);
        if (x) |ix| try testing.expectEqual(ix, y.?);
    }
}

test "every frame is drawn only with the letters of Metask Lab" {
    const l = layoutFor(100, 30).?;
    var sp = try Splash.init(testing.allocator, l, test_style, 7);
    defer sp.deinit();
    var lit_frames: usize = 0;
    var t: f32 = 0;
    var frame: u32 = 0;
    while (t < duration) : (t += 0.1) {
        sp.advanceTo(t);
        sp.compose(t, frame);
        frame += 1;
        var lit: usize = 0;
        for (sp.cells) |c| if (c) |ink| {
            try testing.expect(std.mem.indexOfScalar(u8, "MetaskLb", ink.ch) != null);
            try testing.expect(ink.tier >= 1 and ink.tier <= tiers);
            lit += 1;
        };
        if (lit > 0) lit_frames += 1;
    }
    try testing.expectEqual(@as(usize, frame), lit_frames);
}

test "the settled wordmark ignores the seed and the moment of the skip" {
    const l = layoutFor(120, 40).?;
    var a = try Splash.init(testing.allocator, l, test_style, 1);
    defer a.deinit();
    var b = try Splash.init(testing.allocator, l, test_style, 2);
    defer b.deinit();
    a.advanceTo(0.1);
    a.compose(0.1, 3);
    b.advanceTo(1.2);
    b.compose(1.2, 36);
    a.composeFinal();
    b.composeFinal();
    try expectCellsEqual(a.cells, b.cells);
    for (a.cells) |c| if (c) |ink| try testing.expect(!ink.italic);
}

test "the settled wordmark has ink under every letter and none between the words" {
    const l = layoutFor(120, 40).?;
    var sp = try Splash.init(testing.allocator, l, test_style, 1);
    defer sp.deinit();
    sp.composeFinal();

    var pen: f32 = stroke_r;
    for (wordmark) |ch| {
        const g = glyphDef(ch);
        const x0: usize = @intFromFloat(@floor(l.origin_x + pen * l.scale));
        const x1: usize = @intFromFloat(@ceil(l.origin_x + (pen + g.width) * l.scale));
        var core: usize = 0;
        for (0..l.rows) |row| for (x0..x1 + 1) |col| {
            if (sp.cells[row * l.cols + col]) |ink| {
                if (ink.tier >= tiers - 1) core += 1;
            }
        };
        if (ch == ' ') {
            try testing.expectEqual(@as(usize, 0), core);
        } else {
            try testing.expect(core >= 4);
        }
        pen += g.width + 2 * stroke_r + tracking;
    }

    // Away from the strokes the region stays empty: the margins are blank,
    // and so are the counters and gaps the halo does not reach.
    var blank: usize = 0;
    for (sp.cells) |c| {
        if (c == null) blank += 1;
    }
    try testing.expect(blank * 3 > sp.cells.len); // 46% at this size
    for (0..l.rows) |row| {
        try testing.expect(sp.cells[row * l.cols] == null);
        try testing.expect(sp.cells[row * l.cols + l.cols - 1] == null);
    }
}

test "in flight the light is italic; it starts as two orbs" {
    const l = layoutFor(120, 40).?;
    var sp = try Splash.init(testing.allocator, l, test_style, 11);
    defer sp.deinit();
    sp.advanceTo(0.2);
    sp.compose(0.2, 6);
    var italic: usize = 0;
    var left: usize = 0;
    var right: usize = 0;
    const mid = sp.word_left + sp.word_width / 2;
    for (sp.cells, 0..) |c, i| if (c) |ink| {
        if (ink.italic) italic += 1;
        const col: f32 = @floatFromInt(i % l.cols);
        if (col < mid) left += 1 else right += 1;
    };
    try testing.expect(italic > 20);
    try testing.expect(left > 20 and right > 20);
}

/// Splits a frame into its rows' visible text, failing on anything that is
/// not a known control sequence. Returns the number of rows seen.
fn checkFrame(bytes: []const u8, cols: usize, allow_sgr: bool) !usize {
    var rows: usize = 0;
    var width: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const c = bytes[i];
        try testing.expect(c < 0x80);
        if (c == 0x1b) {
            try testing.expectEqual(@as(u8, '['), bytes[i + 1]);
            var j = i + 2;
            while (bytes[j] < 0x40 or bytes[j] > 0x7e) j += 1;
            const final = bytes[j];
            try testing.expect(std.mem.indexOfScalar(u8, if (allow_sgr) "AKhlm" else "AKhl", final) != null);
            i = j + 1;
            continue;
        }
        switch (c) {
            '\r' => width = 0,
            '\n' => rows += 1,
            else => {
                try testing.expect(c >= 0x20);
                width += 1;
                try testing.expect(width < cols);
            },
        }
        i += 1;
    }
    return rows;
}

test "writeFrame: ASCII rows that never reach the last column, redrawn in place" {
    const l = layoutFor(90, 30).?;
    inline for (.{ ColorMode.none, ColorMode.basic_16, ColorMode.extended_256, ColorMode.truecolor }) |mode| {
        inline for (.{ Background.dark, Background.light }) |bg| {
            var sp = try Splash.init(testing.allocator, l, .{ .mode = mode, .bg = bg }, 5);
            defer sp.deinit();
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(testing.allocator);

            var up_buf: [16]u8 = undefined;
            const up = try std.fmt.bufPrint(&up_buf, "\x1b[?2026h\x1b[{d}A", .{l.rows});

            sp.advanceTo(0.9);
            sp.compose(0.9, 27);
            try sp.writeFrame(testing.allocator, &out, .first);
            try testing.expect(std.mem.startsWith(u8, out.items, "\x1b[?25l\x1b[?2026h\r"));
            try testing.expect(std.mem.indexOf(u8, out.items, up[8..]) == null);
            try testing.expectEqual(@as(usize, l.rows), try checkFrame(out.items, l.cols, mode != .none));

            out.clearRetainingCapacity();
            try sp.writeFrame(testing.allocator, &out, .next);
            try testing.expect(std.mem.startsWith(u8, out.items, up));
            try testing.expectEqual(@as(usize, l.rows), try checkFrame(out.items, l.cols, mode != .none));

            sp.composeFinal();
            out.clearRetainingCapacity();
            try sp.writeFrame(testing.allocator, &out, .last);
            try testing.expect(std.mem.endsWith(u8, out.items, if (mode == .none) "\x1b[K\r\n\x1b[?25h\x1b[?2026l" else "\x1b[0m\x1b[?25h\x1b[?2026l"));
            try testing.expectEqual(@as(usize, l.rows), try checkFrame(out.items, l.cols, mode != .none));

            const has_rgb = std.mem.indexOf(u8, out.items, ";38;2;") != null;
            const has_256 = std.mem.indexOf(u8, out.items, ";38;5;") != null;
            try testing.expectEqual(mode == .truecolor, has_rgb);
            try testing.expectEqual(mode == .extended_256, has_256);
            // The core spells the name in colour; without colour it keeps density.
            const spells = std.mem.indexOf(u8, out.items, "Met") != null or std.mem.indexOf(u8, out.items, "ask") != null or std.mem.indexOf(u8, out.items, "Lab") != null;
            try testing.expectEqual(mode != .none, spells);
        }
    }
}

test "frames are a function of seed and time" {
    const l = layoutFor(100, 30).?;
    var a = try Splash.init(testing.allocator, l, test_style, 99);
    defer a.deinit();
    var b = try Splash.init(testing.allocator, l, test_style, 99);
    defer b.deinit();
    a.advanceTo(0.4);
    a.advanceTo(0.7);
    b.advanceTo(0.7);
    a.compose(0.7, 21);
    b.compose(0.7, 21);
    try expectCellsEqual(a.cells, b.cells);
}

test "palette tables: tiers brighten monotonically on dark and darken on light" {
    for (2..tiers + 1) |t| {
        const d0 = tier_colors[0].rgb[t - 1];
        const d1 = tier_colors[0].rgb[t];
        const l0 = tier_colors[1].rgb[t - 1];
        const l1 = tier_colors[1].rgb[t];
        try testing.expect(@as(u32, d1[0]) + d1[1] + d1[2] >= @as(u32, d0[0]) + d0[1] + d0[2]);
        try testing.expect(@as(u32, l1[0]) + l1[1] + l1[2] <= @as(u32, l0[0]) + l0[1] + l0[2]);
        try testing.expect(tier_colors[0].idx256[t] >= 16);
    }
    // The ramp is sorted by ink so pickVariant's tolerance window is contiguous.
    for (ramp[0 .. ramp.len - 1], ramp[1..]) |a, b| try testing.expect(a.ink <= b.ink);
}
