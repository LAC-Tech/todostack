const std = @import("std");
const debug = std.debug;
const fmt = std.fmt;
const mem = std.mem;
const process = std.process;

const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

const Tui = @import("./tui.zig");

const max_stack_len = 64;
const max_item_len = 256; // SMS size!
const mmap_size = 512 * 4096; // huge page size, about 2mb
const file_ext = "tds.txt";

const buf_size = struct {
    const input = max_item_len + 1; // to allow room for newline;
    const err = 1024;
    const filename = 512; // Daniel's Constant
};

pub fn main(init: process.Init) !void {
    const io = init.io;

    var filename_buf = [_]u8{0} ** buf_size.filename;
    var args = init.minimal.args.iterate();
    _ = args.skip();

    const arg1 = args.next() orelse {
        debug.print("Usage:\n", .{});
        debug.print("\ttds <file.{s}>\t- Open existing file\n", .{file_ext});
        debug.print(
            "\ttds -n <name>\t\t- Create new file <name>.{s}\n",
            .{file_ext},
        );
        return;
    };

    const create = mem.eql(u8, arg1, "-n");

    const file = if (create) blk: {
        const name = args.next() orelse {
            debug.print("Error: Missing name after -n\n", .{});
            return;
        };

        const filename =
            try fmt.bufPrint(&filename_buf, "{s}.{s}", .{ name, file_ext });

        const f = try Dir.createFile(.cwd(), io, filename, .{
            .exclusive = true,
            .read = true,
        });

        try File.sync(f, io);
        break :blk f;
    } else try Dir.openFile(.cwd(), io, arg1, .{ .mode = .read_write });

    defer file.close(io);

    var app = try App.init(io, file);
    defer app.deinit();

    try app.mainLoop();
}

const App = struct {
    stack: Stack,
    input_buf: [buf_size.input]u8 = .{0} ** buf_size.input,
    err_buf: [buf_size.err]u8 = .{0} ** buf_size.err,
    tui: Tui,

    fn init(io: Io, file: File) !App {
        return .{
            .stack = try Stack.init(io, file),
            .tui = try Tui.init(io),
        };
    }

    fn deinit(self: *App) void {
        self.tui.deinit();
        self.stack.deinit();
    }

    fn mainLoop(self: *App) !void {
        while (true) {
            try self.tui.clearHome();
            try self.printStack();
            try self.tui.printRedCursorHome(&self.err_buf);
            try self.tui.refresh();
            @memset(&self.err_buf, 0);

            self.handleInput() catch |err| {
                switch (err) {
                    error.quit => return,
                    else => {
                        _ = try fmt.bufPrint(&self.err_buf, "{}", .{err});
                        return;
                    },
                }
            };
        }
    }

    fn handleInput(self: *App) !void {
        return switch (try self.tui.readByte()) {
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

        try self.tui.clearSetPos(.{ .row = 2, .col = 1 });
        try self.printStack();

        return self.tui.getLine(&self.input_buf);
    }

    fn printStack(self: *App) !void {
        if (self.stack.abstr.len == 0) return;

        const top = self.stack.get(0);
        try self.tui.printBold(top);

        for (1..self.stack.abstr.len) |i| {
            const item = self.stack.get(i);
            try self.tui.print("{s}", .{item});
        }
    }
};

const Stack = struct {
    file: File,
    io: Io,
    mm: File.MemoryMap,
    abstr: Abstraction,

    fn init(io: Io, file: File) !Stack {
        const mm = try File.createMemoryMap(file, io, .{ .len = mmap_size });
        debug.assert(mm.memory.len == mmap_size);

        const stat = try File.stat(file, io);
        const bytes = mm.memory[0..@intCast(stat.size)];

        return .{
            .file = file,
            .io = io,
            .mm = mm,
            .abstr = Abstraction.init(bytes),
        };
    }

    fn deinit(self: *Stack) void {
        self.mm.destroy(self.io);
    }

    fn push(self: *Stack, item: []const u8) !void {
        const offset = try self.abstr.appendOffset();
        const bytes_written: u16 = @intCast(item.len);

        @memcpy(self.mm.memory[@as(usize, offset)..][0..item.len], item);
        try File.setLength(self.file, self.io, offset + bytes_written);

        self.abstr.len += 1;
        self.abstr.offsets[self.abstr.len] = offset + bytes_written;

        try self.sync();
    }

    fn drop(self: *Stack) !void {
        try self.ensureMinLen(1);
        self.abstr.len -= 1;
        try File.setLength(self.file, self.io, self.abstr.offsets[self.abstr.len]);
        try self.sync();
    }

    fn swap(self: *Stack) !void {
        try self.ensureMinLen(2);
        const a = self.get(0);
        const b = self.get(1);

        @memcpy(self.abstr.temp_a[0..a.len], a);
        @memcpy(self.abstr.temp_b[0..b.len], b);

        self.set(&.{
            self.abstr.temp_b[0..b.len],
            self.abstr.temp_a[0..a.len],
        });
        try self.sync();
    }

    fn rot(self: *Stack) !void {
        try self.ensureMinLen(3);
        const a = self.get(0);
        const b = self.get(1);
        const c = self.get(2);

        @memcpy(self.abstr.temp_a[0..a.len], a);
        @memcpy(self.abstr.temp_b[0..b.len], b);
        @memcpy(self.abstr.temp_c[0..c.len], c);

        self.set(&.{
            self.abstr.temp_c[0..c.len],
            self.abstr.temp_a[0..a.len],
            self.abstr.temp_b[0..b.len],
        });
        try self.sync();
    }

    fn get(self: Stack, idx: usize) []const u8 {
        const offset_idx = self.abstr.len - 1 - idx;
        const start = self.abstr.offsets[offset_idx];
        const end = self.abstr.offsets[offset_idx + 1];

        return self.mm.memory[start..end];
    }

    fn set(self: *Stack, items: []const []const u8) void {
        for (items, 0..) |item, idx| {
            const end = self.abstr.offsets[self.abstr.len - idx];
            const start = end - item.len;

            @memcpy(self.mm.memory[start..end], item);
            self.abstr.offsets[self.abstr.len - 1 - idx] = @intCast(start);
        }
    }

    fn ensureMinLen(self: *Stack, n: usize) !void {
        if (self.abstr.len < n) return error.Underflow;
    }

    fn sync(self: *Stack) !void {
        try self.mm.write(self.io);
    }
};

const Abstraction = struct {
    const max_offsets = max_stack_len + 1;

    temp_a: [max_item_len]u8 = .{0} ** max_item_len,
    temp_b: [max_item_len]u8 = .{0} ** max_item_len,
    temp_c: [max_item_len]u8 = .{0} ** max_item_len,
    offsets: [max_offsets]u16 = .{0} ** max_offsets,
    len: u8 = 0,

    fn init(bytes: []const u8) @This() {
        var res: @This() = .{};

        for (bytes, 0..) |byte, i| {
            if (byte == '\n') {
                res.len += 1;
                res.offsets[res.len] = @intCast(i + 1);
            }
        }

        return res;
    }

    fn appendOffset(self: @This()) !usize {
        if (self.abstr.len >= max_stack_len) return error.StackOverflow;
        return self.abstr.offsets[self.abstr.len];
    }
};
