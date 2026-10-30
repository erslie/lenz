const std = @import("std");

pub const Board = enum { virt, pi5 };

pub fn build(b: *std.Build) void {
    const board = b.option(Board, "board", "target board (virt / pi5)") orelse .virt;
    const strict_align = b.option(bool, "strict_align", "Prevent the issuance of out-of-bounds memory access instructions (default: true)") orelse true;
    const optimize = b.standardOptimizeOption(.{});

    var sub = std.Target.Cpu.Feature.Set.empty;
    sub.addFeature(@intFromEnum(std.Target.aarch64.Feature.neon));
    sub.addFeature(@intFromEnum(std.Target.aarch64.Feature.fp_armv8));
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{
            .explicit = switch (board) {
                //qemu
                .virt => &std.Target.aarch64.cpu.cortex_a72,
                //pi5
                .pi5 => &std.Target.aarch64.cpu.cortex_a76,
            },
        },
        .cpu_features_sub = sub,
        .cpu_features_add = if (strict_align) std.Target.aarch64.featureSet(&.{.strict_align}) else .empty,
    });

    const opts = b.addOptions();
    opts.addOption(Board, "board", board);

    const base: []const u8 = switch (board) {
        .virt => "0x40080000",
        .pi5 => "0x80000",
    };
    const wf = b.addWriteFiles();
    const ld = wf.add("linker.ld", b.fmt(@embedFile("linker.ld.in"), .{base}));

    const kmod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .small,
        .red_zone = false,
        .omit_frame_pointer = false,
        .pic = false,
    });
    kmod.addOptions("build_options", opts);
    const kernel = b.addExecutable(.{ .name = "lenz.elf", .root_module = kmod });
    kernel.setLinkerScript(ld);

    // Remove functions and data that are unreachable by the entry point or exported symbols.
    kernel.link_gc_sections = true;

    b.installArtifact(kernel);

    //pi5's firmware reads raw binaries rather than ELF.
    const img = "kernel_2712.img";
    const bin = kernel.addObjCopy(.{ .format = .bin, .basename = img });
    b.getInstallStep().dependOn(&b.addInstallBinFile(bin.getOutput(), img).step);

    //zig build run : QEMU virt
    const qemu = b.addSystemCommand(&.{
        "qemu-system-aarch64",
        "-M",
        "virt,gic-version=2,virtualization=on",
        "-cpu",
        "cortex-a72",
        "-m",
        "512M",
        "-nographic",
        "-kernel",
    });
    qemu.addArtifactArg(kernel);
    if (b.args) |args| qemu.addArgs(args);
    const run = b.step("run", "Booting with QEMU");
    run.dependOn(&qemu.step);
}
