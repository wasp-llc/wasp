const std = @import("std");
pub const ParseOptions = struct {
    mac_address: bool = false,
    raw_path: bool = false,
};
pub const ParseError = std.Uri.ParseError || error{InvalidMacAddress};
pub fn parse(text: []const u8, options: ParseOptions) ParseError!std.Uri {
    var uri = std.Uri.parse(text) catch |err| uri: {
        if (err != error.InvalidPort or !options.mac_address) return err;
        const scheme_end = std.mem.indexOf(u8, text, "://") orelse {
            return error.InvalidFormat;
        };
        const scheme = text[0..scheme_end];
        const host_start = scheme_end + "://".len;
        const host_end = std.mem.indexOfScalarPos(u8, text, host_start, '/') orelse text.len;
        const mac_address = text[host_start..host_end];
        if (!isValidMacAddress(mac_address)) return error.InvalidMacAddress;
        var uri = try std.Uri.parseAfterScheme(scheme, text[host_end..]);
        uri.host = .{ .percent_encoded = mac_address };
        break :uri uri;
    };
    if (options.mac_address and uri.host != null) mac: {
        const host = uri.host.?.percent_encoded;
        if (host.len != 14 or std.mem.count(u8, host, ":") != 4) break :mac;
        const port = uri.port orelse break :mac;
        if (port > 99) break :mac;
        const host_start = @intFromPtr(host.ptr) - @intFromPtr(text.ptr);
        const path_start = @intFromPtr(uri.path.percent_encoded.ptr) - @intFromPtr(text.ptr);
        const mac_address = text[host_start..path_start];
        if (!isValidMacAddress(mac_address)) return error.InvalidMacAddress;
        uri.host = .{ .percent_encoded = mac_address };
        uri.port = null;
    }
    if (options.raw_path) {
        const path_start = @intFromPtr(uri.path.percent_encoded.ptr) - @intFromPtr(text.ptr);
        uri.path = .{ .raw = text[path_start..] };
        uri.query = null;
        uri.fragment = null;
    }
    return uri;
}
test "parse: mac_address" {
    const testing = @import("std").testing;
    const uri1 = try parse("file://00:12:34:56:78:90/path", .{ .mac_address = true });
    try testing.expectEqualStrings("file", uri1.scheme);
    try testing.expectEqualStrings("00:12:34:56:78:90", uri1.host.?.percent_encoded);
    try testing.expectEqualStrings("/path", uri1.path.percent_encoded);
    try testing.expectEqual(null, uri1.port);
    const uri2 = try parse("file://00:12:34:56:78:90:999/path", .{ .mac_address = true });
    try testing.expectEqualStrings("file", uri2.scheme);
    try testing.expectEqualStrings("00:12:34:56:78:90", uri2.host.?.percent_encoded);
    try testing.expectEqualStrings("/path", uri2.path.percent_encoded);
    try testing.expectEqual(999, uri2.port);
    const uri3 = try parse("file://ab:cd:ef:ab:cd:ef/path", .{ .mac_address = true });
    try testing.expectEqualStrings("file", uri3.scheme);
    try testing.expectEqualStrings("ab:cd:ef:ab:cd:ef", uri3.host.?.percent_encoded);
    try testing.expectEqualStrings("/path", uri3.path.percent_encoded);
    try testing.expectEqual(null, uri3.port);
    const uri4 = try parse("file://ab:cd:ef:ab:cd:ef:999/path", .{ .mac_address = true });
    try testing.expectEqualStrings("file", uri4.scheme);
    try testing.expectEqualStrings("ab:cd:ef:ab:cd:ef", uri4.host.?.percent_encoded);
    try testing.expectEqualStrings("/path", uri4.path.percent_encoded);
    try testing.expectEqual(999, uri4.port);
    const uri5 = try parse("file://00:12:34:56:78:90", .{ .mac_address = true });
    try testing.expectEqualStrings("file", uri5.scheme);
    try testing.expectEqualStrings("00:12:34:56:78:90", uri5.host.?.percent_encoded);
    try testing.expect(uri5.path.isEmpty());
    const uri6 = try parse("file://ab:cd:ef:ab:cd:ef", .{ .mac_address = true });
    try testing.expectEqualStrings("file", uri6.scheme);
    try testing.expectEqualStrings("ab:cd:ef:ab:cd:ef", uri6.host.?.percent_encoded);
    try testing.expect(uri6.path.isEmpty());
    try testing.expectError(error.InvalidMacAddress, parse(
        "file://zz:zz:zz:zz:zz:00/path",
        .{ .mac_address = true },
    ));
    try testing.expectError(error.InvalidMacAddress, parse(
        "file://zz:zz:zz:zz:zz:zz/path",
        .{ .mac_address = true },
    ));
}
test "parse: raw_path" {
    const testing = @import("std").testing;
    const text = "file://localhost/path??#fragment";
    var buf: [256]u8 = undefined;
    const uri1 = try parse(text, .{ .raw_path = false });
    try testing.expectEqualStrings("file", uri1.scheme);
    try testing.expectEqualStrings("localhost", uri1.host.?.percent_encoded);
    try testing.expectEqualStrings("/path", try uri1.path.toRaw(&buf));
    try testing.expectEqualStrings("?", uri1.query.?.percent_encoded);
    try testing.expectEqualStrings("fragment", uri1.fragment.?.percent_encoded);
    const uri2 = try parse(text, .{ .raw_path = true });
    try testing.expectEqualStrings("file", uri2.scheme);
    try testing.expectEqualStrings("localhost", uri2.host.?.percent_encoded);
    try testing.expectEqualStrings("/path??#fragment", try uri2.path.toRaw(&buf));
    try testing.expectEqual(null, uri2.query);
    try testing.expectEqual(null, uri2.fragment);
    const uri3 = try parse("file://localhost", .{ .raw_path = true });
    try testing.expectEqualStrings("file", uri3.scheme);
    try testing.expectEqualStrings("localhost", uri3.host.?.percent_encoded);
    try testing.expect(uri3.path.isEmpty());
    try testing.expectEqual(null, uri3.query);
    try testing.expectEqual(null, uri3.fragment);
}
fn isValidMacAddress(s: []const u8) bool {
    if (s.len != 17) return false;
    for (s, 0..) |c, i| {
        if (i % 3 == 2) {
            if (c != ':') return false;
        } else {
            switch (c) {
                '0'...'9', 'A'...'F', 'a'...'f' => {},
                else => return false,
            }
        }
    }
    return true;
}
test isValidMacAddress {
    const testing = @import("std").testing;
    try testing.expect(isValidMacAddress("01:23:45:67:89:Aa"));
    try testing.expect(isValidMacAddress("Aa:Bb:Cc:Dd:Ee:Ff"));
    try testing.expect(!isValidMacAddress(""));
    try testing.expect(!isValidMacAddress("00:23:45"));
    try testing.expect(!isValidMacAddress("00:23:45:Xx:Yy:Zz"));
    try testing.expect(!isValidMacAddress("01-23-45-67-89-Aa"));
    try testing.expect(!isValidMacAddress("01:23:45:67:89:Aa:Bb"));
}
