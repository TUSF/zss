const std = @import("std");
const Allocator = std.mem.Allocator;

const zss = @import("zss.zig");
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;
const Images = zss.Images;

const normal = @import("layout/normal.zig");
const cosmetic = @import("layout/cosmetic.zig");
const StyleComputer = @import("layout/StyleComputer.zig");
const StackingContexts = @import("layout/StackingContexts.zig");

const used_values = zss.used_values;
const BoxTree = used_values.BoxTree;
const GeneratedBox = used_values.GeneratedBox;
const ZssSize = used_values.ZssSize;

pub const Error = error{
    InvalidValue,
    OutOfMemory,
    OutOfRefs,
    TooManyBlockSubtrees,
    TooManyBlocks,
    TooManyIfcs,
    TooManyInlineBoxes,
};

pub const ViewportSize = struct {
    width: u32,
    height: u32,
};

pub fn doLayout(
    element_tree_slice: ElementTree.Slice,
    root: Element,
    images: Images.Slice,
    allocator: Allocator,
    /// The size of the viewport in ZssUnits.
    viewport_size: ZssSize,
) Error!BoxTree {
    var computer = StyleComputer{
        .root_element = root,
        .element_tree_slice = element_tree_slice,
        // TODO: Store viewport_size in a LayoutInputs struct instead of the StyleComputer
        .viewport_size = viewport_size,
        .stage = undefined,
        .allocator = allocator,
    };
    defer computer.deinit();

    var box_tree = BoxTree{
        .allocator = allocator,
    };
    errdefer box_tree.deinit();

    try boxGeneration(&computer, &box_tree, allocator);
    try cosmeticLayout(&computer, &box_tree, images);

    return box_tree;
}

fn boxGeneration(computer: *StyleComputer, box_tree: *BoxTree, allocator: Allocator) !void {
    computer.stage = .{ .box_gen = .{} };
    defer computer.deinitStage(.box_gen);

    var layout = normal.BlockLayoutContext{ .allocator = allocator };
    defer layout.deinit();

    var sc = StackingContexts{ .allocator = allocator };
    defer sc.deinit();

    try normal.createAndPushInitialContainingBlock(&layout, computer, box_tree);
    try normal.mainLoop(&layout, &sc, computer, box_tree);

    computer.assertEmptyStage(.box_gen);
}

fn cosmeticLayout(computer: *StyleComputer, box_tree: *BoxTree, images: Images.Slice) !void {
    computer.stage = .{ .cosmetic = .{} };
    defer computer.deinitStage(.cosmetic);

    try cosmetic.run(computer, box_tree, images);

    computer.assertEmptyStage(.cosmetic);
}
