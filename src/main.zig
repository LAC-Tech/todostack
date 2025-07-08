const std = @import("std");
const debug = std.debug;
const fmt = std.fmt;
const fs = std.fs;
const mem = std.mem;
const posix = std.posix;
const allocator = std.heap.page_allocator;

const max_stack_size = 64;
const max_item_size = 64;
const file_size = 64 * 64;
const file_ext = "tds.bin";

pub fn main() !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const file = if (mem.eql(u8, args[1], "-n")) blk: {
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

    defer file.close();

    const bytes = try posix.mmap(
        null, // OS chooses virtual address
        file_size,
        posix.PROT.READ | posix.PROT.WRITE,
        .{ .TYPE = .SHARED }, // Changes are written to file
        file.handle, // file descriptor
        0, // offset in file
    );

    debug.assert(bytes.len == file_size);
}

fn printUsage() void {
    debug.print("Usage:\n", .{});
    debug.print("\ttds <file.{s}>\t- Open existing file\n", .{file_ext});
    debug.print("\ttds -n <name>\t- Create new file name.{s}\n", .{file_ext});
}

fn createFile(name: []const u8) !fs.File {
    var filename_buf: [256]u8 = undefined;
    const filename = try fmt.bufPrint(
        &filename_buf,
        "{s}.{s}",
        .{ name, file_ext },
    );

    const file = try fs.cwd().createFile(filename, .{ .exclusive = true });
    const zeros = [_]u8{0} ** file_size;
    try file.writeAll(&zeros);

    debug.print("Created new file: {s}\n", .{filename});
    return file;
}

fn openFile(filename: []const u8) !fs.File {
    const file = try fs.cwd().openFile(filename, .{ .mode = .read_write });

    // Check file size
    const stat = try file.stat();
    if (stat.size != file_size) {
        debug.print(
            "Error: File {s} is not exactly {} bytes\n",
            .{ filename, file_size },
        );
        return error.InvalidFileSize;
    }

    debug.print("Opened file: {s}\n", .{filename});
    return file;
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
        if (self.top >= max_stack_size) return error.StackOverflow;
        if (item.len >= max_item_size) return error.ItemTooLong;
        @memcpy(self.data[self.len][0..item.len], item);
        self.len += 1;
    }

    fn drop(self: *Stack) !void {
        if (self.top == 0) return error.Underflow;
        self.top -= 1;
    }
};
