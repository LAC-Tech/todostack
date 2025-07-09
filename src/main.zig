const std = @import("std");
const debug = std.debug;
const fmt = std.fmt;
const fs = std.fs;
const heap = std.heap;
const io = std.io;
const mem = std.mem;
const posix = std.posix;

const max_stack_size = 64;
const max_item_size = 64;
const file_size = max_stack_size * max_item_size;
const file_ext = "tds.bin";

pub fn main() !void {
    const args = try std.process.argsAlloc(heap.page_allocator);
    defer std.process.argsFree(heap.page_allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const fd = if (mem.eql(u8, args[1], "-n")) blk: {
        if (args.len < 3) {
            debug.print("Error: -n requires a name argument\n", .{});
            printUsage();
            return;
        }
        break :blk file.create(args[2]) catch |err| {
            debug.print("Error creating stack '{s}': {}\n", .{ args[2], err });
            return;
        };
    } else blk: {
        break :blk file.open(args[1]) catch |err| {
            debug.print("Error opening stack '{s}': {}\n", .{ args[1], err });
            return;
        };
    };

    defer {
        posix.fsync(fd) catch |err| {
            debug.print("Warning: fsync failed: {}\n", .{err});
        };
        posix.close(fd);
    }

    const bytes = try posix.mmap(
        null, // OS chooses virtual address
        file_size,
        posix.PROT.READ | posix.PROT.WRITE,
        .{ .TYPE = .SHARED }, // Changes are written to file
        fd,
        0, // offset in file
    );

    debug.assert(bytes.len == file_size);

    var stack = Stack.init(bytes);
    var tui = try TUI.init(&stack);
    try tui.main_loop();
    defer tui.deinit();
}

fn printUsage() void {
    debug.print("Usage:\n", .{});
    debug.print("\ttds <file.{s}>\t- Open existing file\n", .{file_ext});
    debug.print("\ttds -n <name>\t- Create new file <name>.{s}\n", .{file_ext});
}

const file = struct {
    fn create(name: []const u8) !posix.fd_t {
        var filename_buf: [256]u8 = undefined;
        const filename = try fmt.bufPrint(
            &filename_buf,
            "{s}.{s}",
            .{ name, file_ext },
        );

        const fd = try posix.open(
            filename,
            .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true },
            0o666,
        );

        try posix.ftruncate(fd, file_size);

        return fd;
    }

    fn open(filename: []const u8) !posix.fd_t {
        const fd = try posix.open(
            filename,
            .{ .ACCMODE = .RDWR },
            0,
        );

        const stat = try posix.fstat(fd);
        if (stat.size != file_size) {
            debug.print(
                "Error: File {s} is not exactly {} bytes\n",
                .{ filename, file_size },
            );
            return error.InvalidFileSize;
        }

        debug.print("Opened file: {s}\n", .{filename});
        return fd;
    }
};

const Stack = struct {
    items: *[max_stack_size][max_item_size]u8,
    temp_a: [max_item_size]u8,
    len: u8,

    fn init(bytes: []u8) Stack {
        debug.assert(bytes.len == file_size);
        const data = @as(
            *[max_stack_size][max_item_size]u8,
            @ptrCast(bytes.ptr),
        );

        var len: u8 = 0;

        for (data) |item| {
            if (isEmptyItem(item)) break;
            len += 1;
        }
        return Stack{
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

fn isEmptyItem(item: [max_item_size]u8) bool {
    return mem.allEqual(u8, &item, 0);
}

fn init_terms(fd: posix.fd_t) !struct {
    original: posix.termios,
    tui: posix.termios,
} {
    var term: posix.termios = undefined;
    var rc = posix.system.tcgetattr(fd, &term);
    if (rc != 0) return error.TcgetattrFailed;
    const original = term;
    term.lflag.ICANON = false;
    term.lflag.ECHO = false;
    rc = posix.system.tcsetattr(fd, .NOW, &term);
    if (rc != 0) return error.TcsetattrFailed;
    return .{ .original = original, .tui = term };
}

const buf_size = struct {
    const input = max_item_size + 1; // to allow room for newline;
    const err = 128;
};

const TUI = struct {
    reader: io.Reader(std.fs.File, std.posix.ReadError, std.fs.File.read),
    writer: io.Writer(std.fs.File, std.posix.WriteError, std.fs.File.write),
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
        debug.print("rows = {}\n", .{ws.row});

        var term: posix.termios = undefined;
        if (posix.system.tcgetattr(io.getStdIn().handle, &term) != 0) {
            return error.TcgetattrFailed;
        }
        const original = term;
        term.lflag.ICANON = false;
        term.lflag.ECHO = false;
        if (posix.system.tcsetattr(io.getStdIn().handle, .NOW, &term) != 0) {
            return error.TcsetattrFailed;
        }

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

    fn main_loop(self: *@This()) !void {
        while (true) {
            try self.writer.writeAll(cc.clear_screen ++ cc.cursor_home);
            try self.print_stack();
            try self.writer.print(
                "{s}{s}{s}",
                .{ cc.red_on, self.err_buf, cc.color_reset },
            );
            try self.writer.writeAll(cc.cursor_home);

            @memset(&self.err_buf, 0);
            self.handle_input() catch |err| {
                switch (err) {
                    error.quit => return,
                    else => {
                        _ = try fmt.bufPrint(&self.err_buf, "{}", .{err});
                    },
                }
            };
        }
    }

    fn handle_input(self: *@This()) !void {
        var rc: usize = 0;
        return switch (try self.reader.readByte()) {
            'q' => error.quit,
            's' => try self.stack.swap(),
            'd' => try self.stack.drop(),
            'p' => {
                @memset(&self.input_buf, 0);
                try self.writer.print(
                    "{s}> ",
                    .{cc.clear_screen ++ cc.show_cursor},
                );
                try cc.setCursorPos(self.writer, 2, 1);
                try self.print_stack();
                try cc.setCursorPos(self.writer, 1, 3);
                self.terms.tui.lflag.ECHO = true;
                self.terms.tui.lflag.ICANON = true;
                rc = posix.system.tcsetattr(
                    io.getStdIn().handle,
                    .NOW,
                    &self.terms.tui,
                );
                defer {
                    self.terms.tui.lflag.ECHO = false;
                    self.terms.tui.lflag.ICANON = false;
                    _ = posix.system.tcsetattr(
                        io.getStdIn().handle,
                        .NOW,
                        &self.terms.tui,
                    );
                    self.writer.print(
                        "{s}",
                        .{cc.hide_cursor},
                    ) catch unreachable;

                    cc.setCursorPos(
                        self.writer,
                        self.stack.len + 1,
                        1,
                    ) catch unreachable;
                }
                if (rc != 0) return error.TcsetattrFailed;
                const input = try self.reader.readUntilDelimiter(
                    &self.input_buf,
                    '\n',
                );
                const trimmed = mem.trim(u8, input, " \t\r\n");
                if (trimmed.len > 0) {
                    try self.stack.push(trimmed);
                }
            },
            else => {},
        };
    }

    fn print_stack(self: *@This()) !void {
        for (0..self.stack.len) |i| {
            const item = self.stack.items[self.stack.len - 1 - i];
            if (isEmptyItem(item)) break;
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
