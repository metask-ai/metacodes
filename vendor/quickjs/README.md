# QuickJS

Vendored MIT-licensed QuickJS 2025-09-13, official archive revision 2:
https://bellard.org/quickjs/quickjs-2025-09-13-2.tar.xz

Archive SHA-256: `996c6b5018fc955ad4d06426d0e9cb713685a00c825aa5c0418bd53f7df8b0b4`.
Only engine sources and their headers are included. No qjs executable,
quickjs-libc, filesystem, process, network or module loader is linked.
Builds use these checked-in sources and never fetch an engine.

Local changes: `METACODES_NO_ATOMICS` guards `CONFIG_ATOMICS` in quickjs.c.
This removes the blocking Atomics.wait API and pthread dependency from the
embedded engine on every target. The engine's stack checks remain enabled.
The integration does not register classes or use SharedArrayBuffer across
threads; each runtime is confined to the calling session's execution thread.
The DynBuf allocator uses a correctly typed `void *` adapter instead of casting
`js_realloc_rt` to an incompatible callback type, preserving function sanitizer
checks in ReleaseSafe builds.

The C bridge is repository-owned code in `src/code/bridge.c`; its ownership
and evaluation contracts are declared in `src/code/bridge.h`.
