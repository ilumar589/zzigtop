//! User repository — type-safe CRUD operations for the `users` table.
//!
//! Every query uses PostgreSQL's parameterized query protocol (`$1`, `$2`, ...)
//! so user-supplied data is **never** interpolated into SQL strings. This
//! provides SQL injection protection at the protocol level.
//!
//! ## SQL Injection Safety
//!
//! - All SQL strings are compile-time literals — no runtime string building
//! - All user data flows through `$1`, `$2`, ... parameters
//! - pg.zig sends parameters via PostgreSQL's binary protocol
//! - Type checking at bind time (e.g. passing a string where i32 expected → error)
//!
//! ## Memory
//!
//! String fields in returned `User` structs point into pg.zig's read buffer.
//! They are only valid until the next call to `result.next()`, `result.deinit()`,
//! or `row.deinit()`. For longer lifetimes, use `.{ .dupe = true }` or pass
//! an arena allocator to `row.to()`.

const std = @import("std");
const pg = @import("pg");
const Database = @import("database.zig");

/// A user record from the `users` table.
///
/// Field order matches the SELECT column order (ordinal mapping).
pub const User = struct {
    id: i32,
    name: []const u8,
    email: []const u8,
    age: ?i32 = null,
};

/// Input for creating or updating a user.
///
/// Used by handlers to parse JSON request bodies.
pub const CreateUserInput = struct {
    name: []const u8,
    email: []const u8,
    age: ?i32 = null,
};

const UserRepository = @This();

db: *Database,

/// Initialize with a database reference.
pub fn init(db: *Database) UserRepository {
    return .{ .db = db };
}

/// List all users, ordered by ID.
///
/// Returns a `pg.Result` that must be iterated with `result.next()`.
/// Remember to `defer result.deinit()`.
///
/// SQL: `SELECT id, name, email, age FROM users ORDER BY id`
pub fn getAll(self: *UserRepository) !*pg.Result {
    return self.db.query(
        "SELECT id, name, email, age FROM users ORDER BY id",
        .{},
    );
}

/// Find a user by ID.
///
/// Returns a `User` struct with string fields duped into `arena`,
/// so they remain valid after the query row is released.
/// Returns `null` if no user with that ID exists.
///
/// SQL: `SELECT id, name, email, age FROM users WHERE id = $1`
pub fn getById(self: *UserRepository, id: i32, arena: std.mem.Allocator) !?User {
    if (try self.db.row(
        "SELECT id, name, email, age FROM users WHERE id = $1",
        .{id},
    )) |qr_val| {
        var qr = qr_val;
        defer qr.deinit() catch {};
        return qr.to(User, .{ .allocator = arena }) catch return null;
    }
    return null;
}

/// Create a new user.
///
/// Returns the created `User` (with generated ID) or null on failure.
/// String fields are duped into `arena`.
///
/// SQL: `INSERT INTO users (name, email, age) VALUES ($1, $2, $3) RETURNING id, name, email, age`
pub fn create(self: *UserRepository, input: CreateUserInput, arena: std.mem.Allocator) !?User {
    if (try self.db.row(
        "INSERT INTO users (name, email, age) VALUES ($1, $2, $3) RETURNING id, name, email, age",
        .{ input.name, input.email, input.age },
    )) |qr_val| {
        var qr = qr_val;
        defer qr.deinit() catch {};
        return qr.to(User, .{ .allocator = arena }) catch return null;
    }
    return null;
}

/// Update an existing user by ID.
///
/// Returns the updated `User` or null if no user with that ID exists.
/// String fields are duped into `arena`.
///
/// SQL: `UPDATE users SET name = $1, email = $2, age = $3 WHERE id = $4 RETURNING id, name, email, age`
pub fn update(self: *UserRepository, id: i32, input: CreateUserInput, arena: std.mem.Allocator) !?User {
    if (try self.db.row(
        "UPDATE users SET name = $1, email = $2, age = $3 WHERE id = $4 RETURNING id, name, email, age",
        .{ input.name, input.email, input.age, id },
    )) |qr_val| {
        var qr = qr_val;
        defer qr.deinit() catch {};
        return qr.to(User, .{ .allocator = arena }) catch return null;
    }
    return null;
}

/// Delete a user by ID.
///
/// Returns `true` if a row was deleted, `false` if no user with that ID existed.
///
/// SQL: `DELETE FROM users WHERE id = $1`
pub fn delete(self: *UserRepository, id: i32) !bool {
    const affected = try self.db.exec(
        "DELETE FROM users WHERE id = $1",
        .{id},
    );
    return (affected orelse 0) > 0;
}
