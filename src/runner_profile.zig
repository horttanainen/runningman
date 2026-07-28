const std = @import("std");
const date = @import("date.zig");

const Io = std.Io;

pub const Source = enum {
    measured,
    user_entered,
    derived,
    defaulted,
};

pub fn Sourced(comptime T: type) type {
    return struct {
        value: T,
        source: Source,
    };
}

pub const RaceDistance = enum {
    half_marathon,
};

pub const GoalIntent = enum {
    finish_comfortably,
    performance,
};

pub const Weekday = enum {
    monday,
    tuesday,
    wednesday,
    thursday,
    friday,
    saturday,
    sunday,
};

pub const PerformanceDistance = enum {
    five_km,
    ten_km,
    half_marathon,
};

pub const PerformanceKind = enum {
    race,
    time_trial,
    training,
};

pub const Effort = enum {
    easy,
    moderate,
    hard,
    maximal,
    unknown,
};

pub const RecentPerformance = struct {
    date: []const u8,
    distance: PerformanceDistance,
    duration_seconds: u32,
    kind: PerformanceKind,
    effort: Effort,
};

pub const Goal = struct {
    race_date: Sourced([]const u8),
    race_distance: Sourced(RaceDistance),
    intent: Sourced(GoalIntent),
    target_time_seconds: ?Sourced(u32) = null,
};

pub const Availability = struct {
    running_days: Sourced([]const Weekday),
    preferred_long_run_day: Sourced(Weekday),
    preferred_quality_day: ?Sourced(Weekday) = null,
    optional_recovery_day: ?Sourced(Weekday) = null,
};

pub const Baseline = struct {
    average_weekly_distance_km: Sourced(f64),
    longest_run_km: Sourced(f64),
    recent_performances: Sourced([]const RecentPerformance),
    weekly_distance_history_km: ?Sourced([]const f64) = null,
};

pub const Constraints = struct {
    recent_training_interruption_days: Sourced(u16),
    unavailable_dates: ?Sourced([]const []const u8) = null,
    notes: ?Sourced([]const u8) = null,
};

pub const RunnerProfile = struct {
    schema_version: u8,
    profile_id: []const u8,
    plan_start_date: Sourced([]const u8),
    goal: Goal,
    availability: Availability,
    baseline: Baseline,
    constraints: Constraints,
};

pub const Summary = struct {
    plan_days: u16,
    core_running_days: u8,
    recent_performances: usize,
};

pub fn load(
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
) !RunnerProfile {
    const contents = Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.RunnerProfileFileNotFound,
        else => return err,
    };
    return std.json.parseFromSliceLeaky(
        RunnerProfile,
        allocator,
        contents,
        .{ .ignore_unknown_fields = false },
    ) catch error.InvalidRunnerProfileFile;
}

pub fn validate(profile: RunnerProfile) !Summary {
    if (profile.schema_version != 2) return error.UnsupportedRunnerProfileSchema;
    if (profile.profile_id.len == 0) return error.RunnerProfileIdRequired;

    const plan_start = date.parse(profile.plan_start_date.value) catch
        return error.InvalidPlanStartDate;
    const race_date = date.parse(profile.goal.race_date.value) catch
        return error.InvalidRaceDate;
    const plan_days_signed = date.daysBetween(plan_start, race_date) + 1;
    if (plan_days_signed < 56 or plan_days_signed > 168) {
        return error.UnsupportedPlanLength;
    }

    if (profile.goal.target_time_seconds) |target| {
        if (target.value == 0) return error.InvalidTargetTime;
    }

    const running_days = profile.availability.running_days.value;
    if (running_days.len < 3 or running_days.len > 6) {
        return error.InvalidRunningDayCount;
    }
    if (hasDuplicateWeekdays(running_days)) return error.DuplicateRunningDay;
    if (!containsWeekday(
        running_days,
        profile.availability.preferred_long_run_day.value,
    )) {
        return error.LongRunDayUnavailable;
    }
    if (profile.availability.preferred_quality_day) |quality_day| {
        if (!containsWeekday(running_days, quality_day.value)) {
            return error.QualityDayUnavailable;
        }
        if (quality_day.value == profile.availability.preferred_long_run_day.value) {
            return error.QualityDayMatchesLongRunDay;
        }
    }
    if (profile.availability.optional_recovery_day) |recovery_day| {
        if (containsWeekday(running_days, recovery_day.value)) {
            return error.OptionalDayIsCoreDay;
        }
    }

    try validateDistance(
        profile.baseline.average_weekly_distance_km.value,
        error.InvalidAverageWeeklyDistance,
    );
    try validateDistance(
        profile.baseline.longest_run_km.value,
        error.InvalidLongestRun,
    );
    if (profile.baseline.weekly_distance_history_km) |history| {
        if (history.value.len == 0) return error.EmptyWeeklyDistanceHistory;
        for (history.value) |distance_km| {
            try validateDistance(distance_km, error.InvalidWeeklyDistanceHistory);
        }
    }
    for (profile.baseline.recent_performances.value) |performance| {
        const performance_date = date.parse(performance.date) catch
            return error.InvalidPerformanceDate;
        if (date.compare(performance_date, plan_start) == .gt) {
            return error.PerformanceAfterPlanStart;
        }
        if (performance.duration_seconds == 0) return error.InvalidPerformanceTime;
    }

    if (profile.constraints.unavailable_dates) |unavailable| {
        for (unavailable.value) |date_text| {
            const unavailable_date = date.parse(date_text) catch
                return error.InvalidUnavailableDate;
            if (date.compare(unavailable_date, plan_start) == .lt or
                date.compare(unavailable_date, race_date) == .gt)
            {
                return error.UnavailableDateOutsidePlan;
            }
        }
    }

    return .{
        .plan_days = @intCast(plan_days_signed),
        .core_running_days = @intCast(running_days.len),
        .recent_performances = profile.baseline.recent_performances.value.len,
    };
}

