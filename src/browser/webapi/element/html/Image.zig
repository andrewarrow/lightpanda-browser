const std = @import("std");
const lp = @import("lightpanda");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const HttpClient = @import("../../../HttpClient.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const log = lp.log;
const String = lp.String;
const Image = @This();
_proto: *HtmlElement,
_current_src: ?[:0]const u8 = null,
_data: []const u8 = "",
_natural_width: u32 = 0,
_natural_height: u32 = 0,
_state: LoadState = .unavailable,

const LoadState = enum {
    unavailable,
    loading,
    available,
    broken,
};

pub fn constructor(w_: ?u32, h_: ?u32, frame: *Frame) !*Image {
    const node = try frame.createElementNS(.html, "img", null);
    const el = node.as(Element);

    if (w_) |w| blk: {
        const w_string = std.fmt.bufPrint(&frame.buf, "{d}", .{w}) catch break :blk;
        try el.setAttributeSafe(comptime .wrap("width"), .wrap(w_string), frame);
    }
    if (h_) |h| blk: {
        const h_string = std.fmt.bufPrint(&frame.buf, "{d}", .{h}) catch break :blk;
        try el.setAttributeSafe(comptime .wrap("height"), .wrap(h_string), frame);
    }
    return el.as(Image);
}

pub fn asElement(self: *Image) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Image) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Image) *Node {
    return self.asElement().asNode();
}

pub fn getSrc(self: *const Image, frame: *Frame) ![]const u8 {
    const element = self.asConstElement();
    const src = element.getAttributeSafe(comptime .wrap("src")) orelse return "";
    if (src.len == 0) {
        return "";
    }
    return element.asConstNode().resolveURL(src, frame, .{});
}

pub fn setSrc(self: *Image, value: []const u8, frame: *Frame) !void {
    const element = self.asElement();
    try element.setAttributeSafe(comptime .wrap("src"), .wrap(value), frame);
}

pub fn getAlt(self: *const Image) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("alt")) orelse "";
}

pub fn setAlt(self: *Image, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("alt"), .wrap(value), frame);
}

pub fn getWidth(self: *const Image) u32 {
    const attr = self.asConstElement().getAttributeSafe(comptime .wrap("width")) orelse return 0;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 0;
}

pub fn setWidth(self: *Image, value: u32, frame: *Frame) !void {
    const str = try std.fmt.allocPrint(frame.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("width"), .wrap(str), frame);
}

pub fn getHeight(self: *const Image) u32 {
    const attr = self.asConstElement().getAttributeSafe(comptime .wrap("height")) orelse return 0;
    return std.fmt.parseUnsigned(u32, attr, 10) catch 0;
}

pub fn setHeight(self: *Image, value: u32, frame: *Frame) !void {
    const str = try std.fmt.allocPrint(frame.call_arena, "{d}", .{value});
    try self.asElement().setAttributeSafe(comptime .wrap("height"), .wrap(str), frame);
}

pub fn getCrossOrigin(self: *const Image) ?[]const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("crossorigin"));
}

pub fn setCrossOrigin(self: *Image, value: ?[]const u8, frame: *Frame) !void {
    if (value) |v| {
        return self.asElement().setAttributeSafe(comptime .wrap("crossorigin"), .wrap(v), frame);
    }
    return self.asElement().removeAttribute(comptime .wrap("crossorigin"), frame);
}

pub fn getLoading(self: *const Image) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("loading")) orelse "eager";
}

pub fn setLoading(self: *Image, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("loading"), .wrap(value), frame);
}

pub fn getNaturalWidth(self: *const Image) u32 {
    return self._natural_width;
}

pub fn getNaturalHeight(self: *const Image) u32 {
    return self._natural_height;
}

pub fn getComplete(self: *const Image) bool {
    // Per spec, complete is true when: no src/srcset, src is empty,
    // image is fully available, or image is broken (with no pending request).
    const src = self.asConstElement().getAttributeSafe(comptime .wrap("src")) orelse return true;
    if (src.len == 0) {
        return true;
    }
    return self._state != .loading;
}

