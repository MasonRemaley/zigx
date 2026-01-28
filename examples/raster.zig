// XXX: get tests running, maybe disable slow tests by default
// XXX: consider comparing ot preompocuting, need to profile in general
// XXX: vectorize? bin on threads?
// XXX: compare to f32 version visually, and benchmark
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

        // Fast path for when alpha blending isn't required
        if (color.a == 0xff) {
            for (y_min..y_max) |y| {
                @memset(self.buf[y * self.size.x + x_min ..][0 .. x_max - x_min], color);
            }
            return;
        }

        // Alpha blended implementation
        const color_p = color.premul();
        for (y_min..y_max) |y| {
            const row_start = y * self.size.x;
            for (self.buf[row_start + x_min .. row_start + x_max]) |*dst| {
                dst.* = dst.blend(color_p);
            }
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
                .ButtonPress = 1,
                .ButtonRelease = 1,
                .PointerMotion = 1,
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

    rt.clear(.{ .r = 0xff, .g = 0x00, .b = 0x00, .a = 0xff });
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
const clamp = std.math.clamp;
