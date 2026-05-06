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

const Display = enum { block, flex, grid, none };
const AlignItems = enum { start, center, end };
const JustifyContent = enum { start, center, end };

const Edges = struct {
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
    left: i32 = 0,

    fn all(value: i32) Edges {
        return .{ .top = value, .right = value, .bottom = value, .left = value };
    }

    fn horizontal(self: Edges) i32 {
        return self.left + self.right;
    }

    fn vertical(self: Edges) i32 {
        return self.top + self.bottom;
    }
};

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
    margin: Edges,
    padding: Edges,
    width: i32,
    explicit_height: ?i32,
    min_height: i32,
    color: Rgba,
    background: ?Rgba,
    font_scale: u8,
    display: Display,
    flex_column: bool,
    align_items: AlignItems,
    justify_content: JustifyContent,
    nowrap: bool,
    center_auto: bool,
    gap: i32,
};

const RawDeclaration = struct {
    sheet_index: usize,
    selector: []const u8,
    name: []const u8,
    value: []const u8,
};

const Renderer = struct {
    allocator: Allocator,
    css_allocator: Allocator,
    frame: *Frame,
    image: *Image,
    raw_style_texts: []?[]const u8 = &.{},
    raw_declarations: []RawDeclaration = &.{},

    fn render(self: *Renderer) !void {
        try self.loadRawStylesheetTexts();
        self.image.fill(.white);

        const root = self.renderRoot() orelse return;
        if (self.resolveColor(root, "background-color") orelse self.resolveColor(root, "background")) |bg| {
            self.image.fill(bg);
        }

        const width: i32 = @intCast(self.image.width);
        _ = try self.layoutElement(.paint, root, 0, 0, width, .black, 2, 0);
    }

    fn renderRoot(self: *Renderer) ?*Element {
        if (self.frame.document.is(HTMLDocument)) |html_doc| {
            if (html_doc.getBody()) |body| {
                return body.asElement();
            }
        }
        return self.frame.document.getDocumentElement();
    }

    fn loadRawStylesheetTexts(self: *Renderer) !void {
        const sheets = self.frame.document._style_sheets orelse return;
        if (self.raw_style_texts.len == sheets._sheets.items.len) return;

        self.raw_style_texts = try self.css_allocator.alloc(?[]const u8, sheets._sheets.items.len);
        @memset(self.raw_style_texts, null);

        var declarations: std.ArrayList(RawDeclaration) = .empty;
        for (sheets._sheets.items, 0..) |sheet, i| {
            if (sheet._css_rules != null) continue;
            const owner = sheet.getOwnerNode() orelse continue;
            if (owner.is(Element.Html.Style) == null) continue;
            const text = owner.asNode().getTextContentAlloc(self.css_allocator) catch continue;
            self.raw_style_texts[i] = text;

            var rule_it = CssParser.parseStylesheet(text);
            while (rule_it.next()) |rule| {
                var decl_it = CssParser.parseDeclarationsList(rule.block);
                while (decl_it.next()) |decl| {
                    try declarations.append(self.css_allocator, .{
                        .sheet_index = i,
                        .selector = rule.selector,
                        .name = decl.name,
                        .value = decl.value,
                    });
                }
            }
        }
        self.raw_declarations = try declarations.toOwnedSlice(self.css_allocator);
    }

    fn layoutElement(
        self: *Renderer,
        pass: Pass,
        el: *Element,
        x: i32,
        y: i32,
        max_width_: i32,
        inherited_color: Rgba,
        inherited_font_scale: u8,
        depth: u16,
    ) !i32 {
        if (depth > 256 or !self.isRenderable(el)) return 0;

        const max_width = @max(1, max_width_);
        const style = try self.elementStyle(el, max_width, inherited_color, inherited_font_scale);
        if (style.display == .none) return 0;

        const outer_width = @max(1, @min(style.width, max_width - style.margin.horizontal()));
        const inner_width = @max(1, outer_width - style.padding.horizontal());
        const extra_width = max_width - outer_width - style.margin.horizontal();
        const auto_x = if (style.center_auto and extra_width > 0) @divTrunc(extra_width, 2) else 0;
        const outer_x = x + style.margin.left + auto_x;
        const outer_y = y + style.margin.top;
        const inner_x = outer_x + style.padding.left;
        var cursor_y = outer_y + style.padding.top;

        const measured_total_for_paint = if (pass == .paint) blk: {
            const measured = try self.layoutElement(.measure, el, x, y, max_width_, inherited_color, inherited_font_scale, depth);
            const measured_content_height = @max(0, measured - style.margin.vertical());
            if (style.background) |bg| {
                self.image.fillRect(outer_x, outer_y, outer_width, measured_content_height, bg);
            }
            try self.paintIntrinsic(el, outer_x, outer_y, outer_width, measured_content_height, style);
            break :blk measured;
        } else null;

        var intrinsic_height = if (style.explicit_height == null) self.intrinsicHeight(el, style.font_scale) else 0;
        const row_children = self.rowChildCount(el, style);
        if (row_children > 1) {
            const gap_total = style.gap * @as(i32, @intCast(row_children - 1));
            var child_widths: [64]i32 = undefined;
            var child_width_count: usize = 0;
            if (style.display == .flex) {
                var width_child = el.asNode().firstChild();
                while (width_child) |node| {
                    switch (node._type) {
                        .cdata => |cd| {
                            if (cd.is(CData.Text)) |_| {
                                const text = cd.getData().str();
                                if (isRenderableText(text) and child_width_count < child_widths.len) {
                                    child_widths[child_width_count] = @max(1, textInlineWidth(text, style.font_scale));
                                    child_width_count += 1;
                                }
                            }
                        },
                        .element => |child_el| {
                            if (self.isRenderable(child_el) and child_width_count < child_widths.len) {
                                child_widths[child_width_count] = try self.preferredChildWidth(child_el, @max(1, inner_width - gap_total), style.color, style.font_scale);
                                child_width_count += 1;
                            }
                        },
                        else => {},
                    }
                    width_child = node.nextSibling();
                }
            } else if (style.display == .grid) {
                child_width_count = try self.gridChildWidths(el, inner_width, gap_total, row_children, style, &child_widths);
            }

            const grid_child_width = @max(1, @divTrunc(@max(1, inner_width - gap_total), @as(i32, @intCast(row_children))));
            const used_width = childWidthsTotal(child_widths[0..child_width_count], style.gap);
            const free_width = @max(0, inner_width - used_width);
            var cursor_x = inner_x + switch (style.justify_content) {
                .start => 0,
                .center => @divTrunc(free_width, 2),
                .end => free_width,
            };
            var max_child_height: i32 = 0;
            var row_target_height: i32 = 0;
            var child_index: usize = 0;

            var child = el.asNode().firstChild();
            while (child) |node| {
                switch (node._type) {
                    .cdata => |cd| {
                        if (style.display == .flex and cd.is(CData.Text) != null) {
                            const text = cd.getData().str();
                            if (isRenderableText(text)) {
                                const child_width = if (child_index < child_width_count)
                                    @min(child_widths[child_index], @max(1, inner_x + inner_width - cursor_x))
                                else
                                    textInlineWidth(text, style.font_scale);
                                const measured_child_height = lineHeight(style.font_scale);
                                max_child_height = @max(max_child_height, measured_child_height);
                                const min_content_height = @max(style.explicit_height orelse 0, style.min_height) - style.padding.vertical();
                                row_target_height = @max(max_child_height, min_content_height);
                                const child_y = cursor_y + switch (style.align_items) {
                                    .start => 0,
                                    .center => @divTrunc(@max(0, row_target_height - measured_child_height), 2),
                                    .end => @max(0, row_target_height - measured_child_height),
                                };
                                _ = self.layoutText(pass, text, cursor_x, child_y, child_width, style.color, style.font_scale, style.nowrap);
                                cursor_x += child_width + style.gap;
                                child_index += 1;
                            }
                        }
                    },
                    .element => |child_el| {
                        if (self.isRenderable(child_el)) {
                            const child_width = if (child_index < child_width_count)
                                @min(child_widths[child_index], @max(1, inner_x + inner_width - cursor_x))
                            else
                                grid_child_width;
                            const measured_child_height = try self.layoutElement(.measure, child_el, cursor_x, cursor_y, child_width, style.color, style.font_scale, depth + 1);
                            max_child_height = @max(max_child_height, measured_child_height);
                            const min_content_height = @max(style.explicit_height orelse 0, style.min_height) - style.padding.vertical();
                            row_target_height = @max(max_child_height, min_content_height);
                            const child_y = cursor_y + switch (style.align_items) {
                                .start => 0,
                                .center => @divTrunc(@max(0, row_target_height - measured_child_height), 2),
                                .end => @max(0, row_target_height - measured_child_height),
                            };
                            const h = try self.layoutElement(pass, child_el, cursor_x, child_y, child_width, style.color, style.font_scale, depth + 1);
                            max_child_height = @max(max_child_height, h);
                            cursor_x += child_width + style.gap;
                            child_index += 1;
                        }
                    },
                    else => {},
                }
                child = node.nextSibling();
            }
            cursor_y += @max(max_child_height, row_target_height);
        } else {
            var child = el.asNode().firstChild();
            while (child) |node| {
                switch (node._type) {
                    .cdata => |cd| {
                        if (cd.is(CData.Text)) |_| {
                            const h = self.layoutText(pass, cd.getData().str(), inner_x, cursor_y, inner_width, style.color, style.font_scale, style.nowrap);
                            cursor_y += h;
                        }
                    },
                    .element => |child_el| {
                        const h = try self.layoutElement(pass, child_el, inner_x, cursor_y, inner_width, style.color, style.font_scale, depth + 1);
                        cursor_y += h;
                    },
                    else => {},
                }
                child = node.nextSibling();
            }
        }

        if (intrinsic_height == 0 and cursor_y == outer_y + style.padding.top) {
            intrinsic_height = self.emptyElementHeight(el, style.font_scale);
        }

        var content_height = cursor_y - outer_y + style.padding.bottom;
        content_height = if (style.explicit_height) |h| @max(content_height, h) else @max(content_height, intrinsic_height);
        content_height = @max(content_height, style.min_height);
        const total_height = content_height + style.margin.vertical();

        if (pass == .paint) {
            return measured_total_for_paint.?;
        }

        return @max(0, total_height);
    }

    fn elementStyle(self: *Renderer, el: *Element, max_width: i32, inherited_color: Rgba, inherited_font_scale: u8) !ElementStyle {
        const tag = el.getTag();
        const base_font_scale = defaultFontScale(tag) orelse inherited_font_scale;
        const font_scale = self.resolveFontScale(el, base_font_scale) orelse base_font_scale;
        const margin = self.resolveEdges(el, "margin", defaultMargin(tag), max_width, font_scale);
        const padding = self.resolveEdges(el, "padding", defaultPadding(tag), max_width, font_scale);
        const available_width = @max(1, max_width - margin.horizontal());
        const explicit_width = self.resolveLength(el, "width", available_width, font_scale) orelse self.attributeLength(el, "width", available_width);
        const explicit_height = self.resolveLength(el, "height", available_width, font_scale) orelse self.attributeLength(el, "height", available_width);
        const min_height = self.resolveLength(el, "min-height", available_width, font_scale) orelse 0;
        const width = explicit_width orelse defaultWidth(tag, available_width);
        const color_value = self.resolveColor(el, "color") orelse inherited_color;

        return .{
            .margin = margin,
            .padding = padding,
            .width = @max(1, width),
            .explicit_height = explicit_height,
            .min_height = min_height,
            .color = color_value,
            .background = self.resolveColor(el, "background-color") orelse self.resolveColor(el, "background"),
            .font_scale = font_scale,
            .display = self.resolveDisplay(el),
            .flex_column = self.hasCssValue(el, "flex-direction", "column"),
            .align_items = self.resolveAlignItems(el),
            .justify_content = self.resolveJustifyContent(el),
            .nowrap = self.hasCssValue(el, "white-space", "nowrap"),
            .center_auto = self.hasAutoHorizontalMargin(el),
            .gap = self.resolveLength(el, "gap", available_width, font_scale) orelse 0,
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
            .img, .iframe, .embed, .object, .video, .canvas => 120,
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
            .img, .iframe, .embed, .object, .video, .canvas => {
                if (el.getTag() == .img and w <= 48 and h <= 48) {
                    self.paintSmallImagePlaceholder(el, x, y, w, h);
                    return;
                }
                self.image.fillRect(x, y, w, h, .surface);
                self.image.strokeRect(x, y, w, h, .light_border);
                const label = switch (el.getTag()) {
                    .img => el.getAttributeSafe(comptime .wrap("alt")) orelse "image",
                    .iframe => "iframe",
                    .video => "video",
                    .canvas => "canvas",
                    else => "media",
                };
                _ = self.layoutText(.paint, label, x + 8, y + 8, @max(1, w - 16), .muted, 1, false);
            },
            .input, .select, .textarea, .button => {
                self.image.fillRect(x, y, w, h, .{ .r = 250, .g = 252, .b = 255 });
                self.image.strokeRect(x, y, w, h, .light_border);
                if (el.getAttributeSafe(comptime .wrap("value")) orelse el.getAttributeSafe(comptime .wrap("placeholder"))) |label| {
                    _ = self.layoutText(.paint, label, x + 8, y + 10, @max(1, w - 16), style.color, 1, false);
                } else {
                    const text = el.asNode().getTextContentAlloc(self.css_allocator) catch null;
                    _ = self.layoutText(.paint, text orelse "", x + 8, y + 10, @max(1, w - 16), style.color, 1, false);
                }
            },
            else => {},
        }
    }

    fn layoutText(self: *Renderer, pass: Pass, text: []const u8, x: i32, y: i32, max_width: i32, c: Rgba, scale: u8, nowrap: bool) i32 {
        if (text.len == 0 or max_width <= 0) return 0;

        const glyph_advance = glyphAdvance(scale);
        const glyph_width: i32 = @as(i32, scale) * 5;
        const lh = lineHeight(scale);
        var cursor_x = x;
        var cursor_y = y;
        var drew = false;

        var word_it = std.mem.tokenizeAny(u8, text, " \t\r\n");
        while (word_it.next()) |word| {
            const word_width = @as(i32, @intCast(word.len)) * glyph_advance;
            const needs_space = cursor_x > x;
            const space_width = if (needs_space) glyph_advance else 0;
            if (!nowrap and needs_space and cursor_x + space_width + word_width > x + max_width) {
                cursor_x = x;
                cursor_y += lh;
            } else if (needs_space) {
                cursor_x += glyph_advance;
            }

            for (word) |raw| {
                if (nowrap and cursor_x + glyph_width > x + max_width) break;
                if (!nowrap and cursor_x + glyph_width > x + max_width) {
                    cursor_x = x;
                    cursor_y += lh;
                }
                if (pass == .paint) {
                    self.drawGlyph(cursor_x, cursor_y, raw, c, scale);
                }
                cursor_x += glyph_advance;
                drew = true;
            }
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

    fn rowChildCount(self: *Renderer, el: *Element, style: ElementStyle) usize {
        switch (style.display) {
            .flex => {
                if (style.flex_column) return 0;
            },
            .grid => {
                const columns = self.propertyValue(el, "grid-template-columns") orelse return 0;
                if (!looksMultiColumnGrid(columns)) return 0;
            },
            else => return 0,
        }

        var count: usize = 0;
        var child = el.asNode().firstChild();
        while (child) |node| {
            switch (node._type) {
                .cdata => |cd| {
                    if (style.display == .flex and cd.is(CData.Text) != null and isRenderableText(cd.getData().str())) {
                        count += 1;
                    }
                },
                .element => |child_el| {
                    if (self.isRenderable(child_el)) count += 1;
                },
                else => {},
            }
            child = node.nextSibling();
        }
        return count;
    }

    fn preferredChildWidth(self: *Renderer, el: *Element, max_width: i32, inherited_color: Rgba, inherited_font_scale: u8) !i32 {
        const tag = el.getTag();
        const base_font_scale = defaultFontScale(tag) orelse inherited_font_scale;
        const font_scale = self.resolveFontScale(el, base_font_scale) orelse base_font_scale;
        const explicit_width = self.resolveLength(el, "width", max_width, font_scale) orelse self.attributeLength(el, "width", max_width);
        if (explicit_width) |w| return @max(1, @min(max_width, w));

        const child_style = try self.elementStyle(el, max_width, inherited_color, inherited_font_scale);
        if (child_style.display == .flex and !child_style.flex_column) {
            var total: i32 = 0;
            var count: usize = 0;
            var child = el.asNode().firstChild();
            while (child) |node| {
                switch (node._type) {
                    .cdata => |cd| {
                        if (cd.is(CData.Text) != null) {
                            const text = cd.getData().str();
                            if (isRenderableText(text)) {
                                total += textInlineWidth(text, child_style.font_scale);
                                count += 1;
                            }
                        }
                    },
                    .element => |child_el| {
                        if (self.isRenderable(child_el)) {
                            total += try self.preferredChildWidth(child_el, max_width, child_style.color, child_style.font_scale);
                            count += 1;
                        }
                    },
                    else => {},
                }
                child = node.nextSibling();
            }
            if (count > 0) {
                total += child_style.gap * @as(i32, @intCast(count - 1));
                total += child_style.padding.horizontal();
                return @max(1, @min(max_width, total));
            }
        }
        const text = el.asNode().getTextContentAlloc(self.css_allocator) catch "";
        const text_width = textInlineWidth(text, child_style.font_scale) + child_style.padding.horizontal();
        if (text_width > child_style.padding.horizontal()) {
            return @max(1, @min(max_width, text_width));
        }
        return @max(1, @min(max_width, child_style.width));
    }

    fn gridChildWidths(
        self: *Renderer,
        el: *Element,
        inner_width: i32,
        gap_total: i32,
        child_count: usize,
        style: ElementStyle,
        out: *[64]i32,
    ) !usize {
        const columns = self.propertyValue(el, "grid-template-columns") orelse return 0;
        const available = @max(1, inner_width - gap_total);
        if (std.ascii.indexOfIgnoreCase(columns, "repeat(") != null) {
            const each = @max(1, @divTrunc(available, @as(i32, @intCast(child_count))));
            for (0..@min(child_count, out.len)) |i| out[i] = each;
            return @min(child_count, out.len);
        }

        var parts: [64][]const u8 = undefined;
        const track_count = @min(splitCssComponents(stripImportant(columns), &parts), child_count);
        if (track_count == 0) return 0;

        var mins: [64]i32 = .{0} ** 64;
        var frs: [64]f64 = .{0} ** 64;
        var fixed_sum: i32 = 0;
        var fr_sum: f64 = 0;

        var i: usize = 0;
        while (i < track_count) : (i += 1) {
            const parsed = self.parseGridTrack(parts[i], available, style.font_scale);
            mins[i] = if (parsed.auto_width) blk: {
                const child = self.nthRenderableChild(el, i) orelse break :blk parsed.min_width;
                break :blk @max(parsed.min_width, try self.preferredChildWidth(child, available, style.color, style.font_scale));
            } else parsed.min_width;
            frs[i] = parsed.fr;
            fixed_sum += mins[i];
            fr_sum += parsed.fr;
        }

        const remaining = @max(0, available - fixed_sum);
        i = 0;
        while (i < track_count) : (i += 1) {
            const extra: i32 = if (fr_sum > 0 and frs[i] > 0)
                @intFromFloat(@round(@as(f64, @floatFromInt(remaining)) * frs[i] / fr_sum))
            else
                0;
            out[i] = @max(1, mins[i] + extra);
        }
        return track_count;
    }

    fn nthRenderableChild(self: *Renderer, el: *Element, target: usize) ?*Element {
        var index: usize = 0;
        var child = el.asNode().firstChild();
        while (child) |node| {
            switch (node._type) {
                .element => |child_el| {
                    if (self.isRenderable(child_el)) {
                        if (index == target) return child_el;
                        index += 1;
                    }
                },
                else => {},
            }
            child = node.nextSibling();
        }
        return null;
    }

    const GridTrack = struct {
        min_width: i32 = 0,
        fr: f64 = 0,
        auto_width: bool = false,
    };

    fn parseGridTrack(self: *Renderer, value_: []const u8, available: i32, font_scale: u8) GridTrack {
        const value = std.mem.trim(u8, value_, " \t\r\n;");
        if (std.ascii.eqlIgnoreCase(value, "auto")) return .{ .auto_width = true };
        if (parseFr(value)) |fr| return .{ .fr = fr };

        if (stripFunction(value, "minmax")) |inner| {
            var args: [2][]const u8 = undefined;
            if (splitCssArgs(inner, &args) == 2) {
                const min_width = parseLength(args[0], available, @intCast(self.image.width), @intCast(self.image.height), font_scale) orelse 0;
                if (std.ascii.eqlIgnoreCase(args[1], "auto")) return .{ .min_width = min_width, .auto_width = true };
                return .{ .min_width = min_width, .fr = parseFr(args[1]) orelse 0 };
            }
        }

        return .{
            .min_width = parseLength(value, available, @intCast(self.image.width), @intCast(self.image.height), font_scale) orelse 0,
        };
    }

    fn paintSmallImagePlaceholder(self: *Renderer, el: *Element, x: i32, y: i32, w: i32, h: i32) void {
        if (w <= 0 or h <= 0) return;
        const src = el.getAttributeSafe(comptime .wrap("src")) orelse "";
        const bg = colorFromHash(hashBytes(src));
        self.image.fillRect(x, y, w, h, bg);

        const letter = imagePlaceholderLetter(src);
        const glyph_scale: u8 = if (@min(w, h) >= 20) 2 else 1;
        const glyph_w = @as(i32, glyph_scale) * 5;
        const glyph_h = @as(i32, glyph_scale) * 7;
        self.drawGlyph(
            x + @divTrunc(@max(0, w - glyph_w), 2),
            y + @divTrunc(@max(0, h - glyph_h), 2),
            letter,
            .white,
            glyph_scale,
        );
    }

    fn resolveLength(self: *Renderer, el: *Element, property: []const u8, percent_base: i32, font_scale: u8) ?i32 {
        const value = self.propertyValue(el, property) orelse return null;
        return parseLength(value, percent_base, @intCast(self.image.width), @intCast(self.image.height), font_scale);
    }

    fn resolveEdges(self: *Renderer, el: *Element, property: []const u8, default_value: i32, percent_base: i32, font_scale: u8) Edges {
        var edges = Edges.all(default_value);
        if (self.propertyValue(el, property)) |value| {
            edges = parseEdges(value, percent_base, @intCast(self.image.width), @intCast(self.image.height), font_scale) orelse edges;
        }

        if (std.mem.eql(u8, property, "margin")) {
            edges.top = self.resolveLength(el, "margin-top", percent_base, font_scale) orelse edges.top;
            edges.right = self.resolveLength(el, "margin-right", percent_base, font_scale) orelse edges.right;
            edges.bottom = self.resolveLength(el, "margin-bottom", percent_base, font_scale) orelse edges.bottom;
            edges.left = self.resolveLength(el, "margin-left", percent_base, font_scale) orelse edges.left;
        } else {
            edges.top = self.resolveLength(el, "padding-top", percent_base, font_scale) orelse edges.top;
            edges.right = self.resolveLength(el, "padding-right", percent_base, font_scale) orelse edges.right;
            edges.bottom = self.resolveLength(el, "padding-bottom", percent_base, font_scale) orelse edges.bottom;
            edges.left = self.resolveLength(el, "padding-left", percent_base, font_scale) orelse edges.left;
        }
        return edges;
    }

    fn resolveFontScale(self: *Renderer, el: *Element, inherited_scale: u8) ?u8 {
        const value = self.propertyValue(el, "font-size") orelse return null;
        const px = parseLength(value, @intCast(self.image.width), @intCast(self.image.width), @intCast(self.image.height), inherited_scale) orelse return null;
        const scale = std.math.clamp(@divTrunc(px + 3, 7), 1, 12);
        return @intCast(scale);
    }

    fn resolveColor(self: *Renderer, el: *Element, property: []const u8) ?Rgba {
        const value = self.propertyValue(el, property) orelse return null;
        return self.parseCssColorValue(value);
    }

    fn parseCssColorValue(self: *Renderer, value: []const u8) ?Rgba {
        if (lastCssVariableName(value)) |name| {
            if (self.variableValue(name)) |var_value| {
                if (parseCssColor(var_value)) |rgba| return rgba;
            }
        }
        return parseCssColor(value);
    }

    fn resolveDisplay(self: *Renderer, el: *Element) Display {
        const value = self.propertyValue(el, "display") orelse return .block;
        if (containsCssIdent(value, "none")) return .none;
        if (containsCssIdent(value, "flex") or containsCssIdent(value, "inline-flex")) return .flex;
        if (containsCssIdent(value, "grid") or containsCssIdent(value, "inline-grid")) return .grid;
        return .block;
    }

    fn resolveAlignItems(self: *Renderer, el: *Element) AlignItems {
        const value = self.propertyValue(el, "align-items") orelse return .start;
        if (containsCssIdent(value, "center")) return .center;
        if (containsCssIdent(value, "end") or containsCssIdent(value, "flex-end")) return .end;
        return .start;
    }

    fn resolveJustifyContent(self: *Renderer, el: *Element) JustifyContent {
        const value = self.propertyValue(el, "justify-content") orelse return .start;
        if (containsCssIdent(value, "center")) return .center;
        if (containsCssIdent(value, "end") or containsCssIdent(value, "flex-end")) return .end;
        return .start;
    }

    fn hasCssValue(self: *Renderer, el: *Element, property: []const u8, needle: []const u8) bool {
        const value = self.propertyValue(el, property) orelse return false;
        return containsCssIdent(value, needle);
    }

    fn hasAutoHorizontalMargin(self: *Renderer, el: *Element) bool {
        if (self.hasCssValue(el, "margin-left", "auto") or self.hasCssValue(el, "margin-right", "auto")) {
            return true;
        }
        const value = self.propertyValue(el, "margin") orelse return false;
        return containsCssIdent(value, "auto");
    }

    fn propertyValue(self: *Renderer, el: *Element, property: []const u8) ?[]const u8 {
        var value = self.stylesheetProperty(el, property);

        const style = el.getOrCreateStyle(self.frame) catch return value;
        const inline_value = style.asCSSStyleDeclaration().getPropertyValue(property, self.frame);
        if (inline_value.len > 0) {
            value = inline_value;
        }
        return value;
    }

    fn stylesheetProperty(self: *Renderer, el: *Element, property: []const u8) ?[]const u8 {
        const sheets = self.frame.document._style_sheets orelse return null;
        var value: ?[]const u8 = null;

        for (sheets._sheets.items, 0..) |sheet, sheet_i| {
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

            for (self.raw_declarations) |decl| {
                if (decl.sheet_index != sheet_i) continue;
                if (!std.ascii.eqlIgnoreCase(decl.name, property)) continue;
                if (!(Selector.matches(el, decl.selector, self.frame) catch false)) continue;
                value = decl.value;
            }
        }
        return value;
    }

    fn variableValue(self: *Renderer, name: []const u8) ?[]const u8 {
        const sheets = self.frame.document._style_sheets orelse return null;
        var value: ?[]const u8 = null;

        for (self.raw_style_texts) |maybe_text| {
            const text = maybe_text orelse continue;
            if (findRootCustomProperty(text, name)) |raw_value| {
                value = raw_value;
            }
        }

        for (sheets._sheets.items, 0..) |sheet, sheet_i| {
            if (sheet._css_rules) |rules| {
                for (rules._rules.items) |rule| {
                    const style_rule = rule.is(CSSStyleRule) orelse continue;
                    if (!selectorCanDefineRootVars(style_rule.getSelectorText())) continue;
                    const style = style_rule._style orelse continue;
                    const next = style.asCSSStyleDeclaration().getPropertyValue(name, self.frame);
                    if (next.len > 0) value = next;
                }
                continue;
            }

            for (self.raw_declarations) |decl| {
                if (decl.sheet_index != sheet_i) continue;
                if (!std.ascii.eqlIgnoreCase(decl.name, name)) continue;
                if (!selectorCanDefineRootVars(decl.selector)) continue;
                value = decl.value;
            }
        }
        return value;
    }

    fn attributeLength(self: *Renderer, el: *Element, comptime attr: []const u8, percent_base: i32) ?i32 {
        const value = if (std.mem.eql(u8, attr, "width"))
            el.getAttributeSafe(comptime .wrap("width"))
        else
            el.getAttributeSafe(comptime .wrap("height"));
        return parseLength(value orelse return null, percent_base, @intCast(self.image.width), @intCast(self.image.height), 2);
    }
};

pub fn writePngFile(allocator: Allocator, frame: *Frame, path: []const u8, opts: Options) !void {
    var image = try Image.init(allocator, opts.width, opts.height);
    defer image.deinit(allocator);

    var css_arena = std.heap.ArenaAllocator.init(allocator);
    defer css_arena.deinit();

    var renderer = Renderer{
        .allocator = allocator,
        .css_allocator = css_arena.allocator(),
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
        .img, .iframe, .embed, .object, .video, .canvas => @min(max_width, 320),
        .input, .select, .textarea => @min(max_width, 240),
        .button => @min(max_width, 180),
        else => max_width,
    };
}

fn defaultFontScale(tag: Element.Tag) ?u8 {
    return switch (tag) {
        .h1 => 6,
        .h2, .h3 => 4,
        else => null,
    };
}

fn lineHeight(scale: u8) i32 {
    return @as(i32, scale) * 8 + 2;
}

fn textInlineWidth(text: []const u8, scale: u8) i32 {
    const glyph_advance = glyphAdvance(scale);
    var width: i32 = 0;
    var needs_space = false;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |word| {
        if (needs_space) width += glyph_advance;
        width += @as(i32, @intCast(word.len)) * glyph_advance;
        needs_space = true;
    }
    return width;
}

fn isRenderableText(text: []const u8) bool {
    for (text) |c| {
        if (!std.ascii.isWhitespace(c)) return true;
    }
    return false;
}

fn glyphAdvance(scale: u8) i32 {
    const s: i32 = @intCast(scale);
    return s * 5 + @max(1, @divTrunc(s, 2));
}

fn fontScalePx(scale: u8) f64 {
    return @as(f64, @floatFromInt(@max(@as(u8, 1), scale))) * 7.0;
}

fn childWidthsTotal(widths: []const i32, gap: i32) i32 {
    if (widths.len == 0) return 0;
    var total: i32 = gap * @as(i32, @intCast(widths.len - 1));
    for (widths) |w| total += w;
    return total;
}

fn parseFr(value_: []const u8) ?f64 {
    const value = stripImportant(std.mem.trim(u8, value_, " \t\r\n;"));
    if (!std.mem.endsWith(u8, value, "fr")) return null;
    const n = std.mem.trim(u8, value[0 .. value.len - 2], " \t\r\n");
    if (n.len == 0) return 1.0;
    return std.fmt.parseFloat(f64, n) catch null;
}

fn hashBytes(bytes: []const u8) u32 {
    var h: u32 = 2166136261;
    for (bytes) |b| {
        h ^= b;
        h *%= 16777619;
    }
    return h;
}

fn colorFromHash(h: u32) Rgba {
    const palette = [_]Rgba{
        .{ .r = 78, .g = 221, .b = 209 },
        .{ .r = 90, .g = 157, .b = 255 },
        .{ .r = 255, .g = 182, .b = 94 },
        .{ .r = 204, .g = 86, .b = 205 },
        .{ .r = 255, .g = 92, .b = 112 },
        .{ .r = 66, .g = 176, .b = 120 },
        .{ .r = 120, .g = 132, .b = 255 },
        .{ .r = 238, .g = 238, .b = 238 },
    };
    return palette[h % palette.len];
}

fn imagePlaceholderLetter(src: []const u8) u8 {
    var last_dot: ?usize = null;
    var end = src.len;
    if (std.mem.indexOf(u8, src, "://")) |scheme| {
        var host_start = scheme + 3;
        while (host_start < src.len and src[host_start] == '/') : (host_start += 1) {}
        end = std.mem.indexOfAnyPos(u8, src, host_start, "/?#") orelse src.len;
        var i = host_start;
        while (i < end) : (i += 1) {
            if (src[i] == '.') last_dot = i;
        }
        if (last_dot) |dot| {
            var start = dot;
            while (start > host_start and src[start - 1] != '.') : (start -= 1) {}
            if (start < dot) return src[start];
        }
        if (host_start < end) return src[host_start];
    }

    for (src, 0..) |c, i| {
        if (c == '.') last_dot = i;
    }
    if (last_dot) |dot| {
        var start = dot;
        while (start > 0 and src[start - 1] != '/' and src[start - 1] != '.') : (start -= 1) {}
        if (start < dot) return src[start];
    }
    return 'i';
}

fn stripImportant(value: []const u8) []const u8 {
    if (std.mem.indexOf(u8, value, "!important")) |pos| {
        return std.mem.trim(u8, value[0..pos], " \t\r\n;");
    }
    return value;
}

fn stripFunction(value: []const u8, name: []const u8) ?[]const u8 {
    if (!std.ascii.startsWithIgnoreCase(value, name)) return null;
    var pos = name.len;
    while (pos < value.len and std.ascii.isWhitespace(value[pos])) : (pos += 1) {}
    if (pos >= value.len or value[pos] != '(') return null;
    const close = std.mem.lastIndexOfScalar(u8, value, ')') orelse return null;
    if (close <= pos) return null;
    return std.mem.trim(u8, value[pos + 1 .. close], " \t\r\n");
}

fn splitCssArgs(value: []const u8, out: [][]const u8) usize {
    var count: usize = 0;
    var start: usize = 0;
    var depth: u16 = 0;
    for (value, 0..) |c, i| {
        switch (c) {
            '(' => depth += 1,
            ')' => {
                if (depth > 0) depth -= 1;
            },
            ',' => if (depth == 0) {
                if (count < out.len) {
                    out[count] = std.mem.trim(u8, value[start..i], " \t\r\n");
                    count += 1;
                }
                start = i + 1;
            },
            else => {},
        }
    }
    if (count < out.len) {
        out[count] = std.mem.trim(u8, value[start..], " \t\r\n");
        count += 1;
    }
    return count;
}

fn splitCssComponents(value: []const u8, out: [][]const u8) usize {
    var count: usize = 0;
    var start: ?usize = null;
    var depth: u16 = 0;
    for (value, 0..) |c, i| {
        if (start == null and !std.ascii.isWhitespace(c)) start = i;
        switch (c) {
            '(' => depth += 1,
            ')' => {
                if (depth > 0) depth -= 1;
            },
            else => {},
        }
        if (depth == 0 and std.ascii.isWhitespace(c)) {
            if (start) |s| {
                if (s < i and count < out.len) {
                    out[count] = value[s..i];
                    count += 1;
                }
            }
            start = null;
        }
    }
    if (start) |s| {
        if (s < value.len and count < out.len) {
            out[count] = value[s..];
            count += 1;
        }
    }
    return count;
}

fn topLevelOperator(value: []const u8, op: u8) ?usize {
    var depth: u16 = 0;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        const c = value[i];
        switch (c) {
            '(' => depth += 1,
            ')' => {
                if (depth > 0) depth -= 1;
            },
            else => {},
        }
        if (depth != 0 or c != op or i == 0) continue;
        const prev = value[i - 1];
        if ((prev == 'e' or prev == 'E') and i + 1 < value.len and (std.ascii.isDigit(value[i + 1]) or value[i + 1] == '.')) continue;
        return i;
    }
    return null;
}

fn looksMultiColumnGrid(value_: []const u8) bool {
    const value = stripImportant(std.mem.trim(u8, value_, " \t\r\n;"));
    if (containsCssIdent(value, "none") or value.len == 0) return false;
    if (std.ascii.indexOfIgnoreCase(value, "repeat(") != null) return true;

    var parts: [4][]const u8 = undefined;
    return splitCssComponents(value, &parts) > 1;
}

fn containsCssIdent(value_: []const u8, needle: []const u8) bool {
    const value = stripImportant(std.mem.trim(u8, value_, " \t\r\n;"));
    var it = std.mem.tokenizeAny(u8, value, " \t\r\n,;/()");
    while (it.next()) |token| {
        if (std.ascii.eqlIgnoreCase(token, needle)) return true;
    }
    return false;
}

fn lastCssVariableName(value: []const u8) ?[]const u8 {
    var result: ?[]const u8 = null;
    var pos: usize = 0;
    while (pos < value.len) {
        const rel_start = std.ascii.indexOfIgnoreCase(value[pos..], "var(") orelse break;
        const start = pos + rel_start;
        var name_start = start + 4;
        while (name_start < value.len and std.ascii.isWhitespace(value[name_start])) : (name_start += 1) {}

        var end = name_start;
        while (end < value.len and value[end] != ')' and value[end] != ',' and !std.ascii.isWhitespace(value[end])) : (end += 1) {}
        if (end > name_start) result = value[name_start..end];
        pos = start + 4;
    }
    return result;
}

fn findRootCustomProperty(text: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, ":root")) |root_pos| {
        const open = std.mem.indexOfScalarPos(u8, text, root_pos, '{') orelse return null;
        const close = std.mem.indexOfScalarPos(u8, text, open + 1, '}') orelse return null;
        if (findDeclarationInBlock(text[open + 1 .. close], name)) |value| return value;
        pos = close + 1;
    }
    return null;
}

