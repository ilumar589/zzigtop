//! Database module root.
//!
//! Re-exports the database connection pool and repository types.
//! Separated from the HTTP module so the data layer can be used
//! independently of the web server (e.g. CLI tools, migrations).

/// PostgreSQL connection-pool wrapper with lifecycle helpers.
pub const Database = @import("database.zig");
/// CRUD repository for the `users` table.
pub const UserRepository = @import("user_repository.zig");
