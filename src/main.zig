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
        break :blk createFile(args[2]) catch |err| {
            debug.print("Error creating stack '{s}': {}\n", .{ args[2], err });
            return;
        };
    } else blk: {
        break :blk openFile(args[1]) catch |err| {
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
    try repl(&stack);
}

fn printUsage() void {
    debug.print("Usage:\n", .{});
    debug.print("\ttds <file.{s}>\t- Open existing file\n", .{file_ext});
    debug.print("\ttds -n <name>\t- Create new file name.{s}\n", .{file_ext});
}

fn createFile(name: []const u8) !posix.fd_t {
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

fn openFile(filename: []const u8) !posix.fd_t {
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

fn repl(stack: *Stack) !void {
    var buffer: [1024]u8 = undefined;
    const stdin = io.getStdIn().reader();
    const stdout = io.getStdIn().writer();

    while (true) {
        try stdout.print("> ", .{});
        const input = try stdin.readUntilDelimiterOrEof(&buffer, '\n');
        if (input == null) break;

        const trimmed = mem.trim(u8, input.?, " \t\r\n");
        if (mem.eql(u8, trimmed, "d")) {
            stack.drop() catch |err| {
                try stdout.print("{}\n", .{err});
            };
        } else if (mem.eql(u8, trimmed, "s")) {
            stack.swap() catch |err| {
                try stdout.print("{}\n", .{err});
            };
        } else if (mem.eql(u8, trimmed, "q")) {
            return;
        } else if (mem.eql(u8, trimmed, ".")) {
            for (stack.items) |item| {
                if (isEmptyItem(item)) break;
                try stdout.print("{s}\n", .{item});
            }
        } else if (isStringLiteral(trimmed)) {
            // Extract content between quotes
            const content = trimmed[1 .. trimmed.len - 1];
            if (content.len == 0) {
                try stdout.print("Empty string\n", .{});
                continue;
            }

            stack.push(content) catch |err| {
                try stdout.print("{}\n", .{err});
            };
        } else {
            debug.print("Err: unknown command '{s}'\n", .{trimmed});
        }
    }
}

fn isStringLiteral(s: []const u8) bool {
    if (2 > s.len) return false;
    if (s[0] != '"') return false;
    if (s[s.len - 1] != '"') return false;

    return true;
}

fn isEmptyItem(item: [max_item_size]u8) bool {
    return mem.allEqual(u8, &item, 0);
}
