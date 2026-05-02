// Copyright (C) 2026  Lightpanda (Selecy SAS)
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

const Frame = @import("Frame.zig");
const CSS = @import("webapi/CSS.zig");
const CData = @import("webapi/CData.zig");
const Element = @import("webapi/Element.zig");
const HTMLDocument = @import("webapi/HTMLDocument.zig");
const Node = @import("webapi/Node.zig");
const Selector = @import("webapi/selector/Selector.zig");
const CssParser = @import("css/Parser.zig");
const CSSStyleRule = @import("webapi/css/CSSStyleRule.zig");
const color = @import("color.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    width: u32 = 1280,
    height: u32 = 720,
};

const Pass = enum { measure, paint };

const Rgba = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    const black: Rgba = .{ .r = 0, .g = 0, .b = 0 };
    const white: Rgba = .{ .r = 255, .g = 255, .b = 255 };
    const light_border: Rgba = .{ .r = 204, .g = 211, .b = 219 };
    const muted: Rgba = .{ .r = 96, .g = 106, .b = 118 };
    const surface: Rgba = .{ .r = 244, .g = 247, .b = 250 };

    fn fromCss(rgba: color.RGBA) Rgba {
        return .{ .r = rgba.r, .g = rgba.g, .b = rgba.b, .a = rgba.a };
    }
};

const Image = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    fn init(allocator: Allocator, width: u32, height: u32) !Image {
        if (width == 0 or height == 0) return error.InvalidArgument;
        const len = try std.math.mul(usize, @as(usize, width) * 3, @intCast(height));
        const pixels = try allocator.alloc(u8, len);
        @memset(pixels, 255);
        return .{ .width = width, .height = height, .pixels = pixels };
    }

    fn deinit(self: *Image, allocator: Allocator) void {
        allocator.free(self.pixels);
    }

    fn fill(self: *Image, c: Rgba) void {
        self.fillRect(0, 0, @intCast(self.width), @intCast(self.height), c);
    }

    fn fillRect(self: *Image, x_: i32, y_: i32, w_: i32, h_: i32, c: Rgba) void {
        if (w_ <= 0 or h_ <= 0) return;

        const x0 = @max(0, x_);
        const y0 = @max(0, y_);
        const x1 = @min(@as(i32, @intCast(self.width)), x_ + w_);
        const y1 = @min(@as(i32, @intCast(self.height)), y_ + h_);
        if (x1 <= x0 or y1 <= y0) return;

        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                self.setPixel(x, y, c);
            }
        }
    }

    fn strokeRect(self: *Image, x: i32, y: i32, w: i32, h: i32, c: Rgba) void {
        self.fillRect(x, y, w, 1, c);
        self.fillRect(x, y + h - 1, w, 1, c);
        self.fillRect(x, y, 1, h, c);
        self.fillRect(x + w - 1, y, 1, h, c);
    }

    fn setPixel(self: *Image, x: i32, y: i32, c: Rgba) void {
        if (x < 0 or y < 0) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= self.width or uy >= self.height) return;

        const i = (@as(usize, uy) * self.width + ux) * 3;
        if (c.a == 255) {
            self.pixels[i] = c.r;
            self.pixels[i + 1] = c.g;
            self.pixels[i + 2] = c.b;
            return;
        }

        const alpha: u16 = c.a;
        const inv: u16 = 255 - alpha;
        self.pixels[i] = @intCast((@as(u16, c.r) * alpha + @as(u16, self.pixels[i]) * inv) / 255);
        self.pixels[i + 1] = @intCast((@as(u16, c.g) * alpha + @as(u16, self.pixels[i + 1]) * inv) / 255);
        self.pixels[i + 2] = @intCast((@as(u16, c.b) * alpha + @as(u16, self.pixels[i + 2]) * inv) / 255);
    }
};

const ElementStyle = struct {
    margin: i32,
    padding: i32,
    width: i32,
    explicit_height: ?i32,
    color: Rgba,
    background: ?Rgba,
    font_scale: u8,
};

