const std = @import("std");
const debug = std.debug;
const fmt = std.fmt;
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const posix = std.posix;
const process = std.process;

const term = @import("./term.zig");
const cc = term.cc;
const Term = term.Term;

const max_stack_len = 64;
const max_item_len = 256; // SMS size!
const mmap_size = 512 * 4096; // huge page size, about 2mb
const file_ext = "tds.txt";

const buf_size = struct {
    const input = max_item_len + 1; // to allow room for newline;
    const err = 1024;
    const filename = 512; // Daniel's Constant
};

pub fn main() !void {
    var filename_buf = [_]u8{0} ** buf_size.filename;
    var args = process.args();
    _ = args.skip();

    const arg1 = args.next() orelse {
        debug.print("Usage:\n", .{});
        debug.print("\ttds <file.{s}>\t- Open existing file\n", .{file_ext});
        debug.print("\ttds -n <name>\t\t- Create new file <name>.{s}\n", .{file_ext});
        return;
    };

    const create = mem.eql(u8, arg1, "-n");
    const name = if (create) args.next() orelse {
        debug.print("Error: Missing name after -n\n", .{});
        return;
    } else arg1;

    const filename = if (create)
        try fmt.bufPrint(&filename_buf, "{s}.{s}", .{ name, file_ext })
    else
        name;

    const fd = try posix.open(
        filename,
        .{ .ACCMODE = .RDWR, .CREAT = create, .EXCL = create },
        0o666,
    );
    if (create) {
        try posix.fsync(fd);
    }

    defer posix.close(fd);

    var stack = try Stack.init(fd);
    var app = try App.init(&stack);
    defer app.deinit();

    try app.mainLoop();
}

const App = struct {
    stack: *Stack,
    input_buf: [buf_size.input]u8 = .{0} ** buf_size.input,
    err_buf: [buf_size.err]u8 = .{0} ** buf_size.err,
    term: Term,

    fn init(stack: *Stack) !App {
        var tui = try Term.init();
        try tui.rawMode(true);
        try tui.write(&.{ cc.clear, cc.cursor.hide });
        try tui.refresh();

        return .{ .stack = stack, .term = tui };
    }

    fn deinit(self: *App) void {
        self.term.write(&.{cc.clear}) catch unreachable;
        self.term.refresh() catch unreachable;
        self.term.deinit();
    }

    fn mainLoop(self: *App) !void {
        while (true) {
            try self.term.write(&.{ cc.clear, cc.cursor.home });
            try self.printStack();
            try self.term.print(
                "{s}{s}{s}{s}",
                .{ cc.fg_red, self.err_buf, cc.reset_attrs, cc.cursor.home },
            );
            try self.term.refresh();
            @memset(&self.err_buf, 0);

            self.handleInput() catch |err| {
                switch (err) {
                    error.quit => return,
                    else => {
                        _ = try fmt.bufPrint(&self.err_buf, "{}", .{err});
                    },
                }
            };
        }
    }

    fn handleInput(self: *App) !void {
        return switch (try Term.readByte()) {
            'q' => error.quit,
            's' => try self.stack.swap(),
            'd' => try self.stack.drop(),
            'r' => try self.stack.rot(),
            'p' => {
                const line = try self.readLine();
                if (line.len > 1) try self.stack.push(line);
            },
            else => {},
        };
    }

    fn readLine(self: *App) ![]const u8 {
        @memset(&self.input_buf, 0);

        try self.term.write(&.{
            cc.clear,
            cc.cursor.setPos(.{ .row = 2, .col = 1 }),
        });
        try self.printStack();
        try self.term.write(&.{ cc.cursor.home, "> ", cc.cursor.show });
        try self.term.rawMode(false);
        try self.term.refresh();

        defer {
            self.term.rawMode(true) catch unreachable;
            self.term.write(&.{cc.cursor.hide}) catch unreachable;
            self.term.refresh() catch unreachable;
        }

        const end = try Term.readString(&self.input_buf);
        self.input_buf[end] = '\n';
        return self.input_buf[0 .. end + 1];
    }

    fn printStack(self: *App) !void {
        if (self.stack.items.len == 0) return;

        const top = self.stack.items.get(0);
        try self.term.print(
            "{s}{s}{s}",
            .{ cc.bold_on, top, cc.reset_attrs },
        );

        for (1..self.stack.items.len) |i| {
            const item = self.stack.items.get(i);
            try self.term.print("{s}", .{item});
        }
    }
};

