//! malt — cask artifact resolution tests
//! Covers Content-Disposition parsing and the HEAD-based redirect
//! fallback for extensionless cask URLs.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const cask = malt.cask;

// --- artifactTypeFromUrl: extensionless / edge-case URLs ---

test "artifactTypeFromUrl returns unknown for extensionless path with query" {
    try testing.expectEqual(
        cask.ArtifactType.unknown,
        cask.artifactTypeFromUrl("https://releases.example.com/v1.0/download?build=arm"),
    );
}

test "artifactTypeFromUrl returns unknown for bare path" {
    try testing.expectEqual(
        cask.ArtifactType.unknown,
        cask.artifactTypeFromUrl("https://example.com/releases/latest/download"),
    );
}

test "artifactTypeFromUrl detects .dmg with fragment" {
    try testing.expectEqual(
        cask.ArtifactType.dmg,
        cask.artifactTypeFromUrl("https://example.com/App.dmg#anchor"),
    );
}

test "artifactTypeFromUrl detects .pkg with query" {
    try testing.expectEqual(
        cask.ArtifactType.pkg,
        cask.artifactTypeFromUrl("https://cdn.example.com/Install.pkg?v=2"),
    );
}

// --- artifactTypeFromContentDisposition ---

test "Content-Disposition: extracts .dmg from filename" {
    try testing.expectEqual(
        cask.ArtifactType.dmg,
        cask.artifactTypeFromContentDisposition("attachment; filename=\"App.dmg\""),
    );
}

test "Content-Disposition: extracts .zip from filename" {
    try testing.expectEqual(
        cask.ArtifactType.zip,
        cask.artifactTypeFromContentDisposition("attachment; filename=\"App.zip\""),
    );
}

test "Content-Disposition: extracts .pkg from filename" {
    try testing.expectEqual(
        cask.ArtifactType.pkg,
        cask.artifactTypeFromContentDisposition("attachment; filename=\"Installer.pkg\""),
    );
}

test "Content-Disposition: handles filename* (RFC 5987 extended)" {
    try testing.expectEqual(
        cask.ArtifactType.dmg,
        cask.artifactTypeFromContentDisposition("attachment; filename*=UTF-8''My%20App.dmg"),
    );
}

test "Content-Disposition: handles unquoted filename" {
    try testing.expectEqual(
        cask.ArtifactType.zip,
        cask.artifactTypeFromContentDisposition("attachment; filename=release.zip"),
    );
}

test "Content-Disposition: returns unknown for no filename" {
    try testing.expectEqual(
        cask.ArtifactType.unknown,
        cask.artifactTypeFromContentDisposition("attachment"),
    );
}

test "Content-Disposition: returns unknown for non-matching extension" {
    try testing.expectEqual(
        cask.ArtifactType.unknown,
        cask.artifactTypeFromContentDisposition("attachment; filename=\"archive.bin\""),
    );
}

// A `.tar.gz` filename surfaced through Content-Disposition must resolve
// to tar_gz — download endpoints that 302 to a versioned release URL
// sometimes expose the extension only via the header.
test "Content-Disposition: extracts .tar.gz from filename" {
    try testing.expectEqual(
        cask.ArtifactType.tar_gz,
        cask.artifactTypeFromContentDisposition("attachment; filename=\"release.tar.gz\""),
    );
}

test "Content-Disposition: extracts .tgz from filename" {
    try testing.expectEqual(
        cask.ArtifactType.tar_gz,
        cask.artifactTypeFromContentDisposition("attachment; filename=\"release.tgz\""),
    );
}

test "Content-Disposition: returns unknown for empty string" {
    try testing.expectEqual(
        cask.ArtifactType.unknown,
        cask.artifactTypeFromContentDisposition(""),
    );
}

test "Content-Disposition: handles case with spaces around equals" {
    try testing.expectEqual(
        cask.ArtifactType.dmg,
        cask.artifactTypeFromContentDisposition("attachment; filename = \"App.dmg\""),
    );
}

// --- resolveArtifactType: combined resolution logic ---

test "resolveArtifactType returns url-detected type without network" {
    const result = cask.resolveArtifactType(
        testing.allocator,
        "https://example.com/App.dmg",
        null,
    );
    try testing.expectEqual(cask.ArtifactType.dmg, result);
}

test "resolveArtifactType falls back to Content-Disposition" {
    // Simulates a HEAD response that returned a Content-Disposition header.
    // When the URL has no extension, Content-Disposition is the next signal.
    const result = cask.resolveArtifactType(
        testing.allocator,
        "https://releases.example.com/v1.0/download?build=arm",
        "attachment; filename=\"Raycast.dmg\"",
    );
    try testing.expectEqual(cask.ArtifactType.dmg, result);
}

test "resolveArtifactType returns unknown when all signals fail" {
    const result = cask.resolveArtifactType(
        testing.allocator,
        "https://releases.example.com/download",
        null,
    );
    try testing.expectEqual(cask.ArtifactType.unknown, result);
}

test "resolveArtifactType prefers url over Content-Disposition" {
    // URL says .zip, Content-Disposition says .dmg — trust the URL
    const result = cask.resolveArtifactType(
        testing.allocator,
        "https://example.com/App.zip",
        "attachment; filename=\"wrong.dmg\"",
    );
    try testing.expectEqual(cask.ArtifactType.zip, result);
}

test "resolveArtifactType handles Content-Disposition with unknown ext" {
    const result = cask.resolveArtifactType(
        testing.allocator,
        "https://example.com/download",
        "attachment; filename=\"archive.bin\"",
    );
    try testing.expectEqual(cask.ArtifactType.unknown, result);
}

// The HEAD fallback must surface tar.gz for extensionless release URLs
// (e.g. `releases/latest/download`) when the filename only appears in
// the Content-Disposition header.
test "resolveArtifactType falls back to Content-Disposition for .tar.gz" {
    const result = cask.resolveArtifactType(
        testing.allocator,
        "https://releases.example.com/v1.0/download?build=arm",
        "attachment; filename=\"tool.tar.gz\"",
    );
    try testing.expectEqual(cask.ArtifactType.tar_gz, result);
}
