// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const lp = @import("lightpanda");
const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const HttpClient = @import("../../../HttpClient.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const CSSStyleSheet = @import("../../css/CSSStyleSheet.zig");

const log = lp.log;
const String = lp.String;
const Link = @This();
_proto: *HtmlElement,
_sheet: ?*CSSStyleSheet = null,
_loading_url: ?[:0]const u8 = null,

pub fn asElement(self: *Link) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Link) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Link) *Node {
    return self.asElement().asNode();
}

pub fn getHref(self: *Link, frame: *Frame) ![]const u8 {
    const element = self.asElement();
    const href = element.getAttributeSafe(comptime .wrap("href")) orelse return "";
    if (href.len == 0) {
        return "";
    }
    return element.asNode().resolveURL(href, frame, .{});
}

pub fn setHref(self: *Link, value: []const u8, frame: *Frame) !void {
    const element = self.asElement();
    try element.setAttributeSafe(comptime .wrap("href"), .wrap(value), frame);
}

pub fn getRel(self: *Link) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("rel")) orelse return "";
}

pub fn setRel(self: *Link, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("rel"), .wrap(value), frame);
}

pub fn getAs(self: *const Link) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("as")) orelse "";
}

pub fn setAs(self: *Link, value: []const u8, frame: *Frame) !void {
    return self.asElement().setAttributeSafe(comptime .wrap("as"), .wrap(value), frame);
}

pub fn getCrossOrigin(self: *const Link) ?[]const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("crossOrigin"));
}

pub fn setCrossOrigin(self: *Link, value: []const u8, frame: *Frame) !void {
    var normalized: []const u8 = "anonymous";
    if (std.ascii.eqlIgnoreCase(value, "use-credentials")) {
        normalized = "use-credentials";
    }
    return self.asElement().setAttributeSafe(comptime .wrap("crossOrigin"), .wrap(normalized), frame);
}

pub fn getSheet(self: *Link, _: *Frame) ?*CSSStyleSheet {
    if (!self.asNode().isConnected()) {
        return null;
    }
    if (!relHasToken(self.getRel(), "stylesheet")) {
        return null;
    }
    return self._sheet;
}

pub fn linkAddedCallback(self: *Link, frame: *Frame) !void {
    // if we're planning on navigating to another frame, don't trigger load event.
    if (frame.isGoingAway()) {
        return;
    }

    const element = self.asElement();

    const rel = element.getAttributeSafe(comptime .wrap("rel")) orelse return;
    if (relIsLoadable(rel) == false) {
        return;
    }

    const href = element.getAttributeSafe(comptime .wrap("href")) orelse return;
    if (href.len == 0) {
        return;
    }

    if (relHasToken(rel, "stylesheet")) {
        if (!self.isCssType()) {
            return;
        }
        try self.loadStylesheet(frame, href);
        return;
    }

    try frame.queueOrDispatchLoad(self._proto);
}

fn relIsLoadable(rel: []const u8) bool {
    return relHasToken(rel, "stylesheet") or
        relHasToken(rel, "preload") or
        relHasToken(rel, "modulepreload");
}

fn relHasToken(rel: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, rel, " \t\n\r\x0c");
    while (it.next()) |part| {
        if (std.ascii.eqlIgnoreCase(part, token)) {
            return true;
        }
    }
    return false;
}

fn isCssType(self: *const Link) bool {
    const value = self.asConstElement().getAttributeSafe(comptime .wrap("type")) orelse return true;
    return value.len == 0 or std.ascii.eqlIgnoreCase(value, "text/css");
}

fn loadingUrlMatches(self: *const Link, url: []const u8) bool {
    const loading_url = self._loading_url orelse return false;
    return std.mem.eql(u8, loading_url, url);
}

fn removeSheet(self: *Link, frame: *Frame) void {
    if (self._sheet) |sheet| {
        if (frame.document._style_sheets) |sheets| {
            sheets.remove(sheet);
        }
        self._sheet = null;
        frame._style_manager.sheetModified();
    }
    self._loading_url = null;
}

fn getOrCreateSheet(self: *Link, frame: *Frame, url: [:0]const u8) !*CSSStyleSheet {
    if (self._sheet) |sheet| {
        sheet._href = url;
        return sheet;
    }

    const sheet = try CSSStyleSheet.initWithOwner(self.asElement(), frame);
    sheet._href = url;
    self._sheet = sheet;

    const sheets = try frame.document.getStyleSheets(frame);
    try sheets.add(sheet, frame);

    return sheet;
}

fn loadStylesheet(self: *Link, frame: *Frame, href: []const u8) !void {
    const url = try self.asNode().resolveURL(href, frame, .{ .allocator = frame.arena });

    if (self.loadingUrlMatches(url)) {
        return;
    }

    if (self._sheet) |sheet| {
        if (sheet._href) |sheet_url| {
            if (std.mem.eql(u8, sheet_url, url)) {
                return;
            }
        }
    }

    self._loading_url = url;
    const counted_for_load = frame.subresourceStartedLoading();
    var handed_to_client = false;
    errdefer if (!handed_to_client) {
        self._loading_url = null;
        frame.subresourceFailedLoading(counted_for_load);
    };

    var headers = try frame._session.browser.http_client.newHeaders();
    errdefer headers.deinit();
    try frame.headersForRequest(&headers);

    const ctx = try frame.arena.create(StylesheetRequest);
    ctx.* = .{
        .frame = frame,
        .link = self,
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
            .resource_type = .stylesheet,
            .notification = frame._session.notification,
        },
        .header_callback = StylesheetRequest.headerCallback,
        .data_callback = StylesheetRequest.dataCallback,
        .done_callback = StylesheetRequest.doneCallback,
        .error_callback = StylesheetRequest.errorCallback,
        .shutdown_callback = StylesheetRequest.shutdownCallback,
    }) catch |err| {
        log.warn(.http, "stylesheet fetch start failed", .{ .err = err, .url = url });
    };
}

