//! GHCR blob URL parser + repo-path builder. Pure helpers shared
//! between the install-phase token prefetch, the per-worker blob
//! download, and the formula-name → GHCR repo mapping.

const std = @import("std");

/// Parsed `<repo>@<digest>` reference from a GHCR blob URL.
/// Both fields are slices into the input URL — no allocation; valid
/// for the lifetime of the caller's string.
pub const GhcrRef = struct {
    repo: []const u8,
    digest: []const u8,
};

/// Split a `https://ghcr.io/v2/<repo>/blobs/<digest>` URL into its
/// `<repo>` and `<digest>` parts, returning `null` if the URL is not
/// in that shape. Exposed so the install-phase token prefetch and the
/// per-worker blob download parse identically — a single pure helper
/// prevents the two code paths from drifting apart.
pub fn parseGhcrUrl(url: []const u8) ?GhcrRef {
    const prefix = "https://ghcr.io/v2/";
    if (!std.mem.startsWith(u8, url, prefix)) return null;
    const path = url[prefix.len..];
    const blobs_pos = std.mem.find(u8, path, "/blobs/") orelse return null;
    return .{
        .repo = path[0..blobs_pos],
        .digest = path[blobs_pos + "/blobs/".len ..],
    };
}

/// Build GHCR repo path from formula name, replacing @ with /
pub fn buildGhcrRepo(buf: []u8, name: []const u8) ![]const u8 {
    // Replace @ with / for versioned formulas (openssl@3 -> homebrew/core/openssl/3)
    var pos: usize = 0;
    const prefix_str = "homebrew/core/";
    if (pos + prefix_str.len > buf.len) return error.OutOfMemory;
    @memcpy(buf[pos .. pos + prefix_str.len], prefix_str);
    pos += prefix_str.len;

    for (name) |ch| {
        if (pos >= buf.len) return error.OutOfMemory;
        buf[pos] = if (ch == '@') '/' else ch;
        pos += 1;
    }
    return buf[0..pos];
}
