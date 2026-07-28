const std = @import("std");
const date = @import("date.zig");
const garmin_fit = @import("garmin_fit.zig");

const Io = std.Io;

const Output = struct {
    date: []const u8,
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

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout_file_writer.flush() catch {};

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
    defer stderr_file_writer.flush() catch {};

    run(allocator, init.io, stdout, args) catch |err| {
        try stderr.print("Error: {s}\n", .{friendlyError(err)});
        try stderr_file_writer.flush();
        std.process.exit(1);
    };
}

fn run(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    args: []const []const u8,
) !void {
    if (args.len != 2) return error.FitPathRequired;
    const contents = Io.Dir.cwd().readFileAlloc(
        io,
        args[1],
        allocator,
        .limited(64 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.FitFileNotFound,
        else => return err,
    };
    const summary = try garmin_fit.parse(contents);
    const date_text = try date.format(allocator, summary.date);
    const output: Output = .{
        .date = date_text,
        .duration_seconds = summary.duration_seconds,
        .distance_km = summary.distance_km,
        .average_heart_rate = summary.average_heart_rate,
        .maximum_heart_rate = summary.maximum_heart_rate,
        .average_cadence = summary.average_cadence,
        .maximum_cadence = summary.maximum_cadence,
        .average_power = summary.average_power,
        .maximum_power = summary.maximum_power,
        .normalized_power = summary.normalized_power,
        .calories = summary.calories,
        .ascent_meters = summary.ascent_meters,
        .descent_meters = summary.descent_meters,
        .average_speed_kph = summary.average_speed_kph,
        .maximum_speed_kph = summary.maximum_speed_kph,
        .aerobic_training_effect = summary.aerobic_training_effect,
        .anaerobic_training_effect = summary.anaerobic_training_effect,
        .training_stress_score = summary.training_stress_score,
        .intensity_factor = summary.intensity_factor,
        .laps = summary.laps,
        .average_temperature_celsius = summary.average_temperature_celsius,
        .minimum_temperature_celsius = summary.minimum_temperature_celsius,
        .maximum_temperature_celsius = summary.maximum_temperature_celsius,
        .sport_profile_name = summary.sport_profile_name,
        .heart_rate_zone_seconds = summary.heart_rate_zone_seconds,
    };
    try std.json.Stringify.value(output, .{}, writer);
    try writer.writeByte('\n');
}

fn friendlyError(err: anyerror) []const u8 {
    return switch (err) {
        error.FitPathRequired => "expected exactly one FIT file path",
        error.FitFileNotFound => "FIT file not found",
        error.InvalidFitFile,
        error.InvalidFitHeader,
        error.InvalidFitSize,
        error.InvalidFitArchitecture,
        error.FitDefinitionMissing,
        => "the file is not a supported FIT file",
        error.TruncatedFitFile => "the FIT file is truncated",
        error.InvalidFitHeaderChecksum,
        error.InvalidFitChecksum,
        => "the FIT file checksum is invalid",
        error.FitFileTooLarge => "the FIT file is too large",
        error.NotActivityFitFile => "the FIT file is not an activity",
        error.SessionMissing => "the FIT activity does not contain a session summary",
        error.MultipleSessionsUnsupported => "multisport FIT activities are not supported",
        error.NotCyclingActivity => "the FIT activity is not cycling",
        error.StartTimeMissing,
        error.InvalidStartTime,
        => "the FIT session has no valid start time",
        error.TimerTimeMissing,
        error.InvalidTimerTime,
        => "the FIT session has no valid timer duration",
        error.InvalidLocalTimestamp => "the FIT activity has an invalid local timestamp",
        error.FitValueOutOfRange => "the FIT activity contains a value outside the supported range",
        else => @errorName(err),
    };
}
