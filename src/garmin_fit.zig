const std = @import("std");
const date = @import("date.zig");

const fit_epoch_unix_seconds: i64 = 631065600;
const activity_message_number: u16 = 34;
const file_id_message_number: u16 = 0;
const session_message_number: u16 = 18;
const time_in_zone_message_number: u16 = 216;

pub const Sport = enum {
    running,
    cycling,
};

pub const Summary = struct {
    date: date.Date,
    sport: Sport,
    duration_seconds: u32,
    distance_km: ?f64,
    average_heart_rate: ?u16,
    maximum_heart_rate: ?u16,
    average_cadence: ?u16,
    maximum_cadence: ?u16,
    average_power: ?u16,
    maximum_power: ?u16,
    normalized_power: ?u16,
    calories: ?u16,
    ascent_meters: ?u16,
    descent_meters: ?u16,
    average_speed_kph: ?f64,
    maximum_speed_kph: ?f64,
    aerobic_training_effect: ?f64,
    anaerobic_training_effect: ?f64,
    training_stress_score: ?f64,
    intensity_factor: ?f64,
    laps: ?u16,
    average_temperature_celsius: ?i8,
    minimum_temperature_celsius: ?i8,
    maximum_temperature_celsius: ?i8,
    sport_profile_name: ?[]const u8,
    heart_rate_zone_seconds: ?[7]u32,
};

const FieldDefinition = struct {
    number: u8,
    size: u8,
    base_type: u8,
};

const MessageDefinition = struct {
    present: bool = false,
    big_endian: bool = false,
    global_number: u16 = 0,
    field_count: u8 = 0,
    fields: [256]FieldDefinition = undefined,
    developer_field_count: u8 = 0,
    developer_field_sizes: [256]u8 = undefined,
};

const SessionFields = struct {
    start_time: ?u32 = null,
    timer_milliseconds: ?u64 = null,
    distance_centimeters: ?u64 = null,
    calories: ?u16 = null,
    average_speed_millimeters_per_second: ?u64 = null,
    maximum_speed_millimeters_per_second: ?u64 = null,
    average_heart_rate: ?u16 = null,
    maximum_heart_rate: ?u16 = null,
    average_cadence: ?u16 = null,
    maximum_cadence: ?u16 = null,
    average_power: ?u16 = null,
    maximum_power: ?u16 = null,
    normalized_power: ?u16 = null,
    ascent_meters: ?u16 = null,
    descent_meters: ?u16 = null,
    aerobic_training_effect_tenths: ?u16 = null,
    anaerobic_training_effect_tenths: ?u16 = null,
    training_stress_score_tenths: ?u16 = null,
    intensity_factor_thousandths: ?u16 = null,
    laps: ?u16 = null,
    average_temperature_celsius: ?i8 = null,
    minimum_temperature_celsius: ?i8 = null,
    maximum_temperature_celsius: ?i8 = null,
    sport: ?u8 = null,
    sport_profile_name: ?[]const u8 = null,
};

const ZoneFields = struct {
    reference_message: ?u16 = null,
    durations: ?[7]u32 = null,
};

const Parser = struct {
    bytes: []const u8,
    offset: usize,
    end: usize,
    definitions: [16]MessageDefinition = [_]MessageDefinition{.{}} ** 16,
    is_activity_file: bool = false,
    session_count: u8 = 0,
    session: SessionFields = .{},
    activity_timestamp: ?u32 = null,
    local_activity_timestamp: ?u32 = null,
    heart_rate_zone_seconds: ?[7]u32 = null,
};

