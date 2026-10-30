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
const Env = @import("Env.zig");
const v8 = @import("js.zig").v8;

pub const Zone = [128]u16;

// ICU's default is process-wide. Nested V8 calls on one Env must not relock.
var lock: std.Io.RwLock = .init;
threadlocal var depth: usize = 0;
threadlocal var active_env: ?*Env = null;
threadlocal var active_exclusive: bool = false;
threadlocal var active_applied: bool = false;
var host: ?Zone = null;
var host_ready: std.atomic.Value(bool) = .init(false);

pub fn parse(id: []const u8) error{InvalidTimezoneId}!Zone {
    if (id.len == 0 or id.len >= 128) return error.InvalidTimezoneId;
    var input: Zone = @splat(0);
    for (id, 0..) |byte, i| {
        if (byte == 0 or byte > 127) return error.InvalidTimezoneId;
        input[i] = byte;
    }
    var canonical: Zone = @splat(0);
    var status: c_int = 0;
    var is_system: i8 = 0;
    const len = ucal_getCanonicalTimeZoneID_78(&input, @intCast(id.len), &canonical, canonical.len, &is_system, &status);
    if (status > 0 or is_system == 0 or len <= 0 or len >= canonical.len) return error.InvalidTimezoneId;
    return canonical;
}

fn current() Zone {
    var zone: Zone = @splat(0);
    var status: c_int = 0;
    const len = ucal_getDefaultTimeZone_78(&zone, zone.len, &status);
    if (status > 0 or len <= 0 or len >= zone.len) @panic("cannot read native timezone");
    return zone;
}

fn setDefault(zone: *const Zone) void {
    var status: c_int = 0;
    ucal_setDefaultTimeZone_78(zone, &status);
    if (status > 0) @panic("cannot set native timezone");
}

pub const Scope = struct {
    outermost: bool,
    previous_env: ?*Env = null,
    previous_depth: usize = 0,

    pub fn enter(env: *Env) Scope {
        if (active_env == env) {
            depth += 1;
            return .{ .outermost = false };
        }

        const previous_env = active_env;
        const previous_depth = depth;
        // Agent microtasks can enter the Browser's other isolate on this thread.
        if (previous_env != null) release();
        acquire(env);
        return .{ .outermost = true, .previous_env = previous_env, .previous_depth = previous_depth };
    }

    pub fn exit(self: Scope) void {
        std.debug.assert(depth > 0);
        depth -= 1;
        if (!self.outermost) return;
        std.debug.assert(depth == 0);
        release();
        if (self.previous_env) |env| {
            acquire(env);
            depth = self.previous_depth;
        }
    }
};

fn acquire(env: *Env) void {
    const override = env.timezone_override;
    const exclusive = override != null or env.timezone_cached != null or !host_ready.load(.acquire);
    if (exclusive) {
        lock.lockUncancelable(lp.io);
    } else {
        lock.lockSharedUncancelable(lp.io);
    }
    active_env = env;
    active_exclusive = exclusive;
    active_applied = override != null;
    depth = 1;

    if (!host_ready.load(.acquire)) {
        std.debug.assert(exclusive);
        host = current();
        host_ready.store(true, .release);
    }

    if (override) |zone| {
        setDefault(&zone);
    }
    if (!std.meta.eql(env.timezone_cached, override)) {
        date_config_changed(env.isolate.handle, 0);
        env.timezone_cached = override;
    }
}

fn release() void {
    if (active_applied) setDefault(&host.?);
    if (active_exclusive) {
        lock.unlock(lp.io);
    } else {
        lock.unlockShared(lp.io);
    }
    active_env = null;
    active_exclusive = false;
    active_applied = false;
    depth = 0;
}

// Private ABI pinned to ICU 78 / V8 15.5. Move these to zig-v8-fork bindings
// when zzwong/zig-v8-fork PR #1 is available.
extern fn ucal_getDefaultTimeZone_78(result: [*]u16, capacity: c_int, status: *c_int) c_int;
extern fn ucal_getCanonicalTimeZoneID_78(id: [*]const u16, length: c_int, result: [*]u16, capacity: c_int, is_system: *i8, status: *c_int) c_int;
extern fn ucal_setDefaultTimeZone_78(id: [*]const u16, status: *c_int) void;
const date_config_changed = @extern(*const fn (*v8.Isolate, c_int) callconv(.c) void, .{
    .name = "_ZN2v87Isolate39DateTimeConfigurationChangeNotificationENS0_17TimeZoneDetectionE",
});

const testing = @import("../../testing.zig");

test "Timezone: canonicalizes and rejects invalid ids" {
    const utc = try parse("UTC");
    try testing.expectEqualSlices(u16, &parseExpected("Etc/UTC"), &utc);
    const tokyo = try parse("Asia/Tokyo");
    try testing.expectEqualSlices(u16, &parseExpected("Asia/Tokyo"), &tokyo);
    try testing.expectError(error.InvalidTimezoneId, parse(""));
    try testing.expectError(error.InvalidTimezoneId, parse("Not/AZone"));
    const too_long: [128]u8 = @splat('A');
    try testing.expectError(error.InvalidTimezoneId, parse(&too_long));
    try testing.expectError(error.InvalidTimezoneId, parse("UTC\x00"));
}

fn parseExpected(comptime id: []const u8) Zone {
    var zone: Zone = @splat(0);
    for (id, 0..) |byte, i| zone[i] = byte;
    return zone;
}

test "Timezone: scope restores ICU default after override" {
    var env = try Env.init(testing.test_app, .{});
    defer env.deinit();

    const original = current();
    const tokyo = try parse("Asia/Tokyo");
    env.timezone_override = tokyo;
    {
        const scope = Scope.enter(&env);
        defer scope.exit();
        try testing.expectEqualSlices(u16, &tokyo, &current());
    }
    try testing.expectEqualSlices(u16, &original, &current());
}

test "Timezone: nested scopes switch between isolates" {
    var first = try Env.init(testing.test_app, .{});
    defer first.deinit();
    var second = try Env.init(testing.test_app, .{});
    defer second.deinit();

    const original = current();
    const tokyo = try parse("Asia/Tokyo");
    const paris = try parse("Europe/Paris");
    first.timezone_override = tokyo;
    second.timezone_override = paris;
    {
        const outer = Scope.enter(&first);
        defer outer.exit();
        try testing.expectEqualSlices(u16, &tokyo, &current());
        {
            const inner = Scope.enter(&second);
            defer inner.exit();
            try testing.expectEqualSlices(u16, &paris, &current());
        }
        try testing.expectEqualSlices(u16, &tokyo, &current());
    }
    try testing.expectEqualSlices(u16, &original, &current());
}
