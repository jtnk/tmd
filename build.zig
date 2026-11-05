const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = b.option([]const u8, "version", "Version string") orelse "0.1.0";
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    // Symbols for profiling a release build: `zig build --release=small -Dstrip=false`.
    const strip = b.option(bool, "strip", "Strip the binary") orelse (optimize != .debug);
    const exe_mod = module(b, "src/main.zig", target, optimize, strip);
    exe_mod.addOptions("build_options", options);
    const exe = b.addExecutable(.{ .name = "tmd", .root_module = exe_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run tmd").dependOn(&run.step);

    // The test binary links the whole Ghostty terminal emulator, which the shipped binary doesn't:
    // tests push tmd's real output through it and assert on the resulting screen.
    const test_mod = module(b, "src/test.zig", target, .debug, false);
    const test_options = b.addOptions();
    test_options.addOption([]const u8, "version", version);
    // A font for heading tests, so they don't depend on what this machine has installed.
    if (b.lazyDependency("ghostty", .{ .simd = false, .target = target, .optimize = optimize })) |dep| {
        test_options.addOptionPath("test_font", dep.path("src/font/res/JetBrainsMonoNerdFont-Bold.ttf"));
    }
    test_mod.addOptions("build_options", test_options);
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    run_tests.has_side_effects = true; // never skip them as cached
    b.step("test", "Run unit and terminal tests").dependOn(&run_tests.step);
}

fn module(
    b: *std.Build,
    root: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: bool,
) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = true,
    });
    // simd = false keeps Ghostty's C++ dependencies out of the binary.
    if (b.lazyDependency("ghostty", .{ .simd = false, .target = target, .optimize = optimize })) |dep| {
        m.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }
    m.addIncludePath(b.path("vendor"));
    m.addCSourceFile(.{ .file = b.path("vendor/decoders.c"), .flags = &.{ "-std=c99", "-fno-sanitize=undefined" } });
    return m;
}
