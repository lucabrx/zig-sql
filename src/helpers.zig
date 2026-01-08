const std = @import("std");

pub fn is_letter(c: u8) bool {
    return ('a' <= c and c <= 'z') or ('A' <= c and c <= 'Z');
}

pub fn is_digit(c: u8) bool {
    return '0' <= c and c <= '9';
}

test "is_letter" {
    try std.testing.expect(is_letter('a'));
    try std.testing.expect(is_letter('A'));
    try std.testing.expect(!is_letter('1'));
}

test "is_digit" {
    try std.testing.expect(is_digit('0'));
    try std.testing.expect(is_digit('9'));
    try std.testing.expect(!is_digit('a'));
}
