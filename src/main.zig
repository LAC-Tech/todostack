const std = @import("std");
const ncurses = @cImport({
    @cInclude("ncurses.h");
});
const debug = std.debug;
const fmt = std.fmt;
const fs = std.fs;
const heap = std.heap;
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
        null,
        file_size,
        posix.PROT.READ | posix.PROT.WRITE,
        .{ .TYPE = .SHARED },
        fd,
        0,
    );

    debug.assert(bytes.len == file_size);

    var stack = Stack.init(bytes);
    try runNcurses(&stack);
}

fn printUsage() void {
    debug.print("Usage:\n", .{});
    debug.print("\ttds <file.{s}>\t- Open existing file\n", .{file_ext});
    debug.print("\ttds -n <name>\t- Create new file <name>.{s}\n", .{file_ext});
}

const file = struct {
    fn create(name: []const u8) !posix.fd_t {
        var filename_buf: [256]u8 = undefined;
        const filename = try fmt.bufPrint(&filename_buf, "{s}.{s}", .{ name, file_ext });

        const fd = try posix.open(
            filename,
            .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true },
            0o666,
        );

        try posix.ftruncate(fd, file_size);
        debug.print("Created new file: {s}\n", .{filename});
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
            debug.print("Error: File {s} is not exactly {} bytes\n", .{ filename, file_size });
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
        const data = @as(*[max_stack_size][max_item_size]u8, @ptrCast(bytes.ptr));
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

fn runNcurses(stack: *Stack) !void {
    _ = ncurses.initscr();
    defer _ = ncurses.endwin();

    _ = ncurses.cbreak();
    _ = ncurses.noecho();
    _ = ncurses.keypad(ncurses.stdscr, true);
    _ = ncurses.curs_set(0); // Hide cursor by default

    var input_buf = [_]u8{0} ** max_item_size;
    var input_len: usize = 0;
    var input_mode = false;
    var error_msg = [_]u8{0} ** 128;

    while (true) {
        renderStack(stack, input_mode, input_buf[0..input_len], &error_msg);

        const ch = ncurses.getch();
        if (input_mode) {
            if (ch == '\n') { // Enter
                if (input_len > 0) {
                    stack.push(input_buf[0..input_len]) catch |err| {
                        _ = try fmt.bufPrint(&error_msg, "Error: {}", .{err});
                    };
                }
                input_len = 0;
                input_mode = false;
                _ = ncurses.curs_set(0);
                @memset(&error_msg, 0);
            } else if (ch == 27) { // Escape
                input_len = 0;
                input_mode = false;
                _ = ncurses.curs_set(0);
                @memset(&error_msg, 0);
            } else if (ch == 127 or ch == 8) { // Backspace
                if (input_len > 0) input_len -= 1;
            } else if (ch >= 32 and ch <= 126 and input_len < max_item_size - 1) {
                input_buf[input_len] = @intCast(ch);
                input_len += 1;
            }
        } else {
            switch (ch) {
                'q' => break,
                's' => {
                    stack.swap() catch |err| {
                        _ = try fmt.bufPrint(&error_msg, "Error: {}", .{err});
                    };
                },
                'd' => {
                    stack.drop() catch |err| {
                        _ = try fmt.bufPrint(&error_msg, "Error: {}", .{err});
                    };
                },
                'p' => {
                    input_mode = true;
                    input_len = 0;
                    _ = ncurses.curs_set(1); // Show cursor
                    @memset(&error_msg, 0);
                },
                else => {},
            }
        }
    }
}

fn renderStack(stack: *Stack, input_mode: bool, input: []const u8, error_msg: []const u8) void {
    _ = ncurses.erase();
    const max_y = ncurses.getmaxy(ncurses.stdscr);
    const max_y_usize: usize = @intCast(max_y);

    // Draw stack, starting at y=0 unless in input mode (then y=1)
    const stack_start_y: i32 = if (input_mode) 1 else 0;
    const stack_display_limit: usize = @min(stack.len, max_y_usize - 2); // Reserve space for commands/error
    for (0..stack_display_limit) |i| {
        const item = stack.items[stack.len - 1 - i];
        if (isEmptyItem(item)) break;
        const str = std.mem.sliceTo(&item, 0);

        const idx: i32 = @intCast(i);
        if (i == 0) {
            _ = ncurses.attron(ncurses.A_BOLD);
            _ = ncurses.mvprintw(stack_start_y + idx, 0, "%.*s", str.len, str.ptr);
            _ = ncurses.attroff(ncurses.A_BOLD);
        } else {
            _ = ncurses.mvprintw(stack_start_y + idx, 0, "%.*s", str.len, str.ptr);
        }
    }

    // Draw input or commands at the bottom
    if (input_mode) {
        _ = ncurses.mvprintw(0, 0, "%.*s", input.len, input.ptr); // Input at (0,0)
        _ = ncurses.move(0, @intCast(input.len)); // Move cursor to end of input
    } else {
        _ = ncurses.mvprintw(max_y - 1, 0, "Commands: s (swap), d (drop), p (push), q (quit)");
    }

    // Draw error message one row above commands if present
    if (error_msg.len > 0 and !input_mode) {
        _ = ncurses.mvprintw(max_y - 2, 0, "%.*s", error_msg.len, error_msg.ptr);
    }

    _ = ncurses.refresh();
}

fn isEmptyItem(item: [max_item_size]u8) bool {
    return mem.allEqual(u8, &item, 0);
}
