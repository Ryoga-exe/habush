# Wasm plugin host (experimental)

The optional `habush-plugin` Zig module uses the official Wasmtime **50.0.1 C API SDK**. One module can provide commands and their argument completion. The default shell build does not link Wasmtime; requesting plugins in that build reports an error.

Download the SDK for your target from the [official release](https://github.com/bytecodealliance/wasmtime/releases/tag/v50.0.1), extract it, then run:

```sh
zig build -Dwasmtime=/absolute/path/to/wasmtime-v50.0.1-aarch64-macos-c-api
zig-out/bin/habush --config examples/plugins/demo.zon
```

The directory must contain `include/wasmtime.h` and `lib/`. This builds the shell and `zig-out/bin/habush-plugin-demo.wasm` from [demo.zig](demo.zig). In the shell, run `hb-demo 'hello world'`: it prints `VALUE:hello world` and returns status 7. `hb-demo read` reads one chunk from stdin; `fail` traps and `loop` runs until canceled or limited.

Type `hb-demo sec` and press Tab to insert a safely quoted candidate containing an apostrophe and `$()`. For multiple candidates, Tab or Up/Down selects, Enter inserts, and a second Enter submits the command. Typing, moving the cursor, pasting, or undoing closes the selection. A plugin failure leaves the input editable; Ctrl-C cancels a running command.

`zig build test -Dwasmtime=<SDK> --test-timeout 60s` includes host tests and a real CLI/PTY test. `test-plugin` runs just the host tests, and `check-plugin` compiles them without running. The SDK tests run on macOS and Linux in CI; Windows/FreeBSD shell tests continue without it. Wasm behavior on those two platforms has not been verified. On stock Zig 0.17.1, macOS full tests also use the existing `-Dskip-zig-36010=true` quarantine; the new plugin cancellation tests are not skipped.

On Linux, the SDK's shared library is used with a build rpath pointing to the SDK because Zig 0.17.1's ELF linker does not resolve its Rust static archive. Keep that library directory available when running these development binaries. Runtime packaging is not implemented yet.

## ZON registration

```zig
.{
    .plugins = .{.{
        .path = "plugins/demo.wasm",
        .commands = .{.{
            .name = "hb-demo",
            .entry = "command",
            .completion = "complete",
        }},
        .fuel = 10_000_000,
        .memory_bytes = 16 * 1024 * 1024,
        .timeout_ms = 1000,
    }},
}
```

Paths are relative to the configuration file's directory. `entry` defaults to `command`; completion is optional. Budget fields above show their defaults. Completion uses the same limits with a deadline capped at 100 ms. The CLI owns parsed strings until shutdown, loads modules before creating the Session, and destroys them after Session/input tasks have ended.

Empty paths/entries/names, command names containing path separators, duplicate names, and builtin name collisions are rejected. Shell functions retain precedence over registered commands. Explicit paths such as `./hb-demo` use external command lookup. File/compilation failures stop startup with status 2; entry/version/type failures are reported when called. Command failures produce status 1 and permit subsequent commands.

The initial command API supports standalone execution, including standard-stream redirection. Pipeline stages, background execution, and restricted sandbox contexts reject these commands before opening their redirections. They do not fall back to external executables. No cwd/environment or Session access is passed to the Wasm guest.

Argument completion receives the literal command and completed arguments before the current word, plus its literal prefix. It never evaluates substitutions or variable expansions; unsupported contexts use native fallback. A successful plugin result replaces file fallback for that command. Failed providers leave an incomplete result that cannot auto-insert an apparently unique candidate.

## Ownership and calls

`Host.init(io)` creates an engine and an epoch ticker. `Host.load(bytes)` compiles a module without running guest code; the module borrows its host. Each `module.invoke(allocator, entry, request, scope)` creates a fresh store/instance, applies the scope before initialization, calls the entry, copies the response, and destroys the instance. The returned byte slice belongs to the supplied allocator.

Join all calls before destroying their module, and destroy modules before their host. This first implementation uses ordinary borrowed Zig objects; it does not provide hot unload or persistent guest instances. Compilation is limited to 4 MiB of Wasm input but is not covered by invocation deadlines/fuel or a process-wide memory limit.

`Scope` grants optional stdin/stdout/stderr streams for one invocation. Missing grants deny access, so the same module's completion entry cannot use its command's streams. No WASI, environment, filesystem, network, subprocess, or Session access is linked. Native streams are supplied by the embedding application and must honor cancellation and their I/O deadlines; epoch interruption cannot stop an arbitrary blocking native callback.

Fuel, linear memory, table/instance counts, request/reply bytes, input/output bytes and an optional deadline bound calls. Initialization and ABI helpers share the same budgets as the entry. Epoch checkpoints propagate cancellation and deadlines while executing Wasm. A normal command's nonzero status is separate from a trap or host failure. Bytes already read or written before a failure are not rolled back.

## Core ABI v0

The following exports are required when invoking an entry:

```text
memory                              wasm32 linear memory
habush_version() -> i32              must return 0
habush_alloc(length: i32) -> i32      writable request region
<entry>(pointer: i32, length: i32) -> i64
```

The entry result packs the reply pointer into its low 32 bits and reply length into its high 32 bits. The host validates length and memory bounds before copying. No guest `free` is needed because the instance is destroyed after each invocation. Entry/type/version errors are reported; they do not expose guest memory to callers.

The host imports are:

```text
habush.write(descriptor: i32, pointer: i32, length: i32) -> i32
habush.read(descriptor: i32, pointer: i32, length: i32) -> i32
```

Write descriptors 1 and 2 require the corresponding scope writer. Read descriptor 0 requires stdin. Other descriptors and missing grants fail the call. Return values count bytes transferred; read may return fewer bytes than requested and returns zero at EOF or for an empty request. Both validate guest memory and enforce byte budgets before I/O. A failed operation traps the call rather than returning an unchecked error code to the guest.

## Extension schemas v0

These sit above the host and do not change its execution API:

- `command.run`: request is an argv byte list, including argv[0]. Reply is exactly one byte, the exit status. Command output goes through the scope's streams, not the reply.
- `completion.collect`: request is a byte list containing the literal prefix first, then literal command/argument values supplied by the caller. Reply is a byte list of candidate values. The result owns its reply and index; call `deinit(allocator)` after use.

A byte list is little-endian `u32 count`, followed by `u32 length` and raw bytes for each item. NUL is rejected, other bytes (including invalid UTF-8) are preserved. Candidate count and total response limits are enforced before allocating the index. Trailing data and truncated lengths/items are rejected. Candidate quoting and source edits belong to the language adapter, not the guest or editor.

The tests execute both extensions from the same real module, exercise denied stream access, malformed replies/types, traps, memory/fuel/I/O limits, deadline/cancellation during loops, initialization loops, and recovery. The CLI test also covers ZON registration, exit status, stdin redirection, candidate selection, literal quoting, stale selection invalidation, and input after failure/Ctrl-C. This ABI is experimental and has no compatibility promise yet.
