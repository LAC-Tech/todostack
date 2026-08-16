const std = @import("std");
const debug = std.debug;
const fmt = std.fmt;
const mem = std.mem;
const process = std.process;

const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

const Term = @import("./term.zig");

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
    term: Term,

    fn init(io: Io, file: File) !App {
        var t = try Term.init(io);
        try t.write(&.{ Term.cc.clear, Term.cc.cursor.hide });
        try t.refresh();

        return .{ .stack = try Stack.init(io, file), .term = t };
    }

    fn deinit(self: *App) void {
        self.term.write(&.{Term.cc.clear}) catch unreachable;
        self.term.refresh() catch unreachable;
        self.term.deinit();
        self.stack.deinit();
    }

    fn mainLoop(self: *App) !void {
        while (true) {
            try self.term.write(&.{ Term.cc.clear, Term.cc.cursor.home });
            try self.printStack();
            try self.term.print(
                "{s}{s}{s}{s}",
                .{
                    Term.cc.fg_red,
                    self.err_buf,
                    Term.cc.reset_attrs,
                    Term.cc.cursor.home,
                },
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
                if (line.len > 1) try self.stack.push(line);
            },
            else => {},
        };
    }

    fn readLine(self: *App) ![]const u8 {
        @memset(&self.input_buf, 0);

        try self.term.write(&.{
            Term.cc.clear,
            Term.cc.cursor.setPos(.{ .row = 2, .col = 1 }),
        });
        try self.printStack();
        try self.term.write(&.{
            Term.cc.cursor.home,
            "> ",
            Term.cc.cursor.show,
        });
        try self.term.rawMode(false);
        try self.term.refresh();

        defer {
            self.term.rawMode(true) catch unreachable;
            self.term.write(&.{Term.cc.cursor.hide}) catch unreachable;
            self.term.refresh() catch unreachable;
        }

        const end = try self.term.readString(&self.input_buf);
        self.input_buf[end] = '\n';
        return self.input_buf[0 .. end + 1];
    }

    fn printStack(self: *App) !void {
        if (self.stack.items.len == 0) return;

        const top = self.stack.items.get(0);
        try self.term.print(
            "{s}{s}{s}",
            .{ Term.cc.bold_on, top, Term.cc.reset_attrs },
        );

        for (1..self.stack.items.len) |i| {
            const item = self.stack.items.get(i);
            try self.term.print("{s}", .{item});
        }
    }
};

const Stack = struct {
    items: Items,
    io: Io,
    temp_a: [max_item_len]u8 = .{0} ** max_item_len,
    temp_b: [max_item_len]u8 = .{0} ** max_item_len,
    temp_c: [max_item_len]u8 = .{0} ** max_item_len,

    fn init(io: Io, file: File) !Stack {
        return .{ .items = try Items.init(io, file), .io = io };
    }

    fn deinit(self: *Stack) void {
        self.items.deinit();
    }

    fn push(self: *Stack, item: []const u8) !void {
        if (self.items.len >= max_stack_len) return error.StackOverflow;
        try self.items.push(item);
        try self.items.sync();
    }

    fn drop(self: *Stack) !void {
        try self.items.ensureMinLen(1);
        try self.items.drop();
        try self.items.sync();
    }

    fn swap(self: *Stack) !void {
        try self.items.ensureMinLen(2);
        const a = self.items.get(0);
        const b = self.items.get(1);

        @memcpy(self.temp_a[0..a.len], a);
        @memcpy(self.temp_b[0..b.len], b);

        self.items.set(&.{
            self.temp_b[0..b.len],
            self.temp_a[0..a.len],
        });
        try self.items.sync();
    }

    fn rot(self: *Stack) !void {
        try self.items.ensureMinLen(3);
        const a = self.items.get(0);
        const b = self.items.get(1);
        const c = self.items.get(2);

        @memcpy(self.temp_a[0..a.len], a);
        @memcpy(self.temp_b[0..b.len], b);
        @memcpy(self.temp_c[0..c.len], c);

        self.items.set(&.{
            self.temp_c[0..c.len],
            self.temp_a[0..a.len],
            self.temp_b[0..b.len],
        });
        try self.items.sync();
    }
};

const Items = struct {
    const max_offsets = max_stack_len + 1;

    file: File,
    io: Io,
    mm: File.MemoryMap,
    offsets: [max_offsets]u16,
    len: u8,

    fn init(io: Io, file: File) !Items {
        const mm = try File.createMemoryMap(file, io, .{ .len = mmap_size });
        debug.assert(mm.memory.len == mmap_size);

        const stat = try File.stat(file, io);

        var offsets = [_]u16{0} ** max_offsets;
        var len: u8 = 0;

        for (mm.memory[0..@intCast(stat.size)], 0..) |byte, i| {
            if (byte == '\n') {
                len += 1;
                offsets[len] = @intCast(i + 1);
            }
        }

        return .{
            .file = file,
            .io = io,
            .mm = mm,
            .offsets = offsets,
            .len = len,
        };
    }

    fn deinit(self: *Items) void {
        self.mm.destroy(self.io);
    }

    fn push(self: *Items, item: []const u8) !void {
        const offset = self.offsets[self.len];
        const bytes_written: u16 = @intCast(
            try File.writePositional(self.file, self.io, &.{item}, offset),
        );
        self.len += 1;
        self.offsets[self.len] = offset + bytes_written;
    }

    fn drop(self: *Items) !void {
        self.len -= 1;
        try File.setLength(self.file, self.io, self.offsets[self.len]);
    }

    fn get(self: *Items, idx: usize) []u8 {
        const offset_idx = self.len - 1 - idx;
        const start = self.offsets[offset_idx];
        const end = self.offsets[offset_idx + 1];

        return self.mm.memory[start..end];
    }

    fn set(self: *Items, items: []const []const u8) void {
        for (items, 0..) |item, idx| {
            const end = self.offsets[self.len - idx];
            const start = end - item.len;

            @memcpy(self.mm.memory[start..end], item);
            self.offsets[self.len - 1 - idx] = @intCast(start);
        }
    }

    fn ensureMinLen(self: *Items, n: usize) !void {
        if (self.len < n) return error.Underflow;
    }

    fn sync(self: *Items) !void {
        try self.mm.write(self.io);
    }
};
