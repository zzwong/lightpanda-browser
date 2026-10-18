const std = @import("std");
const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const CSSStyleSheet = @import("CSSStyleSheet.zig");
const GenericIterator = @import("../collections/iterator.zig").Entry;

const StyleSheetList = @This();

pub fn registerTypes() []const type {
    return &.{ StyleSheetList, ValueIterator };
}

_sheets: std.ArrayList(*CSSStyleSheet) = .empty,

pub fn init(frame: *Frame) !*StyleSheetList {
    return frame._factory.create(StyleSheetList{});
}

pub fn length(self: *const StyleSheetList) u32 {
    return @intCast(self._sheets.items.len);
}

pub fn item(self: *const StyleSheetList, index: usize) ?*CSSStyleSheet {
    if (index >= self._sheets.items.len) return null;
    return self._sheets.items[index];
}

pub fn add(self: *StyleSheetList, sheet: *CSSStyleSheet, frame: *Frame) !void {
    for (self._sheets.items) |existing| {
        if (existing == sheet) return;
    }
    try self._sheets.append(frame.page_arena, sheet);
    // A moved subtree can contain several styles. The remaining registrations
    // need not already be sorted while its ready callbacks run, so reorder
    // the whole list rather than inserting into an assumed-sorted prefix.
    std.sort.insertion(*CSSStyleSheet, self._sheets.items, {}, struct {
        fn lessThan(_: void, a: *CSSStyleSheet, b: *CSSStyleSheet) bool {
            const owner = a.getOwnerNode() orelse return false;
            const other = b.getOwnerNode() orelse return false;
            const position = owner.asNode().compareDocumentPosition(other.asNode());
            return position & 0x01 == 0 and position & 0x04 != 0;
        }
    }.lessThan);
}

pub fn remove(self: *StyleSheetList, sheet: *CSSStyleSheet) void {
    for (self._sheets.items, 0..) |s, i| {
        if (s == sheet) {
            _ = self._sheets.orderedRemove(i);
            return;
        }
    }
}

fn values(self: *StyleSheetList, frame: *Frame) !*ValueIterator {
    return .init(.{ .list = self }, frame);
}

const ValueIterator = GenericIterator(Iterator, null);

const Iterator = struct {
    index: u32 = 0,
    list: *StyleSheetList,

    pub fn next(self: *Iterator, _: *Frame) ?*CSSStyleSheet {
        const sheet = self.list.item(self.index) orelse return null;
        self.index += 1;
        return sheet;
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(StyleSheetList);

    pub const Meta = struct {
        pub const name = "StyleSheetList";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(StyleSheetList.length, null, .{});
    pub const @"[]" = bridge.indexed(StyleSheetList.item, null, .{ .null_as_undefined = true });
    pub const symbol_iterator = bridge.iterator(StyleSheetList.values, .{});
};
