# Wasm plugin host (experimental)

The optional `habush-plugin` Zig module uses the official Wasmtime **50.0.1 C API SDK**. The default shell build does not link Wasmtime. CLI command registration and ZON plugin configuration are not implemented yet.

Download the SDK for your target from the [official release](https://github.com/bytecodealliance/wasmtime/releases/tag/v50.0.1), extract it, then run:

```sh
zig build test-plugin -Dwasmtime=/absolute/path/to/wasmtime-v50.0.1-aarch64-macos-c-api --test-timeout 60s --summary all
```

The directory must contain `include/wasmtime.h` and `lib/`. `zig build test` also includes the host tests when this option is supplied. Native host tests run on macOS and Linux in CI; Windows/FreeBSD shell tests continue without the optional SDK. Wasm host behavior on those two platforms has not been verified.

On Linux, the SDK's shared library is used with an SDK-relative build rpath because Zig 0.17.1's ELF linker does not resolve its Rust static archive. Keep that library directory available when running these development binaries. Runtime packaging is not implemented yet. `zig build check-plugin` with the same options compiles the host tests without running them.

## Ownership and calls

`Host.init(io)` creates an engine and an epoch ticker. `Host.load(bytes)` compiles a module without running guest code; the module borrows its host. Each `module.invoke(allocator, entry, request, scope)` creates a fresh store/instance, applies the scope before initialization, calls the entry, copies the response, and destroys the instance. The returned byte slice belongs to the supplied allocator.

Join all calls before destroying their module, and destroy modules before their host. This first implementation uses ordinary borrowed Zig objects; it does not provide hot unload or persistent guest instances. Compilation is limited to 4 MiB of Wasm input but is not covered by invocation deadlines/fuel or a process-wide memory limit.

`Scope` grants optional stdout/stderr writers for one invocation. With no writers, the same module's attempt to write is denied. No WASI, environment, filesystem, network, subprocess, or Session access is linked. Native writers are supplied by the embedding application and must honor cancellation; epoch interruption cannot stop an arbitrary blocking native callback.

Fuel, linear memory, table/instance counts, request/reply bytes, output bytes and an optional deadline bound calls. Initialization and ABI helpers share the same budgets as the entry. Epoch checkpoints propagate cancellation and deadlines while executing Wasm. A normal command's nonzero status is separate from a trap or host failure. Output already written before a failure is not rolled back.

## Core ABI v0

The following exports are required when invoking an entry:

```text
memory                              wasm32 linear memory
habush_version() -> i32              must return 0
habush_alloc(length: i32) -> i32      writable request region
<entry>(pointer: i32, length: i32) -> i64
```

The entry result packs the reply pointer into its low 32 bits and reply length into its high 32 bits. The host validates length and memory bounds before copying. No guest `free` is needed because the instance is destroyed after each invocation. Entry/type/version errors are reported; they do not expose guest memory to callers.

The only host import is:

```text
habush.write(descriptor: i32, pointer: i32, length: i32) -> i32
```

Descriptors 1 and 2 require the corresponding scope writer. Other descriptors and missing grants fail the call. The return is the number of bytes written. Requests to read stdin are not part of v0's current implementation; input streaming can be added as a scoped operation when connecting command execution.

## Extension schemas v0

These sit above the host and do not change its execution API:

- `command.run`: request is an argv byte list, including argv[0]. Reply is exactly one byte, the exit status. Command output goes through the scope's streams, not the reply.
- `completion.collect`: request is a byte list containing the literal prefix first, then literal command/argument values supplied by the caller. Reply is a byte list of candidate values. The result owns its reply and index; call `deinit(allocator)` after use.

A byte list is little-endian `u32 count`, followed by `u32 length` and raw bytes for each item. NUL is rejected, other bytes (including invalid UTF-8) are preserved. Candidate count and total response limits are enforced before allocating the index. Trailing data and truncated lengths/items are rejected. Candidate quoting and source edits belong to the language adapter, not the guest or editor.

The tests execute both extensions from the same real module, exercise denied output access, malformed replies/types, traps, memory/fuel/output limits, deadline/cancellation during loops, initialization loops, and recovery in a subsequent call. This ABI is experimental and has no compatibility promise yet.