/// Used in `Page.nodeIsReady`.
pub fn imageAddedCallback(self: *Image, frame: *Frame) !void {
    // if we're planning on navigating to another frame, don't trigger load event.
    if (frame.isGoingAway()) {
        return;
    }

    const element = self.asElement();
    // Exit if src not set.
    const src = element.getAttributeSafe(comptime .wrap("src")) orelse {
        self.resetImageLoad();
        return;
    };
    if (src.len == 0) {
        self.resetImageLoad();
        return;
    }

    const url = try self.asNode().resolveURL(src, frame, .{ .allocator = frame.arena });
    if (self._current_src) |current_src| {
        if (std.mem.eql(u8, current_src, url) and (self._state == .loading or self._state == .available)) {
            return;
        }
    }

    self._current_src = url;
    self._data = "";
    self._natural_width = 0;
    self._natural_height = 0;
    self._state = .loading;

    const counted_for_load = frame.subresourceStartedLoading();
    var handed_to_client = false;
    errdefer if (!handed_to_client) {
        self._state = .broken;
        frame.subresourceFailedLoading(counted_for_load);
    };

    var headers = try frame._session.browser.http_client.newHeaders();
    errdefer headers.deinit();
    try frame.headersForRequest(&headers);

    const ctx = try frame.arena.create(ImageRequest);
    ctx.* = .{
        .frame = frame,
        .image = self,
        .url = url,
        .counted_for_load = counted_for_load,
    };

    handed_to_client = true;
    frame._session.browser.http_client.request(.{
        .ctx = ctx,
        .params = .{
            .url = url,
            .method = .GET,
            .frame_id = frame._frame_id,
            .loader_id = frame._loader_id,
            .headers = headers,
            .cookie_jar = &frame._session.cookie_jar,
            .cookie_origin = frame.url,
            .resource_type = .image,
            .notification = frame._session.notification,
        },
        .header_callback = ImageRequest.headerCallback,
        .data_callback = ImageRequest.dataCallback,
        .done_callback = ImageRequest.doneCallback,
        .error_callback = ImageRequest.errorCallback,
        .shutdown_callback = ImageRequest.shutdownCallback,
    }) catch |err| {
        log.warn(.http, "image fetch start failed", .{ .err = err, .url = url });
    };
}

fn resetImageLoad(self: *Image) void {
    self._current_src = null;
    self._data = "";
    self._natural_width = 0;
    self._natural_height = 0;
    self._state = .unavailable;
}

fn currentSrcMatches(self: *const Image, url: []const u8) bool {
    const current_src = self._current_src orelse return false;
    return std.mem.eql(u8, current_src, url);
}

const ImageRequest = struct {
    frame: *Frame,
    image: *Image,
    url: [:0]const u8,
    counted_for_load: bool,
    status: u16 = 0,
    body: std.ArrayList(u8) = .empty,

    fn headerCallback(response: HttpClient.Response) !bool {
        const self: *ImageRequest = @ptrCast(@alignCast(response.ctx));
        self.status = response.status() orelse 0;
        if (response.contentLength()) |cl| {
            try self.body.ensureTotalCapacity(self.frame.arena, cl);
        }
        return self.status >= 200 and self.status < 300;
    }

    fn dataCallback(response: HttpClient.Response, data: []const u8) !void {
        const self: *ImageRequest = @ptrCast(@alignCast(response.ctx));
        try self.body.appendSlice(self.frame.arena, data);
    }

    fn doneCallback(ctx: *anyopaque) !void {
        const self: *ImageRequest = @ptrCast(@alignCast(ctx));
        const image = self.image;
        if (!image.currentSrcMatches(self.url)) {
            self.frame.subresourceFailedLoading(self.counted_for_load);
            return;
        }

        image._data = self.body.items;
        if (sniffImageSize(self.body.items)) |size| {
            image._natural_width = size.width;
            image._natural_height = size.height;
        }
        image._state = .available;

        self.frame.subresourceCompletedLoading(image._proto, self.counted_for_load);
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        const self: *ImageRequest = @ptrCast(@alignCast(ctx));
        if (self.image.currentSrcMatches(self.url)) {
            self.image._state = .broken;
            self.image._data = "";
            self.image._natural_width = 0;
            self.image._natural_height = 0;
        }
        log.debug(.http, "image fetch error", .{ .err = err, .url = self.url, .status = self.status });
        self.frame.subresourceFailedLoading(self.counted_for_load);
    }

    fn shutdownCallback(ctx: *anyopaque) void {
        const self: *ImageRequest = @ptrCast(@alignCast(ctx));
        if (self.image.currentSrcMatches(self.url)) {
            self.image._state = .broken;
        }
        self.frame.subresourceFailedLoading(self.counted_for_load);
    }
};