const StylesheetRequest = struct {
    frame: *Frame,
    link: *Link,
    url: [:0]const u8,
    counted_for_load: bool,
    status: u16 = 0,
    body: std.ArrayList(u8) = .empty,

    fn headerCallback(response: HttpClient.Response) !bool {
        const self: *StylesheetRequest = @ptrCast(@alignCast(response.ctx));
        self.status = response.status() orelse 0;
        if (response.contentLength()) |cl| {
            try self.body.ensureTotalCapacity(self.frame.arena, cl);
        }
        return self.status >= 200 and self.status < 300;
    }

    fn dataCallback(response: HttpClient.Response, data: []const u8) !void {
        const self: *StylesheetRequest = @ptrCast(@alignCast(response.ctx));
        try self.body.appendSlice(self.frame.arena, data);
    }

    fn doneCallback(ctx: *anyopaque) !void {
        const self: *StylesheetRequest = @ptrCast(@alignCast(ctx));
        const link = self.link;
        if (!link.loadingUrlMatches(self.url) or !link.asNode().isConnected()) {
            self.frame.subresourceFailedLoading(self.counted_for_load);
            return;
        }

        const sheet = link.getOrCreateSheet(self.frame, self.url) catch |err| {
            log.warn(.browser, "stylesheet create", .{ .err = err, .url = self.url });
            link._loading_url = null;
            self.frame.subresourceFailedLoading(self.counted_for_load);
            return;
        };

        sheet.replaceSync(self.body.items, self.frame) catch |err| {
            log.warn(.browser, "stylesheet parse", .{ .err = err, .url = self.url });
        };

        link._loading_url = null;
        self.frame.subresourceCompletedLoading(link._proto, self.counted_for_load);
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        const self: *StylesheetRequest = @ptrCast(@alignCast(ctx));
        if (self.link.loadingUrlMatches(self.url)) {
            self.link._loading_url = null;
        }
        log.warn(.http, "stylesheet fetch error", .{ .err = err, .url = self.url, .status = self.status });
        self.frame.subresourceFailedLoading(self.counted_for_load);
    }

    fn shutdownCallback(ctx: *anyopaque) void {
        const self: *StylesheetRequest = @ptrCast(@alignCast(ctx));
        if (self.link.loadingUrlMatches(self.url)) {
            self.link._loading_url = null;
        }
        self.frame.subresourceFailedLoading(self.counted_for_load);
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Link);

    pub const Meta = struct {
        pub const name = "HTMLLinkElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const as = bridge.accessor(Link.getAs, Link.setAs, .{});
    pub const rel = bridge.accessor(Link.getRel, Link.setRel, .{});
    pub const href = bridge.accessor(Link.getHref, Link.setHref, .{});
    pub const crossOrigin = bridge.accessor(Link.getCrossOrigin, Link.setCrossOrigin, .{});
    pub const relList = bridge.accessor(_getRelList, null, .{ .null_as_undefined = true });
    pub const sheet = bridge.accessor(Link.getSheet, null, .{ .null_as_undefined = true });

    fn _getRelList(self: *Link, frame: *Frame) !?*@import("../../collections.zig").DOMTokenList {
        const element = self.asElement();
        // relList is only valid for HTML <link> elements, not SVG or MathML
        if (element._namespace != .html) {
            return null;
        }
        return element.getRelList(frame);
    }
};

pub const Build = struct {
    pub fn attributeChange(element: *Element, name: String, _: String, frame: *Frame) !void {
        if (!name.eql(comptime .wrap("href")) and
            !name.eql(comptime .wrap("rel")) and
            !name.eql(comptime .wrap("type")))
        {
            return;
        }

        if (!element.asNode().isConnected()) {
            return;
        }

        const self = element.as(Link);
        const href = element.getAttributeSafe(comptime .wrap("href")) orelse "";
        if (href.len == 0) {
            self.removeSheet(frame);
            return;
        }
        if (!relHasToken(self.getRel(), "stylesheet")) {
            self.removeSheet(frame);
        }
        if (!self.isCssType()) {
            self.removeSheet(frame);
            return;
        }

        try self.linkAddedCallback(frame);
    }

    pub fn attributeRemove(element: *Element, name: String, frame: *Frame) !void {
        if (name.eql(comptime .wrap("type"))) {
            if (element.asNode().isConnected()) {
                try element.as(Link).linkAddedCallback(frame);
            }
            return;
        }

        if (!name.eql(comptime .wrap("href")) and !name.eql(comptime .wrap("rel"))) {
            return;
        }

        element.as(Link).removeSheet(frame);
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Link" {
    try testing.htmlRunner("element/html/link.html", .{});
}
