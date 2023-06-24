const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const syntax = @import("./syntax.zig");
const Component = syntax.Component;
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

    pub fn matchDelimeter(source: *Source, codepoint: u21) bool {
        return source.inner.matchDelimeter(codepoint);
    }

    pub fn matchKeyword(source: *Source, keyword: []const u7) bool {
        return source.inner.matchKeyword(keyword);
    }

    pub fn readIdentToken(source: Source, loc: Location, list: *ArrayList(u21)) !void {
        try source.inner.readIdentToken(loc, list);
    }
};

pub fn parseStylesheet(source: Source, allocator: Allocator) !ComponentTree {
    var stack = try Stack.init(allocator);
    defer stack.deinit(allocator);

    var tree = ComponentTree{ .components = .{} };
    errdefer tree.deinit(allocator);

    var location = Source.Location{};

    try stack.pushListOfRules(&tree, location, true, allocator);
    try loop(&stack, &tree, source, &location, allocator);
    return tree;
}

const Stack = struct {
    list: ArrayListUnmanaged(Frame),

    const Frame = struct {
        skip: ComponentTree.Size,
        index: ComponentTree.Size,
        data: Data,

        const Data = union(enum) {
            root,
            list_of_rules: ListOfRules,
            qualified_rule,
            at_rule,
            simple_block: SimpleBlock,
            function,
        };
    };

    const ListOfRules = struct {
        top_level: bool,
    };

    const SimpleBlock = struct {
        tag: Component.Tag,
        // true if the simple block is part of a qualified rule or an at rule.
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

    fn init(allocator: Allocator) !Stack {
        var stack = Stack{ .list = .{} };
        try stack.list.append(allocator, .{ .skip = 0, .index = undefined, .data = .root });
        return stack;
    }

    fn deinit(stack: *Stack, allocator: Allocator) void {
        stack.list.deinit(allocator);
    }

    fn last(stack: *Stack) *Frame {
        return &stack.list.items[stack.list.items.len - 1];
    }

    fn addComponent(tree: *ComponentTree, allocator: Allocator, component: Component) !ComponentTree.Size {
        if (tree.components.len == std.math.maxInt(ComponentTree.Size)) return error.Overflow;
        const index = @intCast(ComponentTree.Size, tree.components.len);
        try tree.components.append(allocator, component);
        return index;
    }

    fn addToken(stack: *Stack, tree: *ComponentTree, tag: Component.Tag, location: Source.Location, allocator: Allocator) !void {
        _ = try addComponent(tree, allocator, .{ .skip = 1, .tag = tag, .location = location, .extra = 0 });
        stack.last().skip += 1;
    }

    fn pushListOfRules(stack: *Stack, tree: *ComponentTree, location: Source.Location, top_level: bool, allocator: Allocator) !void {
        const index = try addComponent(tree, allocator, .{ .skip = undefined, .tag = .rule_list, .location = location, .extra = 0 });
        try stack.list.append(allocator, .{ .skip = 1, .index = index, .data = .{ .list_of_rules = .{ .top_level = top_level } } });
    }

    fn pushAtRule(stack: *Stack, tree: *ComponentTree, location: Source.Location, allocator: Allocator) !void {
        const index = try addComponent(tree, allocator, .{ .skip = undefined, .tag = .at_rule, .location = location, .extra = 0 });
        try stack.list.append(allocator, .{ .skip = 1, .index = index, .data = .at_rule });
    }

    fn pushQualifiedRule(stack: *Stack, tree: *ComponentTree, location: Source.Location, allocator: Allocator) !void {
        const index = try addComponent(tree, allocator, .{ .skip = undefined, .tag = .qualified_rule, .location = location, .extra = 0 });
        try stack.list.append(allocator, .{ .skip = 1, .index = index, .data = .qualified_rule });
    }

    fn pushFunction(stack: *Stack, tree: *ComponentTree, location: Source.Location, allocator: Allocator) !void {
        const index = try addComponent(tree, allocator, .{ .skip = undefined, .tag = .function, .location = location, .extra = 0 });
        try stack.list.append(allocator, .{ .skip = 1, .index = index, .data = .function });
    }

    fn addSimpleBlock(stack: *Stack, tree: *ComponentTree, tag: Component.Tag, location: Source.Location, allocator: Allocator) !void {
        const component_tag: Component.Tag = switch (tag) {
            .token_left_curly => .simple_block_curly,
            .token_left_bracket => .simple_block_bracket,
            .token_left_paren => .simple_block_paren,
            else => unreachable,
        };
        _ = try addComponent(tree, allocator, .{ .skip = undefined, .tag = component_tag, .location = location, .extra = 0 });
        stack.last().skip += 1;
    }

    fn pushSimpleBlock(stack: *Stack, tree: *ComponentTree, tag: Component.Tag, location: Source.Location, in_a_rule: bool, allocator: Allocator) !void {
        if (in_a_rule) {
            switch (stack.last().data) {
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
        const index = try addComponent(tree, allocator, .{ .skip = undefined, .tag = component_tag, .location = location, .extra = 0 });
        try stack.list.append(allocator, .{
            .skip = 1,
            .index = index,
            .data = .{ .simple_block = .{ .tag = component_tag, .in_a_rule = in_a_rule } },
        });
    }

    fn popFrame(stack: *Stack, tree: *ComponentTree) void {
        const frame = stack.list.pop();
        assert(frame.data != .simple_block); // Use popSimpleBlock instead
        stack.last().skip += frame.skip;
        tree.components.items(.skip)[frame.index] = frame.skip;
    }

    fn popSimpleBlock(stack: *Stack, tree: *ComponentTree) void {
        const frame = stack.list.pop();
        const slice = tree.components.slice();
        slice.items(.skip)[frame.index] = frame.skip;

        if (frame.data.simple_block.in_a_rule) {
            const parent_frame = stack.list.pop();
            switch (parent_frame.data) {
                .at_rule, .qualified_rule => {},
                else => unreachable,
            }
            const combined_skip = parent_frame.skip + frame.skip;
            stack.last().skip += combined_skip;
            slice.items(.skip)[parent_frame.index] = combined_skip;
            slice.items(.extra)[parent_frame.index] = frame.index - parent_frame.index;
        } else {
            stack.last().skip += frame.skip;
        }
    }

    fn ignoreQualifiedRule(stack: *Stack, tree: *ComponentTree) void {
        const frame = stack.list.pop();
        assert(frame.data == .qualified_rule);
        tree.components.shrinkRetainingCapacity(frame.index);
    }
};

fn loop(stack: *Stack, tree: *ComponentTree, source: Source, location: *Source.Location, allocator: Allocator) !void {
    while (stack.list.items.len > 1) {
        const frame = stack.last().*;
        switch (frame.data) {
            .root => unreachable,
            .list_of_rules => try consumeListOfRules(stack, tree, source, location, allocator),
            .qualified_rule => try consumeQualifiedRule(stack, tree, source, location, allocator),
            .at_rule => try consumeAtRule(stack, tree, source, location, allocator),
            .simple_block => try consumeSimpleBlock(stack, tree, source, location, allocator),
            .function => try consumeFunction(stack, tree, source, location, allocator),
        }
    }
}

fn consumeListOfRules(stack: *Stack, tree: *ComponentTree, source: Source, location: *Source.Location, allocator: Allocator) !void {
    while (true) {
        const saved_location = location.*;
        const tag = source.next(location);
        switch (tag) {
            .token_whitespace => {},
            .token_eof => return stack.popFrame(tree),
            .token_cdo, .token_cdc => {
                const top_level = stack.last().data.list_of_rules.top_level;
                if (!top_level) {
                    location.* = saved_location;
                    try stack.pushQualifiedRule(tree, saved_location, allocator);
                    return;
                }
            },
            .token_at_keyword => {
                try stack.pushAtRule(tree, saved_location, allocator);
                return;
            },
            else => {
                location.* = saved_location;
                try stack.pushQualifiedRule(tree, saved_location, allocator);
                return;
            },
        }
    }
}

fn consumeAtRule(stack: *Stack, tree: *ComponentTree, source: Source, location: *Source.Location, allocator: Allocator) !void {
    while (true) {
        const saved_location = location.*;
        const tag = source.next(location);
        switch (tag) {
            .token_semicolon => return stack.popFrame(tree),
            .token_eof => {
                // NOTE: Parse error
                return stack.popFrame(tree);
            },
            .token_left_curly => {
                try stack.pushSimpleBlock(tree, tag, saved_location, true, allocator);
                return;
            },
            .simple_block_curly => {
                try stack.addSimpleBlock(tree, tag, saved_location, allocator);
                stack.popFrame(tree);
                return;
            },
            else => {
                const must_suspend = try consumeComponentValue(stack, tree, tag, saved_location, allocator);
                if (must_suspend) return;
            },
        }
    }
}

fn consumeQualifiedRule(stack: *Stack, tree: *ComponentTree, source: Source, location: *Source.Location, allocator: Allocator) !void {
    while (true) {
        const saved_location = location.*;
        const tag = source.next(location);
        switch (tag) {
            .token_eof => {
                // NOTE: Parse error
                return stack.ignoreQualifiedRule(tree);
            },
            .token_left_curly => {
                try stack.pushSimpleBlock(tree, tag, saved_location, true, allocator);
                return;
            },
            .simple_block_curly => {
                try stack.addSimpleBlock(tree, tag, saved_location, allocator);
                stack.popFrame(tree);
                return;
            },
            else => {
                const must_suspend = try consumeComponentValue(stack, tree, tag, saved_location, allocator);
                if (must_suspend) return;
            },
        }
    }
}

fn consumeComponentValue(stack: *Stack, tree: *ComponentTree, tag: Component.Tag, location: Source.Location, allocator: Allocator) !bool {
    switch (tag) {
        .token_left_curly, .token_left_bracket, .token_left_paren => {
            try stack.pushSimpleBlock(tree, tag, location, false, allocator);
            return true;
        },
        .token_function => {
            try stack.pushFunction(tree, location, allocator);
            return true;
        },
        else => {
            try stack.addToken(tree, tag, location, allocator);
            return false;
        },
    }
}

fn consumeSimpleBlock(stack: *Stack, tree: *ComponentTree, source: Source, location: *Source.Location, allocator: Allocator) !void {
    const ending_tag = stack.last().data.simple_block.endingTokenTag();
    while (true) {
        const saved_location = location.*;
        const tag = source.next(location);
        if (tag == ending_tag) {
            return stack.popSimpleBlock(tree);
        } else if (tag == .token_eof) {
            // NOTE: Parse error
            return stack.popSimpleBlock(tree);
        } else {
            const must_suspend = try consumeComponentValue(stack, tree, tag, saved_location, allocator);
            if (must_suspend) return;
        }
    }
}

fn consumeFunction(stack: *Stack, tree: *ComponentTree, source: Source, location: *Source.Location, allocator: Allocator) !void {
    while (true) {
        const saved_location = location.*;
        const tag = source.next(location);
        switch (tag) {
            .token_right_paren => return stack.popFrame(tree),
            .token_eof => {
                // NOTE: Parse error
                return stack.popFrame(tree);
            },
            else => {
                const must_suspend = try consumeComponentValue(stack, tree, tag, saved_location, allocator);
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

    const asciiString = @import("../../zss.zig").util.asciiString;
    const ascii = asciiString(input);

    const token_source = Source.init(try tokenize.Source.init(ascii));

    var tree = try parseStylesheet(token_source, allocator);
    defer tree.deinit(allocator);

    // zig fmt: off
    const expected = [25]Component{
        .{ .skip = 25, .tag = .rule_list,          .location = .{ .value = 0 },  .extra = 0 },
        .{ .skip = 3,  .tag = .at_rule,            .location = .{ .value = 0 },  .extra = 0 },
        .{ .skip = 1,  .tag = .token_whitespace,   .location = .{ .value = 8 },  .extra = 0 },
        .{ .skip = 1,  .tag = .token_string,       .location = .{ .value = 9 },  .extra = 0 },
        .{ .skip = 3,  .tag = .at_rule,            .location = .{ .value = 18 }, .extra = 2 },
        .{ .skip = 1,  .tag = .token_whitespace,   .location = .{ .value = 27 }, .extra = 0 },
        .{ .skip = 1,  .tag = .simple_block_curly, .location = .{ .value = 28 }, .extra = 0 },
        .{ .skip = 18, .tag = .qualified_rule,     .location = .{ .value = 32 }, .extra = 3 },
        .{ .skip = 1,  .tag = .token_ident,        .location = .{ .value = 32 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_whitespace,   .location = .{ .value = 36 }, .extra = 0 },
        .{ .skip = 15, .tag = .simple_block_curly, .location = .{ .value = 37 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_whitespace,   .location = .{ .value = 38 }, .extra = 0 },
        .{ .skip = 12, .tag = .function,           .location = .{ .value = 43 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_ident,        .location = .{ .value = 49 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_comma,        .location = .{ .value = 51 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_whitespace,   .location = .{ .value = 52 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_ident,        .location = .{ .value = 53 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_comma,        .location = .{ .value = 56 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_whitespace,   .location = .{ .value = 57 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_ident,        .location = .{ .value = 58 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_comma,        .location = .{ .value = 63 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_whitespace,   .location = .{ .value = 64 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_ident,        .location = .{ .value = 65 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_delim,        .location = .{ .value = 69 }, .extra = 0 },
        .{ .skip = 1,  .tag = .token_whitespace,   .location = .{ .value = 71 }, .extra = 0 },
    };
    // zig fmt: on

    const slice = tree.components.slice();
    if (expected.len != slice.len) return error.TestFailure;
    for (expected, 0..) |ex, i| {
        const actual = slice.get(i);
        try std.testing.expectEqual(ex, actual);
    }
}
