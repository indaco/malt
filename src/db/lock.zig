const std = @import("std");

pub const LockFile = struct {
    _fd: ?std.posix.fd_t = null,
    _path: []const u8 = "",

    /// Acquires an advisory file lock at the given path, waiting up to timeout_ms.
    pub fn acquire(path: []const u8, timeout_ms: u32) !LockFile {
        _ = .{ path, timeout_ms };
        return error.NotImplemented;
    }

    /// Releases the advisory file lock.
    pub fn release(self: *LockFile) void {
        self._fd = null;
    }

    /// Returns the PID of the process holding the lock, or null if not locked.
    pub fn holderPid(path: []const u8) !?std.posix.pid_t {
        _ = path;
        return error.NotImplemented;
    }
};
