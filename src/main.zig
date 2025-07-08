const std = @import("std");
const debug = std.debug;
const fmt = std.fmt;
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const posix = std.posix;
const allocator = std.heap.page_allocator;

const max_stack_size = 64;
const max_item_size = 64;
const file_size = max_stack_size * max_item_size;
const file_ext = "tds.bin";

pub fn main() !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

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

    defer posix.close(fd);

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
    data: *[max_stack_size][max_item_size]u8,
    len: u8,

    fn init(bytes: []u8) Stack {
        debug.assert(bytes.len == file_size);
        const data = @as(*[max_stack_size][max_item_size]u8, @ptrCast(bytes.ptr));
        return Stack{ .data = data, .len = 0 };
    }

    fn push(self: *Stack, item: []const u8) !void {
        if (self.len >= max_stack_size) return error.StackOverflow;
        if (item.len >= max_item_size) return error.ItemTooLong;
        @memcpy(self.data[self.len][0..item.len], item);
        self.len += 1;
    }

    fn drop(self: *Stack) !void {
        if (self.len == 0) return error.Underflow;
        self.len -= 1;
    }
};

fn repl(stack: *Stack) !void {
    var buffer: [1024]u8 = undefined;
    const stdin = io.getStdIn().reader();

    while (true) {
        const input = try stdin.readUntilDelimiterOrEof(&buffer, '\n');
        if (input == null) break;

        const trimmed = mem.trim(u8, input.?, " \t\r\n");
        if (mem.eql(u8, trimmed, "drop")) {
            try stack.drop();
        } else if (trimmed.len > 0) {
            try stack.push(trimmed);
        }
    }
}
