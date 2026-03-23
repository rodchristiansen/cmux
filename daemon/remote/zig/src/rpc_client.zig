const std = @import("std");

pub const Client = struct {
    alloc: std.mem.Allocator,
    socket_path: []const u8,

    pub fn init(alloc: std.mem.Allocator, socket_path: []const u8) Client {
        return .{
            .alloc = alloc,
            .socket_path = socket_path,
        };
    }

    pub fn call(self: *Client, request_json: []const u8) !std.json.Parsed(std.json.Value) {
        var unix_addr = try std.net.Address.initUnix(self.socket_path);
        const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
        defer std.posix.close(fd);

        try std.posix.connect(fd, &unix_addr.any, unix_addr.getOsSockLen());

        var file = std.fs.File{ .handle = fd };
        try file.writeAll(request_json);
        try file.writeAll("\n");

        const line = try readLine(self.alloc, &file, 4 * 1024 * 1024);
        defer self.alloc.free(line);

        return std.json.parseFromSlice(std.json.Value, self.alloc, line, .{});
    }
};

fn readLine(alloc: std.mem.Allocator, file: *std.fs.File, max_bytes: usize) ![]u8 {
    var line = std.ArrayList(u8).empty;
    defer line.deinit(alloc);

    var byte: [1]u8 = undefined;
    while (line.items.len < max_bytes) {
        const n = try file.read(&byte);
        if (n == 0) break;
        try line.append(alloc, byte[0]);
        if (byte[0] == '\n') break;
    }

    return line.toOwnedSlice(alloc);
}
