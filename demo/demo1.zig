const std = @import("std");
const fs = std.fs;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const zss = @import("zss");
const box_tree = zss.box_tree;
const pixelToCSSUnit = zss.sdl_freetype.pixelToCSSUnit;

const sdl = @import("SDL2");
const ft = @import("freetype");
const hb = @import("harfbuzz");

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(!gpa.deinit());
    var allocator = &gpa.allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 2) {
        std.debug.print("error: Expected 2 arguments", .{});
        return 1;
    }
    const filename = args[1];
    const bytes = blk: {
        const file = try fs.cwd().openFile(filename, .{});
        defer file.close();
        break :blk try file.readToEndAlloc(allocator, std.math.maxInt(c_int));
    };
    defer allocator.free(bytes);

    assert(sdl.SDL_Init(sdl.SDL_INIT_VIDEO) == 0);
    defer sdl.SDL_Quit();

    const width = 800;
    const height = 600;
    const window = sdl.SDL_CreateWindow(
        "An SDL Window.",
        sdl.SDL_WINDOWPOS_CENTERED_MASK,
        sdl.SDL_WINDOWPOS_CENTERED_MASK,
        width,
        height,
        sdl.SDL_WINDOW_SHOWN | sdl.SDL_WINDOW_RESIZABLE,
    ) orelse unreachable;
    defer sdl.SDL_DestroyWindow(window);

    const dpi = blk: {
        var horizontal: f32 = 0;
        var vertical: f32 = 0;
        if (sdl.SDL_GetDisplayDPI(0, null, &horizontal, &vertical) != 0) {
            horizontal = 96;
            vertical = 96;
        }
        break :blk .{ .horizontal = @floatToInt(hb.FT_UInt, horizontal), .vertical = @floatToInt(hb.FT_UInt, vertical) };
    };

    var library: hb.FT_Library = undefined;
    assert(hb.FT_Init_FreeType(&library) == hb.FT_Err_Ok);
    defer assert(hb.FT_Done_FreeType(library) == hb.FT_Err_Ok);

    var face: hb.FT_Face = undefined;
    assert(hb.FT_New_Face(library, "test/fonts/NotoSans-Regular.ttf", 0, &face) == hb.FT_Err_Ok);
    defer assert(hb.FT_Done_Face(face) == hb.FT_Err_Ok);

    const font_height_pt = 12;
    assert(hb.FT_Set_Char_Size(face, 0, font_height_pt * 64, dpi.horizontal, dpi.vertical) == hb.FT_Err_Ok);

    try createBoxTree(window, face, allocator, filename, bytes);
    return 0;
}

fn createBoxTree(window: *sdl.SDL_Window, face: ft.FT_Face, allocator: *Allocator, filename: []const u8, bytes: []const u8) !void {
    var width: c_int = undefined;
    var height: c_int = undefined;
    sdl.SDL_GetWindowSize(window, &width, &height);

    const font = hb.hb_ft_font_create_referenced(face) orelse unreachable;
    defer hb.hb_font_destroy(font);
    hb.hb_ft_font_set_funcs(font);

    const len = 5;
    var pdfs_flat_tree = [len]u16{ 5, 2, 1, 2, 1 };
    var inline_size = [1]box_tree.LogicalSize{.{}} ** len;
    var block_size = [len]box_tree.LogicalSize{ .{}, .{ .margin_end = .{ .px = 20 } }, .{}, .{}, .{} };
    var display = [len]box_tree.Display{ .{ .block_flow_root = {} }, .{ .block_flow = {} }, .{ .text = {} }, .{ .block_flow = {} }, .{ .text = {} } };
    var latin1_text = [len]box_tree.Latin1Text{ .{ .text = "" }, .{ .text = "" }, .{ .text = filename }, .{ .text = "" }, .{ .text = bytes } };
    var border = [1]box_tree.Border{.{}} ** len;
    var background = [1]box_tree.Background{.{}} ** len;
    var tree = box_tree.BoxTree{
        .pdfs_flat_tree = &pdfs_flat_tree,
        .inline_size = &inline_size,
        .block_size = &block_size,
        .display = &display,
        .latin1_text = &latin1_text,
        .border = &border,
        .background = &background,
        .font = .{ .font = font },
    };

    try sdlMainLoop(window, face, allocator, &tree);
}