const Stack = struct {
    items: Items,
    temp_a: [max_item_len]u8 = .{0} ** max_item_len,
    temp_b: [max_item_len]u8 = .{0} ** max_item_len,
    temp_c: [max_item_len]u8 = .{0} ** max_item_len,

    fn init(fd: posix.fd_t) !Stack {
        return .{ .items = try Items.init(fd) };
    }

    fn push(self: *Stack, item: []const u8) !void {
        if (self.items.len >= max_stack_len) return error.StackOverflow;
        try self.items.push(item);
        try self.items.sync();
    }

    fn drop(self: *Stack) !void {
        try self.items.ensureMinLen(1);
        try self.items.drop();
        try self.items.sync();
    }

    fn swap(self: *Stack) !void {
        try self.items.ensureMinLen(2);
        const a = self.items.get(0);
        const b = self.items.get(1);

        @memcpy(self.temp_a[0..a.len], a);
        @memcpy(self.temp_b[0..b.len], b);

        self.items.set(&.{
            self.temp_b[0..b.len],
            self.temp_a[0..a.len],
        });
        try self.items.sync();
    }

    fn rot(self: *Stack) !void {
        try self.items.ensureMinLen(3);
        const a = self.items.get(0);
        const b = self.items.get(1);
        const c = self.items.get(2);

        @memcpy(self.temp_a[0..a.len], a);
        @memcpy(self.temp_b[0..b.len], b);
        @memcpy(self.temp_c[0..c.len], c);

        self.items.set(&.{
            self.temp_c[0..c.len],
            self.temp_a[0..a.len],
            self.temp_b[0..b.len],
        });
        try self.items.sync();
    }
};

const Items = struct {
    const max_offsets = max_stack_len + 1;

    fd: posix.fd_t,
    bytes: []u8,
    offsets: [max_offsets]u16,
    len: u8,

    fn init(fd: posix.fd_t) !Items {
        const bytes = try posix.mmap(
            null,
            mmap_size,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        debug.assert(bytes.len == mmap_size);

        const stat = try posix.fstat(fd);

        var offsets = [_]u16{0} ** max_offsets;
        var len: u8 = 0;

        for (bytes[0..@intCast(stat.size)], 0..) |byte, i| {
            if (byte == '\n') {
                len += 1;
                offsets[len] = @intCast(i + 1);
            }
        }

        return .{ .fd = fd, .bytes = bytes, .offsets = offsets, .len = len };
    }

    fn push(self: *Items, item: []const u8) !void {
        const offset = self.offsets[self.len];
        const bytes_written: u16 = @intCast(
            try posix.pwrite(self.fd, item, offset),
        );
        self.len += 1;
        self.offsets[self.len] = offset + bytes_written;
    }

    fn drop(self: *Items) !void {
        self.len -= 1;
        try posix.ftruncate(self.fd, self.offsets[self.len]);
    }

    fn get(self: *Items, idx: usize) []u8 {
        const offset_idx = self.len - 1 - idx;
        const start = self.offsets[offset_idx];
        const end = self.offsets[offset_idx + 1];

        return self.bytes[start..end];
    }

    fn set(self: *Items, items: []const []const u8) void {
        for (items, 0..) |item, idx| {
            const end = self.offsets[self.len - idx];
            const start = end - item.len;

            @memcpy(self.bytes[start..end], item);
            self.offsets[self.len - 1 - idx] = @intCast(start);
        }
    }

    fn ensureMinLen(self: *Items, n: usize) !void {
        if (self.len < n) return error.Underflow;
    }

    fn sync(self: *Items) !void {
        try posix.msync(@ptrCast(@alignCast(self.bytes)), posix.MSF.SYNC);
    }
};
