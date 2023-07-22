const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const zss = @import("../../zss.zig");
const toLowercase = zss.util.unicode.toLowercase;
const syntax = @import("./syntax.zig");
const Component = syntax.Component;
const Extra = Component.Extra;
const ComponentTree = syntax.ComponentTree;
const tokenize = @import("./tokenize.zig");

/// A source of `Component.Tag`.
pub const Source = struct {
    inner: tokenize.Source,

    pub const Location = tokenize.Source.Location;

    pub fn init(inner: tokenize.Source) Source {
        return Source{ .inner = inner };
    }

    /// Returns the next component tag, ignoring comments.
    pub fn next(source: Source, location: *Location) Component.Tag {
        var next_location = location.*;
        while (true) {
            const result = tokenize.nextToken(source.inner, next_location);
            if (result.tag != .token_comments) {
                location.* = result.next_location;
                return result.tag;
            }
            next_location = result.next_location;
        }
    }

    fn getDelimeter(source: Source, location: Location) u21 {
        return source.inner.delimTokenCodepoint(location);
    }

    pub fn identTokenIterator(source: Source, start: Location) IdentSequenceIterator {
        return .{ .inner = source.inner.identTokenIterator(start) };
    }

    pub fn hashIdTokenIterator(source: Source, start: Location) IdentSequenceIterator {
        return .{ .inner = source.inner.hashIdTokenIterator(start) };
    }

    pub fn matchKeyword(source: Source, location: Location, keyword: []const u21) bool {
        var it = source.inner.identTokenIterator(location);
        for (keyword) |kw_codepoint| {
            const it_codepoint = it.next(source.inner) orelse return false;
            if (toLowercase(kw_codepoint) != toLowercase(it_codepoint)) return false;
        }
        return it.next(source.inner) == null;
    }

    pub fn identTokensEqlIgnoreCase(source: Source, ident1: Location, ident2: Location) bool {
        if (ident1.value == ident2.value) return true;
        var it1 = source.inner.identTokenIterator(ident1);
        var it2 = source.inner.identTokenIterator(ident2);
        while (it1.next(source.inner)) |codepoint1| {
            const codepoint2 = it2.next(source.inner) orelse return false;
            if (toLowercase(codepoint1) != toLowercase(codepoint2)) return false;
        } else {
            return (it2.next(source.inner) == null);
        }
    }
};

pub const IdentSequenceIterator = struct {
    inner: tokenize.IdentSequenceIterator,

    pub fn next(it: *IdentSequenceIterator, source: Source) ?u21 {
        return it.inner.next(source.inner);
    }
};

pub fn parseStylesheet(source: Source, allocator: Allocator) !ComponentTree {
    var parser = try Parser.init(source, allocator);
    defer parser.deinit();

    var location = Source.Location{};

    try parser.pushListOfRules(location, true);
    try loop(&parser, &location);
    return parser.finish();
}

pub fn parseListOfComponentValues(source: Source, allocator: Allocator) !ComponentTree {
    var parser = try Parser.init(source, allocator);
    defer parser.deinit();

    var location = Source.Location{};

    try parser.pushListOfComponentValues(location);
    try loop(&parser, &location);
    return parser.finish();
}

