//! Database connection pool wrapper.
//!
//! Thin wrapper around `pg.Pool` providing:
//! - Configuration struct with sensible defaults for local development
//! - Server lifecycle integration (init/deinit)
//! - Convenience methods that delegate to the pool
//!
//! All queries use PostgreSQL's parameterized query protocol (`$1`, `$2`, ...)
//! which sends parameters as binary data — never interpolated into SQL strings.
//! This provides SQL injection protection at the protocol level.

const std = @import("std");
const pg = @import("pg");

pub const Pool = pg.Pool;
pub const Conn = pg.Conn;
pub const Result = pg.Result;
pub const Row = pg.Row;
pub const QueryRow = pg.QueryRow;

const Io = std.Io;

const Database = @This();

pool: *pg.Pool,

/// Database connection configuration.
///
/// Defaults match the Docker Compose setup in `docker/compose.yml`.
pub const Config = struct {
    /// PostgreSQL host address.
    host: []const u8 = "127.0.0.1",
    /// PostgreSQL port.
    port: u16 = 5432,
    /// Database username.
    username: []const u8 = "ziglearn",
    /// Database password.
    password: []const u8 = "ziglearn",
    /// Database name.
    database: []const u8 = "ziglearn",
    /// Number of connections in the pool.
    pool_size: u16 = 5,
    /// Pool connection timeout in seconds.
    timeout_seconds: u16 = 10,
};

/// Initialize the database connection pool.
///
/// Opens `config.pool_size` connections to PostgreSQL. The pool runs
/// a background thread to reconnect any failed connections.
///
/// Call `deinit()` to close all connections when shutting down.
pub fn init(allocator: std.mem.Allocator, io: Io, config: Config) !Database {
    const pool = try pg.Pool.init(allocator, io, .{
        .size = config.pool_size,
        .timeout = Io.Duration.fromSeconds(config.timeout_seconds),
        .connect = .{
            .port = config.port,
            .host = config.host,
        },
        .auth = .{
            .username = config.username,
            .database = config.database,
            .password = config.password,
        },
    });
    return .{ .pool = pool };
}

/// Close all pooled connections and release resources.
pub fn deinit(self: *Database) void {
    self.pool.deinit();
}

/// Execute a query that returns rows.
///
/// Acquires a connection from the pool, executes the query, and
/// automatically returns the connection when `result.deinit()` is called.
///
/// All parameters use `$1`, `$2`, ... placeholders — never string interpolation.
///
/// Example:
/// ```zig
/// var result = try db.query("SELECT id, name FROM users WHERE age > $1", .{18});
/// defer result.deinit();
/// while (try result.next()) |row| {
///     const id = try row.get(i32, 0);
/// }
/// ```
pub fn query(self: *Database, sql: []const u8, values: anytype) !*Result {
    return self.pool.query(sql, values);
}

/// Execute a command (INSERT/UPDATE/DELETE) that returns affected row count.
///
/// Returns the number of rows affected, or null.
///
/// Example:
/// ```zig
/// const affected = try db.exec("DELETE FROM users WHERE id = $1", .{42});
/// ```
pub fn exec(self: *Database, sql: []const u8, values: anytype) !?i64 {
    return self.pool.exec(sql, values);
}

/// Execute a query that returns exactly one row.
///
/// Returns null if no rows match. Returns an error if more than one row matches.
/// Call `query_row.deinit()` when done.
///
/// Example:
/// ```zig
/// if (try db.row("SELECT id, name FROM users WHERE id = $1", .{1})) |qr_val| {
///     var qr = qr_val;
///     defer qr.deinit() catch {};
///     const name = try qr.get([]const u8, 1);
/// }
/// ```
pub fn row(self: *Database, sql: []const u8, values: anytype) !?QueryRow {
    return self.pool.row(sql, values);
}

/// Acquire a raw connection from the pool for multi-statement transactions.
///
/// Remember to release: `defer db.release(conn);`
///
/// Example:
/// ```zig
/// const conn = try db.acquire();
/// defer db.release(conn);
/// try conn.begin();
/// errdefer conn.rollback() catch {};
/// _ = try conn.exec("INSERT INTO ...", .{...});
/// try conn.commit();
/// ```
pub fn acquire(self: *Database) !*pg.Conn {
    return self.pool.acquire();
}

/// Release a connection back to the pool.
pub fn release(self: *Database, conn: *pg.Conn) void {
    self.pool.release(conn);
}
