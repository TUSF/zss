const testing = @import("zss").testing;
const Test = testing.Test;
const TestInfo = testing.TestInfo;

pub const name = "shrink to fit";

pub const tests = [_]TestInfo{
    .{ "inline block", inlineBlock },
    .{ "inline block text", inlineBlockText },
};

fn inlineBlock(t: *Test) void {
    const root = t.createRoot();
    const inline_block = t.appendChild(root);

    t.set(.box_style, inline_block, .{ .display = .inline_block });
}

fn inlineBlockText(t: *Test) void {
    const root = t.createRoot();
    const inline_block = t.appendChild(root);
    const text = t.appendChild(inline_block);

    t.set(.box_style, inline_block, .{ .display = .inline_block });
    t.set(.box_style, text, .{ .display = .text });
}
