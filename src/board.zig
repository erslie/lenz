const build_options = @import("build_options");
pub const current = switch (build_options.board) {
    .virt => @import("board/virt.zig"),
    .pi5 => @import("board/pi5.zig"),
};
