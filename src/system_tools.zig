//! Canonical paths for operating-system tools that must not resolve through
//! the user's PATH. A package can populate the prefix's bin directory, so a
//! bare helper name is attacker-controlled after that directory reaches PATH.

const std = @import("std");

pub const codesign = "/usr/bin/codesign";
pub const install_name_tool = "/usr/bin/install_name_tool";
pub const unzip = "/usr/bin/unzip";
pub const tar = "/usr/bin/tar";
pub const ditto = "/usr/bin/ditto";
pub const hdiutil = "/usr/bin/hdiutil";
pub const sudo = "/usr/bin/sudo";
pub const installer = "/usr/sbin/installer";
pub const install = "/usr/bin/install";
pub const ln = "/bin/ln";
pub const launchctl = "/bin/launchctl";
pub const pgrep = "/usr/bin/pgrep";
pub const killall = "/usr/bin/killall";
pub const sw_vers = "/usr/bin/sw_vers";

test "every trusted system tool uses an absolute path" {
    const paths = [_][]const u8{
        codesign,  install_name_tool, unzip, tar,       ditto, hdiutil, sudo,
        installer, install,           ln,    launchctl, pgrep, sw_vers, killall,
    };
    for (paths) |path| {
        try std.testing.expect(std.fs.path.isAbsolute(path));
    }
}
