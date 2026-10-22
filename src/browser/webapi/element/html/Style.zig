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
const Factory = @import("../../../Factory.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Style = @This();

pub const Proto = HtmlElement;
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
_sheet: ?*CSSStyleSheet = null,

pub fn asElement(self: *Style) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Style) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Style) *Node {
    return self.asElement().asNode();
}

// Attribute-backed properties

const CSSStyleSheet = @import("../../css/CSSStyleSheet.zig");
fn getSheet(self: *Style, caller: *Frame) !?*CSSStyleSheet {
    const frame = self.asElement().ownerFrame(caller) orelse caller;
    // Per spec, sheet is null for disconnected elements or non-CSS types.
    // Valid types: absent (defaults to "text/css"), empty string, or
    // case-insensitive match for "text/css".
    if (!self.asNode().isConnected()) {
        return null;
    }
    const t = self.getType();
    if (t.len != 0 and !std.ascii.eqlIgnoreCase(t, "text/css")) {
        return null;
    }

    if (self._sheet) |sheet| return sheet;
    const sheet = try CSSStyleSheet.initWithOwner(self.asElement(), frame);
    // Keep the source with the sheet: a retained, lazily materialized old
    // CSSStyleSheet must not read its former owner's replacement text.
    const node = self.asNode();
    const source = try frame.page_arena.alloc(u8, node.childTextContentLen());
    var writer: std.Io.Writer = .fixed(source);
    try node.getChildTextContent(&writer);
    sheet._source = source;
    self._sheet = sheet;

    const owner = self.asNode().ownerDocument(frame) orelse frame.document;
    const sheets = try owner.getStyleSheets(frame);
    try sheets.add(sheet, frame);

    return sheet;
}

// HTML's update-a-style-block steps are shared by connection, removal,
// and DOM children changes. Replacing the sheet also replaces materialized
// CSSOM rules; changing only the style version cannot do that.
pub fn updateStyleBlock(self: *Style, caller: *Frame) !void {
    if (!self.asNode().isConnected() and self._sheet == null) return;
    const owner_frame = self.asElement().ownerFrame(caller);
    const frame = owner_frame orelse caller;
    if (self._sheet) |sheet| {
        const owner = self.asNode().ownerDocument(frame) orelse frame.document;
        if (owner._style_sheets) |sheets| sheets.remove(sheet);
        sheet._owner_node = null;
        sheet._owner_rule = null;
        self._sheet = null;
    }
    if (owner_frame) |owner| owner._style_manager.sheetModified();
    if ((try self.getSheet(frame)) == null) return;
    if (owner_frame) |owner| {
        if (!owner.isGoingAway()) try owner.queueLoad(Factory.protoOf(self));
    }
}

pub fn styleAddedCallback(self: *Style, frame: *Frame, preserve_sheet: bool) !void {
    if (preserve_sheet) {
        if (self._sheet) |sheet| {
            // A state-preserving move retains CSSOM edits, but its position
            // in the document cascade still follows the new tree order.
            const owner = self.asNode().ownerDocument(frame) orelse frame.document;
            const sheets = try owner.getStyleSheets(frame);
            sheets.remove(sheet);
            try sheets.add(sheet, frame);
            frame._style_manager.sheetModified();
            return;
        }
    }
    try self.updateStyleBlock(frame);
}

pub fn getType(self: *const Style) []const u8 {
    return self.asConstElement().getAttributeInterned("type") orelse "";
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Style);

    pub const Meta = struct {
        pub const name = "HTMLStyleElement";
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Style);
    pub const nonce = reflect.string("nonce");

    pub const blocking = reflect.string("blocking");
    pub const media = reflect.string("media");
    pub const @"type" = reflect.string("type");
    pub const disabled = reflect.boolean("disabled");
    pub const sheet = bridge.accessor(Style.getSheet, null, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: Style" {
    try testing.htmlRunner("element/html/style.html", .{});
}
