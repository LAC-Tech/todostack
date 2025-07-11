const std = @import("std");
const BoundedArray = std.BoundedArray;
const debug = std.debug;
const fmt = std.fmt;
const fs = std.fs;
const heap = std.heap;
const io = std.io;
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
    // always contains the next offset
    offsets: BoundedArray(u16, max_stack_size + 1),
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

        var offsets = try BoundedArray(u16, max_stack_size + 1).fromSlice(&.{0});
        if (!mem.allEqual(u8, file_bytes, 0)) {
            for (file_bytes, 0..) |byte, i| {
                if (byte != '\n') continue;
                const newline_idx: u16 = @intCast(i);
                try offsets.append(newline_idx + 1);
            }
        }

        return .{
            .fd = fd,
            .mmap_bytes = bytes,
            .offsets = offsets,
            .file_len = file_len,
        };
    }

    fn len(self: Stack) usize {
        return self.offsets.len - 1;
    }

    fn push(self: *Stack, item: []const u8) !void {
        if (self.len() >= max_stack_size) return error.StackOverflow;
        // including newline
        if (item.len > max_item_size + 1) return error.ItemTooLong;
        if (item.len == 0) return;
        if (item[item.len - 1] != '\n') return error.ItemMissingNewline;

        const new_size = self.file_len + item.len;
        if (new_size > max_file_size) return error.FileTooLarge;

        const bytes_appended: u16 = @intCast(try posix.pwrite(self.fd, item, self.file_len));
        debug.assert(bytes_appended == item.len);

        const offset = self.offsets.constSlice()[self.len()];
        try self.offsets.append(offset + bytes_appended);
        self.file_len += bytes_appended;

        try posix.msync(self.mmap_bytes, posix.MSF.SYNC);
    }

    fn drop(self: *Stack) !void {
        if (1 > self.len()) return error.Underflow;

        const prev_offset = self.offsets.constSlice()[self.offsets.len - 2];
        try posix.ftruncate(self.fd, prev_offset);
        self.file_len = prev_offset;
        _ = self.offsets.pop();

        try posix.msync(self.mmap_bytes, posix.MSF.SYNC);
    }

    fn swap(self: *Stack) !void {
        if (2 > self.len()) return error.Underflow;

        const offsets = self.offsets.constSlice();
        const last = self.len();

        const a_start = offsets[last - 1];
        const b_start = offsets[last - 2];
        const end = offsets[last];

        const a_len = end - a_start;
        const b_len = a_start - b_start;

        if (a_len > max_item_size or b_len > max_item_size) {
            return error.ItemTooLong;
        }

        @memcpy(self.temp_a[0..a_len], self.mmap_bytes[a_start..end]);
        @memcpy(self.temp_b[0..b_len], self.mmap_bytes[b_start..a_start]);

        const base = b_start;
        @memcpy(self.mmap_bytes[base .. base + a_len], self.temp_a[0..a_len]);
        @memcpy(self.mmap_bytes[base + a_len .. base + a_len + b_len], self.temp_b[0..b_len]);

        self.offsets.slice()[last - 1] = base + a_len;
        self.offsets.slice()[last] = base + a_len + b_len;
        self.file_len = base + a_len + b_len;

        try posix.msync(self.mmap_bytes, posix.MSF.SYNC);
    }

    fn rot(self: *Stack) !void {
        if (3 > self.len()) return error.Underflow;

        const offsets = self.offsets.constSlice();
        const last = self.len();

        const a_start = offsets[last - 3];
        const b_start = offsets[last - 2];
        const c_start = offsets[last - 1];
        const end = offsets[last];

        const a_len = b_start - a_start;
        const b_len = c_start - b_start;
        const c_len = end - c_start;

        if (a_len > max_item_size or b_len > max_item_size or c_len > max_item_size) {
            return error.ItemTooLong;
        }

        @memcpy(self.temp_a[0..a_len], self.mmap_bytes[a_start..b_start]);
        @memcpy(self.temp_b[0..b_len], self.mmap_bytes[b_start..c_start]);
        const c_slice = self.mmap_bytes[c_start..end];

        const base = a_start;
        @memcpy(self.mmap_bytes[base .. base + c_len], c_slice);
        @memcpy(self.mmap_bytes[base + c_len .. base + c_len + a_len], self.temp_a[0..a_len]);
        @memcpy(self.mmap_bytes[base + c_len + a_len .. base + c_len + a_len + b_len], self.temp_b[0..b_len]);

        self.offsets.slice()[last - 3] = base;
        self.offsets.slice()[last - 2] = base + c_len;
        self.offsets.slice()[last - 1] = base + c_len + a_len;
        self.offsets.slice()[last] = base + c_len + a_len + b_len;
        self.file_len = base + c_len + a_len + b_len;

        try posix.msync(self.mmap_bytes, posix.MSF.SYNC);
    }

    fn view(self: Stack) ?struct { first: []const u8, rest: []const u8 } {
        if (self.len() == 0) return null;

        const offsets = self.offsets.constSlice();
        const last_idx = self.len();
        const first_start = offsets[last_idx - 1];
        const first_end = offsets[last_idx];
        const first = self.mmap_bytes[first_start..first_end];
        const rest = self.mmap_bytes[0..first_start];

        return .{ .first = first, .rest = rest };
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
        if (self.stack.view()) |view| {
            // Print the top item (first) in bold
            try self.term.print("{s}{s}{s}", .{ cc.bold_on, view.first, cc.reset_attrs });

            // Split rest into individual items and print in reverse order
            const offsets = self.stack.offsets.constSlice();
            var i: usize = offsets.len - 2; // Start from second-to-last offset
            while (i > 0) : (i -= 1) {
                const item_start = offsets[i - 1];
                const item_end = offsets[i];
                const item = self.stack.mmap_bytes[item_start..item_end];
                try self.term.print("{s}", .{item});
            }
        }
    }
};
