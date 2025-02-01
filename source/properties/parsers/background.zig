const std = @import("std");

const zss = @import("../../zss.zig");
const TokenSource = zss.syntax.TokenSource;

const values = zss.values;
const types = values.types;
const Source = values.Source;

// Spec: CSS Backgrounds and Borders Level 3
// Syntax: <image> | none
//         <image> = <url> | <gradient>
//         <gradient> = <linear-gradient()> | <repeating-linear-gradient()> | <radial-gradient()> | <repeating-radial-gradient()>
pub fn @"background-image"(source: *Source) ?types.BackgroundImage {
    const item = source.next() orelse return null;
    switch (item.type) {
        .url => {
            const url = source.value(.url, item.index) catch std.debug.panic("TODO: Allocation failure", .{});
            if (url) |value| return .{ .url = value };
        },
        .function => {
            // TODO: parse gradient functions
        },
        .keyword => {
            if (source.mapKeyword(item.index, types.BackgroundImage, &.{
                .{ "none", .none },
            })) |value| return value;
        },
        else => {},
    }

    source.sequence.reset(item.index);
    return null;
}

// Spec: CSS Backgrounds and Borders Level 3
// Syntax: <repeat-style> = repeat-x | repeat-y | [repeat | space | round | no-repeat]{1,2}
pub fn @"background-repeat"(source: *Source) ?types.BackgroundRepeat {
    const keyword1 = source.expect(.keyword) orelse return null;

    if (source.mapKeyword(keyword1.index, types.BackgroundRepeat.Repeat, &.{
        .{ "repeat-x", .{ .x = .repeat, .y = .no_repeat } },
        .{ "repeat-y", .{ .x = .no_repeat, .y = .repeat } },
    })) |value| {
        return .{ .repeat = value };
    }

    const Style = types.BackgroundRepeat.Style;
    const map = comptime &[_]TokenSource.KV(Style){
        .{ "repeat", .repeat },
        .{ "space", .space },
        .{ "round", .round },
        .{ "no-repeat", .no_repeat },
    };
    if (source.mapKeyword(keyword1.index, Style, map)) |x| {
        const y = values.parse.parseSingleKeyword(source, Style, map) orelse x;
        return .{ .repeat = .{ .x = x, .y = y } };
    }

    source.sequence.reset(keyword1.index);
    return null;
}

// Spec: CSS Backgrounds and Borders Level 3
// Syntax: <attachment> = scroll | fixed | local
pub fn @"background-attachment"(source: *Source) ?types.BackgroundAttachment {
    return values.parse.parseSingleKeyword(source, types.BackgroundAttachment, &.{
        .{ "scroll", .scroll },
        .{ "fixed", .fixed },
        .{ "local", .local },
    });
}

const bg_position = struct {
    const Side = types.BackgroundPosition.Side;
    const Offset = types.BackgroundPosition.Offset;
    const Axis = enum { x, y, either };

    const KeywordMapValue = struct { axis: Axis, side: Side };
    // zig fmt: off
    const keyword_map = &[_]TokenSource.KV(KeywordMapValue){
        .{ "center", .{ .axis = .either, .side = .center } },
        .{ "left",   .{ .axis = .x,      .side = .start  } },
        .{ "right",  .{ .axis = .x,      .side = .end    } },
        .{ "top",    .{ .axis = .y,      .side = .start  } },
        .{ "bottom", .{ .axis = .y,      .side = .end    } },
    };
    // zig fmt: on

    const Info = struct {
        axis: Axis,
        side: Side,
        offset: Offset,
    };

    const ResultTuple = struct {
        bg_position: types.BackgroundPosition,
        num_items_used: u3,
    };
};