const ImageSize = struct {
    width: u32,
    height: u32,
};

fn sniffImageSize(data: []const u8) ?ImageSize {
    if (sniffPngSize(data)) |size| return size;
    if (sniffGifSize(data)) |size| return size;
    if (sniffJpegSize(data)) |size| return size;
    return null;
}

fn sniffPngSize(data: []const u8) ?ImageSize {
    const signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };
    if (data.len < 24 or !std.mem.eql(u8, data[0..8], &signature)) {
        return null;
    }

    return .{
        .width = readU32BE(data[16..20]),
        .height = readU32BE(data[20..24]),
    };
}

fn sniffGifSize(data: []const u8) ?ImageSize {
    if (data.len < 10) return null;
    if (!std.mem.eql(u8, data[0..6], "GIF87a") and !std.mem.eql(u8, data[0..6], "GIF89a")) {
        return null;
    }

    return .{
        .width = @intCast(readU16LE(data[6..8])),
        .height = @intCast(readU16LE(data[8..10])),
    };
}

fn sniffJpegSize(data: []const u8) ?ImageSize {
    if (data.len < 4 or data[0] != 0xff or data[1] != 0xd8) {
        return null;
    }

    var index: usize = 2;
    while (index + 9 < data.len) {
        if (data[index] != 0xff) {
            index += 1;
            continue;
        }

        while (index < data.len and data[index] == 0xff) {
            index += 1;
        }
        if (index >= data.len) break;

        const marker = data[index];
        index += 1;
        if (marker == 0xd9 or marker == 0xda) {
            break;
        }
        if (index + 2 > data.len) break;

        const segment_len = readU16BE(data[index .. index + 2]);
        const segment_end = index + @as(usize, segment_len);
        if (segment_len < 2 or segment_end > data.len) {
            break;
        }

        if (isJpegStartOfFrame(marker)) {
            if (segment_len < 7) break;
            return .{
                .height = @intCast(readU16BE(data[index + 3 .. index + 5])),
                .width = @intCast(readU16BE(data[index + 5 .. index + 7])),
            };
        }

        index = segment_end;
    }

    return null;
}

fn isJpegStartOfFrame(marker: u8) bool {
    return switch (marker) {
        0xc0,
        0xc1,
        0xc2,
        0xc3,
        0xc5,
        0xc6,
        0xc7,
        0xc9,
        0xca,
        0xcb,
        0xcd,
        0xce,
        0xcf,
        => true,
        else => false,
    };
}

fn readU16BE(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) | @as(u16, bytes[1]);
}

fn readU16LE(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn readU32BE(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        @as(u32, bytes[3]);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Image);

    pub const Meta = struct {
        pub const name = "HTMLImageElement";
        pub const constructor_alias = "Image";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Image.constructor, .{});
    pub const src = bridge.accessor(Image.getSrc, Image.setSrc, .{});
    pub const currentSrc = bridge.accessor(Image.getSrc, null, .{});
    pub const alt = bridge.accessor(Image.getAlt, Image.setAlt, .{});
    pub const width = bridge.accessor(Image.getWidth, Image.setWidth, .{});
    pub const height = bridge.accessor(Image.getHeight, Image.setHeight, .{});
    pub const crossOrigin = bridge.accessor(Image.getCrossOrigin, Image.setCrossOrigin, .{});
    pub const loading = bridge.accessor(Image.getLoading, Image.setLoading, .{});
    pub const naturalWidth = bridge.accessor(Image.getNaturalWidth, null, .{});
    pub const naturalHeight = bridge.accessor(Image.getNaturalHeight, null, .{});
    pub const complete = bridge.accessor(Image.getComplete, null, .{});
};

pub const Build = struct {
    pub fn created(node: *Node, frame: *Frame) !void {
        const self = node.as(Image);
        return self.imageAddedCallback(frame);
    }

    pub fn attributeChange(element: *Element, name: String, _: String, frame: *Frame) !void {
        if (!name.eql(comptime .wrap("src"))) {
            return;
        }
        try element.as(Image).imageAddedCallback(frame);
    }

    pub fn attributeRemove(element: *Element, name: String, _: *Frame) !void {
        if (!name.eql(comptime .wrap("src"))) {
            return;
        }
        element.as(Image).resetImageLoad();
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Image" {
    try testing.htmlRunner("element/html/image.html", .{});
}