fn findDeclarationInBlock(block: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, block, pos, name)) |name_pos| {
        const after_name = name_pos + name.len;
        var colon = after_name;
        while (colon < block.len and std.ascii.isWhitespace(block[colon])) : (colon += 1) {}
        if (colon < block.len and block[colon] == ':') {
            var value_start = colon + 1;
            while (value_start < block.len and std.ascii.isWhitespace(block[value_start])) : (value_start += 1) {}

            var value_end = value_start;
            while (value_end < block.len and block[value_end] != ';') : (value_end += 1) {}
            return std.mem.trim(u8, block[value_start..value_end], " \t\r\n");
        }
        pos = after_name;
    }
    return null;
}

fn selectorCanDefineRootVars(selector_: []const u8) bool {
    const selector = std.mem.trim(u8, selector_, " \t\r\n");
    return std.mem.indexOf(u8, selector, ":root") != null or
        std.mem.eql(u8, selector, "html") or
        std.mem.startsWith(u8, selector, "html,") or
        std.mem.endsWith(u8, selector, ",html");
}

fn parseEdges(value_: []const u8, percent_base: i32, viewport_width: i32, viewport_height: i32, font_scale: u8) ?Edges {
    const value = stripImportant(std.mem.trim(u8, value_, " \t\r\n;"));
    if (value.len == 0) return null;

    var parts: [4][]const u8 = undefined;
    const count = splitCssComponents(value, &parts);
    if (count == 0) return null;

    var lengths: [4]i32 = .{ 0, 0, 0, 0 };
    var i: usize = 0;
    while (i < count) : (i += 1) {
        lengths[i] = parseLength(parts[i], percent_base, viewport_width, viewport_height, font_scale) orelse 0;
    }

    return switch (count) {
        1 => Edges.all(lengths[0]),
        2 => .{ .top = lengths[0], .right = lengths[1], .bottom = lengths[0], .left = lengths[1] },
        3 => .{ .top = lengths[0], .right = lengths[1], .bottom = lengths[2], .left = lengths[1] },
        else => .{ .top = lengths[0], .right = lengths[1], .bottom = lengths[2], .left = lengths[3] },
    };
}

