const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
});

pub const Date = struct {
    year: i32,
    month: u8,
    day: u8,
};

pub const Error = error{
    InvalidDate,
};

pub fn parse(text: []const u8) Error!Date {
    if (text.len != 10 or text[4] != '-' or text[7] != '-') return error.InvalidDate;

    const year = std.fmt.parseInt(i32, text[0..4], 10) catch return error.InvalidDate;
    const month = std.fmt.parseInt(u8, text[5..7], 10) catch return error.InvalidDate;
    const day = std.fmt.parseInt(u8, text[8..10], 10) catch return error.InvalidDate;
    const result: Date = .{ .year = year, .month = month, .day = day };

    if (!isValid(result)) return error.InvalidDate;
    return result;
}

pub fn parseReference(text: []const u8) Error!Date {
    return parseReferenceFrom(text, today());
}

pub fn parseReferenceFrom(text: []const u8, current_date: Date) Error!Date {
    if (resolveRelativeReferenceFrom(text, current_date)) |value| return value;
    if (looksLikeDayOfMonth(text)) return parseDayOfMonth(text, current_date);
    return parse(text);
}

pub fn maybeParseReference(text: []const u8) Error!?Date {
    return maybeParseReferenceFrom(text, today());
}

pub fn maybeParseReferenceFrom(text: []const u8, current_date: Date) Error!?Date {
    if (resolveRelativeReferenceFrom(text, current_date)) |value| return value;
    if (looksLikeDayOfMonth(text)) return try parseDayOfMonth(text, current_date);
    if (!looksLikeDate(text)) return null;
    return try parse(text);
}

pub fn resolveRelativeReference(text: []const u8) ?Date {
    return resolveRelativeReferenceFrom(text, today());
}

pub fn resolveRelativeReferenceFrom(text: []const u8, current_date: Date) ?Date {
    if (std.mem.eql(u8, text, "today")) return current_date;
    if (std.mem.eql(u8, text, "tomorrow")) return addDays(current_date, 1);
    return null;
}

fn looksLikeDate(text: []const u8) bool {
    return text.len == 10 and text[4] == '-' and text[7] == '-';
}

fn looksLikeDayOfMonth(text: []const u8) bool {
    if (text.len == 0 or text.len > 2) return false;
    for (text) |character| {
        if (character < '0' or character > '9') return false;
    }
    return true;
}

fn parseDayOfMonth(text: []const u8, current_date: Date) Error!Date {
    const day = std.fmt.parseInt(u8, text, 10) catch return error.InvalidDate;
    const result: Date = .{ .year = current_date.year, .month = current_date.month, .day = day };
    if (!isValid(result)) return error.InvalidDate;
    return result;
}

pub fn isValid(value: Date) bool {
    if (value.year < 1 or value.month < 1 or value.month > 12 or value.day < 1) return false;
    return value.day <= daysInMonth(value.year, value.month);
}

pub fn today() Date {
    return fromUnixTimestampLocal(@intCast(c.time(null)));
}

pub fn fromUnixTimestampLocal(value: i64) Date {
    var timestamp: c.time_t = @intCast(value);
    var local: c.struct_tm = undefined;
    _ = c.localtime_r(&timestamp, &local);
    return .{
        .year = local.tm_year + 1900,
        .month = @intCast(local.tm_mon + 1),
        .day = @intCast(local.tm_mday),
    };
}

pub fn unixTimestamp() i64 {
    return @intCast(c.time(null));
}

pub fn format(allocator: std.mem.Allocator, value: Date) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}",
        .{ @as(u32, @intCast(value.year)), value.month, value.day },
    );
}

pub fn addDays(value: Date, amount: i32) Date {
    return fromEpochDay(toEpochDay(value) + amount);
}

pub fn daysBetween(start: Date, end: Date) i32 {
    return toEpochDay(end) - toEpochDay(start);
}

pub fn compare(left: Date, right: Date) std.math.Order {
    return std.math.order(toEpochDay(left), toEpochDay(right));
}

pub fn weekday(value: Date) u8 {
    return @intCast(@mod(toEpochDay(value) + 3, 7));
}

pub fn weekdayName(value: Date) []const u8 {
    return weekday_names[weekday(value)];
}

