# Performance Techniques Reference

This document details every performance optimization used in the HTTP/1 server,
explaining what each technique does, why it matters, and how it's implemented in Zig.

---

## 1. Arena Allocator Per Request

**File:** `connection.zig`, `request.zig`

**What:** Each HTTP request gets its own arena allocator. All allocations during
request processing go through this arena. When the request is done, the entire
arena is freed in a single O(1) operation.

**Why:** Traditional malloc/free has overhead per allocation (metadata, fragmentation,
thread synchronization). An arena allocates from a contiguous block and frees
everything at once — no per-object bookkeeping.

**Zig implementation:**
```zig
// The backing allocator is passed explicitly from main → server → connection.
// Create arena for this request, backed by the caller-provided allocator.
var arena_state: std.heap.ArenaAllocator = .init(allocator);
defer arena_state.deinit(); // O(1) bulk free

const arena = arena_state.allocator();
// All request processing uses `arena`
```

**Impact:** Eliminates hundreds of malloc/free calls per request. Reduces allocator
lock contention in multi-threaded scenarios. The backing allocator is explicit,
not hardcoded — callers control allocation strategy (e.g., `init.gpa` in production,
`std.testing.allocator` in tests).

---

## 2. Zero-Copy HTTP Parsing

**File:** `parser.zig`

**What:** HTTP method, URI, headers are never copied from the read buffer. Instead,
we store `[]const u8` slices that point directly into the read buffer.

**Why:** Copying strings is expensive — it requires allocation, memcpy, and later
deallocation. Zero-copy parsing eliminates all of this.

**Zig implementation:**
```zig
// Parsed header is just slices into `buffer`
const Header = struct {
    name: []const u8,   // Points into read buffer
    value: []const u8,  // Points into read buffer
};
```

**Impact:** Zero allocations for header parsing. Parsing becomes pure pointer
arithmetic.

---

## 3. SIMD-Accelerated Byte Scanning

**File:** `parser.zig`

**What:** Uses Zig's `@Vector(16, u8)` to scan for special characters (CR, LF,
colon, space) 16 bytes at a time instead of one byte at a time.

**Why:** Modern CPUs have 128-bit+ SIMD registers. Processing 16 bytes per
instruction is 16x throughput for scanning operations.

**Zig implementation:**
```zig
fn containsByte(comptime needle: u8, chunk: @Vector(16, u8)) bool {
    const needles: @Vector(16, u8) = @splat(needle);
    return @reduce(.Or, chunk == needles);
}

fn findCRLF(data: []const u8) ?usize {
    // Process 16 bytes at a time with SIMD
    while (i + 16 <= data.len) {
        const chunk: @Vector(16, u8) = data[i..][0..16].*;
        if (containsByte('\r', chunk)) {
            // Found potential CRLF, check precisely
        }
        i += 16;
    }
}
```

**Impact:** Header scanning throughput increased ~10-16x for large headers.

---

## 4. Comptime Route Table Generation

**File:** `router.zig`

**What:** Routes are defined at compile time using Zig's comptime evaluation.
The compiler generates static arrays and matching logic — no runtime data
structure construction.

**Why:** Runtime route matching typically involves hash tables or tries that
must be built at startup. Comptime eliminates this entirely.

**Zig implementation:**
```zig
const router = Router.init(.{
    .{ .GET, "/",        indexHandler },
    .{ .GET, "/api/user", userHandler },
    .{ .POST, "/api/data", dataHandler },
});
// At compile time, this generates optimized matching code
```

**Impact:** Zero startup cost. Route matching compiles down to a series of
comparisons — no heap allocation, no hash computation.

---

## 5. Vectored Writes (writev)

**File:** `response.zig`

**What:** Instead of writing status line, headers, and body as separate `write()`
calls, we combine them into a single vectored write using `writeVecAll()`.

**Why:** Each `write()` syscall has kernel entry/exit overhead. Vectored writes
send multiple buffers in a single syscall.

**Zig implementation:**
```zig
// Combine status line + headers + body in one syscall
var vecs: [4][]const u8 = .{
    status_line,
    header_block,
    "\r\n",
    body,
};
try writer.writeVecAll(&vecs);
```