fn sdlMainLoop(window: *sdl.SDL_Window, face: ft.FT_Face, allocator: *Allocator, tree: *box_tree.BoxTree) !void {
    var width: c_int = undefined;
    var height: c_int = undefined;
    sdl.SDL_GetWindowSize(window, &width, &height);

    const pixel_format = sdl.SDL_AllocFormat(sdl.SDL_PIXELFORMAT_RGBA32) orelse unreachable;
    defer sdl.SDL_FreeFormat(pixel_format);

    const renderer = sdl.SDL_CreateRenderer(
        window,
        -1,
        sdl.SDL_RENDERER_ACCELERATED | sdl.SDL_RENDERER_PRESENTVSYNC,
    ) orelse unreachable;
    defer sdl.SDL_DestroyRenderer(renderer);
    assert(sdl.SDL_SetRenderDrawBlendMode(renderer, sdl.SDL_BlendMode.SDL_BLENDMODE_BLEND) == 0);

    var data: zss.used_values.BlockRenderingData = blk: {
        var context = try zss.layout.BlockLayoutContext.init(tree, allocator, 0, pixelToCSSUnit(width), pixelToCSSUnit(height));
        defer context.deinit();
        break :blk try zss.layout.createBlockRenderingData(&context, allocator);
    };
    defer data.deinit(allocator);
    var atlas = try zss.sdl_freetype.GlyphAtlas.init(face, renderer, pixel_format, allocator);
    defer atlas.deinit(allocator);
    var needs_relayout = false;

    var event: sdl.SDL_Event = undefined;
    mainLoop: while (true) {
        while (sdl.SDL_PollEvent(&event) != 0) {
            switch (@intToEnum(sdl.SDL_EventType, @intCast(c_int, event.@"type"))) {
                .SDL_WINDOWEVENT => {
                    switch (@intToEnum(sdl.SDL_WindowEventID, event.window.event)) {
                        .SDL_WINDOWEVENT_SIZE_CHANGED => {
                            width = event.window.data1;
                            height = event.window.data2;
                            tree.inline_size[0].size = .{ .px = @intToFloat(f32, width) };
                            tree.block_size[0].size = .{ .px = @intToFloat(f32, height) };
                            needs_relayout = true;
                        },
                        .SDL_WINDOWEVENT_CLOSE => {
                            break :mainLoop;
                        },
                        else => {},
                    }
                },
                .SDL_QUIT => {
                    break :mainLoop;
                },
                else => {},
            }
        }

        if (needs_relayout) {
            needs_relayout = false;

            var context = try zss.layout.BlockLayoutContext.init(tree, allocator, 0, pixelToCSSUnit(width), pixelToCSSUnit(height));
            defer context.deinit();
            var new_data = try zss.layout.createBlockRenderingData(&context, allocator);
            data.deinit(allocator);
            data = new_data;
        }

        {
            assert(sdl.SDL_RenderClear(renderer) == 0);

            const css_viewport_rect = zss.used_values.CSSRect{
                .x = 0,
                .y = 0,
                .w = pixelToCSSUnit(width),
                .h = pixelToCSSUnit(height),
            };
            const offset = zss.used_values.Offset{
                .x = 0,
                .y = 0,
            };
            zss.sdl_freetype.drawBlockDataRoot(&data, offset, css_viewport_rect, renderer, pixel_format);
            try zss.sdl_freetype.drawBlockDataChildren(&data, allocator, offset, css_viewport_rect, renderer, pixel_format);

            for (data.inline_data) |inline_data| {
                var o = offset;
                var it = zss.util.PdfsFlatTreeIterator.init(data.pdfs_flat_tree, inline_data.id_of_containing_block);
                while (it.next()) |id| {
                    o = o.add(data.box_offsets[id].content_top_left);
                }
                try zss.sdl_freetype.drawInlineData(inline_data.data, o, renderer, pixel_format, &atlas);
            }
        }

        sdl.SDL_RenderPresent(renderer);
    }
}