const Parser = struct {
    stack: ArrayListUnmanaged(Frame),
    tree: ComponentTree,
    source: Source,
    allocator: Allocator,

    const Frame = struct {
        skip: ComponentTree.Size,
        index: ComponentTree.Size,
        data: Data,

        const Data = union(enum) {
            root,
            list_of_rules: ListOfRules,
            list_of_component_values,
            qualified_rule,
            at_rule,
            simple_block: SimpleBlock,
            function,
        };

        const ListOfRules = struct {
            top_level: bool,
        };

        const SimpleBlock = struct {
            tag: Component.Tag,
            // true if the simple block is the associated {}-block of a qualified rule or an at rule.
            in_a_rule: bool,

            fn endingTokenTag(simple_block: SimpleBlock) Component.Tag {
                return switch (simple_block.tag) {
                    .simple_block_curly => .token_right_curly,
                    .simple_block_bracket => .token_right_bracket,
                    .simple_block_paren => .token_right_paren,
                    else => unreachable,
                };
            }
        };
    };

    fn init(source: Source, allocator: Allocator) !Parser {
        var stack = ArrayListUnmanaged(Frame){};
        try stack.append(allocator, .{ .skip = 0, .index = undefined, .data = .root });

        return Parser{
            .stack = stack,
            .tree = .{},
            .source = source,
            .allocator = allocator,
        };
    }

    fn deinit(parser: *Parser) void {
        parser.stack.deinit(parser.allocator);
        parser.tree.deinit(parser.allocator);
    }

    fn finish(parser: *Parser) ComponentTree {
        const tree = parser.tree;
        parser.tree = .{};
        return tree;
    }

    fn allocateComponent(parser: *Parser, component: Component) !ComponentTree.Size {
        if (parser.tree.components.len == std.math.maxInt(ComponentTree.Size)) return error.Overflow;
        const index = @intCast(ComponentTree.Size, parser.tree.components.len);
        try parser.tree.components.append(parser.allocator, component);
        return index;
    }

    /// Creates a Component that has no children.
    fn addComponent(parser: *Parser, tag: Component.Tag, location: Source.Location, extra: Component.Extra) !void {
        const index = @intCast(ComponentTree.Size, parser.tree.components.len);
        _ = try parser.allocateComponent(.{
            .next_sibling = index + 1,
            .tag = tag,
            .location = location,
            .extra = extra,
        });
        parser.stack.items[parser.stack.items.len - 1].skip += 1;
    }

    fn pushListOfRules(parser: *Parser, location: Source.Location, top_level: bool) !void {
        const index = try parser.allocateComponent(.{
            .next_sibling = undefined,
            .tag = .rule_list,
            .location = location,
            .extra = Extra.make(0),
        });
        try parser.stack.append(parser.allocator, .{
            .skip = 1,
            .index = index,
            .data = .{ .list_of_rules = .{ .top_level = top_level } },
        });
    }

    fn pushListOfComponentValues(parser: *Parser, location: Source.Location) !void {
        const index = try parser.allocateComponent(.{
            .next_sibling = undefined,
            .tag = .component_list,
            .location = location,
            .extra = Extra.make(0),
        });
        try parser.stack.append(parser.allocator, .{ .skip = 1, .index = index, .data = .list_of_component_values });
    }

    /// `location` must be the location of the first token of the at-rule (i.e. the <at-keyword-token>).
    fn pushAtRule(parser: *Parser, location: Source.Location) !void {
        const index = try parser.allocateComponent(.{
            .next_sibling = undefined,
            .tag = .at_rule,
            .location = location,
            .extra = Extra.make(0),
        });
        try parser.stack.append(parser.allocator, .{ .skip = 1, .index = index, .data = .at_rule });
    }

    /// `location` must be the location of the first token of the qualified rule.
    fn pushQualifiedRule(parser: *Parser, location: Source.Location) !void {
        const index = try parser.allocateComponent(.{
            .next_sibling = undefined,
            .tag = .qualified_rule,
            .location = location,
            .extra = Extra.make(0),
        });
        try parser.stack.append(parser.allocator, .{ .skip = 1, .index = index, .data = .qualified_rule });
    }

    fn pushFunction(parser: *Parser, location: Source.Location) !void {
        const index = try parser.allocateComponent(.{
            .next_sibling = undefined,
            .tag = .function,
            .location = location,
            .extra = Extra.make(0),
        });
        try parser.stack.append(parser.allocator, .{ .skip = 1, .index = index, .data = .function });
    }

    // fn addSimpleBlock(parser: *Parser, tag: Component.Tag, location: Source.Location) !void {
    //     const component_tag: Component.Tag = switch (tag) {
    //         .simple_block_curly, .simple_block_bracket, .simple_block_paren => {},
    //         else => unreachable,
    //     };
    //     _ = try allocateComponent(tree, allocator, .{
    //         .next_sibling = undefined,
    //         .tag = component_tag,
    //         .location = location,
    //         .extra = Extra.make(0),
    //     });
    //     parser.stack.items[parser.stack.items.len - 1].skip += 1;
    // }

    fn pushSimpleBlock(parser: *Parser, tag: Component.Tag, location: Source.Location, in_a_rule: bool) !void {
        if (in_a_rule) {
            switch (parser.stack.items[parser.stack.items.len - 1].data) {
                .at_rule, .qualified_rule => {},
                else => unreachable,
            }
        }

        const component_tag: Component.Tag = switch (tag) {
            .token_left_curly => .simple_block_curly,
            .token_left_bracket => .simple_block_bracket,
            .token_left_paren => .simple_block_paren,
            else => unreachable,
        };
        const index = try parser.allocateComponent(.{
            .next_sibling = undefined,
            .tag = component_tag,
            .location = location,
            .extra = Extra.make(0),
        });
        try parser.stack.append(parser.allocator, .{
            .skip = 1,
            .index = index,
            .data = .{ .simple_block = .{ .tag = component_tag, .in_a_rule = in_a_rule } },
        });
    }

    fn popFrame(parser: *Parser) void {
        const frame = parser.stack.pop();
        assert(frame.data != .simple_block); // Use popSimpleBlock instead
        parser.stack.items[parser.stack.items.len - 1].skip += frame.skip;
        parser.tree.components.items(.next_sibling)[frame.index] = frame.index + frame.skip;
    }

    fn popSimpleBlock(parser: *Parser) void {
        const frame = parser.stack.pop();
        const slice = parser.tree.components.slice();
        slice.items(.next_sibling)[frame.index] = frame.index + frame.skip;

        if (frame.data.simple_block.in_a_rule) {
            const parent_frame = parser.stack.pop();
            switch (parent_frame.data) {
                .at_rule, .qualified_rule => {},
                else => unreachable,
            }
            const combined_skip = parent_frame.skip + frame.skip;
            parser.stack.items[parser.stack.items.len - 1].skip += combined_skip;
            slice.items(.next_sibling)[parent_frame.index] = parent_frame.index + combined_skip;
            slice.items(.extra)[parent_frame.index] = Extra.make(frame.index);
        } else {
            parser.stack.items[parser.stack.items.len - 1].skip += frame.skip;
        }
    }

    fn ignoreQualifiedRule(parser: *Parser) void {
        const frame = parser.stack.pop();
        assert(frame.data == .qualified_rule);
        parser.tree.components.shrinkRetainingCapacity(frame.index);
    }
};

