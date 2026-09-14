const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const habush = b.addModule("habush", .{
        .root_source_file = b.path("src/lib/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "habush",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("habush", habush);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const lib_tests = b.addTest(.{
        .root_module = habush,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&exe.step);

    const command_control_test = b.addRunArtifact(exe);
    command_control_test.setName("test cli exit control flow");
    command_control_test.addArgs(&.{ "-c", "false; exit; missing" });
    expectCliResult(command_control_test, test_step, 1, "", "");

    const stream_test = b.addRunArtifact(exe);
    stream_test.setName("test cli standard input");
    stream_test.setStdIn(.{ .bytes = "true\nexit 9\n" });
    expectCliResult(stream_test, test_step, 9, "", "");

    const script_test = b.addRunArtifact(exe);
    script_test.setName("test cli script file");
    script_test.addFileArg(b.path("test/cli/exit.hb"));
    expectCliResult(script_test, test_step, 37, "", "");

    const script_diagnostic_test = b.addRunArtifact(exe);
    script_diagnostic_test.setName("test cli script diagnostic");
    script_diagnostic_test.addFileArg(b.path("test/cli/invalid.hb"));
    script_diagnostic_test.expectExitCode(2);
    script_diagnostic_test.expectStdOutEqual("");
    script_diagnostic_test.expectStdErrMatch(":1:1: expected command, found ')'\n");
    test_step.dependOn(&script_diagnostic_test.step);

    const usage_test = b.addRunArtifact(exe);
    usage_test.setName("test cli invalid arguments");
    usage_test.addArg("--unknown");
    expectCliResult(
        usage_test,
        test_step,
        2,
        "",
        "habush: usage: habush [-c command | script]\n",
    );
}

fn expectCliResult(
    run: *std.Build.Step.Run,
    test_step: *std.Build.Step,
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
) void {
    run.expectExitCode(exit_code);
    run.expectStdOutEqual(stdout);
    run.expectStdErrEqual(stderr);
    test_step.dependOn(&run.step);
}
