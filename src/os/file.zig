const std = @import("std");
const builtin = @import("builtin");
const global = @import("../global.zig");
const posix = std.posix;
const windows = @import("windows.zig");
const log = std.log.scoped(.os);
pub const rlimit = if (@hasDecl(posix.system, "rlimit")) posix.rlimit else struct {};
pub fn fixMaxFiles() ?rlimit {
    if (!@hasDecl(posix.system, "rlimit") or
        posix.system.rlimit == void) return null;
    const old = posix.getrlimit(.NOFILE) catch {
        log.warn("failed to query file handle limit, may limit max windows", .{});
        return null;
    };
    if (old.cur >= old.max) {
        log.debug("file handle limit already maximized value={}", .{old.cur});
        return old;
    }
    var lim = old;
    var min: posix.rlim_t = lim.cur;
    var max: posix.rlim_t = 1 << 20;
    if (lim.max != posix.RLIM.INFINITY) {
        min = lim.max;
        max = lim.max;
    }
    while (true) {
        lim.cur = min + @divTrunc(max - min, 2);
        if (posix.setrlimit(.NOFILE, lim)) |_| {
            min = lim.cur;
        } else |_| {
            max = lim.cur;
        }
        if (min + 1 >= max) break;
    }
    log.debug("file handle limit raised value={}", .{lim.cur});
    return old;
}
pub fn restoreMaxFiles(lim: rlimit) void {
    if (!@hasDecl(posix.system, "rlimit")) return;
    posix.setrlimit(.NOFILE, lim) catch {};
}
pub fn allocTmpDir(allocator: std.mem.Allocator, environ: std.process.Environ) std.mem.Allocator.Error![]const u8 {
    if (builtin.os.tag == .windows) {
        var buf: [windows.MAX_PATH + 1:0]u16 = undefined;
        const len = windows.exp.kernel32.GetTempPathW(buf.len, &buf);
        if (len > 0) {
            const trimmed = std.mem.trimEnd(u16, buf[0..len], &.{std.fs.path.sep});
            if (std.unicode.utf16LeToUtf8Alloc(allocator, trimmed)) |utf8| {
                return utf8;
            } else |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => log.warn("failed to convert temp dir path from windows string: {}", .{e}),
            }
        }
        return allocator.dupe(u8, "C:\\Windows\\Temp");
    }
    const tmpdir = environ.getPosix("TMPDIR") orelse environ.getPosix("TMP") orelse return "/tmp";
    return std.mem.trimEnd(u8, tmpdir, &.{std.fs.path.sep});
}
pub fn freeTmpDir(allocator: std.mem.Allocator, dir: []const u8) void {
    if (builtin.os.tag != .windows) return;
    allocator.free(dir);
}
const random_basename_bytes = 16;
const b64_encoder = std.base64.url_safe_no_pad.Encoder;
pub const RandomBasenameError = error{BufferTooSmall};
pub const random_basename_len = b64_encoder.calcSize(random_basename_bytes);
pub fn randomBasename(buf: []u8) RandomBasenameError![]const u8 {
    if (buf.len < random_basename_len) return error.BufferTooSmall;
    var rand_buf: [random_basename_bytes]u8 = undefined;
    global.io().random(&rand_buf);
    return b64_encoder.encode(buf[0..random_basename_len], &rand_buf);
}
pub fn randomTmpPath(
    allocator: std.mem.Allocator,
    prefix: []const u8,
) std.mem.Allocator.Error![]u8 {
    var name_buf: [random_basename_len]u8 = undefined;
    const basename = randomBasename(&name_buf) catch unreachable;
    return std.fmt.allocPrint(
        allocator,
        "{s}{c}{s}{s}",
        .{ global.tmpDirPath(), std.fs.path.sep, prefix, basename },
    );
}
test randomBasename {
    const testing = std.testing;
    var buf: [random_basename_len]u8 = undefined;
    const name = try randomBasename(&buf);
    try testing.expectEqual(random_basename_len, name.len);
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
        try testing.expect(ok);
    }
    var small: [random_basename_len - 1]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, randomBasename(&small));
}
