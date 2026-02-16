// XXX:
// [x] circle
//     [ ] change radius to bigger size?
// [x] rects
//     [ ] switch to extents, decide if input should be floats first though
// [x] get circles right
//     [ ] make sure 1px circle is on right point
//     [ ] clipping on > vs >=? +1 in narrow clip?
//         [ ] related to why adjacent circles touch horizontally but not vertically?
//     [ ] lines and circles are offset slightly on stick figure
// [x] lines
//     [ ] aabb is overbroad, we can probably bound each scanline much more tightly
//     [ ] fill considered pixels with black to test
// [x] image
// [ ] clean up integer types
// [ ] get tests running, maybe disable slow tests by default
// [ ] profile, compare to precomputing blends, compare to f32 version
//     [ ] vectorize/bin?
// [ ] research cpus/muladd

const timer_period_ns = 16 * std.time.ns_per_ms;

pub const Image = struct {
    buf: []Color.Premultiplied,
    size: XY(u32),

    const Color = packed struct(u32) {
        b: u8,
        g: u8,
        r: u8,
        a: u8,

        pub const Premultiplied = packed struct(u32) {
            b: u8,
            g: u8,
            r: u8,
            a: u8,

            /// Efficiently blends source onto destination, emulating the alpha blending you'd get
            /// from alpha blending on a GPU. For best performance, you should cache the
            /// premultiplied source outside of your hot loop or bake it into your data.
            ///
            /// Note: This method is intended for real time use. If you can afford a more expensive
            /// blend or are building a tool that will be used by artists, you should not be calling
            /// this method, you should be blending in a perceptual space like Oklab or at least
            /// doing sRGB correction before you call this method.
            pub fn blend(dst: @This(), src: @This()) @This() {
                const dst_scaled = dst.scale(0xff - src.a);
                return .{
                    .r = src.r + dst_scaled.r,
                    .g = src.g + dst_scaled.g,
                    .b = src.b + dst_scaled.b,
                    .a = src.a + dst_scaled.a,
                };
            }

            /// Similar to `blend`, but opitmized to skip blending if the source is opaque. `blend`
            /// elides this optimization because it can often be done at a higher level, e.g. before
            /// rendering an entire scanline.
            pub fn blendOrBlit(dst: @This(), src: @This()) @This() {
                if (src.a == 0xff) return src;
                return dst.blend(src);
            }

            /// Efficiently scales all channels by the given unorm factor.
            ///
            /// Adapted from "Alpha Blending with No Division Operations" by Jerry R. Van Aken:
            ///
            /// https://arxiv.org/pdf/2202.02864
            pub fn scale(self: @This(), factor: u8) @This() {
                comptime assert(builtin.cpu.arch.endian() == .little);

                if (factor == 0xff) return self;

                const bgra: u32 = @bitCast(self);

                var br = bgra & 0x00ff00ff;
                br *= factor;
                br += 0x00800080;
                br += (br >> 8) & 0x00ff00ff;
                br &= 0xff00ff00;

                var ga = (bgra >> 8) & 0x00ff00ff;
                ga *= factor;
                ga += 0x00800080;
                ga += (ga >> 8) & 0x00ff00ff;
                ga &= 0xff00ff00;

                return @bitCast(ga | (br >> 8));
            }

            /// Simple but slow implementation of `scale` for tests.
            fn scaleF32(color: Color, factor: u8) Color {
                return .{
                    .r = unormTimesUnormF32(factor, color.r),
                    .g = unormTimesUnormF32(factor, color.g),
                    .b = unormTimesUnormF32(factor, color.b),
                    .a = unormTimesUnormF32(factor, color.a),
                };
            }

            test scale {
                // The premul test is already pretty exhaustive, we just need to check a few cases where we
                // are also scaling the alpha channel. Since there's an extra level of nesting here we
                // don't want to check every single value.
                for (0..5) |r| {
                    const r8: u8 = @intCast(r * 255 / 4);
                    for (0..5) |g| {
                        const g8: u8 = @intCast(g * 255 / 4);
                        for (0..5) |b| {
                            const b8: u8 = @intCast(b * 255 / 4);
                            for (0..5) |a| {
                                const a8: u8 = @intCast(a * 255 / 4);
                                for (0..5) |f| {
                                    const f8: u8 = @intCast(f * 255 / 4);
                                    const c: Color = .{ .r = r8, .g = g8, .b = b8, .a = a8 };
                                    try std.testing.expectEqual(
                                        c.scaleF32(f8),
                                        c.scale(f8),
                                    );
                                }
                            }
                        }
                    }
                }
            }
        };

        /// Efficiently scales the color channels by the alpha channel.
        pub fn premul(self: Color) Premultiplied {
            var result: Color.Premultiplied = @bitCast(self);
            result.a = 0xff;
            return result.scale(self.a);
        }

        /// Equivalent to `premul`, but internally computes the result using floating point. This is
        /// slow, used only as a test oracle.
        fn premulF32(self: Color) Premultiplied {
            var bgr = self;
            bgr.a = 0xff;
            return @bitCast(bgr.scaleF32(self.a));
        }

        test premul {
            // We can afford to just test every possible premul to make sure we go this right, so let's
            // do it.
            for (0x00..0xff) |r| {
                for (0x00..0xff) |g| {
                    for (0x00..0xff) |b| {
                        for (0x00..0xff) |a| {
                            const c: Color = .{
                                .r = @intCast(r),
                                .g = @intCast(g),
                                .b = @intCast(b),
                                .a = @intCast(a),
                            };
                            const expected = c.premulF32();
                            const found = c.premul();
                            try std.testing.expectEqual(expected, found);
                        }
                    }
                }
            }
        }
    };

    /// Multiplies two unorms by temporarily converting to f32. This is slow, used only as a test
    /// oracle.
    fn unormTimesUnormF32(alpha: u8, red: u8) u8 {
        const a: f32 = @floatFromInt(alpha);
        const r: f32 = @floatFromInt(red);
        return @intFromFloat(@round((a * r) / 255));
    }

    test {
        _ = Color;
    }

    pub fn init(gpa: Allocator, size: XY(u32)) !@This() {
        return .{
            .buf = try gpa.alloc(Color.Premultiplied, @as(usize, size.x) * @as(usize, size.y)),
            .size = size,
        };
    }

    pub fn deinit(self: *@This(), gpa: Allocator) void {
        gpa.free(self.buf);
        self.* = undefined;
    }

    pub fn clear(self: @This(), color: Color.Premultiplied) void {
        @memset(self.buf, color);
    }

    pub fn fillRect(self: @This(), rect: x11.Rectangle, color: Color) void {
        // Clamp the bounds to the render target
        const x_min: u32 = @intCast(clamp(@as(i64, rect.x), 0, self.size.x));
        const x_max: u32 = @intCast(clamp(@as(i64, rect.x) + rect.width, 0, self.size.x));
        const y_min: u32 = @intCast(clamp(@as(i64, rect.y), 0, self.size.y));
        const y_max: u32 = @intCast(clamp(@as(i64, rect.y) + rect.height, 0, self.size.y));

        const width = x_max - x_min;

        // Premultiply the color
        const color_p = color.premul();

        // Fill the rect
        for (y_min..y_max) |y| {
            fill(self.buf[self.size.x * y + x_min ..][0..width], color_p);
        }
    }

    /// Renders a rounded rectangle.
    pub fn fillRoundedRect(self: @This(), rect: x11.Rectangle, radius: u32, color: Color) void {
        // Clamp the bounds to the render target
        const x_min: u32 = @intCast(clamp(@as(i64, rect.x), 0, self.size.x));
        const x_max: u32 = @intCast(clamp(@as(i64, rect.x) + rect.width, 0, self.size.x));
        const y_min: u32 = @intCast(clamp(@as(i64, rect.y), 0, self.size.y));
        const y_max: u32 = @intCast(clamp(@as(i64, rect.y) + rect.height, 0, self.size.y));

        // Precompute values for sdf
        const r: f32 = @floatFromInt(radius);
        const width: f32 = @floatFromInt(rect.width);
        const height: f32 = @floatFromInt(rect.height);
        const half_width = width / 2;
        const half_height = height / 2;
        const left: f32 = @floatFromInt(rect.x);
        const bottom: f32 = @floatFromInt(rect.y);

        // Premultiply the color
        const color_p = color.premul();

        // Fill the rounded rect. We could do 1/4th as many square roots by taking advantage of the
        // four way symmetry, but we opted not do as this complicates clipping and jumps around in
        // memory more.
        for (y_min..y_max) |y_i| {
            const y: f32 = pixelCenter(y_i);
            const row_start = self.size.x * y_i;

            const p_y = y - half_height - bottom;
            const q_y = @abs(p_y) - half_height + r;
            const q_y_max = @max(q_y, 0);
            const q_y_max2 = q_y_max * q_y_max;

            var x_i = x_min;
            while (x_i < x_max) : (x_i += 1) {
                const x: f32 = pixelCenter(x_i);

                // If we're in the interior rect, just fill it in so we can skip the square root
                if (@as(i64, @intCast(x_i)) - rect.x == radius) {
                    const skip_to_unclamped = @as(i64, rect.x) + rect.width - radius;
                    const skip_to: u32 = @intCast(@min(skip_to_unclamped, self.size.x));
                    fill(self.buf[row_start + x_i ..][0 .. skip_to - x_i], color_p);
                    x_i = skip_to;
                    if (x_i >= x_max) break;
                }

                // Otherwise, evaluate the SDF
                const p_x = x - half_width - left;
                const q_x = @abs(p_x) - half_width + r;
                const q_x_max = @max(q_x, 0);
                const q_x_max2 = q_x_max * q_x_max;

                const q_max_len = @sqrt(q_x_max2 + q_y_max2);

                const sd = @min(@max(q_x, q_y), 0) + q_max_len - r;

                self.fillSdf(row_start + x_i, sd, color_p);
            }
        }
    }

    /// Renders a rounded rectangle.
    pub fn drawRoundedRect(
        self: @This(),
        rect: x11.Rectangle,
        radius: u32,
        stroke_size: f32,
        color: Color,
    ) void {
        const half_stroke = stroke_size / 2;
        const half_stroke_ceil: i64 = @intFromFloat(@ceil(half_stroke));
        const stroke_floor: i64 = @intFromFloat(@floor(stroke_size));

        // Clamp the bounds to the render target
        const x_min: u32 = @intCast(clamp(@as(i64, rect.x) - half_stroke_ceil, 0, self.size.x));
        const x_max: u32 = @intCast(clamp(@as(i64, rect.x) + rect.width + half_stroke_ceil, 0, self.size.x));
        const y_min: u32 = @intCast(clamp(@as(i64, rect.y) - half_stroke_ceil, 0, self.size.y));
        const y_max: u32 = @intCast(clamp(@as(i64, rect.y) + rect.height + half_stroke_ceil, 0, self.size.y));

        // Precompute values for sdf
        const r: f32 = @floatFromInt(radius);
        const width: f32 = @floatFromInt(rect.width);
        const height: f32 = @floatFromInt(rect.height);
        const half_width = width / 2;
        const half_height = height / 2;
        const left: f32 = @floatFromInt(rect.x);
        const bottom: f32 = @floatFromInt(rect.y);

        // Premultiply the color
        const color_p = color.premul();

        // Fill the rounded rect. We could do 1/4th as many square roots by taking advantage of the
        // four way symmetry, but we opted not do as this complicates clipping and jumps around in
        // memory more.
        for (y_min..y_max) |y_i| {
            const y: f32 = pixelCenter(y_i);
            const row_start = self.size.x * y_i;

            const p_y = y - half_height - bottom;
            const q_y = @abs(p_y) - half_height + r;
            const q_y_max = @max(q_y, 0);
            const q_y_max2 = q_y_max * q_y_max;

            var x_i = x_min;
            while (x_i < x_max) : (x_i += 1) {
                const x: f32 = pixelCenter(x_i);

                // If we're in the interior rect, skip it to avoid the square root
                if (@as(i64, @intCast(x_i)) - rect.x + stroke_floor == radius and
                    @as(i64, @intCast(y_i)) - rect.y >= radius - stroke_floor and
                    @as(i64, @intCast(y_i)) - rect.y <= rect.height - radius + stroke_floor)
                {
                    const skip_to_unclamped = @as(i64, rect.x) + rect.width - radius + stroke_floor;
                    const skip_to: u32 = @intCast(@min(skip_to_unclamped, self.size.x));
                    if (skip_to < x_i) break;
                    x_i = skip_to;
                    if (x_i >= x_max) break;
                }

                // Otherwise, evaluate the SDF
                const p_x = x - half_width - left;
                const q_x = @abs(p_x) - half_width + r;
                const q_x_max = @max(q_x, 0);
                const q_x_max2 = q_x_max * q_x_max;

                const q_max_len = @sqrt(q_x_max2 + q_y_max2);

                const sd_fill = @min(@max(q_x, q_y), 0) + q_max_len - r;
                const sd = subtractSdf(sd_fill + half_stroke, sd_fill - half_stroke);

                self.fillSdf(row_start + x_i, sd, color_p);
            }
        }
    }

    pub fn fillCircle(self: @This(), center: x11.XY(i16), radius: u8, color: Color) void {
        // Calculate the AABB, factoring in the line radius and clipping. Early out if zero area.
        const min: x11.XY(u32) = .{
            .x = clamp(@min(center.x, center.x) - radius, 0, self.size.x),
            .y = clamp(@min(center.y, center.y) - radius, 0, self.size.y),
        };
        const max: x11.XY(u32) = .{
            .x = clamp(@max(center.x, center.x) + radius, 0, self.size.x),
            .y = clamp(@max(center.y, center.y) + radius, 0, self.size.y),
        };
        if (min.x == max.x or min.y == max.y) return;

        // Render the SDF within the AABB
        const mid_x: f32 = @floatFromInt(center.x);
        const mid_y: f32 = @floatFromInt(center.y);

        const r: f32 = @floatFromInt(radius);
        const r2 = r * r;
        const r_early_in: f32 = r - 0.5;
        const r_early_in2 = r_early_in * r_early_in;

        const color_p = color.premul();

        // Evaluate the SDF. We take advtange of horizontal symmetry here, but not vertical
        // symmetry. At the cost of jumping around in memory more and increased clipping complexity,
        // we could reduce the square roots by half.
        for (min.y..max.y) |y| {
            const dy = pixelCenter(y) - mid_y;
            const dy2 = dy * dy;
            const row_start = self.size.x * y;

            const scanline_width: i64 = @intFromFloat(@ceil(@sqrt(@abs(r2 - dy2))));
            var left_unclamped: i64 = @as(i64, @intCast(center.x)) - scanline_width;
            if (left_unclamped >= self.size.x) continue;

            while (left_unclamped < center.x) : (left_unclamped += 1) {
                // Calculate the squared distance
                const dx = pixelCenter(left_unclamped) - mid_x;
                const sd2 = dx * dx + dy * dy;
                const width: i64 = 2 * (@as(i64, @intCast(center.x)) - left_unclamped);
                const right_unclamped = left_unclamped + width;

                // Clamp our coordinates
                if (left_unclamped >= self.size.x or right_unclamped < 0) break;
                const left: usize = @max(left_unclamped, 0);
                const right: usize = @intCast(@min(right_unclamped, self.size.x));

                // If we're fully inside the shape, fill the rest of the scanline without
                // antialiasing.
                if (sd2 < r_early_in2) {
                    fill(self.buf[row_start + left .. row_start + right], color_p);
                    break;
                }

                // We're on the edge, we need to do the square root and sample the SDF properly to
                // get correct antialiasing
                const sd = @sqrt(sd2) - r;
                if (left == left_unclamped) self.fillSdf(
                    row_start + left,
                    sd,
                    color_p,
                );
                if (right == right_unclamped and right > 1) self.fillSdf(
                    (row_start + right) - 1,
                    sd,
                    color_p,
                );
            }
        }
    }

    pub fn drawCircle(
        self: @This(),
        center: x11.XY(i16),
        radius: u8,
        stroke_size: f32,
        color: Color,
    ) void {
        // Calculate the AABB, factoring in the line radius and clipping. Early out if zero area.
        const half_stroke = stroke_size / 2;
        const half_stroke_ceil: i16 = @intFromFloat(@ceil(half_stroke));
        const min: x11.XY(u32) = .{
            .x = clamp(@min(center.x, center.x) - radius - half_stroke_ceil, 0, self.size.x),
            .y = clamp(@min(center.y, center.y) - radius - half_stroke_ceil, 0, self.size.y),
        };
        const max: x11.XY(u32) = .{
            .x = clamp(@max(center.x, center.x) + radius + half_stroke_ceil, 0, self.size.x),
            .y = clamp(@max(center.y, center.y) + radius + half_stroke_ceil, 0, self.size.y),
        };
        if (min.x == max.x or min.y == max.y) return;

        // Render the SDF within the AABB
        const mid_x: f32 = @floatFromInt(center.x);
        const mid_y: f32 = @floatFromInt(center.y);

        const r_raw: f32 = @floatFromInt(radius);
        const r_outer = r_raw + half_stroke;
        const r_inner = r_raw - half_stroke;
        const r_outer2 = r_outer * r_outer;
        const r_early_out: f32 = r_inner - 0.5;
        const r_early_out2 = r_early_out * r_early_out;

        const color_p = color.premul();

        // Evaluate the SDF. We take advtange of horizontal symmetry here, but not vertical
        // symmetry. At the cost of jumping around in memory more and increased clipping complexity,
        // we could reduce the square roots by half.
        for (min.y..max.y) |y| {
            const dy = pixelCenter(y) - mid_y;
            const dy2 = dy * dy;
            const row_start = self.size.x * y;

            const scanline_width: i64 = @intFromFloat(@ceil(@sqrt(@abs(r_outer2 - dy2))));
            var left_unclamped: i64 = @as(i64, @intCast(center.x)) - scanline_width;
            if (left_unclamped >= self.size.x) continue;

            while (left_unclamped < center.x) : (left_unclamped += 1) {
                // Calculate the squared distance
                const dx = pixelCenter(left_unclamped) - mid_x;
                const sd2 = dx * dx + dy * dy;
                const width: i64 = 2 * (@as(i64, @intCast(center.x)) - left_unclamped);
                const right_unclamped = left_unclamped + width;

                // Clamp our coordinates
                if (left_unclamped >= self.size.x or right_unclamped < 0) break;
                const left: usize = @max(left_unclamped, 0);
                const right: usize = @intCast(@min(right_unclamped, self.size.x));

                // If we're fully inside the shape, skip the rest of the scanline
                if (sd2 < r_early_out2) break;

                // We're on the edge, we need to do the square root and sample the SDF properly to
                // get correct antialiasing
                const sd_outer = @sqrt(sd2) - r_outer;
                const sd_inner = sd_outer + stroke_size;
                const sd = subtractSdf(sd_inner, sd_outer);
                if (left == left_unclamped) self.fillSdf(
                    row_start + left,
                    sd,
                    color_p,
                );
                if (right == right_unclamped and right > 1) self.fillSdf(
                    (row_start + right) - 1,
                    sd,
                    color_p,
                );
            }
        }
    }

    /// Rounded cap line drawing adapted for the CPU from Inigo Quilez's line SDF.
    pub fn drawLine(
        self: @This(),
        start: x11.XY(i16),
        end: x11.XY(i16),
        radius: u8,
        color: Color,
    ) void {
        // Calculate the AABB, factoring in the line radius and clipping. Early out if zero area.
        const min: x11.XY(u32) = .{
            .x = clamp(@min(start.x, end.x) - radius, 0, self.size.x),
            .y = clamp(@min(start.y, end.y) - radius, 0, self.size.y),
        };
        const max: x11.XY(u32) = .{
            .x = clamp(@max(start.x, end.x) + radius, 0, self.size.x),
            .y = clamp(@max(start.y, end.y) + radius, 0, self.size.y),
        };
        if (min.x == max.x or min.y == max.y) return;

        // Render the SDF within the AABB
        const a_x: f32 = @floatFromInt(start.x);
        const b_x: f32 = @floatFromInt(end.x);
        const a_y: f32 = @floatFromInt(start.y);
        const b_y: f32 = @floatFromInt(end.y);

        const r: f32 = @floatFromInt(radius);
        const r_early_out: f32 = r + 0.5;
        const r_early_out2 = r_early_out * r_early_out;
        const r_early_in: f32 = r - 0.5;
        const r_early_in2 = r_early_in * r_early_in;

        const color_p = color.premul();

        const ba_y = b_y - a_y;
        const ba_ba_y = ba_y * ba_y;

        for (min.y..max.y) |y| {
            const pa_y = pixelCenter(y) - a_y;
            const pa_ba_y = pa_y * ba_y;

            const row_start = self.size.x * y;

            for (min.x..max.x) |x| {
                const pa_x = pixelCenter(x) - a_x;
                const ba_x = b_x - a_x;

                const pa_dot_ba = pa_x * ba_x + pa_ba_y;
                const ba_dot_ba = ba_x * ba_x + ba_ba_y;
                const h = clamp(pa_dot_ba / ba_dot_ba, 0, 1);
                const sd_x = pa_x - ba_x * h;
                const sd_y = pa_y - ba_y * h;
                const sd2 = sd_x * sd_x + sd_y * sd_y;

                // If we're fully outside the shape, early out before the square root
                if (sd2 > r_early_out2) {
                    continue;
                }

                // If we're fully inside the shape, blit or alpha blend the color and early out to
                // avoid the square root
                if (sd2 < r_early_in2) {
                    const sample = &self.buf[row_start + x];
                    sample.* = sample.blendOrBlit(color_p);
                    continue;
                }

                // We're on the edge, we need to do the square root and sample the SDF properly to
                // get correct antialiasing
                const sd = @sqrt(sd2) - r;
                self.fillSdf(
                    row_start + x,
                    sd,
                    color_p,
                );
            }
        }
    }

    pub fn drawImage(self: @This(), origin: x11.XY(i16), image: @This(), opacity: u8) void {
        const min_dst: x11.XY(u32) = .{
            .x = clamp(origin.x, 0, self.size.x),
            .y = clamp(origin.y, 0, self.size.y),
        };
        const max_dst: x11.XY(u32) = .{
            .x = @intCast(clamp(origin.x + @as(i64, image.size.x), 0, self.size.x)),
            .y = @intCast(clamp(origin.y + @as(i64, image.size.x), 0, self.size.y)),
        };
        const min_src: x11.XY(u32) = .{
            .x = @intCast(@max(0, -@as(i64, origin.x))),
            .y = @intCast(@max(0, -@as(i64, origin.y))),
        };
        for (min_dst.y..max_dst.y, min_src.y..) |dst_y, src_y| {
            const dst_row_start = self.size.x * dst_y;
            const src_row_start = image.size.x * src_y;
            for (min_dst.x..max_dst.x, min_src.x..) |dst_x, src_x| {
                const dst = &self.buf[dst_row_start + dst_x];
                const src = image.buf[src_row_start + src_x];
                dst.* = dst.blendOrBlit(src.scale(opacity));
            }
        }
    }

    /// Fills the range of pixels using memset if possible, falling back to a for loop if alpha
    /// blending is required.
    fn fill(slice: []Color.Premultiplied, color: Color.Premultiplied) void {
        if (color.a == 0xff) {
            @memset(slice, color);
        } else for (slice) |*sample| {
            sample.* = sample.*.blend(color);
        }
    }

    fn subtractSdf(lhs: f32, rhs: f32) f32 {
        return @max(-lhs, rhs);
    }

    fn fillSdf(self: @This(), index: usize, sd: f32, color: Color.Premultiplied) void {
        // If we're fully outside the shape, early out. Otherwise get the sample.
        if (sd > 0.5) return;
        const sample = &self.buf[index];

        // If we're fully inside the shape, blit or alpha blend the premul color.
        if (sd < -0.5) {
            sample.* = sample.blendOrBlit(color);
            return;
        }

        // Apply antialiasing
        const a = floatToUnorm(0.5 - sd);
        sample.* = sample.*.blend(color.scale(a));
    }

    /// Returns the floating point coordinate of the given pixel's center.
    fn pixelCenter(i: anytype) f32 {
        return @as(f32, @floatFromInt(i)) + 0.5;
    }

    fn floatToUnorm(f: f32) u8 {
        return @intFromFloat(f * math.maxInt(u8) + 0.5);
    }

    pub fn bytes(self: @This()) []u8 {
        return @ptrCast(self.buf);
    }
};

