//Copyright © 2025 Lewis Andrew Campbell
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the “Software”), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
// IN THE SOFTWARE.

const std = @import("std");

const debug = std.debug;
const fmt = std.fmt;
const posix = std.posix;

const Io = std.Io;
const File = Io.File;

writer: File.Writer,
io: Io,
termios: posix.termios,
ws: posix.winsize,
buffer: [4096]u8,

const Self = @This();

pub fn init(io: Io) !Self {
    var ws: posix.winsize = undefined;
    const rc = posix.system.ioctl(1, posix.T.IOCGWINSZ, @intFromPtr(&ws));
    debug.assert(rc == 0);

    var term: posix.termios = undefined;
    if (posix.system.tcgetattr(posix.STDIN_FILENO, &term) != 0) {
        return error.TcgetattrFailed;
    }

    try rawMode(&term, true);

    const stdout = File.stdout();
    var buffer = [_]u8{0} ** 4096;
    var result = Self{
        .writer = stdout.writerStreaming(io, &buffer),
        .io = io,
        .termios = term,
        .ws = ws,
        .buffer = buffer,
    };

    try result.write(&.{ cc.clear, cc.cursor.hide });
    try result.refresh();
    return result;
}

/// Resets the terminal state to what it was before
pub fn deinit(self: *Self) void {
    self.write(&.{cc.clear}) catch unreachable;
    self.refresh() catch unreachable;
    rawMode(&self.termios, false) catch unreachable;
    const rc = posix.system.tcsetattr(
        posix.STDIN_FILENO,
        .NOW,
        &self.termios,
    );
    debug.assert(rc == 0);
    _ = self.writer.interface.write(
        cc.clear ++ cc.cursor.home,
    ) catch unreachable;
}

pub fn renderFrame(self: *Self, err_buf: []const u8, items: anytype) !void {
    try self.write(&.{ cc.clear, cc.cursor.home });
    try self.printStack(items);
    try self.print(
        "{s}{s}{s}{s}",
        .{ cc.fg_red, err_buf, cc.reset_attrs, cc.cursor.home },
    );
    try self.refresh();
}

pub fn getLine(self: *Self, input_buf: []u8, iter: anytype) ![]const u8 {
    try self.write(&.{ cc.clear, cc.cursor.setPos(.{ .row = 2, .col = 1 }) });
    try self.printStack(iter);

    try self.write(&.{
        cc.cursor.home,
        "> ",
        cc.cursor.show,
    });
    try rawMode(&self.termios, false);
    try self.refresh();

    const end = try self.readString(input_buf);

    try rawMode(&self.termios, true);
    try self.write(&.{cc.cursor.hide});
    try self.refresh();

    input_buf[end] = '\n';
    return input_buf[0 .. end + 1];
}

pub fn readByte(self: *Self) !u8 {
    var byte: u8 = undefined;
    const n = try File.stdin().readStreaming(self.io, &.{(&byte)[0..1]});
    if (n == 0) return error.EndOfStream;
    return byte;
}

/// For runtime known values
fn print(
    self: *Self,
    comptime format: []const u8,
    args: anytype,
) !void {
    try self.writer.interface.print(format, args);
}

fn refresh(self: *Self) !void {
    try self.writer.interface.flush();
}

fn printStack(self: *Self, items: anytype) !void {
    const top: []const u8 = items.next() orelse return;
    try self.print("{s}{s}{s}", .{ cc.bold_on, top, cc.reset_attrs });

    while (items.next()) |item| {
        try self.print("{s}", .{item});
    }
}

fn rawMode(termios: *posix.termios, enabled: bool) !void {
    termios.lflag.ICANON = !enabled;
    termios.lflag.ECHO = !enabled;
    if (posix.system.tcsetattr(posix.STDIN_FILENO, .NOW, termios) != 0) {
        return error.TcsetattrFailed;
    }
}

/// For comptime known values
fn write(self: *Self, comptime codes: []const []const u8) !void {
    const combined = comptime blk: {
        var result: []const u8 = "";
        for (codes) |code| {
            result = result ++ code;
        }
        break :blk result;
    };
    _ = try self.writer.interface.write(combined);
}

/// For runtime known cursor positons
/// For comptime known, use cc.cursor.setPos
fn setCursorPos(self: *Self, pos: CursorPos) !void {
    try self.writer.interface.print(cc.cursor.set_pos_fmt_str, .{ pos.row, pos.col });
}

fn readString(self: *Self, buf: []u8) !usize {
    var i: usize = 0;
    while (i < buf.len) {
        const byte = try self.readByte();
        if (byte == '\n' or byte == '\r') break;
        buf[i] = byte;
        i += 1;
    }
    return i;
}

/// ECMA-48 Control Codes
const cc = struct {
    const clear = "\x1B[2J";
    const bold_on = "\x1B[1m";
    const reset_attrs = "\x1B[0m";

    // Foreground colors
    const fg_black = "\x1B[30m";
    const fg_red = "\x1B[31m";
    const fg_green = "\x1B[32m";
    const fg_yellow = "\x1B[33m";
    const fg_blue = "\x1B[34m";
    const fg_magenta = "\x1B[35m";
    const fg_cyan = "\x1B[36m";
    const fg_white = "\x1B[37m";

    // Background colors
    const bg_black = "\x1B[40m";
    const bg_red = "\x1B[41m";
    const bg_green = "\x1B[42m";
    const bg_yellow = "\x1B[43m";
    const bg_blue = "\x1B[44m";
    const bg_magenta = "\x1B[45m";
    const bg_cyan = "\x1B[46m";
    const bg_white = "\x1B[47m";

    const cursor = struct {
        const home = "\x1B[H";
        const hide = "\x1B[?25l";
        const show = "\x1B[?25h";

        const set_pos_fmt_str = "\x1B[{d};{d}H";

        /// Set cursor with a comptime known position
        /// For runtime values, see Term.setCursorPos
        fn setPos(comptime pos: CursorPos) []const u8 {
            return fmt.comptimePrint(set_pos_fmt_str, .{ pos.row, pos.col });
        }
    };

    const region = struct {
        // Reset to full screen scrolling
        const reset = "\x1B[r";

        // Reverse line feed (scroll down when at top margin)
        const reverse_lf = "\x1BM";

        // Normal line feed (scroll up when at bottom margin)
        const normal_lf = "\x1B[1E";

        const set_region_fmt_str = "\x1B[{d};{d}r";

        fn set(r: Region) []const u8 {
            return fmt.comptimePrint(set_region_fmt_str, .{ r.top, r.bottom });
        }
    };
};

const CursorPos = struct { row: u16, col: u16 };
const Region = struct { top: u16, bottom: u16 };
