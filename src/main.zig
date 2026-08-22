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
    io: Io,
    file: File,
    mm: File.MemoryMap,
    ui: Tui,
    stack: Stack,
    input_buf: [buf_size.input]u8 = .{0} ** buf_size.input,
    err_buf: [buf_size.err]u8 = .{0} ** buf_size.err,

    fn init(io: Io, file: File) !App {
        const mm = try File.createMemoryMap(file, io, .{ .len = mmap_size });
        debug.assert(mm.memory.len == mmap_size);

        const stat = try File.stat(file, io);
        const bytes = mm.memory[0..@intCast(stat.size)];
        return .{
            .io = io,
            .file = file,
            .stack = Stack.init(bytes),
            .mm = mm,
            .ui = try Tui.init(io),
        };
    }

    fn deinit(self: *App) void {
        self.ui.deinit();
        self.mm.destroy(self.io);
    }

    fn mainLoop(self: *App) !void {
        while (true) {
            var iter = StackIter.init(&self.stack);
            try self.ui.renderFrame(&self.err_buf, &iter);
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
        return switch (try self.ui.readByte()) {
            'q' => error.quit,
            's' => {
                try self.stack.swap();
                try self.mm.write(self.io);
            },
            'd' => {
                const new_len = try self.stack.drop();
                try File.setLength(self.file, self.io, new_len);
                try self.mm.write(self.io);
            },
            'r' => {
                try self.stack.rot();
                try self.mm.write(self.io);
            },
            'p' => {
                const line = try self.readLine();
                const new_len = try self.stack.push(line) orelse return;
                try File.setLength(self.file, self.io, new_len);
                try self.mm.write(self.io);
            },
            else => {},
        };
    }

    fn readLine(self: *App) ![]const u8 {
        @memset(&self.input_buf, 0);

        var iter = StackIter.init(&self.stack);
        return self.ui.getLine(&self.input_buf, &iter);
    }
};

const Stack = struct {
    const max_offsets = max_stack_len + 1;

    content: []u8,

    temp_a: [max_item_len]u8 = .{0} ** max_item_len,
    temp_b: [max_item_len]u8 = .{0} ** max_item_len,
    temp_c: [max_item_len]u8 = .{0} ** max_item_len,
    offsets: [max_offsets]u16 = .{0} ** max_offsets,
    len: u8 = 0,

    fn init(bytes: []u8) @This() {
        var res: @This() = .{ .content = bytes };

        for (bytes, 0..) |byte, i| {
            if (byte == '\n') {
                res.len += 1;
                res.offsets[res.len] = @intCast(i + 1);
            }
        }

        return res;
    }

    /// Returns new offset
    fn push(self: *@This(), item: []const u8) !?usize {
        if (2 > item.len) return null;
        if (self.len >= max_stack_len) return error.StackOverflow;
        const offset = self.offsets[self.len];
        const new_offset = offset + item.len;
        self.len += 1;
        self.offsets[self.len] = @intCast(new_offset);
        @memcpy(self.content[@as(usize, offset)..][0..item.len], item);
        return new_offset;
    }

    /// Returns new offset
    fn drop(self: *@This()) !usize {
        try self.ensureMinLen(1);
        self.len -= 1;
        return self.offsets[self.len];
    }

    fn get(self: @This(), idx: usize) []const u8 {
        const offset_idx = self.len - 1 - idx;
        const start = self.offsets[offset_idx];
        const end = self.offsets[offset_idx + 1];

        return self.content[start..end];
    }

    fn _replaceFromTop(self: *@This(), items: []const []const u8) void {
        for (items, 0..) |item, idx| {
            const end = self.offsets[self.len - idx];
            const start = end - item.len;

            @memcpy(self.content[start..end], item);
            self.offsets[self.len - 1 - idx] = @intCast(start);
        }
    }

    fn ensureMinLen(self: *@This(), n: usize) !void {
        if (self.len < n) return error.Underflow;
    }

    fn rot(self: *@This()) !void {
        try self.ensureMinLen(3);
        const a = self.get(0);
        const b = self.get(1);
        const c = self.get(2);

        @memcpy(self.temp_a[0..a.len], a);
        @memcpy(self.temp_b[0..b.len], b);
        @memcpy(self.temp_c[0..c.len], c);

        self._replaceFromTop(&.{
            self.temp_c[0..c.len],
            self.temp_a[0..a.len],
            self.temp_b[0..b.len],
        });
    }

    fn swap(self: *@This()) !void {
        try self.ensureMinLen(2);
        const a = self.get(0);
        const b = self.get(1);

        @memcpy(self.temp_a[0..a.len], a);
        @memcpy(self.temp_b[0..b.len], b);

        self._replaceFromTop(&.{
            self.temp_b[0..b.len],
            self.temp_a[0..a.len],
        });
    }
};

const StackIter = struct {
    idx: usize = 0,
    stack: *const Stack,

    fn init(stack: *const Stack) @This() {
        return .{ .idx = 0, .stack = stack };
    }

    pub fn next(self: *@This()) ?[]const u8 {
        if (self.idx >= self.stack.len) return null;
        const item = self.stack.get(self.idx);
        return item;
    }
};
