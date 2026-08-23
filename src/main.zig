const std = @import("std");
const debug = std.debug;
const fmt = std.fmt;
const mem = std.mem;
const process = std.process;

const Dir = std.Io.Dir;
const File = std.Io.File;

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

        const f = try Dir.createFile(.cwd(), init.io, filename, .{
            .exclusive = true,
            .read = true,
        });

        try File.sync(f, init.io);
        break :blk f;
    } else try Dir.openFile(.cwd(), init.io, arg1, .{ .mode = .read_write });

    const fs = try RealFs.init(init.io, file);
    const ui = try Tui.init(init.io);
    var app = try App(RealFs, Tui).init(fs, ui);
    defer app.deinit();

    try app.mainLoop();
}

const RealFs = struct {
    std_io: std.Io,
    file: File,
    mm: File.MemoryMap,

    fn init(std_io: std.Io, file: File) !@This() {
        return .{
            .std_io = std_io,
            .file = file,
            .mm = try File.createMemoryMap(file, std_io, .{ .len = mmap_size }),
        };
    }

    fn deinit(self: *@This()) void {
        self.mm.destroy(self.std_io);
        self.file.close(self.std_io);
    }

    fn initialBytes(self: @This()) ![]u8 {
        const stat = try File.stat(self.file, self.std_io);
        return self.mm.memory[0..@intCast(stat.size)];
    }

    fn writeFile(self: *@This()) !void {
        try self.mm.write(self.std_io);
    }

    fn setFileLen(self: *@This(), new_len: usize) !void {
        try File.setLength(self.file, self.std_io, new_len);
    }
};

fn App(comptime Fs: type, comptime Ui: type) type {
    return struct {
        const Self = @This();
        fs: Fs,
        ui: Ui,
        stack: Stack,
        input_buf: [buf_size.input]u8 = .{0} ** buf_size.input,
        err_buf: [buf_size.err]u8 = .{0} ** buf_size.err,

        fn init(fs: Fs, ui: Ui) !Self {
            const bytes: []u8 = try fs.initialBytes();
            return .{ .fs = fs, .ui = ui, .stack = Stack.init(bytes) };
        }

        fn deinit(self: *Self) void {
            self.ui.deinit();
            self.fs.deinit();
        }

        fn mainLoop(self: *Self) !void {
            while (true) {
                var iter = self.stack.iter();
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

        fn handleInput(self: *Self) !void {
            return switch (try self.ui.readByte()) {
                'q' => error.quit,
                's' => {
                    try self.stack.swap();
                    try self.fs.writeFile();
                },
                'd' => {
                    const new_len = try self.stack.drop();
                    try self.fs.setFileLen(new_len);
                    try self.fs.writeFile();
                },
                'r' => {
                    try self.stack.rot();
                    try self.fs.writeFile();
                },
                'p' => {
                    @memset(&self.input_buf, 0);
                    var iter = self.stack.iter();
                    const line: []const u8 =
                        try self.ui.getLine(&self.input_buf, &iter);
                    const new_len = try self.stack.push(line) orelse return;
                    try self.fs.setFileLen(new_len);
                    try self.fs.writeFile();
                },
                else => {},
            };
        }
    };
}

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

    fn iter(self: *const @This()) Iter {
        return .{ .idx = 0, .stack = self };
    }

    const Iter = struct {
        idx: usize = 0,
        stack: *const Stack,

        pub fn next(self: *@This()) ?[]const u8 {
            if (self.idx >= self.stack.len) return null;
            const item = self.stack.get(self.idx);
            return item;
        }
    };
};
