const std = @import("std");

pub const Board = enum { virt, pi5 };

const syms_size: usize = 256 * 1024;

pub fn build(b: *std.Build) void {
    const board = b.option(Board, "board", "target board (virt / pi5)") orelse .virt;
    const semihosting = b.option(bool, "semihosting", "Terminate QEMU in the event of a panic (virt only)") orelse (board == .virt);
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
    opts.addOption(bool, "semihosting", semihosting);
    opts.addOption(usize, "syms_size", syms_size);

    const base: []const u8 = switch (board) {
        .virt => "0x40080000",
        .pi5 => "0x80000",
    };
    const wf = b.addWriteFiles();
    const ld = wf.add("linker.ld", b.fmt(@embedFile("linker.ld.in"), .{base}));

    const pass1 = addKernel(b, "lenz-pass1.elf", target, optimize, opts, ld, emptyFile(b, wf));

    const symgen = b.addExecutable(.{
        .name = "symgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/symgen.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const gen = b.addRunArtifact(symgen);
    gen.addArg("gen");
    gen.addArtifactArg(pass1);
    const syms_bin = gen.addOutputFileArg("syms.bin");
    gen.addArg(b.fmt("{d}", .{syms_size}));

    const kernel = addKernel(b, "lenz.elf", target, optimize, opts, ld, syms_bin);

    const verify = b.addRunArtifact(symgen);
    verify.addArg("verify");
    verify.addArtifactArg(pass1);
    verify.addArtifactArg(kernel);
    verify.expectExitCode(0);

    const install_elf = b.addInstallArtifact(kernel, .{});
    install_elf.step.dependOn(&verify.step);
    b.getInstallStep().dependOn(&install_elf.step);

    //The Pi5 firmware reads raw binaries rather than ELF files.
    const bin = kernel.addObjCopy(.{ .format = .bin, .basename = "kernel_2712.img" });
    const install_bin = b.addInstallBinFile(bin.getOutput(), "kernel_2712.img");
    install_bin.step.dependOn(&verify.step);
    b.getInstallStep().dependOn(&install_bin.step);

    const qemu = b.addSystemCommand(&.{
        "qemu-system-aarch64",
        "-M",
        "virt,gic-version=2,virtualization=on",
        "-cpu",
        "cortex-a72",
        "-m",
        "512M",
        "-nographic",
        "-semihosting-config",
        "enable=on,target=native",
        "-kernel",
    });
    qemu.addArtifactArg(kernel);
    qemu.step.dependOn(&verify.step);
    if (b.args) |args| qemu.addArgs(args);
    const run = b.step("run", "booting on QEMU");
    run.dependOn(&qemu.step);
}

fn emptyFile(b: *std.Build, wf: *std.Build.Step.WriteFile) std.Build.LazyPath {
    const zeros = b.allocator.alloc(u8, syms_size) catch @panic("OOM");
    @memset(zeros, 0);
    return wf.add("syms-zero.bin", zeros);
}

fn addKernel(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    opts: *std.Build.Step.Options,
    ld: std.Build.LazyPath,
    syms: std.Build.LazyPath,
) *std.Build.Step.Compile {
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
    kmod.addAnonymousImport("syms", .{ .root_source_file = syms });
    const k = b.addExecutable(.{ .name = name, .root_module = kmod });
    k.setLinkerScript(ld);
    k.link_gc_sections = true;
    return k;
}
