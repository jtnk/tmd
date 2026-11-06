const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = b.option([]const u8, "version", "Version string") orelse "0.2.0";
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    // Symbols for profiling a release build: `zig build --release=small -Dstrip=false`.
    const strip = b.option(bool, "strip", "Strip the binary") orelse (optimize != .debug);
    const exe_mod = module(b, "src/main.zig", target, optimize, optimize, strip);
    addDecoders(b, exe_mod);
    exe_mod.addOptions("build_options", options);
    // Laying a document out is nearly all of what a user waits for, and is a sliver of the binary,
    // so it alone is built for speed: that costs about 6KB, where the whole binary would cost 225KB.
    const layout_optimize: std.builtin.OptimizeMode = if (optimize == .small) .fast else optimize;
    exe_mod.addImport("layout", module(b, "src/layout.zig", target, layout_optimize, optimize, strip));
    const exe = b.addExecutable(.{ .name = "tmd", .root_module = exe_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run tmd").dependOn(&run.step);

    // The test binary links the whole Ghostty terminal emulator, which the shipped binary doesn't:
    // tests push tmd's real output through it and assert on the resulting screen.
    const test_mod = module(b, "src/test.zig", target, .debug, .debug, false);
    addDecoders(b, test_mod);
    test_mod.addImport("layout", module(b, "src/layout.zig", target, .debug, .debug, false));
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
    const test_step = b.step("test", "Run unit and terminal tests");
    test_step.dependOn(&run_tests.step);

    // A test binary only runs the tests of its root module, so layout has one of its own.
    const layout_test_mod = module(b, "src/layout.zig", target, .debug, .debug, false);
    addDecoders(b, layout_test_mod);
    const run_layout_tests = b.addRunArtifact(b.addTest(.{ .root_module = layout_test_mod }));
    run_layout_tests.has_side_effects = true;
    test_step.dependOn(&run_layout_tests.step);
}

fn module(
    b: *std.Build,
    root: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    // Every module of a binary has to share one Ghostty, or it's linked twice.
    ghostty_optimize: std.builtin.OptimizeMode,
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
    if (b.lazyDependency("ghostty", .{ .simd = false, .target = target, .optimize = ghostty_optimize })) |dep| {
        m.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }
    return m;
}

/// Once per binary, in its root module.
fn addDecoders(b: *std.Build, m: *std.Build.Module) void {
    m.addIncludePath(b.path("vendor"));
    m.addCSourceFile(.{ .file = b.path("vendor/decoders.c"), .flags = &.{ "-std=c99", "-fno-sanitize=undefined" } });
}