const Renderer = struct {
    allocator: Allocator,
    frame: *Frame,
    image: *Image,

    fn render(self: *Renderer) !void {
        self.image.fill(.white);

        const root = self.renderRoot() orelse return;
        if (self.resolveColor(root, "background-color") orelse self.resolveColor(root, "background")) |bg| {
            self.image.fill(bg);
        }

        const width: i32 = @intCast(self.image.width);
        _ = try self.layoutElement(.paint, root, 0, 0, width, .black, 0);
    }

    fn renderRoot(self: *Renderer) ?*Element {
        if (self.frame.document.is(HTMLDocument)) |html_doc| {
            if (html_doc.getBody()) |body| {
                return body.asElement();
            }
        }
        return self.frame.document.getDocumentElement();
    }

    fn layoutElement(
        self: *Renderer,
        pass: Pass,
        el: *Element,
        x: i32,
        y: i32,
        max_width_: i32,
        inherited_color: Rgba,
        depth: u16,
    ) !i32 {
        if (depth > 256 or !self.isRenderable(el)) return 0;

        const max_width = @max(1, max_width_);
        const style = try self.elementStyle(el, max_width, inherited_color);
        const outer_width = @max(1, @min(style.width, max_width - style.margin * 2));
        const inner_width = @max(1, outer_width - style.padding * 2);
        const outer_x = x + style.margin;
        const outer_y = y + style.margin;
        const inner_x = outer_x + style.padding;
        var cursor_y = outer_y + style.padding;

        const measured_total_for_paint = if (pass == .paint) blk: {
            const measured = try self.layoutElement(.measure, el, x, y, max_width_, inherited_color, depth);
            const measured_content_height = @max(0, measured - style.margin * 2);
            if (style.background) |bg| {
                self.image.fillRect(outer_x, outer_y, outer_width, measured_content_height, bg);
            }
            try self.paintIntrinsic(el, outer_x, outer_y, outer_width, measured_content_height, style);
            break :blk measured;
        } else null;

        var intrinsic_height = self.intrinsicHeight(el, style.font_scale);
        var child = el.asNode().firstChild();
        while (child) |node| {
            switch (node._type) {
                .cdata => |cd| {
                    if (cd.is(CData.Text)) |_| {
                        const h = self.layoutText(pass, cd.getData().str(), inner_x, cursor_y, inner_width, style.color, style.font_scale);
                        cursor_y += h;
                    }
                },
                .element => |child_el| {
                    const h = try self.layoutElement(pass, child_el, inner_x, cursor_y, inner_width, style.color, depth + 1);
                    cursor_y += h;
                },
                else => {},
            }
            child = node.nextSibling();
        }

        if (intrinsic_height == 0 and cursor_y == outer_y + style.padding) {
            intrinsic_height = self.emptyElementHeight(el, style.font_scale);
        }

        var content_height = cursor_y - outer_y + style.padding;
        content_height = @max(content_height, intrinsic_height);
        if (style.explicit_height) |h| {
            content_height = @max(content_height, h);
        }
        const total_height = content_height + style.margin * 2;

        if (pass == .paint) {
            return measured_total_for_paint.?;
        }

        return @max(0, total_height);
    }

    fn elementStyle(self: *Renderer, el: *Element, max_width: i32, inherited_color: Rgba) !ElementStyle {
        const tag = el.getTag();
        const margin = self.resolveLength(el, "margin") orelse defaultMargin(tag);
        const padding = self.resolveLength(el, "padding") orelse defaultPadding(tag);
        const explicit_width = self.resolveLength(el, "width") orelse self.attributeLength(el, "width");
        const explicit_height = self.resolveLength(el, "height") orelse self.attributeLength(el, "height");
        const width = explicit_width orelse defaultWidth(tag, max_width - margin * 2);
        const color_value = self.resolveColor(el, "color") orelse inherited_color;
        const font_scale = self.resolveFontScale(el) orelse defaultFontScale(tag);

        return .{
            .margin = margin,
            .padding = padding,
            .width = @max(1, width),
            .explicit_height = explicit_height,
            .color = color_value,
            .background = self.resolveColor(el, "background-color") orelse self.resolveColor(el, "background"),
            .font_scale = font_scale,
        };
    }

    fn isRenderable(self: *Renderer, el: *Element) bool {
        if (!el.checkVisibilityCached(null, self.frame)) return false;
        return switch (el.getTag()) {
            .base, .head, .link, .meta, .noscript, .param, .script, .source, .style, .template, .title, .track => false,
            else => true,
        };
    }

    fn intrinsicHeight(_: *Renderer, el: *Element, scale: u8) i32 {
        return switch (el.getTag()) {
            .br => lineHeight(scale),
            .hr => 2,
            .img, .iframe, .embed, .object, .video, .canvas, .svg => 120,
            .input, .select, .textarea, .button => 34,
            else => 0,
        };
    }

    fn emptyElementHeight(_: *Renderer, el: *Element, scale: u8) i32 {
        return switch (el.getTag()) {
            .h1, .h2, .h3, .h4, .h5, .h6, .p, .li => lineHeight(scale),
            else => 0,
        };
    }

    fn paintIntrinsic(self: *Renderer, el: *Element, x: i32, y: i32, w: i32, h: i32, style: ElementStyle) !void {
        switch (el.getTag()) {
            .hr => self.image.fillRect(x, y + @divTrunc(h, 2), w, 1, .light_border),
            .img, .iframe, .embed, .object, .video, .canvas, .svg => {
                self.image.fillRect(x, y, w, h, .surface);
                self.image.strokeRect(x, y, w, h, .light_border);
                const label = switch (el.getTag()) {
                    .img => el.getAttributeSafe(comptime .wrap("alt")) orelse "image",
                    .iframe => "iframe",
                    .video => "video",
                    .canvas => "canvas",
                    .svg => "svg",
                    else => "media",
                };
                _ = self.layoutText(.paint, label, x + 8, y + 8, @max(1, w - 16), .muted, 1);
            },
            .input, .select, .textarea, .button => {
                self.image.fillRect(x, y, w, h, .{ .r = 250, .g = 252, .b = 255 });
                self.image.strokeRect(x, y, w, h, .light_border);
                if (el.getAttributeSafe(comptime .wrap("value")) orelse el.getAttributeSafe(comptime .wrap("placeholder"))) |label| {
                    _ = self.layoutText(.paint, label, x + 8, y + 10, @max(1, w - 16), style.color, 1);
                } else {
                    const text = el.asNode().getTextContentAlloc(self.allocator) catch null;
                    defer if (text) |t| self.allocator.free(t);
                    _ = self.layoutText(.paint, text orelse "", x + 8, y + 10, @max(1, w - 16), style.color, 1);
                }
            },
            else => {},
        }
    }

    fn layoutText(self: *Renderer, pass: Pass, text: []const u8, x: i32, y: i32, max_width: i32, c: Rgba, scale: u8) i32 {
        if (text.len == 0 or max_width <= 0) return 0;

        const glyph_advance: i32 = @as(i32, scale) * 6;
        const glyph_width: i32 = @as(i32, scale) * 5;
        const lh = lineHeight(scale);
        var cursor_x = x;
        var cursor_y = y;
        var drew = false;
        var last_space = true;

        for (text) |raw| {
            const is_space = std.ascii.isWhitespace(raw);
            if (is_space) {
                if (!last_space) {
                    if (cursor_x + glyph_advance > x + max_width) {
                        cursor_x = x;
                        cursor_y += lh;
                    } else {
                        cursor_x += glyph_advance;
                    }
                }
                last_space = true;
                continue;
            }
            last_space = false;

            if (cursor_x + glyph_width > x + max_width) {
                cursor_x = x;
                cursor_y += lh;
            }

            if (pass == .paint) {
                self.drawGlyph(cursor_x, cursor_y, raw, c, scale);
            }
            cursor_x += glyph_advance;
            drew = true;
        }

        return if (drew) cursor_y - y + lh else 0;
    }

    fn drawGlyph(self: *Renderer, x: i32, y: i32, raw: u8, c: Rgba, scale: u8) void {
        const rows = glyph(raw);
        for (rows, 0..) |bits, row| {
            var col: usize = 0;
            while (col < 5) : (col += 1) {
                const shift: u3 = @intCast(4 - col);
                if ((bits & (@as(u8, 1) << shift)) == 0) continue;
                self.image.fillRect(
                    x + @as(i32, @intCast(col)) * @as(i32, scale),
                    y + @as(i32, @intCast(row)) * @as(i32, scale),
                    @intCast(scale),
                    @intCast(scale),
                    c,
                );
            }
        }
    }

    fn resolveLength(self: *Renderer, el: *Element, comptime property: []const u8) ?i32 {
        const value = self.propertyValue(el, property) orelse return null;
        return parseLength(value);
    }

    fn resolveFontScale(self: *Renderer, el: *Element) ?u8 {
        const value = self.propertyValue(el, "font-size") orelse return null;
        const px = parseLength(value) orelse return null;
        if (px >= 30) return 3;
        if (px >= 18) return 2;
        return 1;
    }

    fn resolveColor(self: *Renderer, el: *Element, comptime property: []const u8) ?Rgba {
        const value = self.propertyValue(el, property) orelse return null;
        return parseCssColor(value);
    }

    fn propertyValue(self: *Renderer, el: *Element, comptime property: []const u8) ?[]const u8 {
        var value = self.stylesheetProperty(el, property);

        const style = el.getOrCreateStyle(self.frame) catch return value;
        const inline_value = style.asCSSStyleDeclaration().getPropertyValue(property, self.frame);
        if (inline_value.len > 0) {
            value = inline_value;
        }
        return value;
    }

    fn stylesheetProperty(self: *Renderer, el: *Element, comptime property: []const u8) ?[]const u8 {
        const sheets = self.frame.document._style_sheets orelse return null;
        var value: ?[]const u8 = null;

        for (sheets._sheets.items) |sheet| {
            if (sheet._css_rules) |rules| {
                for (rules._rules.items) |rule| {
                    const style_rule = rule.is(CSSStyleRule) orelse continue;
                    if (!(Selector.matches(el, style_rule.getSelectorText(), self.frame) catch false)) continue;
                    const style = style_rule._style orelse continue;
                    const next = style.asCSSStyleDeclaration().getPropertyValue(property, self.frame);
                    if (next.len > 0) value = next;
                }
                continue;
            }

            const owner = sheet.getOwnerNode() orelse continue;
            if (owner.is(Element.Html.Style) == null) continue;
            const text = owner.asNode().getTextContentAlloc(self.allocator) catch continue;
            defer self.allocator.free(text);

            var rule_it = CssParser.parseStylesheet(text);
            while (rule_it.next()) |rule| {
                if (!(Selector.matches(el, rule.selector, self.frame) catch false)) continue;
                var decl_it = CssParser.parseDeclarationsList(rule.block);
                while (decl_it.next()) |decl| {
                    if (std.ascii.eqlIgnoreCase(decl.name, property)) {
                        value = decl.value;
                    }
                }
            }
        }
        return value;
    }

    fn attributeLength(_: *Renderer, el: *Element, comptime attr: []const u8) ?i32 {
        const value = if (std.mem.eql(u8, attr, "width"))
            el.getAttributeSafe(comptime .wrap("width"))
        else
            el.getAttributeSafe(comptime .wrap("height"));
        return parseLength(value orelse return null);
    }
};