pub fn parse(bytes: []const u8) !Summary {
    if (bytes.len < 14) return error.InvalidFitFile;

    const header_size = bytes[0];
    if (header_size < 12) return error.InvalidFitHeader;
    if (bytes.len < @as(usize, header_size) + 2) return error.TruncatedFitFile;
    if (!std.mem.eql(u8, bytes[8..12], ".FIT")) return error.InvalidFitHeader;

    const data_size = readLittleUnsigned(bytes[4..8]);
    const data_end_u64 = @as(u64, header_size) + data_size;
    if (data_end_u64 > std.math.maxInt(usize)) return error.FitFileTooLarge;
    const data_end: usize = @intCast(data_end_u64);
    if (data_end + 2 != bytes.len) return error.InvalidFitSize;

    if (header_size >= 14) {
        const expected_header_crc: u16 = @intCast(readLittleUnsigned(bytes[12..14]));
        if (expected_header_crc != 0 and crc16(bytes[0..12]) != expected_header_crc) {
            return error.InvalidFitHeaderChecksum;
        }
    }
    const expected_file_crc: u16 = @intCast(readLittleUnsigned(bytes[data_end .. data_end + 2]));
    if (crc16(bytes[0..data_end]) != expected_file_crc) {
        return error.InvalidFitChecksum;
    }

    var parser: Parser = .{
        .bytes = bytes,
        .offset = header_size,
        .end = data_end,
    };
    while (parser.offset < parser.end) {
        try parseRecord(&parser);
    }

    if (!parser.is_activity_file) return error.NotActivityFitFile;
    if (parser.session_count == 0) return error.SessionMissing;
    if (parser.session_count > 1) return error.MultipleSessionsUnsupported;
    const sport = switch (parser.session.sport orelse return error.SportMissing) {
        1 => Sport.running,
        2 => Sport.cycling,
        else => return error.UnsupportedSport,
    };

    const start_time = parser.session.start_time orelse return error.StartTimeMissing;
    const timer_milliseconds = parser.session.timer_milliseconds orelse
        return error.TimerTimeMissing;
    const rounded_duration = (timer_milliseconds + 500) / 1000;
    if (rounded_duration == 0 or rounded_duration > std.math.maxInt(u32)) {
        return error.InvalidTimerTime;
    }

    var local_offset_seconds: i64 = 0;
    if (parser.activity_timestamp != null and parser.local_activity_timestamp != null) {
        local_offset_seconds = @as(i64, parser.local_activity_timestamp.?) -
            @as(i64, parser.activity_timestamp.?);
        if (local_offset_seconds < -24 * 60 * 60 or local_offset_seconds > 24 * 60 * 60) {
            return error.InvalidLocalTimestamp;
        }
    }
    const start_unix_seconds = fit_epoch_unix_seconds + @as(i64, start_time) +
        local_offset_seconds;
    const epoch_day = @divFloor(start_unix_seconds, 24 * 60 * 60);
    if (epoch_day < std.math.minInt(i32) or epoch_day > std.math.maxInt(i32)) {
        return error.InvalidStartTime;
    }

    return .{
        .date = date.fromEpochDay(@intCast(epoch_day)),
        .sport = sport,
        .duration_seconds = @intCast(rounded_duration),
        .distance_km = scaledPositiveOptional(parser.session.distance_centimeters, 100_000),
        .average_heart_rate = positiveOptional(parser.session.average_heart_rate),
        .maximum_heart_rate = parser.session.maximum_heart_rate,
        .average_cadence = parser.session.average_cadence,
        .maximum_cadence = parser.session.maximum_cadence,
        .average_power = parser.session.average_power,
        .maximum_power = parser.session.maximum_power,
        .normalized_power = parser.session.normalized_power,
        .calories = parser.session.calories,
        .ascent_meters = parser.session.ascent_meters,
        .descent_meters = parser.session.descent_meters,
        .average_speed_kph = speedKph(parser.session.average_speed_millimeters_per_second),
        .maximum_speed_kph = speedKph(parser.session.maximum_speed_millimeters_per_second),
        .aerobic_training_effect = scaledOptional(
            parser.session.aerobic_training_effect_tenths,
            10,
        ),
        .anaerobic_training_effect = scaledOptional(
            parser.session.anaerobic_training_effect_tenths,
            10,
        ),
        .training_stress_score = scaledOptional(
            parser.session.training_stress_score_tenths,
            10,
        ),
        .intensity_factor = scaledOptional(
            parser.session.intensity_factor_thousandths,
            1000,
        ),
        .laps = parser.session.laps,
        .average_temperature_celsius = parser.session.average_temperature_celsius,
        .minimum_temperature_celsius = parser.session.minimum_temperature_celsius,
        .maximum_temperature_celsius = parser.session.maximum_temperature_celsius,
        .sport_profile_name = parser.session.sport_profile_name,
        .heart_rate_zone_seconds = parser.heart_rate_zone_seconds,
    };
}

