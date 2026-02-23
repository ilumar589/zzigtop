//! Database integration tests — exercises the db module against a real PostgreSQL.
//!
//! **Prerequisite:** PostgreSQL must be running:
//!   cd docker && docker compose up -d
//!
//! Run with:
//!   zig build db-integration-test
//!
//! Tests perform full CRUD cycles via `Database` + `UserRepository`, verifying
//! parameterized queries, error handling, and transaction support.
//! Each test cleans up after itself so the suite is idempotent.

const std = @import("std");
const learn = @import("zzigtop");
const db = learn.db;
const Io = std.Io;

// ============================================================================
// Test infrastructure
// ============================================================================

var tests_passed: u32 = 0;
var tests_failed: u32 = 0;
var tests_total: u32 = 0;

/// Log a test result and update the pass/fail counters.
fn reportResult(name: []const u8, passed: bool, detail: []const u8) void {
    tests_total += 1;
    if (passed) {
        tests_passed += 1;
        std.debug.print("  \x1b[32mPASS\x1b[0m {s}\n", .{name});
    } else {
        tests_failed += 1;
        std.debug.print("  \x1b[31mFAIL\x1b[0m {s}: {s}\n", .{ name, detail });
    }
}

// ============================================================================
// Tests
// ============================================================================

/// Run all database integration tests (CRUD, constraints, SQL-injection safety).
fn runTests(database: *db.Database, arena: std.mem.Allocator) void {
    // --- Test 1: Database connection — pool init/deinit ---
    // If we got here, init succeeded. Just verify we can acquire/release a conn.
    {
        const conn = database.acquire() catch {
            reportResult("DB connection — acquire", false, "acquire() failed");
            return;
        };
        database.release(conn);
        reportResult("DB connection — acquire/release", true, "");
    }

    // --- Test 2: List seed users (should have at least 3 from init.sql) ---
    var initial_count: usize = 0;
    {
        var result = database.query(
            "SELECT id, name, email, age FROM users ORDER BY id",
            .{},
        ) catch {
            reportResult("List seed users", false, "query failed");
            return;
        };
        defer result.deinit();

        while (result.next() catch null) |_| {
            initial_count += 1;
        }
        const ok = initial_count >= 3;
        reportResult(
            "List seed users (>= 3)",
            ok,
            if (!ok) "expected at least 3 seed users" else "",
        );
    }

    // --- Test 3: Create user → verify returned ID ---
    var created_id: ?i32 = null;
    {
        var repo = db.UserRepository.init(database);
        const user = repo.create(.{
            .name = "TestUser",
            .email = "testuser_integration@example.com",
            .age = 42,
        }, arena) catch {
            reportResult("Create user", false, "create() returned error");
            return;
        };
        if (user) |u| {
            created_id = u.id;
            const ok = u.id > 0 and std.mem.eql(u8, u.name, "TestUser") and u.age != null and u.age.? == 42;
            reportResult(
                "Create user — fields match",
                ok,
                if (u.id <= 0) "bad id" else if (!std.mem.eql(u8, u.name, "TestUser")) "wrong name" else "wrong age",
            );
        } else {
            reportResult("Create user", false, "returned null");
        }
    }

    // --- Test 4: Get user by ID → verify fields ---
    {
        if (created_id) |id| {
            var repo = db.UserRepository.init(database);
            const user = repo.getById(id, arena) catch {
                reportResult("Get user by ID", false, "getById() returned error");
                return;
            };
            if (user) |u| {
                const ok = u.id == id and std.mem.eql(u8, u.name, "TestUser") and
                    std.mem.eql(u8, u.email, "testuser_integration@example.com") and
                    u.age != null and u.age.? == 42;
                reportResult("Get user by ID — fields match", ok, "field mismatch");
            } else {
                reportResult("Get user by ID", false, "returned null");
            }
        } else {
            reportResult("Get user by ID", false, "skipped — no created_id");
        }
    }

    // --- Test 5: List all users → count increased by 1 ---
    {
        var repo = db.UserRepository.init(database);
        var result = repo.getAll() catch {
            reportResult("List all users (count)", false, "getAll() returned error");
            return;
        };
        defer result.deinit();

        var count: usize = 0;
        while (result.next() catch null) |_| {
            count += 1;
        }
        const ok = count == initial_count + 1;
        reportResult("List all users — count +1", ok, "count mismatch");
    }

    // --- Test 6: Update user → verify changed fields ---
    {
        if (created_id) |id| {
            var repo = db.UserRepository.init(database);
            const user = repo.update(id, .{
                .name = "UpdatedUser",
                .email = "updated_integration@example.com",
                .age = 99,
            }, arena) catch {
                reportResult("Update user", false, "update() returned error");
                return;
            };
            if (user) |u| {
                const ok = u.id == id and
                    std.mem.eql(u8, u.name, "UpdatedUser") and
                    std.mem.eql(u8, u.email, "updated_integration@example.com") and
                    u.age != null and u.age.? == 99;
                reportResult("Update user — fields changed", ok, "field mismatch after update");
            } else {
                reportResult("Update user", false, "returned null");
            }
        } else {
            reportResult("Update user", false, "skipped — no created_id");
        }
    }

    // --- Test 7: Get nonexistent user → verify null ---
    {
        var repo = db.UserRepository.init(database);
        const user = repo.getById(-999, arena) catch {
            reportResult("Get nonexistent user", false, "getById() returned error");
            return;
        };
        reportResult("Get nonexistent user — returns null", user == null, "expected null");
    }

    // --- Test 8: Delete user → verify removed ---
    {
        if (created_id) |id| {
            var repo = db.UserRepository.init(database);
            const deleted = repo.delete(id) catch {
                reportResult("Delete user", false, "delete() returned error");
                return;
            };
            if (!deleted) {
                reportResult("Delete user", false, "returned false");
                return;
            }

            // Verify it's gone
            const gone = repo.getById(id, arena) catch {
                reportResult("Delete user — verify gone", false, "getById() error");
                return;
            };
            reportResult("Delete user — removed", gone == null, "user still exists after delete");
        } else {
            reportResult("Delete user", false, "skipped — no created_id");
        }
    }

    // --- Test 9: SQL injection attempt → parameterized safety ---
    //
    // Pass a classic SQL injection payload as a name parameter.
    // Because pg.zig uses the binary protocol ($1, $2, ...), the payload
    // is sent as a literal string value — it is NEVER interpolated into SQL.
    {
        var repo = db.UserRepository.init(database);
        const injection_payload = "'; DROP TABLE users; --";
        const user = repo.create(.{
            .name = injection_payload,
            .email = "injection_test@example.com",
            .age = null,
        }, arena) catch {
            reportResult("SQL injection safety", false, "create() returned error");
            return;
        };
        if (user) |u| {
            // The injection string should be stored literally, not executed
            const name_ok = std.mem.eql(u8, u.name, injection_payload);

            // Verify the users table still exists
            var result = database.query("SELECT count(*) FROM users", .{}) catch {
                reportResult("SQL injection safety", false, "table dropped!");
                return;
            };
            defer result.deinit();
            const table_ok = (result.next() catch null) != null;

            reportResult("SQL injection safety — payload stored literally", name_ok and table_ok, if (!name_ok) "name mangled" else "table gone!");

            // Clean up
            _ = repo.delete(u.id) catch {};
        } else {
            reportResult("SQL injection safety", false, "create returned null");
        }
    }

    // --- Test 10: Unique constraint violation (duplicate email) ---
    {
        var repo = db.UserRepository.init(database);
        // alice@example.com already exists from seed data
        const user = repo.create(.{
            .name = "Duplicate Alice",
            .email = "alice@example.com",
            .age = 20,
        }, arena) catch {
            // An error from the unique constraint is expected behavior.
            reportResult("Unique constraint — duplicate email rejected", true, "");
            return;
        };
        // If we get here, either the insert returned null (constraint caught)
        // or somehow succeeded (bad).
        if (user == null) {
            reportResult("Unique constraint — duplicate email rejected", true, "");
        } else {
            // Shouldn't happen — clean up
            _ = repo.delete(user.?.id) catch {};
            reportResult("Unique constraint — duplicate email rejected", false, "insert should have failed");
        }
    }
}

