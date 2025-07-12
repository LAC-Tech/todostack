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

const max_stack_size = 64;
const max_item_size = 64;
const file_size = max_stack_size * max_item_size;
const file_ext = "tds.bin";

const buf_size = struct {
    const input = max_item_size + 1; // to allow room for newline;
    const err = 1024;
    const filename = 512; // Daniel's Constant
};

pub fn main() !void {
    var filename_buf = [_]u8{0} ** buf_size.filename;
    const args = parseArgs() catch {
        printUsage();
        return;
    };
    const fd = try openFile(args.filename, args.create, &filename_buf);

    const bytes = try posix.mmap(
        null,
        file_size,
        posix.PROT.READ | posix.PROT.WRITE,
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    debug.assert(bytes.len == file_size);

    var stack = Stack.init(bytes);
    var app = try App.init(&stack);
    try app.mainLoop();

    defer {
        posix.close(fd);
        defer app.deinit();
    }
}

fn parseArgs() !struct { filename: []const u8, create: bool } {
    var args = process.args();
    _ = args.skip();
    const arg1 = args.next() orelse return error.MissingFilename;
    if (mem.eql(u8, arg1, "-n")) {
        const name = args.next() orelse return error.MissingName;
        return .{ .filename = name, .create = true };
    }
    return .{ .filename = arg1, .create = false };
}

fn openFile(name: []const u8, create: bool, buf: []u8) !posix.fd_t {
    const filename = if (create) try fmt.bufPrint(
        buf,
        "{s}.{s}",
        .{ name, file_ext },
    ) else name;

    const fd = try posix.open(
        filename,
        .{ .ACCMODE = .RDWR, .CREAT = create, .EXCL = true },
        0o666,
    );
    if (create) {
        try posix.ftruncate(fd, file_size);
        try posix.fsync(fd);
    } else if ((try posix.fstat(fd)).size != file_size) {
        return error.InvalidFileSize;
    }
    return fd;
}

fn printUsage() void {
    debug.print("Usage:\n", .{});
    debug.print("\ttds <file.{s}>\t- Open existing file\n", .{file_ext});
    debug.print("\ttds -n <name>\t\t- Create new file <name>.{s}\n", .{file_ext});
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
        return switch (try self.term.readByte()) {
            'q' => error.quit,
            's' => try self.stack.swap(),
            'd' => try self.stack.drop(),
            'r' => try self.stack.rot(),
            'p' => {
                const line = try self.readLine();
                if (line.len > 0) try self.stack.push(line);
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

        return self.term.readString(&self.input_buf);
    }

    fn printStack(self: *App) !void {
        for (0..self.stack.len) |i| {
            const item = self.stack.items.get(self.stack.len - 1 - i);
            if (i == 0) {
                try self.term.print(
                    "{s}{s}{s}\n",
                    .{ cc.bold_on, item, cc.reset_attrs },
                );
            } else {
                try self.term.print("{s}\n", .{item});
            }
        }
    }
};

const Stack = struct {
    items: Items,
    len: u8,
    temp_a: [max_item_size]u8 = .{0} ** max_item_size,
    temp_b: [max_item_size]u8 = .{0} ** max_item_size,

    fn init(bytes: []u8) Stack {
        const items = Items.init(bytes);
        var len: u8 = 0;
        for (0..max_stack_size) |i| {
            if (items.isEmpty(i)) break;
            len = @intCast(i + 1);
        }
        return .{ .items = items, .len = len };
    }

    fn push(self: *Stack, item: []const u8) !void {
        if (self.len >= max_stack_size) return error.StackOverflow;
        if (item.len >= max_item_size) return error.ItemTooLong;
        self.items.set(self.len, item);
        self.len += 1;
        try self.items.sync();
    }

    fn drop(self: *Stack) !void {
        try self.ensureMinStackLen(1);
        self.len -= 1;
        self.items.clear(self.len);
        try self.items.sync();
    }

    fn swap(self: *Stack) !void {
        try self.ensureMinStackLen(2);
        @memcpy(&self.temp_a, self.items.get(self.len - 1));
        self.items.copy(self.len - 2, self.len - 1);
        @memcpy(self.items.get(self.len - 2), &self.temp_a);
        try self.items.sync();
    }

    fn rot(self: *Stack) !void {
        try self.ensureMinStackLen(3);
        @memcpy(&self.temp_a, self.items.get(self.len - 1));
        @memcpy(&self.temp_b, self.items.get(self.len - 2));
        self.items.copy(self.len - 3, self.len - 1);
        @memcpy(self.items.get(self.len - 2), &self.temp_a);
        @memcpy(self.items.get(self.len - 3), &self.temp_b);
        try self.items.sync();
    }

    fn ensureMinStackLen(self: Stack, n: usize) !void {
        if (self.len < n) return error.Underflow;
    }
};

const Items = struct {
    bytes: *[max_stack_size][max_item_size]u8,

    fn init(data: []u8) Items {
        return .{ .bytes = @ptrCast(data.ptr) };
    }

    fn get(self: *Items, index: usize) []u8 {
        return &self.bytes[index];
    }

    fn set(self: *Items, index: usize, item: []const u8) void {
        @memcpy(self.bytes[index][0..item.len], item);
    }

    fn clear(self: *Items, index: usize) void {
        @memset(&self.bytes[index], 0);
    }

    fn copy(self: *Items, from: usize, to: usize) void {
        @memcpy(&self.bytes[to], &self.bytes[from]);
    }

    fn isEmpty(self: Items, index: usize) bool {
        return mem.allEqual(u8, &self.bytes[index], 0);
    }

    fn sync(self: *Items) !void {
        try posix.msync(@ptrCast(@alignCast(self.bytes)), posix.MSF.SYNC);
    }
};