fn parseRecord(parser: *Parser) !void {
    const record_header = try takeByte(parser);
    if (record_header & 0x80 != 0) {
        const local_number = (record_header >> 5) & 0x03;
        try parseDataMessage(parser, local_number, true);
        return;
    }

    const local_number = record_header & 0x0f;
    if (record_header & 0x40 != 0) {
        try parseDefinitionMessage(parser, local_number, record_header & 0x20 != 0);
        return;
    }
    try parseDataMessage(parser, local_number, false);
}

fn parseDefinitionMessage(
    parser: *Parser,
    local_number: u8,
    has_developer_fields: bool,
) !void {
    _ = try takeByte(parser);
    const architecture = try takeByte(parser);
    if (architecture > 1) return error.InvalidFitArchitecture;

    var definition: MessageDefinition = .{
        .present = true,
        .big_endian = architecture == 1,
    };
    definition.global_number = @intCast(readUnsigned(
        try take(parser, 2),
        definition.big_endian,
    ));
    definition.field_count = try takeByte(parser);

    var field_index: usize = 0;
    while (field_index < definition.field_count) : (field_index += 1) {
        definition.fields[field_index] = .{
            .number = try takeByte(parser),
            .size = try takeByte(parser),
            .base_type = try takeByte(parser),
        };
    }

    if (has_developer_fields) {
        definition.developer_field_count = try takeByte(parser);
        var developer_index: usize = 0;
        while (developer_index < definition.developer_field_count) : (developer_index += 1) {
            _ = try takeByte(parser);
            definition.developer_field_sizes[developer_index] = try takeByte(parser);
            _ = try takeByte(parser);
        }
    }
    parser.definitions[local_number] = definition;
}

fn parseDataMessage(
    parser: *Parser,
    local_number: u8,
    compressed_timestamp: bool,
) !void {
    const definition = parser.definitions[local_number];
    if (!definition.present) return error.FitDefinitionMissing;

    var zone_fields: ZoneFields = .{};
    var field_index: usize = 0;
    while (field_index < definition.field_count) : (field_index += 1) {
        const field = definition.fields[field_index];
        if (compressed_timestamp and field.number == 253) continue;
        const value = try take(parser, field.size);
        switch (definition.global_number) {
            file_id_message_number => parseFileIdField(parser, field, value),
            session_message_number => try parseSessionField(parser, definition, field, value),
            activity_message_number => try parseActivityField(parser, definition, field, value),
            time_in_zone_message_number => try parseZoneField(&zone_fields, definition, field, value),
            else => {},
        }
    }

    var developer_index: usize = 0;
    while (developer_index < definition.developer_field_count) : (developer_index += 1) {
        _ = try take(parser, definition.developer_field_sizes[developer_index]);
    }

    if (definition.global_number == session_message_number) {
        parser.session_count +|= 1;
    }
    if (definition.global_number == time_in_zone_message_number and
        zone_fields.reference_message == session_message_number and
        zone_fields.durations != null)
    {
        parser.heart_rate_zone_seconds = zone_fields.durations;
    }
}

fn parseFileIdField(parser: *Parser, field: FieldDefinition, bytes: []const u8) void {
    if (field.number != 0) return;
    const value = decodeUnsigned(field, bytes, false) orelse return;
    if (value == 4) parser.is_activity_file = true;
}

