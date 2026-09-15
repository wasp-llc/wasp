const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const testing = std.testing;
pub fn expand(
    io: std.Io,
    alloc: Allocator,
    environ_map: *const std.process.Environ.Map,
    cmd: []const u8,
) !?[]u8 {
    if (std.mem.indexOfScalar(u8, cmd, '/') != null) {
        return try alloc.dupe(u8, cmd);
    }
    const PATH = environ_map.get("PATH") orelse return null;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.mem.tokenizeScalar(u8, PATH, std.fs.path.delimiter);
    var seen_eacces = false;
    while (it.next()) |search_path| {
        const path_len = search_path.len + cmd.len + 1;
        if (path_buf.len < path_len) return error.PathTooLong;
        @memcpy(path_buf[0..search_path.len], search_path);
        path_buf[search_path.len] = std.fs.path.sep;
        @memcpy(path_buf[search_path.len + 1 ..][0..cmd.len], cmd);
        path_buf[path_len] = 0;
        const full_path = path_buf[0..path_len :0];
        const f = std.Io.Dir.cwd().openFile(
            io,
            full_path,
            .{},
        ) catch |err| switch (err) {
            error.FileNotFound => continue,
            error.AccessDenied => {
                seen_eacces = true;
                continue;
            },
            else => return err,
        };
        defer f.close(io);
        const stat = try f.stat(io);
        if (stat.kind != .directory and isExecutable(stat.permissions)) {
            return try alloc.dupe(u8, full_path);
        }
    }
    if (seen_eacces) return error.AccessDenied;
    return null;
}
fn isExecutable(perms: std.Io.File.Permissions) bool {
    return switch (builtin.os.tag) {
        .windows => true,
        else => posix: {
            break :posix switch (std.posix.mode_t) {
                u0 => true,
                else => perms.toMode() & 0o0111 != 0,
            };
        },
    };
}
test "expand: hostname" {
    var environ_map = try testing.environ.createMap(testing.allocator);
    defer environ_map.deinit();
    const executable = if (builtin.os.tag == .windows) "hostname.exe" else "uname";
    const path = (try expand(testing.io, testing.allocator, &environ_map, executable)).?;
    defer testing.allocator.free(path);
    try testing.expect(path.len > executable.len);
}
test "expand: does not exist" {
    var environ_map = try testing.environ.createMap(testing.allocator);
    defer environ_map.deinit();
    const path = try expand(testing.io, testing.allocator, &environ_map, "thisreallyprobablydoesntexist123");
    try testing.expect(path == null);
}
test "expand: slash" {
    var environ_map = try testing.environ.createMap(testing.allocator);
    defer environ_map.deinit();
    const path = (try expand(testing.io, testing.allocator, &environ_map, "foo/env")).?;
    defer testing.allocator.free(path);
    try testing.expect(path.len == 7);
}
