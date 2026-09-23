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

    const incomplete_heredoc_test = b.addRunArtifact(exe);
    incomplete_heredoc_test.setName("test cli incomplete here-document");
    incomplete_heredoc_test.addArgs(&.{ "-c", ": <<EOF\nbody\n" });
    expectCliResult(
        incomplete_heredoc_test,
        test_step,
        2,
        "",
        "habush: incomplete here-document\n",
    );

    const script_test = b.addRunArtifact(exe);
    script_test.setName("test cli script file");
    script_test.addFileArg(b.path("test/cli/exit.hb"));
    expectCliResult(script_test, test_step, 37, "", "");

    const script_arguments_test = b.addRunArtifact(exe);
    script_arguments_test.setName("test cli script positional arguments");
    script_arguments_test.addFileArg(b.path("test/cli/for-arguments.hb"));
    script_arguments_test.addArgs(&.{ "true", "false" });
    expectCliResult(script_arguments_test, test_step, 1, "", "");

    const function_test = b.addRunArtifact(exe);
    function_test.setName("test cli shell function");
    function_test.addFileArg(b.path("test/cli/function.hb"));
    expectCliResult(function_test, test_step, 23, "", "");

    const word_expansion_test = b.addRunArtifact(exe);
    word_expansion_test.setName("test cli word expansion");
    word_expansion_test.addFileArg(b.path("test/cli/word-expansion.hb"));
    expectCliResult(word_expansion_test, test_step, 23, "", "");

    if (target.result.os.tag != .windows) {
        const heredoc_test = b.addRunArtifact(exe);
        heredoc_test.setName("test cli here-document input");
        heredoc_test.addFileArg(b.path("test/cli/heredoc.hb"));
        expectCliResult(
            heredoc_test,
            test_step,
            0,
            "expanded two words\nliteral $value\ntwo words\n" ++
                "compound input\nsecond input wins\ntabs stripped\n" ++
                "continued delimiter\n",
            "",
        );

        const heredoc_diagnostic_test = b.addRunArtifact(exe);
        heredoc_diagnostic_test.setName("test cli diagnostic after here-document");
        heredoc_diagnostic_test.addFileArg(b.path("test/cli/invalid-after-heredoc.hb"));
        heredoc_diagnostic_test.expectExitCode(2);
        heredoc_diagnostic_test.expectStdOutEqual("");
        heredoc_diagnostic_test.expectStdErrMatch(":4:1: expected command, found ')'\n");
        test_step.dependOn(&heredoc_diagnostic_test.step);

        const continued_heredoc_diagnostic_test = b.addRunArtifact(exe);
        continued_heredoc_diagnostic_test.setName(
            "test cli diagnostic after continued here-document",
        );
        continued_heredoc_diagnostic_test.addFileArg(
            b.path("test/cli/invalid-after-continued-heredoc.hb"),
        );
        continued_heredoc_diagnostic_test.expectExitCode(2);
        continued_heredoc_diagnostic_test.expectStdOutEqual("");
        continued_heredoc_diagnostic_test.expectStdErrMatch(
            ":4:1: expected command, found ')'\n",
        );
        test_step.dependOn(&continued_heredoc_diagnostic_test.step);
    }

    const parameter_diagnostic_test = b.addRunArtifact(exe);
    parameter_diagnostic_test.setName("test cli parameter expansion diagnostic");
    parameter_diagnostic_test.addArgs(&.{ "-c", "/bin/echo ${missing:?required value}" });
    expectCliResult(
        parameter_diagnostic_test,
        test_step,
        1,
        "",
        "habush: missing: required value\n",
    );

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
        "habush: usage: habush [-c command | script [argument ...]]\n",
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
