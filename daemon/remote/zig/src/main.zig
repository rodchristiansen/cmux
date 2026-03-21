const std = @import("std");
const serve_stdio = @import("serve_stdio.zig");
const json_rpc = @import("json_rpc.zig");
const session_registry = @import("session_registry.zig");
const terminal_session = @import("terminal_session.zig");

pub fn main() !void {
    _ = json_rpc;
    _ = session_registry;
    _ = terminal_session;
    try serve_stdio.serve();
}
