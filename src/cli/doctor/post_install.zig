//! malt — doctor post_install DSL status probe.
//!
//! Extracted from the primary walker so the ruby/DSL/formula/api/client
//! imports can live at the top of the file rather than as lazy
//! per-function imports inside the walker.

const std = @import("std");
const sqlite = @import("../../db/sqlite.zig");
const output = @import("../../ui/output.zig");
const ruby_sub = @import("../../core/ruby_subprocess.zig");
const dsl = @import("../../core/dsl/root.zig");
const formula_mod = @import("../../core/formula.zig");
const api_mod = @import("../../net/api.zig");
const client_mod = @import("../../net/client.zig");

/// Check post_install DSL support status for installed formulae.
/// Called when `malt doctor --post-install-status` is passed.
pub fn checkPostInstallStatus(allocator: std.mem.Allocator, prefix: []const u8) void {
    output.info("Post-install DSL status:", .{});

    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return;
    var db = sqlite.Database.open(db_path) catch return;
    defer db.close();

    var stmt = db.prepare("SELECT name, version FROM kegs;") catch return;
    defer stmt.finalize();

    var native_count: u32 = 0;
    var partial_count: u32 = 0;
    var no_pi_count: u32 = 0;
    var total: u32 = 0;

    var http = client_mod.HttpClient.init(allocator);
    defer http.deinit();

    var cache_buf: [512]u8 = undefined;
    const cache_dir = std.fmt.bufPrint(&cache_buf, "{s}/cache", .{prefix}) catch return;
    var api = api_mod.BrewApi.init(allocator, &http, cache_dir);

    while (stmt.step() catch false) {
        const name_raw = stmt.columnText(0) orelse continue;
        const name = std.mem.sliceTo(name_raw, 0);
        total += 1;

        const formula_json = api.fetchFormula(name) catch {
            no_pi_count += 1;
            continue;
        };
        var formula = formula_mod.parseFormula(allocator, formula_json) catch {
            allocator.free(formula_json);
            no_pi_count += 1;
            continue;
        };
        defer formula.deinit();

        if (!formula.post_install_defined) {
            no_pi_count += 1;
            continue;
        }

        const tap_path = ruby_sub.findHomebrewCoreTap();
        var rb_buf: [1024]u8 = undefined;
        const rb_path = if (tap_path) |tp| ruby_sub.resolveFormulaRbPath(&rb_buf, tp, name) else null;

        const post_install_src = if (rb_path) |src_path|
            ruby_sub.extractPostInstallBody(allocator, src_path)
        else
            ruby_sub.fetchPostInstallFromGitHub(allocator, name);

        if (post_install_src) |src| {
            defer allocator.free(src);

            var flog = dsl.FallbackLog.init(allocator);
            defer flog.deinit();

            // Dry-run the DSL (don't actually execute, just parse)
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();

            var lexer = dsl.lexer.Lexer.init(src);
            var prs = dsl.parser.Parser.init(a, &lexer);
            _ = prs.parseBlock() catch {
                partial_count += 1;
                output.warn("  {s}: parse error", .{name});
                continue;
            };
            native_count += 1;
            output.success("  {s}: DSL supported (parseable)", .{name});
        } else {
            partial_count += 1;
            output.warn("  {s}: source not available", .{name});
        }
    }

    output.info("", .{});
    output.info("Installed: {d} total, {d} without post_install, {d} with post_install", .{ total, no_pi_count, native_count + partial_count });
    if (native_count + partial_count > 0) {
        output.info("DSL parseable: {d}/{d} ({d}%)", .{ native_count, native_count + partial_count, if (native_count + partial_count > 0) 100 * native_count / (native_count + partial_count) else 0 });
    }
}