/// Spec: CSS Backgrounds and Borders Level 3
/// Syntax: <bg-position> = [ left | center | right | top | bottom | <length-percentage> ]
///                       |
///                         [ left | center | right | <length-percentage> ]
///                         [ top | center | bottom | <length-percentage> ]
///                       |
///                         [ center | [ left | right ] <length-percentage>? ] &&
///                         [ center | [ top | bottom ] <length-percentage>? ]
pub fn @"background-position"(source: *Source) ?types.BackgroundPosition {
    const first_item = source.next() orelse return null;

    var items: [4]Source.Item = .{ first_item, undefined, undefined, undefined };
    for (items[1..]) |*item| {
        item.* = source.next() orelse .{ .type = .unknown, .index = source.sequence.end };
    }

    const result =
        backgroundPosition3Or4Values(items, source) orelse
        backgroundPosition1Or2Values(items, source) orelse
        {
        source.sequence.reset(first_item.index);
        return null;
    };

    if (result.num_items_used < 4) {
        source.sequence.reset(items[result.num_items_used].index);
    }
    return result.bg_position;
}

/// Spec: CSS Backgrounds and Borders Level 3
/// Syntax: [ center | [ left | right ] <length-percentage>? ] &&
///         [ center | [ top | bottom ] <length-percentage>? ]
fn backgroundPosition3Or4Values(items: [4]Source.Item, source: *Source) ?bg_position.ResultTuple {
    var num_items_used: u3 = 0;
    const first = backgroundPosition3Or4ValuesInfo(items, &num_items_used, source) orelse return null;
    const second = backgroundPosition3Or4ValuesInfo(items, &num_items_used, source) orelse return null;
    if (num_items_used < 3) return null;

    var x_axis: *const bg_position.Info = undefined;
    var y_axis: *const bg_position.Info = undefined;

    switch (first.axis) {
        .x => {
            x_axis = &first;
            y_axis = switch (second.axis) {
                .x => return null,
                .y => &second,
                .either => &second,
            };
        },
        .y => {
            x_axis = switch (second.axis) {
                .x => &second,
                .y => return null,
                .either => &second,
            };
            y_axis = &first;
        },
        .either => switch (second.axis) {
            .x => {
                x_axis = &second;
                y_axis = &first;
            },
            .y, .either => {
                x_axis = &first;
                y_axis = &second;
            },
        },
    }

    const result = types.BackgroundPosition{
        .position = .{
            .x = .{
                .side = x_axis.side,
                .offset = x_axis.offset,
            },
            .y = .{
                .side = y_axis.side,
                .offset = y_axis.offset,
            },
        },
    };
    return .{ .bg_position = result, .num_items_used = num_items_used };
}

fn backgroundPosition3Or4ValuesInfo(items: [4]Source.Item, num_items_used: *u3, source: *Source) ?bg_position.Info {
    const side_item = items[num_items_used.*];
    if (side_item.type != .keyword) return null;
    const map_value = source.mapKeyword(side_item.index, bg_position.KeywordMapValue, bg_position.keyword_map) orelse return null;

    var offset: bg_position.Offset = undefined;
    switch (map_value.side) {
        .center => {
            num_items_used.* += 1;
            offset = .{ .percentage = 0 };
        },
        else => {
            const offset_item = items[num_items_used.* + 1];
            switch (offset_item.type) {
                inline .dimension, .percentage => |@"type"| {
                    if (values.parse.genericLengthPercentage(bg_position.Offset, source.value(@"type", offset_item.index))) |value| {
                        num_items_used.* += 2;
                        offset = value;
                    } else {
                        num_items_used.* += 1;
                        offset = .{ .percentage = 0 };
                    }
                },
                else => {
                    num_items_used.* += 1;
                    offset = .{ .percentage = 0 };
                },
            }
        },
    }

    return .{ .axis = map_value.axis, .side = map_value.side, .offset = offset };
}