const Ids = struct {
    base: x11.ResourceBase,
    pub fn window(self: Ids) x11.Window {
        return self.base.add(0).window();
    }
    pub fn gc(self: Ids) x11.GraphicsContext {
        return self.base.add(1).graphicsContext();
    }
    pub fn backBuffer(self: Ids) x11.Drawable {
        return self.base.add(2).drawable();
    }
    pub fn rasterGc(self: Ids) x11.GraphicsContext {
        return self.base.add(3).graphicsContext();
    }
    pub fn rasterPixmap(self: Ids) x11.Pixmap {
        return self.base.add(4).pixmap();
    }
};

pub fn main() !void {
    const Screen = struct {
        window: x11.Window,
        visual: x11.Visual,
        depth: x11.Depth,
    };
    const stream: std.net.Stream, const ids: Ids, const screen: Screen = blk: {
        var read_buffer: [1000]u8 = undefined;
        var socket_reader, const used_auth = try x11.draft.connect(&read_buffer);
        errdefer x11.disconnect(socket_reader.getStream());
        _ = used_auth;
        const setup = try x11.readSetupSuccess(socket_reader.interface());
        std.log.info("setup reply {f}", .{setup});
        var source: x11.Source = .initFinishSetup(socket_reader.interface(), &setup);
        const screen = try x11.draft.readSetupDynamic(&source, &setup, .{}) orelse {
            std.log.err("no screen?", .{});
            std.process.exit(0xff);
        };
        break :blk .{
            socket_reader.getStream(), .{ .base = setup.resource_id_base }, .{
                .window = screen.root,
                .visual = screen.root_visual,
                .depth = x11.Depth.init(screen.root_depth) orelse std.debug.panic(
                    "unsupported depth {}",
                    .{screen.root_depth},
                ),
            },
        };
    };
    defer x11.disconnect(stream);

    var write_buffer: [1000]u8 = undefined;
    var read_buffer: [1000]u8 = undefined;
    var socket_writer = x11.socketWriter(stream, &write_buffer);
    var socket_reader = x11.socketReader(stream, &read_buffer);
    var sink: x11.RequestSink = .{ .writer = &socket_writer.interface };
    var source: x11.Source = .initAfterSetup(socket_reader.interface());

    var window_size: XY(u16) = .{ .x = 256, .y = 128 };

    try sink.CreateWindow(
        .{
            .window_id = ids.window(),
            .parent_window_id = screen.window,
            .depth = 0,
            .x = 0,
            .y = 0,
            .width = window_size.x,
            .height = window_size.y,
            .border_width = 0,
            .class = .input_output,
            .visual_id = screen.visual,
        },
        .{
            .bg_pixel = screen.depth.rgbFrom24(0),
            .event_mask = .{
                .Exposure = 1,
                .StructureNotify = 1,
            },
        },
    );

    const dbe: Dbe = blk: {
        const ext = try x11.draft.synchronousQueryExtension(&source, &sink, x11.dbe.name) orelse break :blk .unsupported;
        try x11.dbe.Allocate(&sink, ext.opcode_base, ids.window(), ids.backBuffer(), .background);
        break :blk .{ .enabled = .{ .opcode_base = ext.opcode_base, .back_buffer = ids.backBuffer() } };
    };

    try sink.CreateGc(
        ids.gc(),
        ids.window().drawable(),
        .{
            .background = screen.depth.rgbFrom24(0),
            .foreground = screen.depth.rgbFrom24(0xffffff),
            .line_width = 4,
            // prevent NoExposure events when we send CopyArea
            .graphics_exposures = false,
        },
    );

    try sink.MapWindow(ids.window());

    var rt: Image = try .init(std.heap.page_allocator, .{
        .x = @intCast(window_size.x),
        .y = @intCast(window_size.y),
    });
    defer rt.deinit(std.heap.page_allocator);

    const raster_pixmap = ids.rasterPixmap();
    try sink.CreatePixmap(raster_pixmap, ids.window().drawable(), .{
        .depth = .@"24",
        .width = @intCast(rt.size.x),
        .height = @intCast(rt.size.y),
    });
    const raster_gc = ids.rasterGc();
    try sink.CreateGc(raster_gc, raster_pixmap.drawable(), .{});

    var sprite: Image = try .init(std.heap.page_allocator, .{
        .x = 64,
        .y = 64,
    });
    defer sprite.deinit(std.heap.page_allocator);
    sprite.clear(.{
        .r = 0x00,
        .g = 0x00,
        .b = 0x00,
        .a = 0x00,
    });
    sprite.fillCircle(
        .{ .x = 32, .y = 10 },
        10,
        .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xff },
    );
    sprite.drawLine(
        .{ .x = 32, .y = 10 },
        .{ .x = 32, .y = 40 },
        2,
        .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xff },
    );
    sprite.drawLine(
        .{ .x = 20, .y = 59 },
        .{ .x = 32, .y = 40 },
        2,
        .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xff },
    );
    sprite.drawLine(
        .{ .x = 64 - 20, .y = 59 },
        .{ .x = 32, .y = 40 },
        2,
        .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xff },
    );
    sprite.drawLine(
        .{ .x = 20, .y = 35 },
        .{ .x = 32, .y = 20 },
        2,
        .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xff },
    );
    sprite.drawLine(
        .{ .x = 64 - 20, .y = 35 },
        .{ .x = 32, .y = 20 },
        2,
        .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xff },
    );

    var entity_buf: [16]Entity = undefined;
    var entities: std.ArrayList(Entity) = .initBuffer(&entity_buf);
    try entities.appendBounded(.{
        .shape = .{ .rect = .{
            .extent = .{
                .x = 0,
                .y = 0,
                .width = 100,
                .height = 100,
            },
            .color = .{ .r = 0xff, .g = 0xaa, .b = 0x22, .a = 0xaa },
        } },
        .origin = .{ .x = 0, .y = 0 },
        .velocity = .{ .x = 2, .y = 1 },
    });
    try entities.appendBounded(.{
        .shape = .{ .rect = .{
            .extent = .{
                .x = 100,
                .y = 50,
                .width = 100,
                .height = 100,
            },
            .color = .{ .r = 0xff, .g = 0x00, .b = 0x00, .a = 0xee },
        } },
        .origin = .{ .x = 0, .y = 0 },
        .velocity = .{ .x = 3, .y = 4 },
    });
    try entities.appendBounded(.{
        .shape = .{ .fill_rounded_rect = .{
            .extent = .{
                .x = 100,
                .y = 50,
                .width = 50,
                .height = 100,
            },
            .radius = 20,
            .color = .{ .r = 0xff, .g = 0xaa, .b = 0xaa, .a = 0xaa },
        } },
        .origin = .{ .x = 0, .y = 0 },
        .velocity = .{ .x = 2, .y = 4 },
    });
    try entities.appendBounded(.{
        .shape = .{ .draw_rounded_rect = .{
            .extent = .{
                .x = 50,
                .y = 100,
                .width = 50,
                .height = 100,
            },
            .radius = 20,
            .stroke_size = 10,
            .color = .{ .r = 0xaa, .g = 0x00, .b = 0xaa, .a = 0xaa },
        } },
        .origin = .{ .x = 0, .y = 0 },
        .velocity = .{ .x = 2, .y = 3 },
    });
    try entities.appendBounded(.{
        .shape = .{ .fill_circle = .{
            .radius = 50,
            .color = .{ .r = 0x00, .g = 0xff, .b = 0xff, .a = 0xaa },
        } },
        .origin = .{ .x = 10, .y = 10 },
        .velocity = .{ .x = -4, .y = 0 },
    });
    try entities.appendBounded(.{
        .shape = .{ .fill_circle = .{
            .radius = 25,
            .color = .{ .r = 0xff, .g = 0x00, .b = 0xff, .a = 0xaa },
        } },
        .origin = .{ .x = 20, .y = 10 },
        .velocity = .{ .x = 4, .y = -2 },
    });
    try entities.appendBounded(.{
        .shape = .{ .fill_circle = .{
            .radius = 30,
            .color = .{ .r = 0xff, .g = 0xff, .b = 0x00, .a = 0xaa },
        } },
        .origin = .{ .x = 100, .y = 20 },
        .velocity = .{ .x = 3, .y = 2 },
    });
    try entities.appendBounded(.{
        .shape = .{ .draw_circle = .{
            .radius = 50,
            .color = .{ .r = 0x00, .g = 0xaa, .b = 0xaa, .a = 0xaa },
            .stroke_size = 2,
        } },
        .origin = .{ .x = 5, .y = 10 },
        .velocity = .{ .x = -3, .y = 0 },
    });
    try entities.appendBounded(.{
        .shape = .{ .draw_circle = .{
            .radius = 25,
            .color = .{ .r = 0xff, .g = 0x00, .b = 0xff, .a = 0xaa },
            .stroke_size = 10,
        } },
        .origin = .{ .x = 20, .y = 5 },
        .velocity = .{ .x = 4, .y = -3 },
    });
    try entities.appendBounded(.{
        .shape = .{ .draw_circle = .{
            .radius = 30,
            .color = .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xff },
            .stroke_size = 1,
        } },
        .origin = .{ .x = 100, .y = 20 },
        .velocity = .{ .x = 3, .y = 3 },
    });
    try entities.appendBounded(.{
        .shape = .{ .line_start = .{
            .radius = 10,
            .color = .{ .r = 0x00, .g = 0xaa, .b = 0x00, .a = 0xff },
        } },
        .origin = .{ .x = 50, .y = 50 },
        .velocity = .{ .x = 2, .y = 3 },
    });
    try entities.appendBounded(.{
        .shape = .line_end,
        .origin = .{ .x = 100, .y = 40 },
        .velocity = .{ .x = 3, .y = 2 },
    });
    try entities.appendBounded(.{
        .shape = .{ .line_start = .{
            .radius = 5,
            .color = .{ .r = 0x00, .g = 0x00, .b = 0xaa, .a = 0xaa },
        } },
        .origin = .{ .x = 25, .y = 50 },
        .velocity = .{ .x = 4, .y = 3 },
    });
    try entities.appendBounded(.{
        .shape = .line_end,
        .origin = .{ .x = 100, .y = 80 },
        .velocity = .{ .x = -3, .y = -3 },
    });
    try entities.appendBounded(.{
        .shape = .{ .sprite = .{ .image = sprite, .opacity = 0xff / 2 } },
        .origin = .{ .x = 20, .y = 10 },
        .velocity = .{ .x = 1, .y = -1 },
    });
    try entities.appendBounded(.{
        .shape = .{ .sprite = .{ .image = sprite, .opacity = 0xff } },
        .origin = .{ .x = 0, .y = 20 },
        .velocity = .{ .x = 1, .y = 1 },
    });

    var timer: std.time.Timer = try .start();
    while (true) {
        // Poll for events
        while (socket_reader.interface().bufferedLen() > 0) {
            try sink.writer.flush();
            const msg_kind = source.readKind() catch |err| return switch (err) {
                error.EndOfStream => {
                    std.log.info("X11 connection closed (EndOfStream)", .{});
                    std.process.exit(0);
                },
                else => |e| switch (socket_reader.getError() orelse e) {
                    error.ConnectionResetByPeer => {
                        std.log.info("X11 connection closed (ConnectionReset)", .{});
                        return std.process.exit(0);
                    },
                    else => |e2| e2,
                },
            };

            switch (msg_kind) {
                .Expose => {
                    const expose = try source.read2(.Expose);
                    std.log.info("X11 {}", .{expose});
                },
                .ConfigureNotify => {
                    const msg = try source.read2(.ConfigureNotify);
                    std.debug.assert(msg.event == ids.window());
                    std.debug.assert(msg.window == ids.window());
                    if (window_size.x != msg.width or window_size.y != msg.height) {
                        std.log.info("WindowSize {}x{}", .{ msg.width, msg.height });
                        window_size = .{ .x = msg.width, .y = msg.height };
                    }
                },
                .MapNotify,
                .MotionNotify,
                .MappingNotify,
                .ReparentNotify,
                => try source.discardRemaining(),
                else => std.debug.panic("unexpected X11 {f}", .{source.readFmt()}),
            }
        }

        // Update
        Entity.update(entities.items, window_size);

        // Render
        try render(
            &sink,
            ids,
            dbe,
            window_size,
            rt,
            entities.items,
        );

        // Sleep
        while (true) {
            const elapsed = timer.read();
            if (elapsed > timer_period_ns) break;
        }
        timer.reset();
    }

    try sink.FreePixmap(raster_pixmap);
    try sink.FreeGc(ids.raster_gc);
}