fn parseSessionField(
    parser: *Parser,
    definition: MessageDefinition,
    field: FieldDefinition,
    bytes: []const u8,
) !void {
    const unsigned = decodeUnsigned(field, bytes, definition.big_endian);
    switch (field.number) {
        2 => parser.session.start_time = try optionalU32(unsigned),
        5 => parser.session.sport = try optionalU8(unsigned),
        7 => {},
        8 => parser.session.timer_milliseconds = unsigned,
        9 => parser.session.distance_centimeters = unsigned,
        11 => parser.session.calories = try optionalU16(unsigned),
        14 => parser.session.average_speed_millimeters_per_second = unsigned,
        15 => parser.session.maximum_speed_millimeters_per_second = unsigned,
        16 => parser.session.average_heart_rate = try optionalU16(unsigned),
        17 => parser.session.maximum_heart_rate = try optionalU16(unsigned),
        18 => parser.session.average_cadence = try optionalU16(unsigned),
        19 => parser.session.maximum_cadence = try optionalU16(unsigned),
        20 => parser.session.average_power = try optionalU16(unsigned),
        21 => parser.session.maximum_power = try optionalU16(unsigned),
        22 => parser.session.ascent_meters = try optionalU16(unsigned),
        23 => parser.session.descent_meters = try optionalU16(unsigned),
        24 => parser.session.aerobic_training_effect_tenths = try optionalU16(unsigned),
        26 => parser.session.laps = try optionalU16(unsigned),
        34 => parser.session.normalized_power = try optionalU16(unsigned),
        35 => parser.session.training_stress_score_tenths = try optionalU16(unsigned),
        36 => parser.session.intensity_factor_thousandths = try optionalU16(unsigned),
        57 => parser.session.average_temperature_celsius = decodeSigned8(field, bytes),
        58 => parser.session.maximum_temperature_celsius = decodeSigned8(field, bytes),
        110 => parser.session.sport_profile_name = decodeString(bytes),
        137 => parser.session.anaerobic_training_effect_tenths = try optionalU16(unsigned),
        150 => parser.session.minimum_temperature_celsius = decodeSigned8(field, bytes),
        else => {},
    }
}

fn parseActivityField(
    parser: *Parser,
    definition: MessageDefinition,
    field: FieldDefinition,
    bytes: []const u8,
) !void {
    const value = decodeUnsigned(field, bytes, definition.big_endian) orelse return;
    switch (field.number) {
        5 => parser.local_activity_timestamp = try optionalU32(value),
        253 => parser.activity_timestamp = try optionalU32(value),
        else => {},
    }
}

fn parseZoneField(
    zone_fields: *ZoneFields,
    definition: MessageDefinition,
    field: FieldDefinition,
    bytes: []const u8,
) !void {
    switch (field.number) {
        0 => zone_fields.reference_message = try optionalU16(
            decodeUnsigned(field, bytes, definition.big_endian),
        ),
        2 => zone_fields.durations = try decodeZoneDurations(
            field,
            bytes,
            definition.big_endian,
        ),
        else => {},
    }
}

fn decodeZoneDurations(
    field: FieldDefinition,
    bytes: []const u8,
    big_endian: bool,
) !?[7]u32 {
    if (elementSize(field.base_type) != 4 or bytes.len < 7 * 4) return null;

    var result: [7]u32 = undefined;
    for (0..7) |index| {
        const start = index * 4;
        const value = decodeUnsigned(
            .{ .number = field.number, .size = 4, .base_type = field.base_type },
            bytes[start .. start + 4],
            big_endian,
        ) orelse return null;
        const rounded_seconds = (value + 500) / 1000;
        if (rounded_seconds > std.math.maxInt(u32)) return error.FitValueOutOfRange;
        result[index] = @intCast(rounded_seconds);
    }
    return result;
}