pub fn writePngFile(allocator: Allocator, frame: *Frame, path: []const u8, opts: Options) !void {
    var image = try Image.init(allocator, opts.width, opts.height);
    defer image.deinit(allocator);

    var renderer = Renderer{
        .allocator = allocator,
        .frame = frame,
        .image = &image,
    };
    try renderer.render();

    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    var file_buf: [16 * 1024]u8 = undefined;
    var writer = file.writer(&file_buf);
    try writePng(allocator, &image, &writer.interface);
    try writer.interface.flush();
}

fn defaultMargin(tag: Element.Tag) i32 {
    return switch (tag) {
        .body => 8,
        .h1, .h2, .h3, .h4, .h5, .h6 => 12,
        .p, .blockquote, .ul, .ol, .li, .section, .article, .header, .footer, .main, .nav => 8,
        else => 0,
    };
}

fn defaultPadding(tag: Element.Tag) i32 {
    return switch (tag) {
        .button, .input, .select, .textarea => 6,
        .fieldset => 8,
        else => 0,
    };
}

fn defaultWidth(tag: Element.Tag, max_width: i32) i32 {
    return switch (tag) {
        .img, .iframe, .embed, .object, .video, .canvas, .svg => @min(max_width, 320),
        .input, .select, .textarea => @min(max_width, 240),
        .button => @min(max_width, 180),
        else => max_width,
    };
}

