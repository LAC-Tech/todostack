const std = @import("std");
const debug = std.debug;
const fmt = std.fmt;
const fs = std.fs;
const heap = std.heap;
const io = std.io;
const mem = std.mem;
const posix = std.posix;

const c = @cImport({
    @cDefine("_DEFAULT_SOURCE", {});
    @cDefine("_XOPEN_SOURCE", {});
    @cDefine("TB_IMPL", {});
    @cInclude("termbox2.h");
});

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
    } else file.open(args[1]) catch |err| {
        debug.print("Error opening stack '{s}': {}\n", .{ args[1], err });
        return;
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
    try tui(&stack);
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

const InputMode = enum {
    normal,
    push,
};

fn tui(stack: *Stack) !void {
    _ = c.tb_init();
    defer _ = c.tb_shutdown();

    var input_mode = InputMode.normal;
    var input_buffer: [max_item_size]u8 = undefined;
    var input_len: usize = 0;
    var error_msg: ?[]const u8 = null;

    while (true) {
        _ = c.tb_clear();

        // Draw stack
        const height = c.tb_height();
        var y: i32 = 1;

        // Title
        _ = c.tb_printf(0, 0, c.TB_CYAN, 0, "Stack (len: %d)", stack.len);

        // Draw items from top to bottom
        for (0..stack.len) |i| {
            const item = stack.items[stack.len - 1 - i];
            if (isEmptyItem(item)) break;

            const fg = if (i == 0) c.TB_GREEN | c.TB_BOLD else c.TB_WHITE;
            _ = c.tb_printf(2, y, @intCast(fg), 0, "%s", &item);
            y += 1;

            if (y >= height - 3) break; // Leave space for input and help
        }

        // Input line
        if (input_mode == .push) {
            _ = c.tb_printf(
                0,
                height - 3,
                c.TB_YELLOW,
                0,
                "Push: %.*s",
                input_len,
                &input_buffer,
            );
            _ = c.tb_set_cursor(@as(c_int, @intCast(6 + input_len)), height - 3);
        } else {
            _ = c.tb_hide_cursor();
        }

        // Error message
        if (error_msg) |msg| {
            _ = c.tb_printf(0, height - 2, c.TB_RED, 0, "Error: %s", &msg);
        }

        // Help line
        const help = if (input_mode == .push)
            "Enter to confirm, Esc to cancel"
        else
            "Commands: (p)ush, (d)rop, (s)wap, (q)uit";
        _ = c.tb_printf(0, height - 1, c.TB_BLUE, 0, "%s", &help);

        _ = c.tb_present();

        // Handle input
        var ev: c.struct_tb_event = undefined;
        _ = c.tb_poll_event(&ev);

        error_msg = null; // Clear error after each input

        if (ev.type == c.TB_EVENT_KEY) {
            if (input_mode == .push) {
                if (ev.key == c.TB_KEY_ENTER) {
                    // Confirm push
                    if (input_len > 0) {
                        stack.push(input_buffer[0..input_len]) catch |err| {
                            error_msg = switch (err) {
                                error.StackOverflow => "Stack overflow",
                                error.ItemTooLong => "Item too long",
                                else => "Unknown error",
                            };
                        };
                    }
                    input_mode = .normal;
                    input_len = 0;
                } else if (ev.key == c.TB_KEY_ESC) {
                    // Cancel push
                    input_mode = .normal;
                    input_len = 0;
                } else if (ev.key == c.TB_KEY_BACKSPACE or ev.key == c.TB_KEY_BACKSPACE2) {
                    // Backspace
                    if (input_len > 0) {
                        input_len -= 1;
                    }
                } else if (ev.ch > 0 and ev.ch < 127) {
                    // Regular character
                    if (input_len < max_item_size - 1) {
                        input_buffer[input_len] = @intCast(ev.ch);
                        input_len += 1;
                    }
                }
            } else {
                // Normal mode
                switch (ev.ch) {
                    'p' => {
                        input_mode = .push;
                        input_len = 0;
                    },
                    'd' => {
                        stack.drop() catch |err| {
                            error_msg = switch (err) {
                                error.Underflow => "Stack underflow",
                                else => "Unknown error",
                            };
                        };
                    },
                    's' => {
                        stack.swap() catch |err| {
                            error_msg = switch (err) {
                                error.Underflow => "Not enough items to swap",
                                else => "Unknown error",
                            };
                        };
                    },
                    'q' => return,
                    else => {
                        if (ev.key == c.TB_KEY_ESC) return;
                    },
                }
            }
        }
    }
}

fn isEmptyItem(item: [max_item_size]u8) bool {
    return mem.allEqual(u8, &item, 0);
}
