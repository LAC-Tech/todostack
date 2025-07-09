const std = @import("std");
const debug = std.debug;
const fmt = std.fmt;
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const posix = std.posix;
const process = std.process;

const max_stack_size = 64;
const max_item_size = 64;
const file_size = max_stack_size * max_item_size;
const file_ext = "tds.bin";

pub fn main() !void {
    var filename_buf = [_]u8{0} ** buf_size.filename;
    const args = try parseArgs();
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
    var tui = try TUI.init(&stack);
    try tui.mainLoop();

    defer {
        posix.close(fd);
        defer tui.deinit();
    }
}

fn parseArgs() !struct { filename: []const u8, create: bool } {
    var args = process.args();
    _ = args.next() orelse return error.NoArgs;
    const arg1 = args.next() orelse {
        printUsage();
        return error.MissingFilename;
    };
    if (mem.eql(u8, arg1, "-n")) {
        const name = args.next() orelse {
            debug.print("Error: -n requires a name\n", .{});
            printUsage();
            return error.MissingName;
        };
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
    debug.print("\ttds -n <name>\t- Create new file <name>.{s}\n", .{file_ext});
}

const Stack = struct {
    items: *[max_stack_size][max_item_size]u8,
    temp_a: [max_item_size]u8,
    len: u8,

    fn init(bytes: []u8) Stack {
        const data: *[max_stack_size][max_item_size]u8 = @ptrCast(bytes.ptr);
        var len: u8 = 0;
        for (data, 0..) |item, i| {
            if (mem.allEqual(u8, &item, 0)) break;
            len = @intCast(i + 1);
        }
        return .{
            .items = data,
            .temp_a = [_]u8{0} ** max_item_size,
            .len = len,
        };
    }

    fn push(self: *@This(), item: []const u8) !void {
        if (self.len >= max_stack_size) return error.StackOverflow;
        if (item.len >= max_item_size) return error.ItemTooLong;
        @memcpy(self.items[self.len][0..item.len], item);
        self.len += 1;
        try self.sync();
    }

    fn drop(self: *@This()) !void {
        if (self.len == 0) return error.Underflow;
        self.len -= 1;
        @memset(&self.items[self.len], 0);
        try self.sync();
    }

    fn swap(self: *@This()) !void {
        if (self.len < 2) return error.Underflow;
        @memcpy(&self.temp_a, &self.items[self.len - 1]);
        @memcpy(&self.items[self.len - 1], &self.items[self.len - 2]);
        @memcpy(&self.items[self.len - 2], &self.temp_a);
        try self.sync();
    }

    fn sync(self: *@This()) !void {
        try posix.msync(@ptrCast(@alignCast(self.items)), posix.MSF.SYNC);
    }
};

const buf_size = struct {
    const input = max_item_size + 1; // to allow room for newline;
    const err = 128;
    const filename = 512; // Daniel's Constant
};

const TUI = struct {
    reader: io.Reader(fs.File, posix.ReadError, fs.File.read),
    writer: io.Writer(fs.File, posix.WriteError, fs.File.write),
    stack: *Stack,
    terms: struct {
        original: posix.termios,
        tui: posix.termios,
    },
    input_buf: [buf_size.input]u8,
    err_buf: [buf_size.err]u8,
    ws: posix.winsize,

    fn init(stack: *Stack) !TUI {
        const reader = io.getStdIn().reader();
        const writer = io.getStdOut().writer();
        var ws: posix.winsize = undefined;
        const rc = posix.system.ioctl(1, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        debug.assert(rc == 0);

        var term: posix.termios = undefined;
        if (posix.system.tcgetattr(io.getStdIn().handle, &term) != 0) {
            return error.TcgetattrFailed;
        }
        const original = term;
        try disableInputMode(&term);

        var tui = TUI{
            .reader = reader,
            .writer = writer,
            .stack = stack,
            .terms = .{ .original = original, .tui = term },
            .input_buf = [_]u8{0} ** buf_size.input,
            .err_buf = [_]u8{0} ** buf_size.err,
            .ws = ws,
        };
        try tui.writer.writeAll(cc.clear_screen ++ cc.hide_cursor);
        return tui;
    }

    fn deinit(self: *TUI) void {
        const rc = posix.system.tcsetattr(
            io.getStdIn().handle,
            .NOW,
            &self.terms.original,
        );
        debug.assert(rc == 0);
        _ = self.writer.writeAll(
            cc.clear_screen ++ cc.cursor_home,
        ) catch unreachable;
    }

    fn disableInputMode(term: *posix.termios) !void {
        term.lflag.ICANON = false;
        term.lflag.ECHO = false;
        if (posix.system.tcsetattr(io.getStdIn().handle, .NOW, term) != 0) {
            return error.TcsetattrFailed;
        }
    }

    fn enableInputMode(term: *posix.termios) !void {
        term.lflag.ICANON = true;
        term.lflag.ECHO = true;
        if (posix.system.tcsetattr(io.getStdIn().handle, .NOW, term) != 0) {
            return error.TcsetattrFailed;
        }
    }

    fn mainLoop(self: *@This()) !void {
        while (true) {
            try self.writer.writeAll(cc.clear_screen ++ cc.cursor_home);
            try self.printStack();
            try self.writer.print(
                "{s}{s}{s}",
                .{ cc.red_on, self.err_buf, cc.color_reset },
            );
            try self.writer.writeAll(cc.cursor_home);

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

    fn handleInput(self: *@This()) !void {
        return switch (try self.reader.readByte()) {
            'q' => error.quit,
            's' => try self.stack.swap(),
            'd' => try self.stack.drop(),
            'p' => try self.stack.push(try self.readLine()),
            else => {},
        };
    }

    fn readLine(self: *@This()) ![]const u8 {
        @memset(&self.input_buf, 0);
        try self.writer.print("{s}> ", .{cc.clear_screen ++ cc.show_cursor});
        try cc.setCursorPos(self.writer, 2, 1);
        try self.printStack();
        try cc.setCursorPos(self.writer, 1, 3);

        var term = self.terms.tui;
        try enableInputMode(&term);
        defer {
            disableInputMode(&term) catch unreachable;
            self.writer.print("{s}", .{cc.hide_cursor}) catch {};
        }

        const input = blk: {
            const result = self.reader.readUntilDelimiter(&self.input_buf, '\n');
            break :blk try result;
        };
        return mem.trim(u8, input, " \t\r\n");
    }

    fn printStack(self: *@This()) !void {
        for (0..self.stack.len) |i| {
            const item = self.stack.items[self.stack.len - 1 - i];
            if (i == 0) {
                try self.writer.print(
                    "{s}{s}{s}\n",
                    .{ cc.bold_on, item, cc.bold_off },
                );
            } else {
                try self.writer.print("{s}\n", .{item});
            }
        }
    }
};

const cc = struct {
    const clear_screen = "\x1B[2J";
    const bold_on = "\x1B[1m";
    const bold_off = "\x1B[0m";
    const cursor_home = "\x1B[H";
    const hide_cursor = "\x1B[?25l";
    const show_cursor = "\x1B[?25h";
    const red_on = "\x1B[31m";
    const color_reset = "\x1B[0m";

    fn setCursorPos(writer: anytype, row: u16, col: u16) !void {
        try writer.print("\x1B[{d};{d}H", .{ row, col });
    }
};