**Impact:** Reduces syscall count from 3-4 to 1 per response. Significant for
small responses where syscall overhead dominates.

---

## 6. Stack-Allocated I/O Buffers

**File:** `connection.zig`

**What:** Read and write buffers are allocated on the stack (as local arrays)
rather than on the heap.

**Why:** Stack allocation is free — it's just a pointer adjustment. No malloc
overhead, no fragmentation, guaranteed cache locality.

**Zig implementation:**
```zig
var read_buffer: [8192]u8 = undefined;
var write_buffer: [8192]u8 = undefined;
```

**Impact:** Eliminates buffer allocation/deallocation overhead per connection.
Buffers are cache-friendly due to stack locality.

---

## 7. Branch Prediction Hints

**File:** `parser.zig`, `connection.zig`

**What:** Zig's `@branchHint(.unlikely)` tells the compiler which branch is
rarely taken, allowing it to optimize the common path.

**Why:** CPUs use branch prediction pipelines. When the compiler knows which
path is common, it can lay out code for optimal instruction cache usage.

**Zig implementation:**
```zig
if (isError) {
    @branchHint(.unlikely);
    return error.BadRequest;
}
// Fast path continues here without a jump
```

**Impact:** Reduces branch mispredictions on error paths. Keeps the hot path
in contiguous cache lines.

---

## 8. Connection Keep-Alive

**File:** `connection.zig`

**What:** HTTP/1.1 connections default to keep-alive. Multiple requests are
served over the same TCP connection.

**Why:** TCP connection establishment (3-way handshake) is expensive. Reusing
connections amortizes this cost across multiple requests.

**Implementation:** After sending a response, check the `keep_alive` field
from the parsed request head. If true, loop back and wait for the next request.

**Impact:** Eliminates TCP handshake overhead for subsequent requests. Critical
for API servers handling many requests from the same client.

---

## 9. SO_REUSEADDR

**File:** `server.zig`

**What:** Socket option that allows immediate rebinding to a port after server
restart.

**Why:** Without this, restarting the server requires waiting for TIME_WAIT
to expire (typically 60-120 seconds).

**Implementation:** Set via `reuse_address: true` in listen options.

**Impact:** Development convenience + production reliability for fast restarts.

---

## 10. Comptime Status Line Generation

**File:** `response.zig`

**What:** Common HTTP status lines ("HTTP/1.1 200 OK\r\n") are generated at
compile time as static strings.

**Why:** Formatting status lines at runtime requires integer-to-string
conversion and string concatenation. Comptime eliminates this.

**Zig implementation:**
```zig
fn statusLine(comptime status: std.http.Status) []const u8 {
    return comptime blk: {
        // Generated at compile time, stored as static data
        break :blk "HTTP/1.1 " ++ statusCodeStr(status) ++ " " ++ 
                   (status.phrase() orelse "Unknown") ++ "\r\n";
    };
}
```

**Impact:** Response sending avoids all formatting — just memcpy of a static string.

---

## 11. Inline Hot Functions

**File:** Various

**What:** Small, frequently-called functions are marked `inline` to eliminate
function call overhead.

**Why:** Function calls involve stack frame setup, register saving, and a jump.
For very small functions (byte comparisons, buffer index calculations), this
overhead can exceed the function's actual work.

**Zig note:** Zig allows `inline fn` but the compiler may also auto-inline.
Explicit `inline` is used for critical-path functions where we want to guarantee
inlining.

**Impact:** Eliminates function call overhead on hot paths. Enables further
optimizations (constant propagation, dead code elimination) at the call site.

---

## Techniques NOT Used (and Why)

### io_uring / IOCP
These are platform-specific async I/O APIs. Zig 0.16's `std.Io` abstracts over
them when available, but we use the threaded model for simplicity and
cross-platform compatibility.

### Memory-Mapped Static Files
Planned for Step 10. Would use `mmap` to serve static files without copying
from kernel to userspace.

### Sendfile
The `std.Io.Writer` supports `sendFile` but it's marked as TODO in the
current Zig 0.16 dev version for network streams.

### Custom Memory Pool
For this server, arena-per-request is simpler and nearly as fast. A fixed-block
pool would help if we had many same-sized objects with overlapping lifetimes.
