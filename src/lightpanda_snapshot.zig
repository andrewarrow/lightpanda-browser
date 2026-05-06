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

pub const log = @import("log.zig");
pub const String = @import("string.zig").String;
pub const js = @import("browser/js/js.zig");
pub const build_config = @import("build_config");

const IS_DEBUG = @import("builtin").mode == .Debug;

pub inline fn assert(ok: bool, comptime ctx: []const u8, args: anytype) void {
    if (!ok) {
        if (comptime IS_DEBUG) {
            unreachable;
        }
        assertionFailure(ctx, args);
    }
}

noinline fn assertionFailure(comptime ctx: []const u8, args: anytype) noreturn {
    @branchHint(.cold);
    _ = args;
    if (@inComptime()) {
        @compileError("assertion failure: " ++ ctx);
    }
    @panic("assertion failure: " ++ ctx);
}

// Reference counting helper used by Web APIs included in the V8 snapshot.
pub fn RC(comptime T: type) type {
    return struct {
        _refs: T = 0,

        pub fn init(refs: T) @This() {
            return .{ ._refs = refs };
        }

        pub fn acquire(self: *@This()) void {
            self._refs += 1;
        }

        pub fn release(self: *@This(), value: anytype, page: anytype) void {
            assert(self._refs > 0, "release overflow", .{ .type = @typeName(@TypeOf(value)) });

            const refs = self._refs - 1;
            self._refs = refs;
            if (refs > 0) {
                return;
            }
            value.deinit(page);
        }

        pub fn format(self: @This(), writer: *std.Io.Writer) !void {
            return writer.print("{d}", .{self._refs});
        }
    };
}
