// XXX: get tests running, maybe disable slow tests by default
// XXX: consider comparing ot preompocuting, need to profile in general
// XXX: vectorize? bin on threads?
// XXX: compare to f32 version visually, and benchmark
// XXX: we could bin this if we need more speed, but i suspect that it will be plenty fast. need to
// divide into multiple copy areas somehow if we want to test visually but idk if we really can from one
// buffer. i guess we could just not worry about the visuals for that test.
pub const RenderTarget = struct {
    buf: []Color,
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
        };

        /// Efficiently blends source onto destination, emulating the alpha blending you'd get from
        /// alpha blending on a GPU. When possible, cache the premultiplied source outside of your hot
        /// loop.
        ///
        /// Note: This method is intended for real time use. If you can afford a more expensive blend
        /// or are building a tool that will be used by artists, you should not be calling this method,
        /// you should be blending in a perceptual space like Oklab or at least doing sRGB correction
        /// before you call this method.
        pub fn blend(dst: Color, src_premul: Premultiplied) Color {
            const dst_scaled = dst.scale(0xff - src_premul.a);
            return .{
                .r = src_premul.r + dst_scaled.r,
                .g = src_premul.g + dst_scaled.g,
                .b = src_premul.b + dst_scaled.b,
                .a = src_premul.a + dst_scaled.a,
            };
        }

        /// Efficiently scales the color channels by the alpha channel.
        pub fn premul(self: Color) Premultiplied {
            if (self.a == 0xff) return @bitCast(self);
            var bgr = self;
            bgr.a = 0xff;
            return @bitCast(bgr.scale(self.a));
        }

        /// Efficiently scales all channels by the given unorm factor.
        ///
        /// Adapted from "Alpha Blending with No Division Operations" by Jerry R. Van Aken:
        ///
        /// https://arxiv.org/pdf/2202.02864
        pub fn scale(self: Color, factor: u8) Color {
            comptime assert(builtin.cpu.arch.endian() == .little);
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

        /// Equivalent to `premul`, but internally computes the result using floating point. This is
        /// slow, used only as a test oracle.
        fn premulF32(self: Color) Premultiplied {
            var bgr = self;
            bgr.a = 0xff;
            return @bitCast(bgr.scaleF32(self.a));
        }

        fn scaleF32(color: Color, factor: u8) Color {
            return .{
                .r = unormTimesUnormF32(factor, color.r),
                .g = unormTimesUnormF32(factor, color.g),
                .b = unormTimesUnormF32(factor, color.b),
                .a = unormTimesUnormF32(factor, color.a),
            };
        }

        /// Multiplies two unorms by temporarily converting to f32. This is slow, used only as a test
        /// oracle.
        fn unormTimesUnormF32(alpha: u8, red: u8) u8 {
            const a: f32 = @floatFromInt(alpha);
            const r: f32 = @floatFromInt(red);
            return @intFromFloat(@round((a * r) / 255));
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

    test {
        _ = Color;
    }

    pub fn init(gpa: Allocator, size: XY(u32)) !@This() {
        return .{
            .buf = try gpa.alloc(Color, @as(usize, size.x) * @as(usize, size.y)),
            .size = size,
        };
    }

    pub fn deinit(self: *@This(), gpa: Allocator) void {
        gpa.free(self.buf);
        self.* = undefined;
    }

    pub fn clear(self: @This(), color: Color) void {
        @memset(self.buf, color);
    }

    pub fn fillRect(self: @This(), rect: x11.Rectangle, color: Color) void {
        // Clamp the bounds to the render target
        const x_min: u32 = @intCast(clamp(@as(i64, rect.x), 0, self.size.x));
        const x_max: u32 = @intCast(clamp(@as(i64, rect.x) + rect.width, 0, self.size.x));
        const y_min: u32 = @intCast(clamp(@as(i64, rect.y), 0, self.size.y));
        const y_max: u32 = @intCast(clamp(@as(i64, rect.y) + rect.height, 0, self.size.y));

        // Premultiply the color
        const color_p = color.premul();

        // Fill the rect
        for (y_min..y_max) |y| {
            self.fillScanline(x_min, x_max, @intCast(y), color_p);
        }
    }

    // XXX: test htat if it's 1px wide it actually is on the righ tpixel
    // XXX: profile blend operating on a pointer vs not?
    // XXX: i think we could step avoiding all sqrts using one of those algorithsm then continue with
    // the scanline fill mirroring, but, probably overkill if it's complex?
    pub fn fillCircle(self: @This(), center: x11.XY(i16), radius: u32, color: Color) void {
        // Precompute values we'll use in the hot loop
        const center_x: i64 = center.x;
        const r: f32 = @floatFromInt(radius);
        const r_sq = r * r;
        const x_mid: f32 = @floatFromInt(center.x);
        const y_mid: f32 = @floatFromInt(center.y);
        const color_p = color.premul();
        const alpha: f32 = @floatFromInt(color.a);

        // Clamp the vertical bounds to the render target
        const y_min: u32 = @intCast(clamp(@as(i64, center.y) - radius, 0, self.size.y));
        const y_max: u32 = @intCast(clamp(@as(i64, center.y) + radius, 0, self.size.y));

        // Iterate over the scanlines
        for (y_min..y_max) |y| {
            // Figure out the width of this scanline
            const dy = @as(f32, @floatFromInt(y)) - y_mid;
            const dy2 = dy * dy;
            const radius_x: i64 = @intFromFloat(@ceil(@sqrt(r_sq - dy2)));
            const x_min: i64 = center_x - radius_x + 1;
            const x_max: i64 = center_x + radius_x;

            // XXX: could have an even more braodphase that clips the whole shape
            // XXX: don't go from 0 to radius, start in the non clipped region
            // XXX: need to do this without overling when negative etc
            // XXX: make sure above 0
            // XXX: i think it's something to do with the dist to the elft and right edges as compared to the radius?
            // we need to set both the upper and lower obunds
            // XXX: >=/<= vs >/<?
            // const min_rad_x: usize = if (center.x < 0)
            //     // @intCast(@min(-center.x, radius_x))
            //     0
            // else if (center.x > self.size.x)
            //     // @intCast(@min(center.x - @as(i64, self.size.x), radius_x))
            //     0
            // else
            //     0;
            // XXX: CURRENT: miscompilation in x64 backend?? try later zig and then report if it's an issue?
            // if we set to 0 it works, if we set to 0 like this it fails
            const min_rad_x: usize = if (center.x < 0) 0 else 0;
            // const max_rad_x: usize = if (center.x < 0)
            //     @intCast(@min(-center.x + @as(i64, self.size.x), radius_x))
            // else if (center.x > self.size.x)
            //     @intCast(@min(center.x, radius_x))
            // else
            //     0;

            // Fill in the scanline
            // for (min_rad_x..max_rad_x) |i| {
            for (min_rad_x..@intCast(radius_x)) |i| {
                // Calculate the left and right x coordinates
                const left_x: i64 = x_min + @as(u32, @intCast(i));
                const right_x: i64 = x_max - @as(u32, @intCast(i));

                // Clip the left and right x coordintes
                const left_clipped = left_x < 0 or left_x >= self.size.x;
                const right_clipped = left_x == right_x or right_x < 0 or right_x >= self.size.x;

                // Calculate the coverage
                const x: f32 = @floatFromInt(left_x);
                const dx = x_mid - x;
                const dx2 = dx * dx;
                const d2 = dy2 + dx2;
                const d = @sqrt(d2);
                const coverage = clamp(r - d, 0, 1);

                // If the coverage is 1, we're past the antialiased region and should just fill in
                // the rest of the scanline at full opacity.
                if (coverage == 1) {
                    // Clip the left and right sides of the flood fill
                    // XXX: clip correctly, check this math not sure why +1 for example
                    const fill_left_unclamped = @as(i64, left_x);
                    const fill_right_unclamped = @as(i64, @intCast(x_max)) + 1 - @as(i64, @intCast(i));
                    const fill_left: u32 = @intCast(clamp(fill_left_unclamped, 0, self.size.x));
                    const fill_right: u32 = @intCast(clamp(fill_right_unclamped, 0, self.size.x));
                    self.fillScanline(fill_left, fill_right, @intCast(y), color_p);
                    break;
                }

                // Calculate the antialiased color
                const color_aa = Color.premul(.{
                    .r = color.r,
                    .g = color.g,
                    .b = color.b,
                    .a = @intFromFloat(coverage * alpha),
                });

                // Blend with the render target. The casts are safe when not clipped.
                const row_index = self.size.x * y;
                if (!left_clipped) {
                    const sample = &self.buf[row_index + @as(usize, @intCast(left_x))];
                    sample.* = sample.*.blend(color_aa);
                }
                if (!right_clipped) {
                    const sample = &self.buf[row_index + @as(usize, @intCast(right_x))];
                    sample.* = sample.*.blend(color_aa);
                }
            }
        }
    }

    /// Fills the scanline using memset if possible, falling back to a for loop if alpha blending is
    /// required. Inputs must be clamped in advance.
    pub fn fillScanline(self: @This(), x0: u32, x1: u32, y: u32, color: Color.Premultiplied) void {
        const row_start: usize = @as(usize, y) * @as(usize, self.size.x);
        const start = row_start + x0;
        const end = row_start + x1;
        if (color.a == 0xff) {
            @memset(self.buf[start..end], @bitCast(color));
        } else for (start..end) |i| {
            const sample = &self.buf[i];
            sample.* = sample.*.blend(color);
        }
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

    var rt: RenderTarget = try .init(std.heap.page_allocator, .{
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

    while (true) {
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

        var do_render = false;
        switch (msg_kind) {
            .Expose => {
                const expose = try source.read2(.Expose);
                std.log.info("X11 {}", .{expose});
                do_render = true;
            },
            .ConfigureNotify => {
                const msg = try source.read2(.ConfigureNotify);
                std.debug.assert(msg.event == ids.window());
                std.debug.assert(msg.window == ids.window());
                if (window_size.x != msg.width or window_size.y != msg.height) {
                    std.log.info("WindowSize {}x{}", .{ msg.width, msg.height });
                    window_size = .{ .x = msg.width, .y = msg.height };
                    do_render = true;
                }
            },
            .MapNotify,
            .MotionNotify,
            .MappingNotify,
            .ReparentNotify,
            => try source.discardRemaining(),
            else => std.debug.panic("unexpected X11 {f}", .{source.readFmt()}),
        }
        if (do_render) {
            try render(
                &sink,
                ids,
                dbe,
                window_size,
                rt,
            );
        }
    }

    try sink.FreePixmap(raster_pixmap);
    try sink.FreeGc(ids.raster_gc);
}

fn render(
    sink: *x11.RequestSink,
    ids: Ids,
    dbe: Dbe,
    window_size: XY(u16),
    rt: RenderTarget,
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
    rt.fillRect(.{
        .x = 100,
        .y = 100,
        .width = 10,
        .height = 100,
    }, .{
        .r = 0x00,
        .g = 0x00,
        .b = 0xff,
        .a = 0xff / 4,
    });

    rt.fillRect(.{
        .x = 100,
        .y = 0,
        .width = 50,
        .height = 50,
    }, .{
        .r = 0x00,
        .g = 0x00,
        .b = 0xff,
        .a = 0xff,
    });

    rt.fillCircle(
        .{ .x = 100, .y = 100 },
        50,
        .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0x22 },
    );
    rt.fillCircle(
        .{ .x = 200, .y = 100 },
        50,
        .{ .r = 0x00, .g = 0xff, .b = 0x00, .a = 0xff },
    );
    // rt.fillCircle(
    //     .{ .x = 0, .y = 100 },
    //     1000,
    //     .{ .r = 0x00, .g = 0xff, .b = 0x00, .a = 0xff },
    // );

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