fn defaultFontScale(tag: Element.Tag) u8 {
    return switch (tag) {
        .h1 => 3,
        .h2, .h3 => 2,
        else => 1,
    };
}

fn lineHeight(scale: u8) i32 {
    return @as(i32, scale) * 9 + 4;
}

fn parseLength(value_: []const u8) ?i32 {
    const value = std.mem.trim(u8, value_, " \t\r\n;");
    if (value.len == 0) return null;

    var end: usize = 0;
    while (end < value.len) : (end += 1) {
        const c = value[end];
        if (!(std.ascii.isDigit(c) or c == '.' or c == '-')) break;
    }
    if (end == 0) return null;

    const n = CSS.parseDimension(value[0..end]) orelse return null;
    if (n <= 0) return null;
    return @intFromFloat(@min(n, 100_000));
}

fn parseCssColor(value_: []const u8) ?Rgba {
    const value = std.mem.trim(u8, value_, " \t\r\n;");
    if (value.len == 0) return null;

    if (std.ascii.eqlIgnoreCase(value, "transparent")) {
        return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    }
    if (color.RGBA.parse(value)) |rgba| {
        return Rgba.fromCss(rgba);
    } else |_| {}

    if (parseRgbFunction(value)) |rgba| return rgba;
    if (std.mem.indexOf(u8, value, "rgb(")) |start| {
        if (std.mem.indexOfScalarPos(u8, value, start, ')')) |end| {
            if (parseRgbFunction(value[start .. end + 1])) |rgba| return rgba;
        }
    }

    var it = std.mem.tokenizeAny(u8, value, " \t\r\n,");
    while (it.next()) |token| {
        if (color.RGBA.parse(token)) |rgba| {
            return Rgba.fromCss(rgba);
        } else |_| {}
    }
    return null;
}