const Entity = struct {
    const Shape = union(enum) {
        rect: struct {
            extent: x11.Rectangle,
            color: Image.Color,
        },
        fill_rounded_rect: struct {
            extent: x11.Rectangle,
            radius: u32,
            color: Image.Color,
        },
        draw_rounded_rect: struct {
            extent: x11.Rectangle,
            radius: u32,
            stroke_size: f32,
            color: Image.Color,
        },
        fill_circle: struct {
            radius: u8,
            color: Image.Color,
        },
        draw_circle: struct {
            radius: u8,
            color: Image.Color,
            stroke_size: f32,
        },
        /// Must be followed by `line_end`.
        line_start: struct { radius: u8, color: Image.Color },
        /// Must come after `line_start`.
        line_end: void,
        sprite: struct { image: Image, opacity: u8 },
    };
    shape: Shape,
    origin: x11.XY(i16),
    velocity: x11.XY(i16),

    pub fn getAabb(entities: []const @This(), index: usize) x11.Rectangle {
        const entity = entities[index];
        switch (entity.shape) {
            inline .rect, .fill_rounded_rect => |rect| return .{
                .x = entity.origin.x + rect.extent.x,
                .y = entity.origin.y + rect.extent.y,
                .width = rect.extent.width,
                .height = rect.extent.height,
            },
            .draw_rounded_rect => |rect| {
                const stroke_size: i16 = @intFromFloat(@ceil(rect.stroke_size));
                return .{
                    .x = entity.origin.x + rect.extent.x - stroke_size,
                    .y = entity.origin.y + rect.extent.y - stroke_size,
                    .width = rect.extent.width + @as(u16, @intCast(stroke_size)),
                    .height = rect.extent.height + @as(u16, @intCast(stroke_size)),
                };
            },
            .fill_circle => |circle| return .{
                .x = entity.origin.x - @as(i16, @intCast(circle.radius)),
                .y = entity.origin.y - @as(i16, @intCast(circle.radius)),
                .width = @as(u16, @intCast(circle.radius)) * 2,
                .height = @as(u16, @intCast(circle.radius)) * 2,
            },
            .draw_circle => |circle| {
                const r: i16 = @intFromFloat(@ceil(@as(f32, @floatFromInt(circle.radius)) + circle.stroke_size / 2));
                return .{
                    .x = entity.origin.x - r,
                    .y = entity.origin.y - r,
                    .width = @as(u16, @intCast(r)) * 2,
                    .height = @as(u16, @intCast(r)) * 2,
                };
            },
            .line_start => |line_start| {
                const rn = -@as(i16, line_start.radius);
                const r2 = @as(u16, line_start.radius) * 2;
                return .{
                    .x = entity.origin.x + rn,
                    .y = entity.origin.y + rn,
                    .width = r2,
                    .height = r2,
                };
            },
            .line_end => {
                var result: x11.Rectangle = .{
                    .x = entity.origin.x,
                    .y = entity.origin.y,
                    .width = 0,
                    .height = 0,
                };
                if (index == 0) return result;
                const prev = entities[index - 1];
                if (prev.shape != .line_start) return result;
                result.x -= prev.shape.line_start.radius;
                result.y -= prev.shape.line_start.radius;
                result.width = prev.shape.line_start.radius * 2;
                result.height = prev.shape.line_start.radius * 2;
                return result;
            },
            .sprite => |sprite| return .{
                .x = entity.origin.x,
                .y = entity.origin.y,
                .width = @intCast(sprite.image.size.x),
                .height = @intCast(sprite.image.size.y),
            },
        }
    }

    pub fn update(entities: []@This(), window_size: x11.XY(u16)) void {
        for (entities, 0..) |*entity, i| {
            const bounce_margin = 50;

            entity.origin.x += entity.velocity.x;
            entity.origin.y += entity.velocity.y;

            const aabb = getAabb(entities, i);

            if (aabb.x - bounce_margin > window_size.x) {
                entity.velocity.x = -@as(i16, @intCast(@abs(entity.velocity.x)));
            } else if (aabb.x + @as(i16, @intCast(aabb.width)) + bounce_margin < 0) {
                entity.velocity.x = @intCast(@abs(entity.velocity.x));
            }

            if (aabb.y - bounce_margin > window_size.y) {
                entity.velocity.y = -@as(i16, @intCast(@abs(entity.velocity.y)));
            } else if (aabb.y + @as(i16, @intCast(aabb.height)) + bounce_margin < 0) {
                entity.velocity.y = @intCast(@abs(entity.velocity.y));
            }
        }
    }

    pub fn render(entities: []const @This(), rt: Image) void {
        var i: usize = 0;
        while (i < entities.len) : (i += 1) {
            const entity = entities[i];
            switch (entity.shape) {
                .rect => |rect| rt.fillRect(
                    getAabb(entities, i),
                    rect.color,
                ),
                .fill_rounded_rect => |rect| rt.fillRoundedRect(
                    getAabb(entities, i),
                    rect.radius,
                    rect.color,
                ),
                .draw_rounded_rect => |rect| rt.drawRoundedRect(
                    getAabb(entities, i),
                    rect.radius,
                    rect.stroke_size,
                    rect.color,
                ),
                .fill_circle => |circle| rt.fillCircle(
                    entity.origin,
                    circle.radius,
                    circle.color,
                ),
                .draw_circle => |circle| rt.drawCircle(
                    entity.origin,
                    circle.radius,
                    circle.stroke_size,
                    circle.color,
                ),
                .line_start => |line_end| {
                    if (i + 1 >= entities.len) continue;
                    const other = entities[i + 1];
                    if (other.shape != .line_end) continue;
                    rt.drawLine(
                        entity.origin,
                        other.origin,
                        line_end.radius,
                        line_end.color,
                    );
                    i += 1;
                },
                .line_end => {},
                .sprite => |sprite| rt.drawImage(entity.origin, sprite.image, sprite.opacity),
            }
        }
    }
};

