# Build & Run Script

## Prerequisites

- [Zig](https://ziglang.org/download/) installed and available on your `PATH`
- PowerShell 5.1+ (included with Windows)

## Usage

```powershell
.\run.ps1 [-Optimize <mode>] [-BuildOnly] [-Clean] [-Server] [-- <exe-args>]
```

### Parameters

| Parameter     | Description                                              | Default   |
|---------------|----------------------------------------------------------|-----------||
| `-Optimize`   | Optimization mode: `Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall` | `Debug`   |
| `-BuildOnly`  | Build without running the executable                     | off       |
| `-Clean`      | Remove build artifacts before building                   | off       |
| `-Server`     | Build and run the HTTP server instead of learn_zig       | off       |
| `<exe-args>`  | Arguments passed through to the executable               | none      |

### Examples

```powershell
# Build and run (debug, default)
.\run.ps1

# Build and run with max performance
.\run.ps1 -Optimize ReleaseFast

# Build optimized for small binary size
.\run.ps1 -Optimize ReleaseSmall

# Only build, don't run
.\run.ps1 -Optimize ReleaseFast -BuildOnly

# Clean build artifacts, then build and run
.\run.ps1 -Clean

# Clean build, optimized, without running
.\run.ps1 -Clean -Optimize ReleaseFast -BuildOnly

# Pass arguments to the executable
.\run.ps1 -Optimize ReleaseFast -- arg1 arg2

# ---- HTTP Server ----

# Build and run the HTTP server (debug, port 8080)
.\run.ps1 -Server

# Run the server with max performance
.\run.ps1 -Server -Optimize ReleaseFast

# Run the server on a custom port
.\run.ps1 -Server -Optimize ReleaseFast -- --port 3000

# Only build the server, don't run it
.\run.ps1 -Server -BuildOnly

# Clean build, then run server
.\run.ps1 -Server -Clean -Optimize ReleaseFast
```

### Optimization Modes

| Mode            | Description                                                  |
|-----------------|--------------------------------------------------------------|
| `Debug`         | No optimizations, includes debug info (default)              |
| `ReleaseSafe`   | Optimized with runtime safety checks (bounds checking, etc.) |
| `ReleaseFast`   | Maximum performance, safety checks disabled                  |
| `ReleaseSmall`  | Optimized for smallest binary size                           |

### Output

The compiled executables are placed at:

```
zig-out\bin\learn_zig.exe      # Default learn_zig app
zig-out\bin\http_server.exe    # HTTP server
```

### Zig Build Commands (without run.ps1)

You can also use `zig build` directly:

```powershell
# Build everything
zig build

# Build and run the HTTP server
zig build run-server

# Build and run the HTTP server with max performance
zig build run-server -Doptimize=ReleaseFast

# Pass arguments (e.g. custom port)
zig build run-server -- --port 3000
```

---

## Running Tests

### Test Script

Use `test.ps1` for a visual test runner with color-coded output:

```powershell
# Run all tests (summary only)
powershell -ExecutionPolicy Bypass -File test.ps1

# Run all tests with each test name listed
powershell -ExecutionPolicy Bypass -File test.ps1 -Verbose
```

**Summary mode** shows a pass/fail count and elapsed time.  
**Verbose mode** lists every individual test with `[PASS]` or `[FAIL]` next to it.

If any tests fail, the script shows which tests failed and the relevant error details.

### Zig Build Commands (without test.ps1)

```powershell
# Run all tests
zig build test

# Run all tests with summary
zig build test --summary all

# Run tests on the root module directly
zig test src/root.zig
```
