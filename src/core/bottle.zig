//! malt — bottle module
//! Bottle download, SHA256 verification, and extraction pipeline.

const std = @import("std");
const ghcr_mod = @import("../net/ghcr.zig");
const atomic = @import("../fs/atomic.zig");
const archive = @import("../fs/archive.zig");

pub const BottleError = error{
    DownloadFailed,
    Sha256Mismatch,
    ExtractionFailed,
    OutOfMemory,
    IoError,
};

pub const BottleResult = struct {
    sha256: []const u8,
    extract_path: []const u8,
};

/// Download a bottle from GHCR, verify SHA256, and extract to tmp.
/// Returns the SHA256 and path to extracted contents.
pub fn download(
    allocator: std.mem.Allocator,
    ghcr: *ghcr_mod.GhcrClient,
    repo: []const u8,
    digest: []const u8,
    expected_sha256: []const u8,
    dest_dir: []const u8,
) BottleError!BottleResult {
    // Download blob into memory
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);

    ghcr.downloadBlob(repo, digest, &body) catch return BottleError.DownloadFailed;

    // Compute SHA256 of downloaded data
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body.items, &hash, .{});
    var hex_buf: [64]u8 = undefined;
    const computed_hex = std.fmt.bufPrint(&hex_buf, "{s}", .{std.fmt.fmtSliceHexLower(&hash)}) catch
        return BottleError.OutOfMemory;

    // Verify SHA256
    if (!std.mem.eql(u8, computed_hex, expected_sha256)) {
        // Clean up dest_dir on mismatch
        std.fs.deleteTreeAbsolute(dest_dir) catch {};
        return BottleError.Sha256Mismatch;
    }

    // Ensure dest_dir exists
    std.fs.makeDirAbsolute(dest_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return BottleError.IoError,
    };

    // Write bottle to temp file for extraction
    var tmp_path_buf: [512]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}/bottle.tar.gz", .{dest_dir}) catch
        return BottleError.OutOfMemory;

    const tmp_file = std.fs.createFileAbsolute(tmp_path, .{}) catch return BottleError.IoError;
    tmp_file.writeAll(body.items) catch {
        tmp_file.close();
        return BottleError.IoError;
    };
    tmp_file.close();

    // Extract
    var out_dir = std.fs.openDirAbsolute(dest_dir, .{}) catch return BottleError.IoError;
    defer out_dir.close();

    const archive_file = std.fs.openFileAbsolute(tmp_path, .{}) catch return BottleError.ExtractionFailed;
    defer archive_file.close();

    var read_buf: [8192]u8 = undefined;
    var reader = archive_file.reader(&read_buf);
    archive.extractTarGz(&reader.interface, out_dir) catch return BottleError.ExtractionFailed;

    // Remove the temp archive file
    std.fs.deleteFileAbsolute(tmp_path) catch {};

    return .{
        .sha256 = expected_sha256,
        .extract_path = dest_dir,
    };
}

/// Verify SHA256 of a file on disk.
pub fn verify(allocator: std.mem.Allocator, file_path: []const u8, expected_sha256: []const u8) !bool {
    const file = std.fs.openFileAbsolute(file_path, .{}) catch return false;
    defer file.close();

    const stat = file.stat() catch return false;
    const data = allocator.alloc(u8, stat.size) catch return false;
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch return false;
    if (bytes_read < data.len) return false;

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    var hex_buf: [64]u8 = undefined;
    const computed_hex = std.fmt.bufPrint(&hex_buf, "{s}", .{std.fmt.fmtSliceHexLower(&hash)}) catch return false;

    return std.mem.eql(u8, computed_hex, expected_sha256);
}
