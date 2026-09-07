const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "runningman",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);

    const garmin_fit = b.addExecutable(.{
        .name = "garmin-fit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/garmin_fit_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const install_garmin_fit = b.addInstallArtifact(garmin_fit, .{});
    b.getInstallStep().dependOn(&install_garmin_fit.step);

    const garmin_fit_step = b.step("garmin-fit", "Build the Garmin FIT summary reader");
    garmin_fit_step.dependOn(&install_garmin_fit.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run runningman");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const garmin_fit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/garmin_fit.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(garmin_fit_tests).step);

    const smoke = b.addSystemCommand(&.{ "sh", "tests/cli.sh" });
    smoke.addFileArg(exe.getEmittedBin());
    test_step.dependOn(&smoke.step);
}