fn loop(parser: *Parser, location: *Source.Location) !void {
    while (parser.stack.items.len > 1) {
        const frame = parser.stack.items[parser.stack.items.len - 1];
        switch (frame.data) {
            .root => unreachable,
            .list_of_rules => try consumeListOfRules(parser, location),
            .list_of_component_values => try consumeListOfComponentValues(parser, location),
            .qualified_rule => try consumeQualifiedRule(parser, location),
            .at_rule => try consumeAtRule(parser, location),
            .simple_block => try consumeSimpleBlock(parser, location),
            .function => try consumeFunction(parser, location),
        }
    }
}

fn consumeListOfRules(parser: *Parser, location: *Source.Location) !void {
    while (true) {
        const saved_location = location.*;
        const tag = parser.source.next(location);
        switch (tag) {
            .token_whitespace => {},
            .token_eof => return parser.popFrame(),
            .token_cdo, .token_cdc => {
                const top_level = parser.stack.items[parser.stack.items.len - 1].data.list_of_rules.top_level;
                if (!top_level) {
                    location.* = saved_location;
                    try parser.pushQualifiedRule(saved_location);
                    return;
                }
            },
            .token_at_keyword => {
                try parser.pushAtRule(saved_location);
                return;
            },
            else => {
                location.* = saved_location;
                try parser.pushQualifiedRule(saved_location);
                return;
            },
        }
    }
}

fn consumeListOfComponentValues(parser: *Parser, location: *Source.Location) !void {
    while (true) {
        const saved_location = location.*;
        const tag = parser.source.next(location);
        switch (tag) {
            .token_eof => return parser.popFrame(),
            else => {
                const must_suspend = try consumeComponentValue(parser, tag, saved_location);
                if (must_suspend) return;
            },
        }
    }
}

fn consumeAtRule(parser: *Parser, location: *Source.Location) !void {
    while (true) {
        const saved_location = location.*;
        const tag = parser.source.next(location);
        switch (tag) {
            .token_semicolon => return parser.popFrame(),
            .token_eof => {
                // NOTE: Parse error
                return parser.popFrame();
            },
            .token_left_curly => {
                try parser.pushSimpleBlock(tag, saved_location, true);
                return;
            },
            .simple_block_curly => {
                // try parser.addSimpleBlock(tag, saved_location);
                // parser.popFrame();
                // return;
                panic("Found a simple block while parsing", .{});
            },
            else => {
                const must_suspend = try consumeComponentValue(parser, tag, saved_location);
                if (must_suspend) return;
            },
        }
    }
}

fn consumeQualifiedRule(parser: *Parser, location: *Source.Location) !void {
    while (true) {
        const saved_location = location.*;
        const tag = parser.source.next(location);
        switch (tag) {
            .token_eof => {
                // NOTE: Parse error
                return parser.ignoreQualifiedRule();
            },
            .token_left_curly => {
                try parser.pushSimpleBlock(tag, saved_location, true);
                return;
            },
            .simple_block_curly => {
                // try parser.addSimpleBlock(tag, saved_location);
                // parser.popFrame();
                // return;
                panic("Found a simple block while parsing", .{});
            },
            else => {
                const must_suspend = try consumeComponentValue(parser, tag, saved_location);
                if (must_suspend) return;
            },
        }
    }
}

