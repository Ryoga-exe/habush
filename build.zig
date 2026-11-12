const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const skip_zig_36010 = (b.option(bool, "skip-zig-36010", "Skip macOS cancellation checks affected by Zig PR #36010") orelse false) and
        target.result.os.tag == .macos;
    const wasm_plugins = b.option(bool, "wasm-plugins", "Enable Wasm plugins using the Wasmtime SDK") orelse false;
    const wasmtime_sdk = if (wasm_plugins) sdk: {
        const name = if (target.result.os.tag == .macos and target.result.cpu.arch == .aarch64)
            "wasmtime_aarch64_macos"
        else if (target.result.os.tag == .linux and target.result.cpu.arch == .x86_64 and target.result.abi == .gnu)
            "wasmtime_x86_64_linux_gnu"
        else {
            std.log.err("Wasmtime SDK is unavailable for {t}-{t}-{t}; supported targets: aarch64-macos, x86_64-linux-gnu", .{
                target.result.cpu.arch, target.result.os.tag, target.result.abi,
            });
            return error.UnsupportedWasmtimeTarget;
        };
        break :sdk try b.dependencyLazy(name, .{});
    } else null;
    var demo_plugin: ?*std.Build.Step.Compile = null;
    var theme_plugin: ?*std.Build.Step.Compile = null;
    const features = b.addOptions();
    features.addOption(bool, "wasm_plugins", wasm_plugins);

    const habush_edit = b.addModule("habush-edit", .{
        .root_source_file = b.path("src/lib/edit.zig"),
        .target = target,
        .optimize = optimize,
    });
    const habush = b.addModule("habush", .{
        .root_source_file = b.path("src/lib/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    habush.addImport("habush-edit", habush_edit);
    const habush_exec = b.addModule("habush-exec", .{
        .root_source_file = b.path("src/lib/exec.zig"),
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
    exe.root_module.addImport("habush-edit", habush_edit);
    exe.root_module.addOptions("features", features);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const pipeline_example = b.addExecutable(.{
        .name = "run-pipeline",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/run_pipeline.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    pipeline_example.root_module.addImport("habush-exec", habush_exec);
    const run_pipeline_step = b.step("run-pipeline", "Run the structured pipeline example");
    const run_pipeline_cmd = b.addRunArtifact(pipeline_example);
    run_pipeline_step.dependOn(&run_pipeline_cmd.step);
    run_pipeline_cmd.addPassthruArgs();

    const sandbox_example = b.addExecutable(.{
        .name = "run-sandbox",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/run_sandbox.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sandbox_example.root_module.addImport("habush-exec", habush_exec);
    const run_sandbox_step = b.step("run-sandbox", "Run the explicit sandbox backend example");
    const run_sandbox_cmd = b.addRunArtifact(sandbox_example);
    run_sandbox_step.dependOn(&run_sandbox_cmd.step);
    run_sandbox_cmd.addPassthruArgs();

    const sandbox_probe = b.addExecutable(.{
        .name = "sandbox-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/sandbox.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sandbox_probe.root_module.addImport("habush-exec", habush_exec);
    const sandbox_test_step = b.step("test-sandbox", "Verify the optional sandbox backend with real workers");
    const sandbox_test_cmd = b.addRunArtifact(sandbox_probe);
    sandbox_test_cmd.addArtifactArg(exe);
    sandbox_test_step.dependOn(&sandbox_test_cmd.step);

    const check_step = b.step("check", "Compile the CLI and structured pipeline example");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&pipeline_example.step);
    check_step.dependOn(&sandbox_example.step);
    check_step.dependOn(&sandbox_probe.step);

    const lib_tests = b.addTest(.{
        .root_module = habush,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_lib_tests.step);
    const edit_tests = b.addTest(.{ .root_module = habush_edit });
    const run_edit_tests = b.addRunArtifact(edit_tests);
    test_step.dependOn(&run_edit_tests.step);
    var plugin_module: ?*std.Build.Module = null;
    if (wasmtime_sdk) |sdk| {
        const headers = b.addTranslateC(.{
            .root_source_file = sdk.path("include/wasmtime.h"),
            .target = target,
            .optimize = optimize,
        });
        headers.addIncludePath(sdk.path("include"));
        if (target.result.os.tag == .windows) {
            headers.defineCMacro("WASM_API_EXTERN", "");
            headers.defineCMacro("WASI_API_EXTERN", "");
        }
        const plugin = b.addModule("habush-plugin", .{
            .root_source_file = b.path("src/plugin.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        plugin.addImport("wasmtime", headers.createModule());
        plugin.addImport("habush-edit", habush_edit);
        plugin_module = plugin;
        exe.root_module.addImport("habush-plugin", plugin);
        plugin.addLibraryPath(sdk.path("lib"));
        plugin.linkSystemLibrary("wasmtime", .{
            .preferred_link_mode = if (target.result.os.tag == .linux) .dynamic else .static,
            .use_pkg_config = .no,
        });
        if (target.result.os.tag == .linux) {
            // Use the SDK's shared library; Zig's ELF linker cannot resolve its Rust archive.
            plugin.addRPath(sdk.path("lib"));
            for ([_][]const u8{ "pthread", "dl", "m" }) |name| plugin.linkSystemLibrary(name, .{});
        } else if (target.result.os.tag == .windows) {
            for ([_][]const u8{ "ws2_32", "advapi32", "userenv", "ntdll", "shell32", "ole32", "bcrypt" }) |name|
                plugin.linkSystemLibrary(name, .{});
        }
        const plugin_tests = b.addTest(.{ .root_module = plugin });
        b.step("check-plugin", "Compile the optional Wasm plugin host tests").dependOn(&plugin_tests.step);
        const run_plugin_tests = b.addRunArtifact(plugin_tests);
        b.step("test-plugin", "Verify the optional Wasm plugin host").dependOn(&run_plugin_tests.step);
        test_step.dependOn(&run_plugin_tests.step);
        const demo = b.addExecutable(.{
            .name = "habush-plugin-demo",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/plugins/demo.zig"),
                .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
                .optimize = .ReleaseSmall,
            }),
        });
        demo.entry = .disabled;
        demo.rdynamic = true;
        demo.export_memory = true;
        demo.stack_size = 64 * 1024;
        b.installArtifact(demo);
        demo_plugin = demo;
        const theme = b.addExecutable(.{
            .name = "habush-theme",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/plugins/theme.zig"),
                .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
                .optimize = .ReleaseSmall,
            }),
        });
        theme.entry = .disabled;
        theme.rdynamic = true;
        theme.export_memory = true;
        theme.stack_size = 64 * 1024;
        b.installArtifact(theme);
        theme_plugin = theme;
    }
    const terminal_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/app_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    terminal_tests.root_module.addImport("habush", habush);
    terminal_tests.root_module.addImport("habush-edit", habush_edit);
    terminal_tests.root_module.addOptions("features", features);
    if (plugin_module) |plugin| terminal_tests.root_module.addImport("habush-plugin", plugin);
    const run_terminal_tests = b.addRunArtifact(terminal_tests);
    run_terminal_tests.setEnvironmentVariable("HABUSH_TEST_SKIP_ZIG_36010", if (skip_zig_36010) "1" else "0");
    test_step.dependOn(&run_terminal_tests.step);
    test_step.dependOn(&exe.step);
    test_step.dependOn(&pipeline_example.step);
    test_step.dependOn(&sandbox_example.step);

    switch (target.result.os.tag) {
        .linux, .macos, .freebsd => {
            const terminal_probe = b.addExecutable(.{
                .name = "terminal-test",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("test/terminal.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }),
            });
            if (target.result.os.tag != .macos)
                terminal_probe.root_module.linkSystemLibrary("util", .{});
            const terminal_test = b.addRunArtifact(terminal_probe);
            terminal_test.setEnvironmentVariable("HABUSH_TEST_SKIP_ZIG_36010", if (skip_zig_36010) "1" else "0");
            terminal_test.addArtifactArg(exe);
            terminal_test.expectExitCode(0);
            test_step.dependOn(&terminal_test.step);
            if (demo_plugin) |demo| {
                const plugin_terminal = b.addRunArtifact(terminal_probe);
                plugin_terminal.setName("test CLI plugin commands and completion");
                plugin_terminal.addArtifactArg(exe);
                plugin_terminal.addArtifactArg(demo);
                plugin_terminal.addArtifactArg(theme_plugin.?);
                plugin_terminal.expectExitCode(0);
                test_step.dependOn(&plugin_terminal.step);
            }
        },
        else => {},
    }

    const command_control_test = b.addRunArtifact(exe);
    command_control_test.setName("test cli exit control flow");
    command_control_test.addArgs(&.{ "-c", "false; exit; missing" });
    expectCliResult(command_control_test, test_step, 1, "", "");

    const zon_config_test = b.addRunArtifact(exe);
    zon_config_test.setName("test cli explicit ZON config");
    zon_config_test.addArg("--config");
    zon_config_test.addFileArg(b.path("test/cli/config.zon"));
    zon_config_test.addArgs(&.{ "-c", "exit 17" });
    expectCliResult(zon_config_test, test_step, 17, "", "");

    if (!wasm_plugins) {
        const unavailable_plugin_test = b.addRunArtifact(exe);
        unavailable_plugin_test.setName("test CLI rejects plugins in a build without Wasm support");
        unavailable_plugin_test.addArg("--config");
        unavailable_plugin_test.addFileArg(b.path("examples/plugins/demo.zon"));
        unavailable_plugin_test.addArgs(&.{ "-c", "exit 17" });
        expectCliResult(unavailable_plugin_test, test_step, 2, "", "habush: plugins require a build with -Dwasm-plugins=true\n");
    }

    const invalid_config_test = b.addRunArtifact(exe);
    invalid_config_test.setName("test cli ZON config diagnostic");
    invalid_config_test.addArg("--config");
    invalid_config_test.addFileArg(b.path("test/cli/invalid-config.zon"));
    invalid_config_test.addArgs(&.{ "-c", "exit 17" });
    invalid_config_test.expectExitCode(2);
    invalid_config_test.expectStdOutEqual("");
    invalid_config_test.expectStdErrMatch("invalid-config.zon:2:");
    test_step.dependOn(&invalid_config_test.step);

    const syntax_stop_test = b.addRunArtifact(exe);
    syntax_stop_test.setName("test cli syntax error stops remaining source");
    syntax_stop_test.addArgs(&.{ "-c", ")\nexit 23" });
    expectCliResult(syntax_stop_test, test_step, 2, "", "habush: 1:1: expected command, found ')'\n");

    const long_name = b.allocator.alloc(u8, 256) catch @panic("out of memory");
    @memset(long_name, 'x');
    const long_command_test = b.addRunArtifact(exe);
    long_command_test.setName("test cli survives an overlong command name");
    long_command_test.addArgs(&.{ "-c", b.fmt("{s}\nexit 23", .{long_name}) });
    expectCliResult(long_command_test, test_step, 23, "", b.fmt("habush: {s}: command not found\n", .{long_name}));

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

    const case_test = b.addRunArtifact(exe);
    case_test.setName("test cli case execution");
    case_test.addArgs(&.{ "--no-config", "-c", "value='a b'; case \"$value\" in (x|a*) exit 7;; *) exit 1;; esac" });
    expectCliResult(case_test, test_step, 7, "", "");

    const parameter_patterns_test = b.addRunArtifact(exe);
    parameter_patterns_test.setName("test cli parameter pattern removal");
    parameter_patterns_test.addArgs(&.{ "--no-config", "-c", "value=a/b/c; case \"${value##*/}\" in c) exit 7;; *) exit 1;; esac" });
    expectCliResult(parameter_patterns_test, test_step, 7, "", "");

    const word_expansion_test = b.addRunArtifact(exe);
    word_expansion_test.setName("test cli word expansion");
    word_expansion_test.addFileArg(b.path("test/cli/word-expansion.hb"));
    expectCliResult(word_expansion_test, test_step, 23, "", "");

    if (target.result.os.tag == .windows) {
        const windows_pipeline_test = b.addRunArtifact(exe);
        windows_pipeline_test.setName("test cli Windows anonymous pipeline");
        windows_pipeline_test.addArgs(&.{ "-c", "cmd.exe /C echo pipeline-data | findstr.exe pipeline-data" });
        windows_pipeline_test.expectExitCode(0);
        windows_pipeline_test.expectStdOutMatch("pipeline-data");
        windows_pipeline_test.expectStdErrEqual("");
        test_step.dependOn(&windows_pipeline_test.step);
    } else {
        const worker_diagnostic_test = b.addRunArtifact(exe);
        worker_diagnostic_test.setName("test worker diagnostic preserves the command name");
        worker_diagnostic_test.addArgs(&.{
            "--internal-command-worker", "1", "command", "original-command", "--", "/definitely/missing-command",
        });
        expectCliResult(worker_diagnostic_test, test_step, 126, "", "habush: original-command: command not found\n");

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

        const pipeline_test = b.addRunArtifact(exe);
        pipeline_test.setName("test cli foreground pipeline");
        pipeline_test.addFileArg(b.path("test/cli/pipeline.hb"));
        expectCliResult(
            pipeline_test,
            test_step,
            0,
            "pipeline-data\noutputerror",
            "",
        );

        const pipeline_status_test = b.addRunArtifact(exe);
        pipeline_status_test.setName("test cli pipeline status");
        pipeline_status_test.addArgs(&.{ "-c", "/usr/bin/true | /usr/bin/false" });
        expectCliResult(pipeline_status_test, test_step, 1, "", "");

        const builtin_pipeline_status_test = b.addRunArtifact(exe);
        builtin_pipeline_status_test.setName("test cli builtin pipeline status");
        builtin_pipeline_status_test.addArgs(&.{ "-c", "true | false" });
        expectCliResult(builtin_pipeline_status_test, test_step, 1, "", "");

        const builtin_pipeline_output_test = b.addRunArtifact(exe);
        builtin_pipeline_output_test.setName("test cli builtin pipeline output");
        builtin_pipeline_output_test.addArgs(&.{ "-c", "pwd | /usr/bin/grep -q /" });
        expectCliResult(builtin_pipeline_output_test, test_step, 0, "", "");

        const failed_builtin_pipeline_output_test = b.addRunArtifact(exe);
        failed_builtin_pipeline_output_test.setName("test cli failed builtin pipeline output");
        failed_builtin_pipeline_output_test.addArgs(&.{ "-c", "pwd | /definitely/missing" });
        expectCliResult(
            failed_builtin_pipeline_output_test,
            test_step,
            127,
            "",
            "habush: /definitely/missing: command not found\n",
        );

        const export_pipeline_output_test = b.addRunArtifact(exe);
        export_pipeline_output_test.setName("test cli export pipeline output");
        export_pipeline_output_test.addArgs(&.{ "-c", "export | /usr/bin/grep -q ." });
        expectCliResult(export_pipeline_output_test, test_step, 0, "", "");

        const pipeline_exit_isolation_test = b.addRunArtifact(exe);
        pipeline_exit_isolation_test.setName("test cli pipeline exit isolation");
        pipeline_exit_isolation_test.addArgs(&.{ "-c", "exit 7 | true; /bin/echo survived" });
        expectCliResult(pipeline_exit_isolation_test, test_step, 0, "survived\n", "");

        const pipeline_final_exit_status_test = b.addRunArtifact(exe);
        pipeline_final_exit_status_test.setName("test cli final pipeline exit status");
        pipeline_final_exit_status_test.addArgs(&.{ "-c", "true | exit 7" });
        expectCliResult(pipeline_final_exit_status_test, test_step, 7, "", "");

        const function_pipeline_test = b.addRunArtifact(exe);
        function_pipeline_test.setName("test cli shell function pipeline");
        function_pipeline_test.addArgs(&.{
            "-c",
            "copy() { /bin/cat; }; /bin/echo function-data | copy | /usr/bin/grep -q function-data",
        });
        expectCliResult(function_pipeline_test, test_step, 0, "", "");

        const compound_pipeline_test = b.addRunArtifact(exe);
        compound_pipeline_test.setName("test cli compound command pipeline");
        compound_pipeline_test.addArgs(&.{
            "-c",
            "/bin/echo compound-data | { /bin/cat; } | /usr/bin/grep -q compound-data",
        });
        expectCliResult(compound_pipeline_test, test_step, 0, "", "");
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
        "habush: usage: habush [--config path | --no-config] [--no-rc] [-c command | script [argument ...]]\n",
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