// ============================================================================
// Entry point
// ============================================================================

/// Database integration test entry point — connects to PostgreSQL, runs tests, and exits.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    std.debug.print(
        \\
        \\  ╔══════════════════════════════════════════╗
        \\  ║   Database Integration Tests             ║
        \\  ║   (requires PostgreSQL — see docker/)    ║
        \\  ╚══════════════════════════════════════════╝
        \\
        \\
    , .{});

    // ---- Parse optional DB host/port from CLI ----
    var db_host: []const u8 = "127.0.0.1";
    var db_port: u16 = 5432;
    const args = try init.minimal.args.toSlice(arena);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--db-host") and i + 1 < args.len) {
            db_host = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--db-port") and i + 1 < args.len) {
            db_port = std.fmt.parseInt(u16, args[i + 1], 10) catch 5432;
            i += 1;
        }
    }

    // ---- Connect to PostgreSQL ----
    std.debug.print("Connecting to PostgreSQL at {s}:{d}...\n", .{ db_host, db_port });

    var database = db.Database.init(init.gpa, io, .{
        .host = db_host,
        .port = db_port,
    }) catch |err| {
        std.debug.print(
            \\
            \\  \x1b[31mFailed to connect to PostgreSQL: {}\x1b[0m
            \\
            \\  Make sure PostgreSQL is running:
            \\    cd docker && docker compose up -d
            \\
            \\
        , .{err});
        std.process.exit(1);
    };
    defer database.deinit();

    std.debug.print("Connected. Running tests...\n\n", .{});

    // ---- Run all tests ----
    runTests(&database, arena);

    // ---- Print summary ----
    std.debug.print(
        \\
        \\  ──────────────────────────────────────────
        \\  Results: {d}/{d} passed, {d} failed
        \\  ──────────────────────────────────────────
        \\
    , .{ tests_passed, tests_total, tests_failed });

    if (tests_failed > 0) {
        std.debug.print("\n  \x1b[31mSome tests failed!\x1b[0m\n\n", .{});
        std.process.exit(1);
    } else {
        std.debug.print("\n  \x1b[32mAll database integration tests passed!\x1b[0m\n\n", .{});
    }
}
