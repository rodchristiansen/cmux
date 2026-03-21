const std = @import("std");
const json_rpc = @import("json_rpc.zig");
const serve_stdio = @import("serve_stdio.zig");
const ticket_auth = @import("ticket_auth.zig");

const c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
});

pub const Config = struct {
    listen_addr: []const u8,
    server_id: []const u8,
    ticket_secret: []const u8,
    cert_file: []const u8,
    key_file: []const u8,
};

pub fn serve(cfg: Config) !void {
    if (cfg.listen_addr.len == 0 or cfg.server_id.len == 0 or cfg.ticket_secret.len == 0 or cfg.cert_file.len == 0 or cfg.key_file.len == 0) {
        return error.MissingTLSConfig;
    }

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var state = serve_stdio.State.init(alloc);
    defer state.deinit();

    var verifier = ticket_auth.TicketVerifier.init(alloc, cfg.server_id, cfg.ticket_secret);
    defer verifier.deinit();

    _ = c.OPENSSL_init_ssl(0, null);

    const ctx = c.SSL_CTX_new(c.TLS_server_method()) orelse return error.TLSContextInitFailed;
    defer c.SSL_CTX_free(ctx);

    const cert_file_z = try alloc.dupeZ(u8, cfg.cert_file);
    defer alloc.free(cert_file_z);
    const key_file_z = try alloc.dupeZ(u8, cfg.key_file);
    defer alloc.free(key_file_z);

    if (c.SSL_CTX_use_certificate_file(ctx, cert_file_z, c.SSL_FILETYPE_PEM) != 1) return error.LoadCertificateFailed;
    if (c.SSL_CTX_use_PrivateKey_file(ctx, key_file_z, c.SSL_FILETYPE_PEM) != 1) return error.LoadPrivateKeyFailed;
    if (c.SSL_CTX_check_private_key(ctx) != 1) return error.InvalidPrivateKey;

    var server = try listen(cfg.listen_addr);
    defer server.deinit();

    while (true) {
        var conn = try server.accept();
        defer conn.stream.close();
        serveConn(alloc, ctx, &state, &verifier, conn.stream.handle) catch {};
    }
}

fn serveConn(
    alloc: std.mem.Allocator,
    ctx: *c.SSL_CTX,
    state: *serve_stdio.State,
    verifier: *ticket_auth.TicketVerifier,
    fd: std.posix.fd_t,
) !void {
    const ssl = c.SSL_new(ctx) orelse return error.SSLCreateFailed;
    defer {
        _ = c.SSL_shutdown(ssl);
        c.SSL_free(ssl);
    }

    if (c.SSL_set_fd(ssl, @intCast(fd)) != 1) return error.SSLSetFdFailed;
    if (c.SSL_accept(ssl) != 1) return error.SSLAcceptFailed;

    const handshake_line = (try sslReadLine(alloc, ssl, 4 * 1024 * 1024)) orelse return;
    defer alloc.free(handshake_line);

    const handshake_trimmed = std.mem.trimRight(u8, handshake_line, "\r\n");
    var parsed_handshake = std.json.parseFromSlice(ticket_auth.Handshake, alloc, handshake_trimmed, .{}) catch {
        return writeError(ssl, alloc, null, "invalid_request", "invalid JSON handshake");
    };
    defer parsed_handshake.deinit();

    var claims = verifier.verifyHandshake(parsed_handshake.value) catch |err| {
        return writeError(ssl, alloc, null, "unauthorized", ticket_auth.verifyErrorMessage(err));
    };
    defer claims.deinit(alloc);

    var authorizer = try ticket_auth.RequestAuthorizer.init(alloc, claims);
    defer authorizer.deinit();

    try writePayload(ssl, alloc, try json_rpc.encodeResponse(alloc, .{
        .ok = true,
        .result = .{ .authenticated = true },
    }));

    while (true) {
        const raw_line = (try sslReadLine(alloc, ssl, 4 * 1024 * 1024)) orelse return;
        defer alloc.free(raw_line);

        const trimmed = std.mem.trimRight(u8, raw_line, "\r\n");
        if (trimmed.len == 0) continue;

        var req = json_rpc.decodeRequest(alloc, trimmed) catch {
            try writeError(ssl, alloc, null, "invalid_request", "invalid JSON request");
            continue;
        };
        defer req.deinit(alloc);

        if (authorizer.authorize(&req)) |unauthorized| {
            try writeError(ssl, alloc, req.id, "unauthorized", unauthorized.message);
            continue;
        }

        const response = try serve_stdio.dispatch(state, &req);
        defer alloc.free(response);
        try authorizer.observe(&req, response);
        try sslWriteAll(ssl, response);
        try sslWriteAll(ssl, "\n");
    }
}

fn listen(listen_addr: []const u8) !std.net.Server {
    const colon = std.mem.lastIndexOfScalar(u8, listen_addr, ':') orelse return error.InvalidListenAddress;
    const host = listen_addr[0..colon];
    const port = try std.fmt.parseInt(u16, listen_addr[colon + 1 ..], 10);
    const address = try std.net.Address.parseIp(host, port);
    return address.listen(.{ .reuse_address = true });
}

fn sslReadLine(alloc: std.mem.Allocator, ssl: *c.SSL, max_bytes: usize) !?[]u8 {
    var line = std.ArrayList(u8).empty;
    defer line.deinit(alloc);

    var byte: [1]u8 = undefined;
    while (line.items.len < max_bytes) {
        const rc = c.SSL_read(ssl, &byte, 1);
        if (rc <= 0) {
            const ssl_err = c.SSL_get_error(ssl, rc);
            switch (ssl_err) {
                c.SSL_ERROR_ZERO_RETURN => {
                    if (line.items.len == 0) return null;
                    break;
                },
                c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => continue,
                else => return error.SSLReadFailed,
            }
        }
        try line.append(alloc, byte[0]);
        if (byte[0] == '\n') break;
    }
    if (line.items.len >= max_bytes) return error.FrameTooLarge;
    return try line.toOwnedSlice(alloc);
}

fn sslWriteAll(ssl: *c.SSL, data: []const u8) !void {
    var offset: usize = 0;
    while (offset < data.len) {
        const rc = c.SSL_write(ssl, data.ptr + offset, @intCast(data.len - offset));
        if (rc <= 0) {
            const ssl_err = c.SSL_get_error(ssl, rc);
            switch (ssl_err) {
                c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => continue,
                else => return error.SSLWriteFailed,
            }
        }
        offset += @as(usize, @intCast(rc));
    }
}

fn writePayload(ssl: *c.SSL, alloc: std.mem.Allocator, payload: []u8) !void {
    defer alloc.free(payload);
    try sslWriteAll(ssl, payload);
    try sslWriteAll(ssl, "\n");
}

fn writeError(ssl: *c.SSL, alloc: std.mem.Allocator, id: ?std.json.Value, code: []const u8, message: []const u8) !void {
    try writePayload(ssl, alloc, try json_rpc.encodeResponse(alloc, .{
        .id = id,
        .ok = false,
        .@"error" = .{
            .code = code,
            .message = message,
        },
    }));
}
