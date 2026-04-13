//! malt — launchd plist emitter
//!
//! Generates Apple plist XML for loading a service under launchd. Output is
//! deterministic (fixed key order) so golden tests can byte-compare.

const std = @import("std");

pub const EnvPair = struct {
    key: []const u8,
    value: []const u8,
};

pub const ServiceSpec = struct {
    label: []const u8,
    program_args: []const []const u8,
    working_dir: ?[]const u8 = null,
    env: []const EnvPair = &.{},
    stdout_path: []const u8,
    stderr_path: []const u8,
    run_at_load: bool = true,
    keep_alive: bool = true,
};

pub fn render(spec: ServiceSpec, writer: anytype) !void {
    try writer.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\
    );

    try writer.writeAll("    <key>Label</key>\n    <string>");
    try writeEscaped(writer, spec.label);
    try writer.writeAll("</string>\n");

    try writer.writeAll("    <key>ProgramArguments</key>\n    <array>\n");
    for (spec.program_args) |arg| {
        try writer.writeAll("        <string>");
        try writeEscaped(writer, arg);
        try writer.writeAll("</string>\n");
    }
    try writer.writeAll("    </array>\n");

    if (spec.working_dir) |wd| {
        try writer.writeAll("    <key>WorkingDirectory</key>\n    <string>");
        try writeEscaped(writer, wd);
        try writer.writeAll("</string>\n");
    }

    if (spec.env.len > 0) {
        try writer.writeAll("    <key>EnvironmentVariables</key>\n    <dict>\n");
        for (spec.env) |pair| {
            try writer.writeAll("        <key>");
            try writeEscaped(writer, pair.key);
            try writer.writeAll("</key>\n        <string>");
            try writeEscaped(writer, pair.value);
            try writer.writeAll("</string>\n");
        }
        try writer.writeAll("    </dict>\n");
    }

    try writer.writeAll("    <key>StandardOutPath</key>\n    <string>");
    try writeEscaped(writer, spec.stdout_path);
    try writer.writeAll("</string>\n");

    try writer.writeAll("    <key>StandardErrorPath</key>\n    <string>");
    try writeEscaped(writer, spec.stderr_path);
    try writer.writeAll("</string>\n");

    try writer.writeAll("    <key>RunAtLoad</key>\n    ");
    try writer.writeAll(if (spec.run_at_load) "<true/>\n" else "<false/>\n");

    if (spec.keep_alive) {
        try writer.writeAll(
            \\    <key>KeepAlive</key>
            \\    <dict>
            \\        <key>SuccessfulExit</key>
            \\        <false/>
            \\    </dict>
            \\
        );
    }

    try writer.writeAll("</dict>\n</plist>\n");
}

fn writeEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&apos;"),
            else => try writer.writeByte(c),
        }
    }
}