fn decodeUnsigned(
    field: FieldDefinition,
    bytes: []const u8,
    big_endian: bool,
) ?u64 {
    const base_type = field.base_type & 0x1f;
    const size = elementSize(field.base_type);
    if (size == null or bytes.len < size.?) return null;
    if (base_type == 7 or base_type == 8 or base_type == 9) return null;

    const value = readUnsigned(bytes[0..size.?], big_endian);
    const invalid: u64 = switch (base_type) {
        0, 2, 13 => std.math.maxInt(u8),
        1 => std.math.maxInt(i8),
        3 => std.math.maxInt(i16),
        4 => std.math.maxInt(u16),
        5 => std.math.maxInt(i32),
        6 => std.math.maxInt(u32),
        10, 11, 12, 16 => 0,
        14 => std.math.maxInt(i64),
        15 => std.math.maxInt(u64),
        else => return null,
    };
    if (value == invalid) return null;
    return value;
}

fn decodeSigned8(field: FieldDefinition, bytes: []const u8) ?i8 {
    if (field.base_type & 0x1f != 1 or bytes.len == 0) return null;
    const bits = bytes[0];
    if (bits == std.math.maxInt(i8)) return null;
    return @bitCast(bits);
}

fn decodeString(bytes: []const u8) ?[]const u8 {
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    if (end == 0) return null;
    return bytes[0..end];
}

fn elementSize(base_type_byte: u8) ?usize {
    return switch (base_type_byte & 0x1f) {
        0, 1, 2, 7, 10, 13 => 1,
        3, 4, 11 => 2,
        5, 6, 8, 12 => 4,
        9, 14, 15, 16 => 8,
        else => null,
    };
}

fn readUnsigned(bytes: []const u8, big_endian: bool) u64 {
    var result: u64 = 0;
    if (big_endian) {
        for (bytes) |byte| result = (result << 8) | byte;
        return result;
    }
    var index = bytes.len;
    while (index > 0) {
        index -= 1;
        result = (result << 8) | bytes[index];
    }
    return result;
}

fn readLittleUnsigned(bytes: []const u8) u64 {
    return readUnsigned(bytes, false);
}

fn take(parser: *Parser, count: usize) ![]const u8 {
    if (count > parser.end - parser.offset) return error.TruncatedFitFile;
    const result = parser.bytes[parser.offset .. parser.offset + count];
    parser.offset += count;
    return result;
}

fn takeByte(parser: *Parser) !u8 {
    return (try take(parser, 1))[0];
}

fn optionalU8(value: ?u64) !?u8 {
    const present = value orelse return null;
    if (present > std.math.maxInt(u8)) return error.FitValueOutOfRange;
    return @intCast(present);
}

fn optionalU16(value: ?u64) !?u16 {
    const present = value orelse return null;
    if (present > std.math.maxInt(u16)) return error.FitValueOutOfRange;
    return @intCast(present);
}

fn optionalU32(value: ?u64) !?u32 {
    const present = value orelse return null;
    if (present > std.math.maxInt(u32)) return error.FitValueOutOfRange;
    return @intCast(present);
}

fn scaledOptional(value: anytype, scale: comptime_int) ?f64 {
    const present = value orelse return null;
    return @as(f64, @floatFromInt(present)) / scale;
}

fn scaledPositiveOptional(value: anytype, scale: comptime_int) ?f64 {
    const present = value orelse return null;
    if (present == 0) return null;
    return @as(f64, @floatFromInt(present)) / scale;
}

fn positiveOptional(value: anytype) @TypeOf(value) {
    const present = value orelse return null;
    if (present == 0) return null;
    return present;
}

fn speedKph(value: ?u64) ?f64 {
    const millimeters_per_second = value orelse return null;
    return @as(f64, @floatFromInt(millimeters_per_second)) * 0.0036;
}

