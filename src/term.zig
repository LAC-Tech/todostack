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

const fmt = std.fmt;
const linux = std.os.linux;

const winsize = extern struct {
    row: u16,
    col: u16,
    xpixel: u16,
    ypixel: u16,
};

fn check(rc: usize) !usize {
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        else => error.SyscallFailed,
    };
}

pub const Term = struct {
    termios: struct { original: linux.termios, tui: linux.termios },
    ws: winsize,

    pub fn init() !Term {
        var ws: winsize = undefined;
        _ = try check(linux.ioctl(linux.STDOUT_FILENO, linux.T.IOCGWINSZ, @intFromPtr(&ws)));

        var term: linux.termios = undefined;
        _ = try check(linux.tcgetattr(linux.STDIN_FILENO, &term));

        return .{
            .termios = .{ .original = term, .tui = term },
            .ws = ws,
        };
    }

    /// Resets the terminal state to what it was before
    pub fn deinit(self: *Term) void {
        _ = linux.tcsetattr(
            linux.STDIN_FILENO,
            .NOW,
            &self.termios.original,
        );
        self.write(&.{ cc.clear, cc.cursor.home }) catch unreachable;
    }

    /// For runtime known values
    pub fn print(
        self: *Term,
        comptime format: []const u8,
        args: anytype,
    ) !void {
        var buf: [4096]u8 = undefined;
        const out = try fmt.bufPrint(&buf, format, args);
        try self.writeRaw(out);
    }

    pub fn refresh(_: *Term) !void {}

    pub fn rawMode(self: *Term, enabled: bool) !void {
        var term = self.termios.tui;
        term.lflag.ICANON = !enabled;
        term.lflag.ECHO = !enabled;
        _ = try check(linux.tcsetattr(linux.STDIN_FILENO, .NOW, &term));
    }

    /// For comptime known values
    pub fn write(self: *Term, comptime codes: []const []const u8) !void {
        const combined = comptime blk: {
            var result: []const u8 = "";
            for (codes) |code| {
                result = result ++ code;
            }
            break :blk result;
        };
        try self.writeRaw(combined);
    }

    /// For runtime known cursor positons
    /// For comptime known, use cc.curosr.setPos
    pub fn setCursorPos(self: *Term, pos: CursorPos) !void {
        var buf: [32]u8 = undefined;
        const out = try fmt.bufPrint(&buf, cc.cursor.set_pos_fmt_str, .{ pos.row, pos.col });
        try self.writeRaw(out);
    }

    fn writeRaw(_: *Term, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            off += try check(linux.write(linux.STDOUT_FILENO, bytes[off..].ptr, bytes.len - off));
        }
    }

    pub fn readByte() !u8 {
        var byte: u8 = undefined;
        const n = try check(linux.read(linux.STDIN_FILENO, (&byte)[0..1], 1));
        if (n == 0) return error.EndOfStream;
        return byte;
    }

    pub fn readString(buf: []u8) !usize {
        var i: usize = 0;
        while (i < buf.len) {
            const byte = try readByte();
            if (byte == '\n' or byte == '\r') break;
            buf[i] = byte;
            i += 1;
        }
        return i;
    }
};

/// ECMA-48 Control Codes
/// These are intended to be passed into the 'write' function of Term
pub const cc = struct {
    pub const clear = "\x1B[2J";
    pub const bold_on = "\x1B[1m";
    pub const reset_attrs = "\x1B[0m";

    // Foreground colors
    pub const fg_black = "\x1B[30m";
    pub const fg_red = "\x1B[31m";
    pub const fg_green = "\x1B[32m";
    pub const fg_yellow = "\x1B[33m";
    pub const fg_blue = "\x1B[34m";
    pub const fg_magenta = "\x1B[35m";
    pub const fg_cyan = "\x1B[36m";
    pub const fg_white = "\x1B[37m";

    // Background colors
    pub const bg_black = "\x1B[40m";
    pub const bg_red = "\x1B[41m";
    pub const bg_green = "\x1B[42m";
    pub const bg_yellow = "\x1B[43m";
    pub const bg_blue = "\x1B[44m";
    pub const bg_magenta = "\x1B[45m";
    pub const bg_cyan = "\x1B[46m";
    pub const bg_white = "\x1B[47m";

    pub const cursor = struct {
        pub const home = "\x1B[H";
        pub const hide = "\x1B[?25l";
        pub const show = "\x1B[?25h";

        const set_pos_fmt_str = "\x1B[{d};{d}H";

        /// Set cursor with a comptime known position
        /// For runtime values, see Term.setCursorPos
        pub fn setPos(comptime pos: CursorPos) []const u8 {
            return fmt.comptimePrint(set_pos_fmt_str, .{ pos.row, pos.col });
        }
    };

    pub const region = struct {
        // Reset to full screen scrolling
        pub const reset = "\x1B[r";

        // Reverse line feed (scroll down when at top margin)
        pub const reverse_lf = "\x1BM";

        // Normal line feed (scroll up when at bottom margin)
        pub const normal_lf = "\x1B[1E";

        const set_region_fmt_str = "\x1B[{d};{d}r";

        pub fn set(r: Region) []const u8 {
            return fmt.comptimePrint(set_region_fmt_str, .{ r.top, r.bottom });
        }
    };
};

const CursorPos = struct { row: u16, col: u16 };
const Region = struct { top: u16, bottom: u16 };
