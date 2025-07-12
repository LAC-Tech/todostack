const std = @import("std");
const debug = std.debug;
const fmt = std.fmt;
const fs = std.fs;
const heap = std.heap;
const io = std.io;
const math = std.math;
const mem = std.mem;
const posix = std.posix;
const process = std.process;

const term = @import("./term.zig");
const cc = term.cc;
const Term = term.Term;

//const max_stack_size = 64;
//const max_item_size = 128;

const max_stack_size = 4;
const max_item_size = 4;
const max_file_size = 4096;
const file_ext = "tds.txt";

pub fn main() !void {
    var filename_buf = [_]u8{0} ** buf_size.filename;
    const args = parseArgs() catch {
        printUsage();
        return;
    };
    const fd = try openFile(args.filename, args.create, &filename_buf);

    var stack = try Stack.init(fd);
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
        try posix.fsync(fd);
    }

    return fd;
}

fn printUsage() void {
    debug.print("Usage:\n", .{});
    debug.print("\ttds <file.{s}>\t- Open existing file\n", .{file_ext});
    debug.print("\ttds -n <name>\t\t- Create new file <name>.{s}\n", .{file_ext});
}

const Stack = struct {
    fd: posix.fd_t,
    mmap_bytes: []align(heap.page_size_min) u8,
    offsets: [max_stack_size]u16,
    item_count: usize,
    file_len: usize,
    temp_a: [max_item_size]u8 = .{0} ** max_item_size,
    temp_b: [max_item_size]u8 = .{0} ** max_item_size,

    fn init(fd: posix.fd_t) !Stack {
        const bytes = try posix.mmap(
            null,
            max_file_size,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        debug.assert(bytes.len == max_file_size);

        const stat = try posix.fstat(fd);
        const file_len: usize = @intCast(stat.size);
        const file_bytes = bytes[0..file_len];

        var offsets = [_]u16{math.maxInt(u16)} ** max_stack_size;

        var item_count: usize = 0;
        var offset: usize = 0;

        while (mem.indexOfScalarPos(u8, file_bytes, offset, '\n')) |index| {
            if (item_count >= offsets.len) return error.BufferTooSmall;
            offsets[item_count] = @intCast(offset);
            item_count += 1;
            offset = index + 1;
        }

        return .{
            .fd = fd,
            .mmap_bytes = bytes,
            .offsets = offsets,
            .item_count = item_count,
            .file_len = file_len,
        };
    }

    fn ensureMinItemCount(self: Stack, min_len: usize) !void {
        if (self.item_count >= min_len) return error.StackUnderflow;
    }

    fn push(self: *Stack, item: []const u8) !void {
        if (self.item_count >= max_stack_size) return error.StackOverflow;
        // including newline
        if (item.len > max_item_size + 1) return error.ItemTooLong;
        if (item.len == 0) return;
        if (item[item.len - 1] != '\n') return error.ItemMissingNewline;

        const new_size = self.file_len + item.len;
        if (new_size > max_file_size) return error.FileTooLarge;

        const bytes_appended: u16 = @intCast(
            try posix.pwrite(self.fd, item, self.file_len),
        );
        debug.assert(bytes_appended == item.len);

        self.offsets[self.item_count] = @intCast(self.file_len);
        self.item_count += 1;
        self.file_len += bytes_appended;

        try posix.msync(self.mmap_bytes, posix.MSF.SYNC);
    }

    fn drop(self: *Stack) !void {
        try self.ensureMinItemCount(1);

        const prev_offset = self.offsets[self.item_count - 2];
        try posix.ftruncate(self.fd, prev_offset);
        self.file_len = prev_offset;
        self.item_count -= 1;

        try posix.msync(self.mmap_bytes, posix.MSF.SYNC);
    }

    // b a -> a b
    fn swap(self: *Stack) !void {
        try self.ensureMinItemCount(2);

        const old_a_offset = self.offsets[self.item_count - 1];
        const old_b_offset = self.offsets[self.item_count - 2];

        const a_len = self.file_len - old_a_offset;
        const b_len = old_a_offset - old_b_offset;

        // Stash A
        const a = self.temp_a[0..a_len];
        @memcpy(a, self.mmap_bytes[old_a_offset..self.file_len]);

        // Write B
        const new_b_offset = old_b_offset + a_len;
        @memcpy(
            self.mmap_bytes[new_b_offset .. new_b_offset + b_len],
            self.mmap_bytes[old_b_offset .. old_b_offset + b_len],
        );

        // Write A
        @memcpy(self.mmap_bytes[old_b_offset..new_b_offset], a);

        // Update offset
        self.offsets[self.item_count - 1] = @intCast(new_b_offset);

        try posix.msync(self.mmap_bytes, posix.MSF.SYNC);
    }

    fn rot(self: *Stack) !void {
        _ = self;
        @panic("Implement ROT");
    }

    fn view(self: Stack) ?struct { top: []const u8, rest: []const u8 } {
        if (self.item_count == 0) return null;

        debug.assert(self.offsets[0] == 0);
        const last_offset = self.offsets[self.item_count - 1];

        return .{
            // TOS is the last line
            .top = self.mmap_bytes[last_offset..self.file_len],
            .rest = self.mmap_bytes[0..last_offset],
        };
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
        const view = self.stack.view() orelse return;

        // Print the top item (first) in bold
        try self.term.print(
            "{s}{s}{s}",
            .{ cc.bold_on, view.top, cc.reset_attrs },
        );

        var lines = mem.splitBackwardsScalar(u8, view.rest, '\n');
        // First one is always an empty newline
        _ = lines.next();

        while (lines.next()) |line| {
            try self.term.print("{s}\n", .{line});
        }
    }
};