pub fn toEpochDay(value: Date) i32 {
    var year = value.year;
    if (value.month <= 2) year -= 1;

    const era = @divFloor(year, 400);
    const year_of_era: i32 = year - era * 400;
    const adjusted_month: i32 = @as(i32, value.month) + (if (value.month > 2) @as(i32, -3) else 9);
    const day_of_year = @divFloor(153 * adjusted_month + 2, 5) + @as(i32, value.day) - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

pub fn fromEpochDay(epoch_day: i32) Date {
    const shifted = epoch_day + 719468;
    const era = @divFloor(shifted, 146097);
    const day_of_era = shifted - era * 146097;
    const year_of_era = @divFloor(
        day_of_era - @divFloor(day_of_era, 1460) +
            @divFloor(day_of_era, 36524) - @divFloor(day_of_era, 146096),
        365,
    );
    var year = year_of_era + era * 400;
    const day_of_year = day_of_era -
        (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const month_prime = @divFloor(5 * day_of_year + 2, 153);
    const day: u8 = @intCast(day_of_year - @divFloor(153 * month_prime + 2, 5) + 1);
    const month: u8 = @intCast(month_prime + (if (month_prime < 10) @as(i32, 3) else -9));
    if (month <= 2) year += 1;
    return .{ .year = year, .month = month, .day = day };
}

fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn isLeapYear(year: i32) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

const weekday_names = [_][]const u8{
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
    "Sunday",
};

test "date round trip and weekday" {
    const value = try parse("2026-07-20");
    try std.testing.expectEqualStrings("Monday", weekdayName(value));
    try std.testing.expectEqual(value, fromEpochDay(toEpochDay(value)));
    try std.testing.expectEqual(Date{ .year = 2026, .month = 7, .day = 21 }, addDays(value, 1));

    const formatted = try format(std.testing.allocator, value);
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("2026-07-20", formatted);
}

test "rejects impossible date" {
    try std.testing.expectError(error.InvalidDate, parse("2026-02-30"));
}

test "parses relative date references from a supplied current date" {
    const current_date: Date = .{ .year = 2026, .month = 7, .day = 31 };

    try std.testing.expectEqual(current_date, try parseReferenceFrom("today", current_date));
    try std.testing.expectEqual(
        Date{ .year = 2026, .month = 8, .day = 1 },
        try parseReferenceFrom("tomorrow", current_date),
    );
    try std.testing.expectEqual(
        Date{ .year = 2026, .month = 8, .day = 2 },
        try parseReferenceFrom("2026-08-02", current_date),
    );
    try std.testing.expectError(error.InvalidDate, parseReferenceFrom("next-week", current_date));
}

test "parses a day number in the supplied current month" {
    const current_date: Date = .{ .year = 2026, .month = 2, .day = 10 };

    try std.testing.expectEqual(
        Date{ .year = 2026, .month = 2, .day = 6 },
        try parseReferenceFrom("6", current_date),
    );
    try std.testing.expectEqual(
        Date{ .year = 2026, .month = 2, .day = 26 },
        try parseReferenceFrom("26", current_date),
    );
    try std.testing.expectError(error.InvalidDate, parseReferenceFrom("0", current_date));
    try std.testing.expectError(error.InvalidDate, parseReferenceFrom("30", current_date));
}

test "resolves only relative date references" {
    const current_date: Date = .{ .year = 2026, .month = 7, .day = 31 };

    try std.testing.expectEqual(
        current_date,
        resolveRelativeReferenceFrom("today", current_date).?,
    );
    try std.testing.expectEqual(
        Date{ .year = 2026, .month = 8, .day = 1 },
        resolveRelativeReferenceFrom("tomorrow", current_date).?,
    );
    try std.testing.expect(resolveRelativeReferenceFrom("2026-08-02", current_date) == null);
    try std.testing.expect(resolveRelativeReferenceFrom("history", current_date) == null);
}

test "recognizes date references without consuming file paths" {
    const current_date: Date = .{ .year = 2026, .month = 8, .day = 2 };

    try std.testing.expect((try maybeParseReferenceFrom("today", current_date)) != null);
    try std.testing.expect((try maybeParseReferenceFrom("tomorrow", current_date)) != null);
    try std.testing.expect((try maybeParseReferenceFrom("26", current_date)) != null);
    try std.testing.expect((try maybeParseReferenceFrom("2026-08-02", current_date)) != null);
    try std.testing.expect((try maybeParseReferenceFrom("proposed-plan.json", current_date)) == null);
    try std.testing.expectError(
        error.InvalidDate,
        maybeParseReferenceFrom("2026-99-99", current_date),
    );
}