fn parseRgbFunction(value_: []const u8) ?Rgba {
    const value = std.mem.trim(u8, value_, " \t\r\n;");
    const open = std.mem.indexOfScalar(u8, value, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, value, ')') orelse return null;
    if (close <= open) return null;

    const name = value[0..open];
    if (!std.ascii.eqlIgnoreCase(name, "rgb") and !std.ascii.eqlIgnoreCase(name, "rgba")) {
        return null;
    }

    const inner = value[open + 1 .. close];
    var parts: [4]f64 = .{ 0, 0, 0, 1 };
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, inner, ", /");
    while (it.next()) |part| {
        if (count >= parts.len) break;
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) continue;
        parts[count] = std.fmt.parseFloat(f64, trimmed) catch return null;
        count += 1;
    }
    if (count < 3) return null;

    return .{
        .r = @intFromFloat(std.math.clamp(parts[0], 0, 255)),
        .g = @intFromFloat(std.math.clamp(parts[1], 0, 255)),
        .b = @intFromFloat(std.math.clamp(parts[2], 0, 255)),
        .a = @intFromFloat(std.math.clamp(if (count >= 4) parts[3] else 1, 0, 1) * 255),
    };
}

fn writePng(allocator: Allocator, image: *const Image, writer: *std.Io.Writer) !void {
    const raw_len = @as(usize, image.height) * (@as(usize, image.width) * 3 + 1);
    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);

    var raw_pos: usize = 0;
    var src_pos: usize = 0;
    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        raw[raw_pos] = 0;
        raw_pos += 1;
        const row_len = @as(usize, image.width) * 3;
        @memcpy(raw[raw_pos .. raw_pos + row_len], image.pixels[src_pos .. src_pos + row_len]);
        raw_pos += row_len;
        src_pos += row_len;
    }

    const zlib = try zlibStore(allocator, raw);
    defer allocator.free(zlib);

    try writer.writeAll("\x89PNG\r\n\x1a\n");

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], image.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], image.height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // truecolor
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter
    ihdr[12] = 0; // interlace

    try writeChunk(writer, "IHDR", &ihdr);
    try writeChunk(writer, "IDAT", zlib);
    try writeChunk(writer, "IEND", "");
}