fn parseLength(value_: []const u8, percent_base: i32, viewport_width: i32, viewport_height: i32, font_scale: u8) ?i32 {
    const value = stripImportant(std.mem.trim(u8, value_, " \t\r\n;"));
    if (value.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(value, "auto") or
        std.ascii.eqlIgnoreCase(value, "none") or
        std.ascii.eqlIgnoreCase(value, "normal"))
    {
        return null;
    }

    if (stripFunction(value, "calc")) |inner| {
        return parseLength(inner, percent_base, viewport_width, viewport_height, font_scale);
    }
    if (stripFunction(value, "min")) |inner| {
        var args: [8][]const u8 = undefined;
        const count = splitCssArgs(inner, &args);
        if (count == 0) return null;

        var result: ?i32 = null;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const next = parseLength(args[i], percent_base, viewport_width, viewport_height, font_scale) orelse continue;
            result = if (result) |current| @min(current, next) else next;
        }
        return result;
    }
    if (stripFunction(value, "max")) |inner| {
        var args: [8][]const u8 = undefined;
        const count = splitCssArgs(inner, &args);
        if (count == 0) return null;

        var result: ?i32 = null;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const next = parseLength(args[i], percent_base, viewport_width, viewport_height, font_scale) orelse continue;
            result = if (result) |current| @max(current, next) else next;
        }
        return result;
    }
    if (stripFunction(value, "clamp")) |inner| {
        var args: [3][]const u8 = undefined;
        const count = splitCssArgs(inner, &args);
        if (count != 3) return null;

        const lo = parseLength(args[0], percent_base, viewport_width, viewport_height, font_scale) orelse return null;
        const mid = parseLength(args[1], percent_base, viewport_width, viewport_height, font_scale) orelse return null;
        const hi = parseLength(args[2], percent_base, viewport_width, viewport_height, font_scale) orelse return null;
        return std.math.clamp(mid, lo, hi);
    }

    if (topLevelOperator(value, '+')) |pos| {
        const left = parseLength(value[0..pos], percent_base, viewport_width, viewport_height, font_scale) orelse return null;
        const right = parseLength(value[pos + 1 ..], percent_base, viewport_width, viewport_height, font_scale) orelse return null;
        return left + right;
    }
    if (topLevelOperator(value, '-')) |pos| {
        const left = parseLength(value[0..pos], percent_base, viewport_width, viewport_height, font_scale) orelse return null;
        const right = parseLength(value[pos + 1 ..], percent_base, viewport_width, viewport_height, font_scale) orelse return null;
        return left - right;
    }

    var end: usize = 0;
    if (end < value.len and (value[end] == '-' or value[end] == '+')) end += 1;
    while (end < value.len) : (end += 1) {
        const c = value[end];
        if (!(std.ascii.isDigit(c) or c == '.')) break;
    }
    if (end == 0 or (end == 1 and (value[0] == '-' or value[0] == '+'))) return null;

    const n = std.fmt.parseFloat(f64, value[0..end]) catch return null;
    const unit = std.mem.trim(u8, value[end..], " \t\r\n");
    const px = if (unit.len == 0 or std.mem.startsWith(u8, unit, "px"))
        n
    else if (std.mem.startsWith(u8, unit, "rem"))
        n * 16.0
    else if (std.mem.startsWith(u8, unit, "em"))
        n * fontScalePx(font_scale)
    else if (std.mem.startsWith(u8, unit, "%"))
        n * @as(f64, @floatFromInt(percent_base)) / 100.0
    else if (std.mem.startsWith(u8, unit, "vw"))
        n * @as(f64, @floatFromInt(viewport_width)) / 100.0
    else if (std.mem.startsWith(u8, unit, "vh") or std.mem.startsWith(u8, unit, "dvh") or std.mem.startsWith(u8, unit, "svh") or std.mem.startsWith(u8, unit, "lvh"))
        n * @as(f64, @floatFromInt(viewport_height)) / 100.0
    else
        n;

    return @intFromFloat(std.math.clamp(@round(px), -100_000.0, 100_000.0));
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
        '{' => .{ 0x02, 0x04, 0x04, 0x18, 0x04, 0x04, 0x02 },
        '}' => .{ 0x08, 0x04, 0x04, 0x03, 0x04, 0x04, 0x08 },
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
