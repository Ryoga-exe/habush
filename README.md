# 🐍 habush

shell written in [Zig](https://ziglang.org/).

https://en.wikipedia.org/wiki/Habushu

## Build

Use Zig 0.16.0.

```sh
zig build
zig build test
zig build run -- -c 'pwd'
```

## Library entry points

- `habush` provides shell parsing, HIR, stateful `Session.evaluate`, and execution.
- `habush-exec` provides `CommandPlan`, `ExecutionContext`, `Host`, and `Pipeline` for structured execution without the shell parser or evaluator.

Applications combining shell sessions with structured execution can use `habush.exec` through the integrated `habush` entry point.
`habush-exec` is the alternative entry point for execution-only consumers.

The shell and the structured API share pipeline resource and process management.
Shell expansion, builtins, and pipeline exit-status rules remain in the language evaluator.

## Structured pipeline example

```sh
zig build run-pipeline -- /usr/bin/printf 'hello\n' --pipe /usr/bin/wc -c
```

The [example](examples/run_pipeline.zig) accepts executable paths and argument arrays separated by `--pipe`; it does not evaluate shell source or search PATH.
It captures its working directory once and explicitly supplies an empty child environment.
Use executable paths appropriate for the host platform.