fn writeChunk(writer: *std.Io.Writer, comptime chunk_type: []const u8, data: []const u8) !void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    try writer.writeAll(&len_buf);
    try writer.writeAll(chunk_type);
    try writer.writeAll(data);

    var crc = std.hash.Crc32.init();
    crc.update(chunk_type);
    crc.update(data);

    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, crc.final(), .big);
    try writer.writeAll(&crc_buf);
}

fn zlibStore(allocator: Allocator, raw: []const u8) ![]u8 {
    const blocks = (raw.len + 65_534) / 65_535;
    const len = 2 + blocks * 5 + raw.len + 4;
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);

    out[0] = 0x78;
    out[1] = 0x01;

    var pos: usize = 2;
    var offset: usize = 0;
    while (offset < raw.len) {
        const remaining = raw.len - offset;
        const block_len: u16 = @intCast(@min(remaining, 65_535));
        const blen: usize = block_len;
        const final = offset + blen == raw.len;
        out[pos] = if (final) 1 else 0;
        pos += 1;
        std.mem.writeInt(u16, out[pos..][0..2], block_len, .little);
        pos += 2;
        std.mem.writeInt(u16, out[pos..][0..2], ~block_len, .little);
        pos += 2;
        @memcpy(out[pos .. pos + blen], raw[offset .. offset + blen]);
        pos += blen;
        offset += blen;
    }

    std.mem.writeInt(u32, out[pos..][0..4], adler32(raw), .big);
    pos += 4;
    return out[0..pos];
}

fn adler32(data: []const u8) u32 {
    const mod = 65521;
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |byte| {
        a = (a + byte) % mod;
        b = (b + a) % mod;
    }
    return (b << 16) | a;
}

