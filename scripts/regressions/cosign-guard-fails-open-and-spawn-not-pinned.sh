#!/usr/bin/env bash
# Regression: the self-update trust guard walked PATH itself, approved the
# first entry it could `access(X_OK)`, then discarded that resolution and
# spawned the bare name `cosign`. The kernel ran its own PATH walk, which
# continues past an entry whose execve returns ENOENT -- exactly what a script
# with a missing shebang interpreter returns. So the guard vetted one binary
# and the kernel ran another, which could be `<prefix>/bin/cosign`: a rubber
# stamp inside malt's own prefix turned every `mt version update` into a
# no-op signature check.
#
# The second arm was fail-open resolution: both realpath sites exited the
# guard on the success path, so any resolution error read as "trusted".
#
# There is no CLI surface that reaches the guard without a real release
# download, so a standalone ReleaseSafe `zig test` harness drives
# verifyCosignBlob directly with a broken-shebang decoy ahead of a runnable
# shim in the prefix, and asserts the call refuses. The harness lives at the
# repo root because src/update/verify.zig imports sibling modules by relative
# path.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network required; finishes well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# Source-shape pin for the fail-open arm: no resolution error may leave the
# guard on its success path.
if grep -qE 'realPathFile\(.*\) catch return;' "$ROOT/src/update/verify.zig"; then
  echo "FAIL: the cosign resolver still treats a realpath error as trusted" >&2
  exit 1
fi

# Pin the defect itself: argv[0] must come from the resolver, never from the
# caller-supplied name, or the spawn resolves PATH a second time.
if grep -qE '^[[:space:]]+args\.cosign_bin,$' "$ROOT/src/update/verify.zig"; then
  echo "FAIL: the cosign spawn takes argv[0] from the unresolved input again" >&2
  exit 1
fi

# The harness cannot notice the in-tree tests being deleted, so guard them too.
while IFS= read -r name; do
  if ! grep -qF -- "$name" "$ROOT/src/update/verify.zig" "$ROOT/tests/verify_test.zig"; then
    echo "FAIL: a cosign pinning test is missing: $name" >&2
    exit 1
  fi
done <<'NAMES'
the resolver pins the spawn to the candidate it vetted
the spawned cosign is the one the guard resolved
NAMES

HARNESS="$ROOT/.cosign-pin-regression.$$.zig"
TMP=$(mktemp -d)
trap 'rm -f "$HARNESS"; rm -rf "$TMP"' EXIT

cat >"$HARNESS" <<'ZIG'
const std = @import("std");
const verify = @import("src/update/verify.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn processEnviron() std.process.Environ {
    var n: usize = 0;
    while (std.c.environ[n] != null) : (n += 1) {}
    return .{ .block = .{ .slice = std.c.environ[0..n :null] } };
}

fn writeExec(io: std.Io, path: []const u8, body: []const u8) !void {
    const f = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, body);
    try f.setPermissions(io, std.Io.File.Permissions.fromMode(0o755));
}

test "a cosign the guard never vetted cannot be spawned" {
    const a = std.testing.allocator;
    const dio = std.Options.debug_io;
    const root = std.process.Environ.getPosix(processEnviron(), "MALT_COSIGN_PIN_TMP").?;

    const decoy_dir = try std.fmt.allocPrint(a, "{s}/decoy", .{root});
    defer a.free(decoy_dir);
    const prefix = try std.fmt.allocPrint(a, "{s}/prefix", .{root});
    defer a.free(prefix);
    const prefix_bin = try std.fmt.allocPrint(a, "{s}/bin", .{prefix});
    defer a.free(prefix_bin);
    try std.Io.Dir.cwd().createDirPath(dio, decoy_dir);
    try std.Io.Dir.cwd().createDirPath(dio, prefix_bin);

    // access(X_OK) says yes, execve says ENOENT: the kernel walks past it.
    const decoy = try std.fmt.allocPrint(a, "{s}/cosign", .{decoy_dir});
    defer a.free(decoy);
    try writeExec(dio, decoy, "#!/nonexistent/interp\n");

    // The rubber stamp the kernel would reach next.
    const shim = try std.fmt.allocPrint(a, "{s}/cosign", .{prefix_bin});
    defer a.free(shim);
    try writeExec(dio, shim, "#!" ++ "/bin/sh\nexit 0\n");

    // The spawn reads PATH from the runtime's environ, the guard from the
    // injected one; set both or the test proves nothing.
    const path_val = try std.fmt.allocPrintSentinel(a, "{s}:{s}", .{ decoy_dir, prefix_bin }, 0);
    defer a.free(path_val);
    if (setenv("PATH", path_val.ptr, 1) != 0) return error.SetEnvFailed;

    // debug_io cannot spawn -- it fails with OutOfMemory, which reads as a pass.
    var threaded: std.Io.Threaded = .init(a, .{ .environ = processEnviron() });
    defer threaded.deinit();

    const result = verify.verifyCosignBlob(threaded.io(), .{
        .cosign_bin = "cosign",
        .environ = processEnviron(),
        .prefix = prefix,
        .blob_path = "/dev/null",
        .bundle_path = "/dev/null",
        .cert_identity_regex = "^x$",
        .oidc_issuer = "https://example.invalid",
    });
    if (result) |_| return error.UnvettedCosignRan else |_| {}
}
ZIG

if OUT=$(cd "$ROOT" && MALT_COSIGN_PIN_TMP="$TMP" zig test -lc -OReleaseSafe "$HARNESS" 2>&1); then
  echo "PASS: the cosign spawn is pinned to the vetted resolution"
elif printf '%s' "$OUT" | grep -q 'UnvettedCosignRan'; then
  echo "FAIL: the guard vetted a PATH entry the spawn did not run; a prefix-resident cosign rubber-stamped the update" >&2
  exit 1
else
  # A harness that will not build is not a verdict on the bug - say so rather
  # than sending whoever triages this after a vulnerability that may not exist.
  echo "FAIL: the regression harness did not build or run; this is not a verdict on the bug" >&2
  printf '%s\n' "$OUT" >&2
  exit 2
fi