pub fn printSummary(
    writer: *Io.Writer,
    profile: RunnerProfile,
    summary: Summary,
) !void {
    try writer.print(
        "Runner profile is valid: {s}\n" ++
            "Goal: half marathon on {s}",
        .{ profile.profile_id, profile.goal.race_date.value },
    );
    if (profile.goal.target_time_seconds) |target| {
        try writer.writeAll(", requested target ");
        try printDuration(writer, target.value);
    } else {
        try writer.writeAll(", target time to be recommended");
    }
    try writer.print(
        "\nPlan span: {d} days\n" ++
            "Availability: {d} core running days per week\n" ++
            "Baseline: {d:.1} km/week, {d:.1} km longest run, {d} recent performance result{s}\n",
        .{
            summary.plan_days,
            summary.core_running_days,
            profile.baseline.average_weekly_distance_km.value,
            profile.baseline.longest_run_km.value,
            summary.recent_performances,
            if (summary.recent_performances == 1) "" else "s",
        },
    );
}

fn validateDistance(value: f64, err: anyerror) !void {
    if (value < 0 or !std.math.isFinite(value)) return err;
}

fn hasDuplicateWeekdays(values: []const Weekday) bool {
    var seen = [_]bool{false} ** 7;
    for (values) |value| {
        const index: usize = @intFromEnum(value);
        if (seen[index]) return true;
        seen[index] = true;
    }
    return false;
}

fn containsWeekday(values: []const Weekday, expected: Weekday) bool {
    for (values) |value| {
        if (value == expected) return true;
    }
    return false;
}

fn printDuration(writer: *Io.Writer, total_seconds: u32) !void {
    const hours = total_seconds / 3600;
    const minutes = total_seconds % 3600 / 60;
    const seconds = total_seconds % 60;
    if (hours > 0) {
        try writer.print("{d}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds });
    } else {
        try writer.print("{d}:{d:0>2}", .{ minutes, seconds });
    }
}

fn validProfile() RunnerProfile {
    return .{
        .schema_version = 2,
        .profile_id = "test-runner",
        .plan_start_date = .{ .value = "2026-07-20", .source = .user_entered },
        .goal = .{
            .race_date = .{ .value = "2026-10-18", .source = .user_entered },
            .race_distance = .{ .value = .half_marathon, .source = .user_entered },
            .intent = .{ .value = .performance, .source = .user_entered },
        },
        .availability = .{
            .running_days = .{
                .value = &.{ .monday, .tuesday, .thursday, .saturday },
                .source = .user_entered,
            },
            .preferred_long_run_day = .{
                .value = .saturday,
                .source = .user_entered,
            },
            .preferred_quality_day = .{
                .value = .tuesday,
                .source = .user_entered,
            },
            .optional_recovery_day = .{
                .value = .wednesday,
                .source = .user_entered,
            },
        },
        .baseline = .{
            .average_weekly_distance_km = .{ .value = 30, .source = .derived },
            .longest_run_km = .{ .value = 15, .source = .measured },
            .recent_performances = .{
                .value = &.{
                    .{
                        .date = "2026-06-15",
                        .distance = .ten_km,
                        .duration_seconds = 3180,
                        .kind = .time_trial,
                        .effort = .maximal,
                    },
                },
                .source = .measured,
            },
        },
        .constraints = .{
            .recent_training_interruption_days = .{
                .value = 0,
                .source = .user_entered,
            },
        },
    };
}

test "validates a supported runner profile" {
    const summary = try validate(validProfile());
    try std.testing.expectEqual(@as(u16, 91), summary.plan_days);
    try std.testing.expectEqual(@as(u8, 4), summary.core_running_days);
    try std.testing.expectEqual(@as(usize, 1), summary.recent_performances);
}

test "accepts an explicitly empty recent performance list" {
    var profile = validProfile();
    profile.baseline.recent_performances.value = &.{};
    const summary = try validate(profile);
    try std.testing.expectEqual(@as(usize, 0), summary.recent_performances);
}

test "rejects unsupported plan lengths and unavailable preferred days" {
    var short = validProfile();
    short.goal.race_date.value = "2026-08-02";
    try std.testing.expectError(error.UnsupportedPlanLength, validate(short));

    var missing_long_day = validProfile();
    missing_long_day.availability.preferred_long_run_day.value = .sunday;
    try std.testing.expectError(error.LongRunDayUnavailable, validate(missing_long_day));
}