fn render(
    sink: *x11.RequestSink,
    ids: Ids,
    dbe: Dbe,
    window_size: XY(u16),
    rt: Image,
    entities: []const Entity,
) !void {
    const window = ids.window();
    const gc = ids.gc();

    if (null == dbe.backBuffer()) {
        try sink.ClearArea(
            window,
            .{
                .x = 0,
                .y = 0,
                .width = window_size.x,
                .height = window_size.y,
            },
            .{ .exposures = false },
        );
    }
    const drawable: x11.Drawable = if (dbe.backBuffer()) |back_buffer| back_buffer else window.drawable();

    rt.clear(.{ .r = 0xff, .g = 0xff, .b = 0xff, .a = 0xff });

    // Render a grid background
    {
        const cell_size = 10;
        var row: i16 = 0;
        while (row <= window_size.x / cell_size) : (row += 1) {
            const y = row * cell_size;
            var col: i16 = 0;
            while (col <= window_size.y / cell_size) : (col += 1) {
                const x = col * cell_size * 2 + cell_size * @mod(row, 2);
                rt.fillRect(
                    .{
                        .x = x,
                        .y = y,
                        .width = cell_size,
                        .height = cell_size,
                    },
                    .{
                        .r = 0x00,
                        .g = 0x00,
                        .b = 0x00,
                        .a = 0x40,
                    },
                );
            }
        }
    }

    Entity.render(entities, rt);

    try sink.PutImage(.{
        .format = .z_pixmap,
        .drawable = ids.rasterPixmap().drawable(),
        .gc_id = ids.rasterGc(),
        .width = @intCast(rt.size.x),
        .height = @intCast(rt.size.y),
        .x = 0,
        .y = 0,
        .depth = .@"24",
    }, .init(rt.bytes().ptr, @intCast(rt.bytes().len)));

    try sink.CopyArea(.{
        .src_drawable = ids.rasterPixmap().drawable(),
        .dst_drawable = drawable,
        .gc = gc,
        .src_x = 0,
        .src_y = 0,
        .dst_x = 0,
        .dst_y = 0,
        .width = @intCast(rt.size.x),
        .height = @intCast(rt.size.y),
    });

    switch (dbe) {
        .unsupported => {},
        .enabled => |enabled| try x11.dbe.Swap(sink, enabled.opcode_base, .initAssume(&.{
            .{ .window = window, .action = .background },
        })),
    }
}

const Dbe = union(enum) {
    unsupported,
    enabled: struct {
        opcode_base: u8,
        back_buffer: x11.Drawable,
    },
    pub fn backBuffer(self: Dbe) ?x11.Drawable {
        return switch (self) {
            .unsupported => null,
            .enabled => |enabled| enabled.back_buffer,
        };
    }
};

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

const builtin = @import("builtin");
const std = @import("std");
const x11 = @import("x11");
const XY = x11.XY;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const Cmdline = @import("Cmdline.zig");
const math = std.math;
const clamp = math.clamp;