fn consumeComponentValue(parser: *Parser, tag: Component.Tag, location: Source.Location) !bool {
    switch (tag) {
        .token_left_curly, .token_left_bracket, .token_left_paren => {
            try parser.pushSimpleBlock(tag, location, false);
            return true;
        },
        .token_function => {
            try parser.pushFunction(location);
            return true;
        },
        .token_delim => {
            const codepoint = parser.source.getDelimeter(location);
            try parser.addComponent(.token_delim, location, Extra.make(codepoint));
            return false;
        },
        else => {
            try parser.addComponent(tag, location, Extra.make(0));
            return false;
        },
    }
}

fn consumeSimpleBlock(parser: *Parser, location: *Source.Location) !void {
    const ending_tag = parser.stack.items[parser.stack.items.len - 1].data.simple_block.endingTokenTag();
    while (true) {
        const saved_location = location.*;
        const tag = parser.source.next(location);
        if (tag == ending_tag) {
            return parser.popSimpleBlock();
        } else if (tag == .token_eof) {
            // NOTE: Parse error
            return parser.popSimpleBlock();
        } else {
            const must_suspend = try consumeComponentValue(parser, tag, saved_location);
            if (must_suspend) return;
        }
    }
}

fn consumeFunction(parser: *Parser, location: *Source.Location) !void {
    while (true) {
        const saved_location = location.*;
        const tag = parser.source.next(location);
        switch (tag) {
            .token_right_paren => return parser.popFrame(),
            .token_eof => {
                // NOTE: Parse error
                return parser.popFrame();
            },
            else => {
                const must_suspend = try consumeComponentValue(parser, tag, saved_location);
                if (must_suspend) return;
            },
        }
    }
}

test "parse a stylesheet" {
    const allocator = std.testing.allocator;
    const input =
        \\@charset "utf-8";
        \\@new-rule {}
        \\
        \\root {
        \\    print(we, can, parse, this!)
        \\}
        \\broken
    ;

    const ascii8ToAscii7 = @import("../../zss.zig").util.ascii8ToAscii7;
    const ascii = ascii8ToAscii7(input);

    const token_source = Source.init(try tokenize.Source.init(ascii));

    var tree = try parseStylesheet(token_source, allocator);
    defer tree.deinit(allocator);

    // zig fmt: off
    const expected = [25]Component{
        .{ .next_sibling = 25, .tag = .rule_list,          .location = .{ .value = 0 },  .extra = Extra.make(0)   },
        .{ .next_sibling = 4,  .tag = .at_rule,            .location = .{ .value = 0 },  .extra = Extra.make(0)   },
        .{ .next_sibling = 3,  .tag = .token_whitespace,   .location = .{ .value = 8 },  .extra = Extra.make(0)   },
        .{ .next_sibling = 4,  .tag = .token_string,       .location = .{ .value = 9 },  .extra = Extra.make(0)   },
        .{ .next_sibling = 7,  .tag = .at_rule,            .location = .{ .value = 18 }, .extra = Extra.make(6)   },
        .{ .next_sibling = 6,  .tag = .token_whitespace,   .location = .{ .value = 27 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 7,  .tag = .simple_block_curly, .location = .{ .value = 28 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 25, .tag = .qualified_rule,     .location = .{ .value = 32 }, .extra = Extra.make(10)  },
        .{ .next_sibling = 9,  .tag = .token_ident,        .location = .{ .value = 32 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 10, .tag = .token_whitespace,   .location = .{ .value = 36 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 25, .tag = .simple_block_curly, .location = .{ .value = 37 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 12, .tag = .token_whitespace,   .location = .{ .value = 38 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 24, .tag = .function,           .location = .{ .value = 43 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 14, .tag = .token_ident,        .location = .{ .value = 49 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 15, .tag = .token_comma,        .location = .{ .value = 51 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 16, .tag = .token_whitespace,   .location = .{ .value = 52 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 17, .tag = .token_ident,        .location = .{ .value = 53 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 18, .tag = .token_comma,        .location = .{ .value = 56 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 19, .tag = .token_whitespace,   .location = .{ .value = 57 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 20, .tag = .token_ident,        .location = .{ .value = 58 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 21, .tag = .token_comma,        .location = .{ .value = 63 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 22, .tag = .token_whitespace,   .location = .{ .value = 64 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 23, .tag = .token_ident,        .location = .{ .value = 65 }, .extra = Extra.make(0)   },
        .{ .next_sibling = 24, .tag = .token_delim,        .location = .{ .value = 69 }, .extra = Extra.make('!') },
        .{ .next_sibling = 25, .tag = .token_whitespace,   .location = .{ .value = 71 }, .extra = Extra.make(0)   },
    };
    // zig fmt: on

    const slice = tree.components.slice();
    if (expected.len != slice.len) return error.TestFailure;
    for (expected, 0..) |ex, i| {
        const actual = slice.get(i);
        try std.testing.expectEqual(ex, actual);
    }
}
