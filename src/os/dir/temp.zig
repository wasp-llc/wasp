const TempDir = @This();
const std = @import("std");
const Dir = std.Io.Dir;
const file = @import("file.zig");
const global = @import("../global.zig");
const log = std.log.scoped(.tempdir);
dir: Dir,
parent: Dir,
name_buf: [file.random_basename_len:0]u8,
pub fn init() !TempDir {
    var tmp_path_buf: [file.random_basename_len:0]u8 = undefined;
    const dir = dir: {
        const cwd = std.Io.Dir.cwd();
        const tmp_dir = try file.allocTmpDir(std.heap.page_allocator, global.environ());
        defer file.freeTmpDir(std.heap.page_allocator, tmp_dir);
        break :dir try cwd.openDir(global.io(), tmp_dir, .{});
    };
    while (true) {
        const tmp_path = try file.randomBasename(&tmp_path_buf);
        tmp_path_buf[tmp_path.len] = 0;
        dir.createDir(global.io(), tmp_path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |e| return e,
        };
        return TempDir{
            .dir = try dir.openDir(global.io(), tmp_path, .{}),
            .parent = dir,
            .name_buf = tmp_path_buf,
        };
    }
}
pub fn name(self: *TempDir) []const u8 {
    return std.mem.sliceTo(&self.name_buf, 0);
}
pub fn deinit(self: *TempDir) void {
    self.close(.delete);
}
pub const CloseMode = enum { delete, retain };
pub fn close(self: *TempDir, mode: CloseMode) void {
    self.dir.close(global.io());
    switch (mode) {
        .delete => self.parent.deleteTree(global.io(), self.name()) catch |err|
            log.err("error deleting temp dir err={}", .{err}),
        .retain => {},
    }
    self.parent.close(global.io());
}
test {
    const testing = std.testing;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var path_len: usize = undefined;
    {
        var td = try init();
        errdefer td.deinit();
        const nameval = td.name();
        try testing.expect(nameval.len > 0);
        var dir = try td.parent.openDir(testing.io, nameval, .{});
        dir.close(testing.io);
        path_len = try td.dir.realPath(testing.io, &path_buf);
        td.deinit();
    }
    try testing.expectError(
        error.FileNotFound,
        Dir.openDirAbsolute(testing.io, path_buf[0..path_len], .{}),
    );
}
test "close retains temporary directory" {
    const testing = std.testing;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var path_len: usize = undefined;
    {
        var td = try init();
        errdefer td.deinit();
        path_len = try td.dir.realPath(testing.io, &path_buf);
        td.close(.retain);
    }
    defer Dir.deleteDirAbsolute(testing.io, path_buf[0..path_len]) catch {};
    var dir = try Dir.openDirAbsolute(testing.io, path_buf[0..path_len], .{});
    dir.close(testing.io);
}
