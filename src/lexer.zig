const std = @import("std");
const Allocator = std.mem.Allocator;
const max_args = 128;

const Self = @This();

input: []const u8,
position: usize,
read_position: usize,
ch: u8,
buffer: std.ArrayList(u8),

pub fn init(input: []const u8, allocator: Allocator) !Self {
    var self = Self{
        .input = input,
        .position = 0,
        .read_position = 0,
        .ch = 0,
        .buffer = try std.ArrayList(u8).initCapacity(allocator, input.len + 1),
    };
    self.readChar();
    return self;
}

pub fn deinit(self: *Self) void {
    self.buffer.deinit();
}

pub fn lex(self: *Self) ![max_args:null]?[*:0]u8 {
    var index: usize = 0;
    var args_ptrs: [max_args:null]?[*:0]u8 = undefined;

    while (self.ch != 0) {
        self.skipWhitespace();

        switch (self.ch) {
            0 => {},
            else => {
                const begin = self.buffer.items.len;
                try self.lexToken();
                try self.buffer.append(0);
                const end = self.buffer.items.len - 1;
                args_ptrs[index] = @as(*align(1) const [*:0]u8, @ptrCast(&self.buffer.items[begin..end :0])).*;
            },
        }
        self.readChar();
        index += 1;
    }
    args_ptrs[index] = null;
    return args_ptrs;
}

fn readChar(self: *Self) void {
    if (self.read_position < self.input.len) {
        self.ch = self.input[self.read_position];
    } else {
        self.ch = 0;
    }
    self.position = self.read_position;
    self.read_position += 1;
}

fn peekChar(self: Self) u8 {
    if (self.read_position < self.input.len) {
        return self.input[self.read_position];
    } else {
        return 0;
    }
}

fn skipWhitespace(self: *Self) void {
    while (std.ascii.isWhitespace(self.ch)) {
        self.readChar();
    }
}

fn readEscapedChar(self: *Self) u8 {
    if (self.peekChar() == 0) {
        // Error
        return 0;
    } else {
        self.readChar();
        return self.ch;
    }
}

fn lexToken(self: *Self) !void {
    while (self.ch != 0 and !std.ascii.isWhitespace(self.ch)) {
        switch (self.ch) {
            '\\' => {
                try self.buffer.append(self.readEscapedChar());
            },
            '\'' => try self.lexSingleQuote(),
            '\"' => try self.lexDoubleQuote(),
            0 => {},
            else => {
                try self.buffer.append(self.ch);
            },
        }
        self.readChar();
    }
}

fn lexSingleQuote(self: *Self) !void {
    self.readChar();
    while (self.ch != 0 and self.ch != '\'') {
        switch (self.ch) {
            '\\' => {
                try self.buffer.append(self.readEscapedChar());
            },
            0 => {},
            else => try self.buffer.append(self.ch),
        }
        self.readChar();
    }
    self.readChar();
}

fn lexDoubleQuote(self: *Self) !void {
    self.readChar();
    while (self.ch != 0 and self.ch != '\"') {
        switch (self.ch) {
            '\\' => {
                try self.buffer.append(self.readEscapedChar());
            },
            0 => {},
            else => try self.buffer.append(self.ch),
        }
        self.readChar();
    }
    self.readChar();
}
