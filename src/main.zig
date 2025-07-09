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
    _ = args.next() orelse return error.NoArgs;
    const arg1 = args.next() orelse {
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
    debug.print("\ttds -n <name>\t\t- Create new file <name>.{s}\n", .{file_ext});
}

const Stack = struct {
    items: *[max_stack_size][max_item_size]u8,
    temp_a: [max_item_size]u8 = .{0} ** max_item_size,
    temp_b: [max_item_size]u8 = .{0} ** max_item_size,
    len: u8,

    fn init(bytes: []u8) Stack {
        const data: *[max_stack_size][max_item_size]u8 = @ptrCast(bytes.ptr);
        var len: u8 = 0;
        for (data, 0..) |item, i| {
            if (mem.allEqual(u8, &item, 0)) break;
            len = @intCast(i + 1);
        }
        return .{ .items = data, .len = len };
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

    fn rot(self: *@This()) !void {
        if (self.len < 3) return error.Underflow;
        @memcpy(&self.temp_a, &self.items[self.len - 1]);
        @memcpy(&self.temp_b, &self.items[self.len - 2]);
        @memcpy(&self.items[self.len - 1], &self.items[self.len - 3]);
        @memcpy(&self.items[self.len - 2], &self.temp_a);
        @memcpy(&self.items[self.len - 3], &self.temp_b);
        try self.sync();
    }

    fn sync(self: *@This()) !void {
        try posix.msync(@ptrCast(@alignCast(self.items)), posix.MSF.SYNC);
    }
};

const buf_size = struct {
    const input = max_item_size + 1; // to allow room for newline;
    const err = 1024;
    const filename = 512; // Daniel's Constant
};

const App = struct {
    stack: *Stack,
    input_buf: [buf_size.input]u8 = .{0} ** buf_size.input,
    err_buf: [buf_size.err]u8 = .{0} ** buf_size.err,
    tui: TUI,

    fn init(stack: *Stack) !@This() {
        var tui = try TUI.init();
        try tui.rawOn();
        try tui.clear();
        try tui.hideCursor();
        try tui.refresh();

        return @This(){ .stack = stack, .tui = tui };
    }

    fn deinit(self: *@This()) void {
        self.tui.clear() catch unreachable;
        self.tui.refresh() catch unreachable;
        self.tui.deinit();
    }

    fn mainLoop(self: *@This()) !void {
        while (true) {
            try self.tui.clear();
            try self.tui.cursorHome();
            try self.printStack();
            try self.tui.print_red("{s}", .{self.err_buf});
            try self.tui.cursorHome();
            try self.tui.refresh();

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
        return switch (try self.tui.readByte()) {
            'q' => error.quit,
            's' => try self.stack.swap(),
            'd' => try self.stack.drop(),
            'r' => try self.stack.rot(),
            'p' => try self.stack.push(try self.readLine()),
            else => {},
        };
    }

    fn readLine(self: *@This()) ![]const u8 {
        @memset(&self.input_buf, 0);

        try self.tui.clear();
        try self.tui.setCursorPos(.{ .row = 2, .col = 1 });
        try self.printStack();
        try self.tui.cursorHome();
        try self.tui.print("> ", .{});
        try self.tui.showCursor();
        try self.tui.rawOff();
        try self.tui.refresh();

        defer {
            self.tui.rawOn() catch unreachable;
            self.tui.hideCursor() catch unreachable;
            self.tui.refresh() catch unreachable;
        }

        return self.tui.readString(&self.input_buf);
    }

    fn printStack(self: *@This()) !void {
        for (0..self.stack.len) |i| {
            const item = self.stack.items[self.stack.len - 1 - i];
            if (i == 0) {
                try self.tui.print_bold("{s}\n", .{item});
            } else {
                try self.tui.print("{s}\n", .{item});
            }
        }
    }
};

const TUI = struct {
    const cc = struct {
        const clear_screen = "\x1B[2J";
        const bold_on = "\x1B[1m";
        const bold_off = "\x1B[0m";
        const cursor_home = "\x1B[H";
        const hide_cursor = "\x1B[?25l";
        const show_cursor = "\x1B[?25h";
        const red_on = "\x1B[31m";
        const color_reset = "\x1B[0m";
    };

    const Pos = struct { row: u16, col: u16 };

    reader: io.Reader(fs.File, posix.ReadError, fs.File.read),
    writer: io.BufferedWriter(4096, io.Writer(
        fs.File,
        posix.WriteError,
        fs.File.write,
    )),
    termios: struct { original: posix.termios, tui: posix.termios },
    ws: posix.winsize,

    fn init() !@This() {
        var ws: posix.winsize = undefined;
        const rc = posix.system.ioctl(1, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        debug.assert(rc == 0);

        var term: posix.termios = undefined;
        if (posix.system.tcgetattr(io.getStdIn().handle, &term) != 0) {
            return error.TcgetattrFailed;
        }

        return .{
            .reader = io.getStdIn().reader(),
            .writer = io.bufferedWriter(io.getStdOut().writer()),
            .termios = .{ .original = term, .tui = term },
            .ws = ws,
        };
    }

    fn deinit(self: *@This()) void {
        const rc = posix.system.tcsetattr(
            io.getStdIn().handle,
            .NOW,
            &self.termios.original,
        );
        debug.assert(rc == 0);
        _ = self.writer.write(
            cc.clear_screen ++ cc.cursor_home,
        ) catch unreachable;
    }

    fn print(self: *@This(), comptime format: []const u8, args: anytype) !void {
        var w = self.writer.writer();
        try w.print(format, args);
    }

    fn print_bold(self: *@This(), comptime format: []const u8, args: anytype) !void {
        var w = self.writer.writer();
        try w.print("{s}", .{cc.bold_on});
        try w.print(format, args);
        try w.print("{s}", .{cc.bold_off});
    }

    fn print_red(self: *@This(), comptime format: []const u8, args: anytype) !void {
        var w = self.writer.writer();
        try w.print("{s}", .{cc.red_on});
        try w.print(format, args);
        try w.print("{s}", .{cc.color_reset});
    }

    fn refresh(self: *@This()) !void {
        try self.writer.flush();
    }

    fn rawOn(self: *@This()) !void {
        var term = self.termios.tui;
        term.lflag.ICANON = false;
        term.lflag.ECHO = false;
        if (posix.system.tcsetattr(io.getStdIn().handle, .NOW, &term) != 0) {
            return error.TcsetattrFailed;
        }
    }

    fn rawOff(self: *@This()) !void {
        var term = self.termios.tui;
        term.lflag.ICANON = true;
        term.lflag.ECHO = true;

        if (posix.system.tcsetattr(io.getStdIn().handle, .NOW, &term) != 0) {
            return error.TcsetattrFailed;
        }
    }

    fn clear(self: *@This()) !void {
        _ = try self.writer.write(cc.clear_screen);
    }

    fn hideCursor(self: *@This()) !void {
        _ = try self.writer.write(cc.hide_cursor);
    }

    fn showCursor(self: *@This()) !void {
        _ = try self.writer.write(cc.show_cursor);
    }

    fn cursorHome(self: *@This()) !void {
        _ = try self.writer.write(cc.cursor_home);
    }

    fn setCursorPos(self: *@This(), pos: Pos) !void {
        var w = self.writer.writer();
        try w.print("\x1B[{d};{d}H", .{ pos.row, pos.col });
    }

    fn readByte(self: @This()) !u8 {
        return self.reader.readByte();
    }

    fn readString(self: @This(), buf: []u8) ![]const u8 {
        const input = self.reader.readUntilDelimiter(buf, '\n') catch |err| {
            switch (err) {
                error.StreamTooLong => {
                    // Consume the rest of the line to avoid bad state
                    try self.reader.skipUntilDelimiterOrEof('\n');
                    return error.InputTooLong;
                },
                else => return err,
            }
        };
        return mem.trim(u8, input, " \t\r\n");
    }
};