fn glyph(raw: u8) [7]u8 {
    const c = std.ascii.toUpper(raw);
    return switch (c) {
        'A' => .{ 0x0e, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11 },
        'B' => .{ 0x1e, 0x11, 0x11, 0x1e, 0x11, 0x11, 0x1e },
        'C' => .{ 0x0e, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0e },
        'D' => .{ 0x1e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1e },
        'E' => .{ 0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x1f },
        'F' => .{ 0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x10 },
        'G' => .{ 0x0e, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0f },
        'H' => .{ 0x11, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11 },
        'I' => .{ 0x0e, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0e },
        'J' => .{ 0x07, 0x02, 0x02, 0x02, 0x12, 0x12, 0x0c },
        'K' => .{ 0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11 },
        'L' => .{ 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1f },
        'M' => .{ 0x11, 0x1b, 0x15, 0x15, 0x11, 0x11, 0x11 },
        'N' => .{ 0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11 },
        'O' => .{ 0x0e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e },
        'P' => .{ 0x1e, 0x11, 0x11, 0x1e, 0x10, 0x10, 0x10 },
        'Q' => .{ 0x0e, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0d },
        'R' => .{ 0x1e, 0x11, 0x11, 0x1e, 0x14, 0x12, 0x11 },
        'S' => .{ 0x0f, 0x10, 0x10, 0x0e, 0x01, 0x01, 0x1e },
        'T' => .{ 0x1f, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04 },
        'U' => .{ 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e },
        'V' => .{ 0x11, 0x11, 0x11, 0x11, 0x11, 0x0a, 0x04 },
        'W' => .{ 0x11, 0x11, 0x11, 0x15, 0x15, 0x1b, 0x11 },
        'X' => .{ 0x11, 0x11, 0x0a, 0x04, 0x0a, 0x11, 0x11 },
        'Y' => .{ 0x11, 0x11, 0x0a, 0x04, 0x04, 0x04, 0x04 },
        'Z' => .{ 0x1f, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1f },
        '0' => .{ 0x0e, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0e },
        '1' => .{ 0x04, 0x0c, 0x04, 0x04, 0x04, 0x04, 0x0e },
        '2' => .{ 0x0e, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1f },
        '3' => .{ 0x1e, 0x01, 0x01, 0x0e, 0x01, 0x01, 0x1e },
        '4' => .{ 0x02, 0x06, 0x0a, 0x12, 0x1f, 0x02, 0x02 },
        '5' => .{ 0x1f, 0x10, 0x10, 0x1e, 0x01, 0x01, 0x1e },
        '6' => .{ 0x0e, 0x10, 0x10, 0x1e, 0x11, 0x11, 0x0e },
        '7' => .{ 0x1f, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08 },
        '8' => .{ 0x0e, 0x11, 0x11, 0x0e, 0x11, 0x11, 0x0e },
        '9' => .{ 0x0e, 0x11, 0x11, 0x0f, 0x01, 0x01, 0x0e },
        '.' => .{ 0, 0, 0, 0, 0, 0x0c, 0x0c },
        ',' => .{ 0, 0, 0, 0, 0, 0x0c, 0x08 },
        ':' => .{ 0, 0x0c, 0x0c, 0, 0x0c, 0x0c, 0 },
        ';' => .{ 0, 0x0c, 0x0c, 0, 0x0c, 0x08, 0x10 },
        '!' => .{ 0x04, 0x04, 0x04, 0x04, 0x04, 0, 0x04 },
        '?' => .{ 0x0e, 0x11, 0x01, 0x02, 0x04, 0, 0x04 },
        '-' => .{ 0, 0, 0, 0x1f, 0, 0, 0 },
        '_' => .{ 0, 0, 0, 0, 0, 0, 0x1f },
        '/' => .{ 0x01, 0x01, 0x02, 0x04, 0x08, 0x10, 0x10 },
        '\\' => .{ 0x10, 0x10, 0x08, 0x04, 0x02, 0x01, 0x01 },
        '(' => .{ 0x02, 0x04, 0x08, 0x08, 0x08, 0x04, 0x02 },
        ')' => .{ 0x08, 0x04, 0x02, 0x02, 0x02, 0x04, 0x08 },
        '[' => .{ 0x0e, 0x08, 0x08, 0x08, 0x08, 0x08, 0x0e },
        ']' => .{ 0x0e, 0x02, 0x02, 0x02, 0x02, 0x02, 0x0e },
        '+' => .{ 0, 0x04, 0x04, 0x1f, 0x04, 0x04, 0 },
        '=' => .{ 0, 0, 0x1f, 0, 0x1f, 0, 0 },
        '*' => .{ 0, 0x15, 0x0e, 0x1f, 0x0e, 0x15, 0 },
        '#' => .{ 0x0a, 0x0a, 0x1f, 0x0a, 0x1f, 0x0a, 0x0a },
        '@' => .{ 0x0e, 0x11, 0x17, 0x15, 0x17, 0x10, 0x0e },
        '&' => .{ 0x0c, 0x12, 0x14, 0x08, 0x15, 0x12, 0x0d },
        '\'' => .{ 0x04, 0x04, 0x08, 0, 0, 0, 0 },
        '"' => .{ 0x0a, 0x0a, 0, 0, 0, 0, 0 },
        '<' => .{ 0x02, 0x04, 0x08, 0x10, 0x08, 0x04, 0x02 },
        '>' => .{ 0x08, 0x04, 0x02, 0x01, 0x02, 0x04, 0x08 },
        else => .{ 0x1f, 0x11, 0x02, 0x04, 0x04, 0, 0x04 },
    };
}

test "render: zlib adler32" {
    try std.testing.expectEqual(@as(u32, 0x062c0215), adler32("hello"));
}