/// Spec: CSS Backgrounds and Borders Level 3
/// Syntax: [ left | center | right | top | bottom | <length-percentage> ]
///       |
///         [ left | center | right | <length-percentage> ]
///         [ top | center | bottom | <length-percentage> ]
fn backgroundPosition1Or2Values(items: [4]Source.Item, source: *Source) ?bg_position.ResultTuple {
    const first = backgroundPosition1Or2ValuesInfo(items[0], source) orelse return null;
    twoValues: {
        if (first.axis == .y) break :twoValues;
        const second = backgroundPosition1Or2ValuesInfo(items[1], source) orelse break :twoValues;
        if (second.axis == .x) break :twoValues;

        const result = types.BackgroundPosition{
            .position = .{
                .x = .{
                    .side = first.side,
                    .offset = first.offset,
                },
                .y = .{
                    .side = second.side,
                    .offset = second.offset,
                },
            },
        };
        return .{ .bg_position = result, .num_items_used = 2 };
    }

    var result = types.BackgroundPosition{
        .position = .{
            .x = .{
                .side = first.side,
                .offset = first.offset,
            },
            .y = .{
                .side = .center,
                .offset = .{ .percentage = 0 },
            },
        },
    };
    if (first.axis == .y) {
        std.mem.swap(types.BackgroundPosition.SideOffset, &result.position.x, &result.position.y);
    }
    return .{ .bg_position = result, .num_items_used = 1 };
}

fn backgroundPosition1Or2ValuesInfo(item: Source.Item, source: *Source) ?bg_position.Info {
    switch (item.type) {
        .keyword => {
            const map_value = source.mapKeyword(item.index, bg_position.KeywordMapValue, bg_position.keyword_map) orelse return null;
            return .{ .axis = map_value.axis, .side = map_value.side, .offset = .{ .percentage = 0 } };
        },
        inline .dimension, .percentage => |@"type"| {
            if (values.parse.genericLengthPercentage(bg_position.Offset, source.value(@"type", item.index))) |offset|
                return .{ .axis = .either, .side = .start, .offset = offset };
        },
        else => {},
    }
    return null;
}

/// Spec: CSS Backgrounds and Borders Level 3
/// Syntax: <box> = border-box | padding-box | content-box
pub fn @"background-clip"(source: *Source) ?types.BackgroundClip {
    return values.parse.parseSingleKeyword(source, types.BackgroundClip, &.{
        .{ "border-box", .border_box },
        .{ "padding-box", .padding_box },
        .{ "content-box", .content_box },
    });
}

/// Spec: CSS Backgrounds and Borders Level 3
/// Syntax: <box> = border-box | padding-box | content-box
pub fn @"background-origin"(source: *Source) ?types.BackgroundOrigin {
    return values.parse.parseSingleKeyword(source, types.BackgroundOrigin, &.{
        .{ "border-box", .border_box },
        .{ "padding-box", .padding_box },
        .{ "content-box", .content_box },
    });
}

/// Spec: CSS Backgrounds and Borders Level 3
/// Syntax: <bg-size> = [ <length-percentage [0,infinity]> | auto ]{1,2} | cover | contain
pub fn @"background-size"(source: *Source) ?types.BackgroundSize {
    const first = source.next() orelse return null;
    switch (first.type) {
        .keyword => {
            if (source.mapKeyword(first.index, types.BackgroundSize, &.{
                .{ "cover", .cover },
                .{ "contain", .contain },
            })) |value| return value;
        },
        else => {},
    }

    if (backgroundSizeOne(first, source)) |width| {
        const height = blk: {
            const second = source.next() orelse break :blk width;
            const result = backgroundSizeOne(second, source) orelse {
                source.sequence.reset(second.index);
                break :blk width;
            };
            break :blk result;
        };
        return types.BackgroundSize{ .size = .{ .width = width, .height = height } };
    }

    source.sequence.reset(first.index);
    return null;
}

fn backgroundSizeOne(item: Source.Item, source: *Source) ?types.BackgroundSize.SizeType {
    switch (item.type) {
        inline .dimension, .percentage => |@"type"| {
            // TODO: Range checking?
            return values.parse.genericLengthPercentage(types.BackgroundSize.SizeType, source.value(@"type", item.index));
        },
        .keyword => return source.mapKeyword(item.index, types.BackgroundSize.SizeType, &.{
            .{ "auto", .auto },
        }),
        else => return null,
    }
}