fn crc16(bytes: []const u8) u16 {
    const table = [_]u16{
        0x0000, 0xcc01, 0xd801, 0x1400,
        0xf001, 0x3c00, 0x2800, 0xe401,
        0xa001, 0x6c00, 0x7800, 0xb401,
        0x5000, 0x9c01, 0x8801, 0x4400,
    };
    var crc: u16 = 0;
    for (bytes) |byte| {
        var temporary = table[crc & 0xf];
        crc = (crc >> 4) & 0x0fff;
        crc ^= temporary ^ table[byte & 0xf];

        temporary = table[crc & 0xf];
        crc = (crc >> 4) & 0x0fff;
        crc ^= temporary ^ table[(byte >> 4) & 0xf];
    }
    return crc;
}

fn appendU16(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
    try list.append(allocator, @truncate(value));
    try list.append(allocator, @truncate(value >> 8));
}

fn appendU32(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    try list.append(allocator, @truncate(value));
    try list.append(allocator, @truncate(value >> 8));
    try list.append(allocator, @truncate(value >> 16));
    try list.append(allocator, @truncate(value >> 24));
}

fn appendDefinition(
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    local_number: u8,
    global_number: u16,
    fields: []const FieldDefinition,
) !void {
    try list.append(allocator, 0x40 | local_number);
    try list.append(allocator, 0);
    try list.append(allocator, 0);
    try appendU16(list, allocator, global_number);
    try list.append(allocator, @intCast(fields.len));
    for (fields) |field| {
        try list.append(allocator, field.number);
        try list.append(allocator, field.size);
        try list.append(allocator, field.base_type);
    }
}

test "parses a cycling activity summary and local date" {
    const allocator = std.testing.allocator;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(allocator);

    try appendDefinition(&data, allocator, 0, file_id_message_number, &.{
        .{ .number = 0, .size = 1, .base_type = 0 },
    });
    try data.appendSlice(allocator, &.{ 0, 4 });

    try appendDefinition(&data, allocator, 1, session_message_number, &.{
        .{ .number = 2, .size = 4, .base_type = 134 },
        .{ .number = 8, .size = 4, .base_type = 134 },
        .{ .number = 9, .size = 4, .base_type = 134 },
        .{ .number = 11, .size = 2, .base_type = 132 },
        .{ .number = 14, .size = 2, .base_type = 132 },
        .{ .number = 15, .size = 2, .base_type = 132 },
        .{ .number = 16, .size = 1, .base_type = 2 },
        .{ .number = 17, .size = 1, .base_type = 2 },
        .{ .number = 22, .size = 2, .base_type = 132 },
        .{ .number = 23, .size = 2, .base_type = 132 },
        .{ .number = 24, .size = 1, .base_type = 2 },
        .{ .number = 26, .size = 2, .base_type = 132 },
        .{ .number = 57, .size = 1, .base_type = 1 },
        .{ .number = 58, .size = 1, .base_type = 1 },
        .{ .number = 110, .size = 12, .base_type = 7 },
        .{ .number = 137, .size = 1, .base_type = 2 },
        .{ .number = 150, .size = 1, .base_type = 1 },
        .{ .number = 5, .size = 1, .base_type = 0 },
    });
    try data.append(allocator, 1);
    try appendU32(&data, allocator, 1_154_198_166);
    try appendU32(&data, allocator, 2_782_590);
    try appendU32(&data, allocator, 2_152_297);
    try appendU16(&data, allocator, 410);
    try appendU16(&data, allocator, 7_735);
    try appendU16(&data, allocator, 12_848);
    try data.appendSlice(allocator, &.{ 150, 171 });
    try appendU16(&data, allocator, 128);
    try appendU16(&data, allocator, 134);
    try data.append(allocator, 22);
    try appendU16(&data, allocator, 9);
    try data.appendSlice(allocator, &.{ 15, 19 });
    try data.appendSlice(allocator, "CYCLOCROSS\x00\x00");
    try data.appendSlice(allocator, &.{ 0, 14, 2 });

    try appendDefinition(&data, allocator, 2, time_in_zone_message_number, &.{
        .{ .number = 0, .size = 2, .base_type = 132 },
        .{ .number = 2, .size = 28, .base_type = 134 },
    });
    try data.append(allocator, 2);
    try appendU16(&data, allocator, session_message_number);
    for ([_]u32{ 26_000, 588_000, 1_570_000, 595_000, 0, 0, 0 }) |value| {
        try appendU32(&data, allocator, value);
    }

    try appendDefinition(&data, allocator, 3, activity_message_number, &.{
        .{ .number = 253, .size = 4, .base_type = 134 },
        .{ .number = 5, .size = 4, .base_type = 134 },
    });
    try data.append(allocator, 3);
    try appendU32(&data, allocator, 1_154_201_101);
    try appendU32(&data, allocator, 1_154_211_901);

    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(allocator);
    try file.appendSlice(allocator, &.{ 14, 0x20, 0, 0 });
    try appendU32(&file, allocator, @intCast(data.items.len));
    try file.appendSlice(allocator, ".FIT");
    try appendU16(&file, allocator, crc16(file.items));
    try file.appendSlice(allocator, data.items);
    try appendU16(&file, allocator, crc16(file.items));

    const summary = try parse(file.items);
    try std.testing.expectEqual(date.Date{ .year = 2026, .month = 7, .day = 28 }, summary.date);
    try std.testing.expectEqual(Sport.cycling, summary.sport);
    try std.testing.expectEqual(@as(u32, 2783), summary.duration_seconds);
    try std.testing.expectApproxEqAbs(@as(f64, 21.52297), summary.distance_km.?, 0.00001);
    try std.testing.expectEqual(@as(u16, 150), summary.average_heart_rate.?);
    try std.testing.expectEqual(@as(u16, 171), summary.maximum_heart_rate.?);
    try std.testing.expectApproxEqAbs(@as(f64, 27.846), summary.average_speed_kph.?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.2), summary.aerobic_training_effect.?, 0.01);
    try std.testing.expectEqualStrings("CYCLOCROSS", summary.sport_profile_name.?);
    try std.testing.expectEqual([7]u32{ 26, 588, 1570, 595, 0, 0, 0 }, summary.heart_rate_zone_seconds.?);
}

test "parses a running activity sport" {
    const allocator = std.testing.allocator;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(allocator);

    try appendDefinition(&data, allocator, 0, file_id_message_number, &.{
        .{ .number = 0, .size = 1, .base_type = 0 },
    });
    try data.appendSlice(allocator, &.{ 0, 4 });

    try appendDefinition(&data, allocator, 1, session_message_number, &.{
        .{ .number = 2, .size = 4, .base_type = 134 },
        .{ .number = 8, .size = 4, .base_type = 134 },
        .{ .number = 5, .size = 1, .base_type = 0 },
    });
    try data.append(allocator, 1);
    try appendU32(&data, allocator, 1_154_198_166);
    try appendU32(&data, allocator, 2_782_590);
    try data.append(allocator, 1);

    try appendDefinition(&data, allocator, 2, activity_message_number, &.{
        .{ .number = 253, .size = 4, .base_type = 134 },
        .{ .number = 5, .size = 4, .base_type = 134 },
    });
    try data.append(allocator, 2);
    try appendU32(&data, allocator, 1_154_201_101);
    try appendU32(&data, allocator, 1_154_211_901);

    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(allocator);
    try file.appendSlice(allocator, &.{ 14, 0x20, 0, 0 });
    try appendU32(&file, allocator, @intCast(data.items.len));
    try file.appendSlice(allocator, ".FIT");
    try appendU16(&file, allocator, crc16(file.items));
    try file.appendSlice(allocator, data.items);
    try appendU16(&file, allocator, crc16(file.items));

    const summary = try parse(file.items);
    try std.testing.expectEqual(Sport.running, summary.sport);
}
