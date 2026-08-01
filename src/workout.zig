const std = @import("std");
const model = @import("model.zig");

const Io = std.Io;

pub const DurationEstimate = struct {
    minimum_seconds: u32 = 0,
    maximum_seconds: u32 = 0,
    complete: bool = true,
};

pub fn durationEstimate(segments: []const model.Segment) DurationEstimate {
    var result: DurationEstimate = .{};
    for (segments) |segment| {
        const estimate = segmentDurationEstimate(segment);
        result.minimum_seconds += estimate.minimum_seconds;
        result.maximum_seconds += estimate.maximum_seconds;
        result.complete = result.complete and estimate.complete;
    }
    return result;
}

pub fn segmentDurationEstimate(segment: model.Segment) DurationEstimate {
    const repetitions: u32 = segment.repetitions;
    var result: DurationEstimate = .{};

    if (segment.distance_km) |distance_km| {
        const fast = segment.pace_fast_seconds_per_km orelse {
            result.complete = false;
            return result;
        };
        const slow = segment.pace_slow_seconds_per_km orelse {
            result.complete = false;
            return result;
        };
        result.minimum_seconds = secondsForDistance(distance_km, fast) * repetitions;
        result.maximum_seconds = secondsForDistance(distance_km, slow) * repetitions;
    } else if (segment.duration_seconds) |seconds| {
        result.minimum_seconds = seconds * repetitions;
        result.maximum_seconds = seconds * repetitions;
    } else if (!std.mem.eql(u8, segment.kind, "rest")) {
        result.complete = false;
    }

    if (segment.recovery_seconds) |recovery| {
        if (repetitions > 1) {
            const recovery_total = @as(u32, recovery) * (repetitions - 1);
            result.minimum_seconds += recovery_total;
            result.maximum_seconds += recovery_total;
        }
    }
    return result;
}

pub fn printDetails(writer: *Io.Writer, value: model.Workout, indent: []const u8) !void {
    try printRunningDetails(writer, value, indent);
    try printBicycleReplacement(writer, value, indent);
}

pub fn printRunningDetails(writer: *Io.Writer, value: model.Workout, indent: []const u8) !void {
    for (value.segments) |segment| {
        try writer.print("{s}- {s}: ", .{ indent, segment.label });
        try printSegmentPrescription(writer, segment);
        try writer.writeByte('\n');
    }

    const estimate = durationEstimate(value.segments);
    const duration_is_already_shown = value.segments.len == 1 and
        value.segments[0].repetitions == 1;
    if (!duration_is_already_shown and
        value.segments.len > 0 and
        estimate.complete and
        estimate.maximum_seconds > 0)
    {
        if (value.distance_min_km != null and value.distance_min_km.? == 0 and
            value.distance_max_km != null and value.distance_max_km.? > 0)
        {
            try writer.print("{s}If run, expected total time: ", .{indent});
        } else {
            try writer.print("{s}Expected total time: ", .{indent});
        }
        try printDurationRange(writer, estimate.minimum_seconds, estimate.maximum_seconds);
        try writer.writeByte('\n');
    }
}

pub fn printBicycleReplacement(
    writer: *Io.Writer,
    value: model.Workout,
    indent: []const u8,
) !void {
    if (std.mem.eql(u8, value.kind, "rest")) return;
    if (std.mem.eql(u8, value.kind, "race")) {
        try writer.print(
            "{s}Bicycle replacement: none is scientifically equivalent to the half-marathon race; " ++
                "cycling can preserve aerobic work but not race-specific readiness.\n",
            .{indent},
        );
        return;
    }

    try writer.print(
        "{s}Bicycle replacement (conservative time-and-effort match; not a proven 1:1 equivalence):\n",
        .{indent},
    );
    try printBicycleDetails(writer, value, indent);
}

pub fn printBicycleDetails(
    writer: *Io.Writer,
    value: model.Workout,
    indent: []const u8,
) !void {
    if (std.mem.eql(u8, value.kind, "rest")) return;
    if (std.mem.eql(u8, value.kind, "race")) {
        try writer.print(
            "{s}- No bicycle workout is equivalent to the half-marathon race.\n",
            .{indent},
        );
        return;
    }

    var total_ride_seconds: u32 = 0;
    var total_is_complete = true;
    for (value.segments, 0..) |segment, index| {
        try writer.print("{s}  - {s}: ", .{ indent, bicycleLabel(segment.label) });
        if (segment.repetitions > 1) {
            try writer.print("{d} × ", .{segment.repetitions});
        }
        if (practicalBicycleDuration(segment)) |seconds| {
            try printDuration(writer, seconds);
            total_ride_seconds += seconds * @as(u32, segment.repetitions);
        } else {
            try writer.writeAll("same planned segment duration");
            total_is_complete = false;
        }
        try writer.print(" at {s}", .{bicycleEffort(value, index)});
        if (segment.recovery_seconds) |seconds| {
            if (segment.repetitions > 1) {
                try writer.writeAll("; ");
                try printDuration(writer, seconds);
                try writer.writeAll(" very easy pedalling between repetitions");
                total_ride_seconds += @as(u32, seconds) *
                    (@as(u32, segment.repetitions) - 1);
            }
        }
        try writer.writeByte('\n');
    }

    if (total_is_complete and total_ride_seconds > 0) {
        try writer.print("{s}  Total ride time: ", .{indent});
        try printDuration(writer, total_ride_seconds);
        try writer.writeAll(". Use cycling-specific effort cues; do not credit bicycle kilometres as running distance.\n");
    } else {
        try writer.print(
            "{s}  Use cycling-specific effort cues; duration cannot be derived without an anchored running pace. " ++
                "Do not credit bicycle kilometres as running distance.\n",
            .{indent},
        );
    }
}

fn practicalBicycleDuration(segment: model.Segment) ?u32 {
    const one_repetition: model.Segment = .{
        .kind = segment.kind,
        .label = segment.label,
        .distance_km = segment.distance_km,
        .duration_seconds = segment.duration_seconds,
        .pace_fast_seconds_per_km = segment.pace_fast_seconds_per_km,
        .pace_slow_seconds_per_km = segment.pace_slow_seconds_per_km,
    };
    const estimate = segmentDurationEstimate(one_repetition);
    if (!estimate.complete or estimate.maximum_seconds == 0) return null;
    if (estimate.minimum_seconds == estimate.maximum_seconds) {
        return estimate.minimum_seconds;
    }

    const midpoint_seconds = estimate.minimum_seconds +
        (estimate.maximum_seconds - estimate.minimum_seconds) / 2;
    const rounding_seconds: u32 = if (segment.repetitions > 1)
        15
    else if (midpoint_seconds < 15 * 60)
        30
    else if (midpoint_seconds < 60 * 60)
        60
    else
        5 * 60;
    return ((midpoint_seconds + rounding_seconds / 2) / rounding_seconds) *
        rounding_seconds;
}

fn bicycleLabel(label: []const u8) []const u8 {
    if (std.mem.eql(u8, label, "Run")) return "Ride";
    return label;
}

fn bicycleEffort(value: model.Workout, segment_index: usize) []const u8 {
    if (isOptionalRecovery(value)) return "very easy RPE 2–3";
    if (isQualityWorkout(value)) {
        const is_support_segment = value.segments.len >= 3 and
            (segment_index == 0 or segment_index + 1 == value.segments.len);
        if (is_support_segment) return "easy conversational RPE 2–4";
        if (isRaceSpecificPhase(value.phase)) return "controlled tempo RPE 5–7";
        return "controlled hard RPE 6–8";
    }
    if (isDemandingLongSegment(value, segment_index)) {
        return "controlled steady RPE 4–6";
    }
    return "easy conversational RPE 2–4";
}

fn isOptionalRecovery(value: model.Workout) bool {
    if (value.decision) |decision| {
        if (decision.allocation_role == .optional_recovery) return true;
    }
    return std.mem.eql(u8, value.kind, "optional-recovery") or
        std.mem.eql(u8, value.kind, "recovery-or-rest");
}

fn isQualityWorkout(value: model.Workout) bool {
    if (value.decision) |decision| {
        if (decision.allocation_role == .quality) return true;
    }
    const quality_kinds = [_][]const u8{
        "quality",
        "hills",
        "strides",
        "intervals",
        "steady",
        "tempo",
        "half-marathon-pace",
    };
    for (quality_kinds) |kind| {
        if (std.mem.eql(u8, value.kind, kind)) return true;
    }
    return false;
}

fn isRaceSpecificPhase(phase: []const u8) bool {
    return std.mem.eql(u8, phase, "race_specific") or
        std.mem.eql(u8, phase, "race-specific") or
        std.mem.eql(u8, phase, "taper") or
        std.mem.eql(u8, phase, "race");
}

fn isDemandingLongSegment(value: model.Workout, segment_index: usize) bool {
    if (segment_index == 0) return false;
    return std.mem.eql(u8, value.kind, "long-progression") or
        std.mem.eql(u8, value.kind, "long-race-specific");
}

pub fn printSegmentPrescription(writer: *Io.Writer, segment: model.Segment) !void {
    if (segment.repetitions > 1) try writer.print("{d} × ", .{segment.repetitions});

    if (segment.distance_km) |distance_km| {
        try printDistance(writer, distance_km);
    } else if (segment.duration_seconds) |seconds| {
        try printDuration(writer, seconds);
    } else if (std.mem.eql(u8, segment.kind, "rest")) {
        try writer.writeAll("no running");
    } else {
        try writer.writeAll("effort-based");
    }

    if (segment.pace_fast_seconds_per_km != null and
        segment.pace_slow_seconds_per_km != null)
    {
        try writer.writeAll(" at ");
        try printPaceRange(
            writer,
            segment.pace_fast_seconds_per_km.?,
            segment.pace_slow_seconds_per_km.?,
        );

        const one_repetition = segment;
        const fast_seconds = secondsForDistance(
            one_repetition.distance_km.?,
            one_repetition.pace_fast_seconds_per_km.?,
        );
        const slow_seconds = secondsForDistance(
            one_repetition.distance_km.?,
            one_repetition.pace_slow_seconds_per_km.?,
        );
        try writer.writeAll(" (");
        try printDurationRange(writer, fast_seconds, slow_seconds);
        if (segment.repetitions > 1) try writer.writeAll(" each");
        try writer.writeByte(')');
    }

    if (segment.recovery_seconds) |seconds| {
        if (segment.repetitions > 1) {
            try writer.writeAll("; ");
            try printDuration(writer, seconds);
            try writer.writeAll(" easy recovery between repetitions");
        }
    }
    if (segment.notes.len != 0) try writer.print(". {s}", .{segment.notes});
}

pub fn printPaceRange(writer: *Io.Writer, fast: u32, slow: u32) !void {
    try printPace(writer, fast);
    if (fast != slow) {
        try writer.writeAll("–");
        try printPace(writer, slow);
    }
    try writer.writeAll("/km, ");
    try printSpeed(writer, slow);
    if (fast != slow) {
        try writer.writeAll("–");
        try printSpeed(writer, fast);
    }
    try writer.writeAll(" km/h");
}

pub fn printDurationRange(writer: *Io.Writer, minimum: u32, maximum: u32) !void {
    try printDuration(writer, minimum);
    if (minimum != maximum) {
        try writer.writeAll("–");
        try printDuration(writer, maximum);
    }
}

pub fn printDuration(writer: *Io.Writer, seconds: u32) !void {
    const hours = seconds / 3600;
    const minutes = (seconds % 3600) / 60;
    const remaining_seconds = seconds % 60;
    if (hours > 0) {
        try writer.print("{d}:{d:0>2}:{d:0>2}", .{ hours, minutes, remaining_seconds });
    } else {
        try writer.print("{d}:{d:0>2}", .{ minutes, remaining_seconds });
    }
}

fn printPace(writer: *Io.Writer, seconds_per_km: u32) !void {
    try writer.print(
        "{d}:{d:0>2}",
        .{ seconds_per_km / 60, seconds_per_km % 60 },
    );
}

fn printSpeed(writer: *Io.Writer, seconds_per_km: u32) !void {
    const kilometers_per_hour = 3600.0 /
        @as(f64, @floatFromInt(seconds_per_km));
    try writer.print("{d:.1}", .{kilometers_per_hour});
}

fn printDistance(writer: *Io.Writer, distance_km: f64) !void {
    if (distance_km < 1) {
        try writer.print("{d:.0} m", .{distance_km * 1000});
    } else {
        try writer.print("{d:.1} km", .{distance_km});
    }
}

fn secondsForDistance(distance_km: f64, seconds_per_km: u16) u32 {
    return @intFromFloat(@round(distance_km * @as(f64, @floatFromInt(seconds_per_km))));
}

test "distance duration is derived from its pace range" {
    const segments = [_]model.Segment{.{
        .kind = "distance",
        .label = "Run",
        .distance_km = 8,
        .pace_fast_seconds_per_km = 375,
        .pace_slow_seconds_per_km = 420,
    }};
    const estimate = durationEstimate(&segments);
    try std.testing.expect(estimate.complete);
    try std.testing.expectEqual(@as(u32, 3000), estimate.minimum_seconds);
    try std.testing.expectEqual(@as(u32, 3360), estimate.maximum_seconds);
}

test "repeat duration includes recovery only between repetitions" {
    const segment: model.Segment = .{
        .kind = "repeat",
        .label = "Intervals",
        .repetitions = 5,
        .distance_km = 0.8,
        .pace_fast_seconds_per_km = 300,
        .pace_slow_seconds_per_km = 315,
        .recovery_seconds = 120,
    };
    const estimate = segmentDurationEstimate(segment);
    try std.testing.expectEqual(@as(u32, 1680), estimate.minimum_seconds);
    try std.testing.expectEqual(@as(u32, 1740), estimate.maximum_seconds);
}

test "pace range includes speed range in ascending order" {
    var output_buffer: [128]u8 = undefined;
    var writer: Io.Writer = .fixed(&output_buffer);

    try printPaceRange(&writer, 371, 416);

    try std.testing.expectEqualStrings(
        "6:11–6:56/km, 8.7–9.7 km/h",
        writer.buffered(),
    );
}

test "single segment details do not repeat the expected duration" {
    const segments = [_]model.Segment{.{
        .kind = "distance",
        .label = "Run",
        .distance_km = 6.5,
        .pace_fast_seconds_per_km = 371,
        .pace_slow_seconds_per_km = 416,
    }};
    const value: model.Workout = .{
        .id = 1,
        .schedule_id = 1,
        .date = "2026-07-27",
        .week = 1,
        .day = "Monday",
        .phase = "foundation",
        .kind = "easy",
        .intensity = "Easy",
        .distance_min_km = 6.5,
        .distance_max_km = 6.5,
        .details = "Easy run.",
        .segments = &segments,
        .recorded_at = 0,
    };
    var output_buffer: [768]u8 = undefined;
    var writer: Io.Writer = .fixed(&output_buffer);

    try printDetails(&writer, value, "");

    try std.testing.expectEqualStrings(
        "- Run: 6.5 km at 6:11–6:56/km, 8.7–9.7 km/h (40:12–45:04)\n" ++
            "Bicycle replacement (conservative time-and-effort match; not a proven 1:1 equivalence):\n" ++
            "  - Ride: 43:00 at easy conversational RPE 2–4\n" ++
            "  Total ride time: 43:00. Use cycling-specific effort cues; do not credit bicycle kilometres as running distance.\n",
        writer.buffered(),
    );
}

test "quality bicycle replacement rounds work and preserves recovery duration" {
    const segments = [_]model.Segment{
        .{
            .kind = "distance",
            .label = "Warm-up",
            .distance_km = 1.5,
            .pace_fast_seconds_per_km = 371,
            .pace_slow_seconds_per_km = 416,
        },
        .{
            .kind = "repeat",
            .label = "Aerobic intervals",
            .repetitions = 4,
            .distance_km = 1,
            .pace_fast_seconds_per_km = 301,
            .pace_slow_seconds_per_km = 326,
            .recovery_seconds = 120,
        },
        .{
            .kind = "distance",
            .label = "Cooldown",
            .distance_km = 1,
            .pace_fast_seconds_per_km = 371,
            .pace_slow_seconds_per_km = 416,
        },
    };
    const value: model.Workout = .{
        .id = 1,
        .schedule_id = 1,
        .date = "2026-07-28",
        .week = 2,
        .day = "Tuesday",
        .phase = "foundation",
        .kind = "quality",
        .intensity = "High",
        .distance_min_km = 6.5,
        .distance_max_km = 6.5,
        .details = "Aerobic intervals.",
        .segments = &segments,
        .recorded_at = 0,
    };
    var output_buffer: [1024]u8 = undefined;
    var writer: Io.Writer = .fixed(&output_buffer);

    try printBicycleReplacement(&writer, value, "");

    try std.testing.expect(std.mem.indexOf(
        u8,
        writer.buffered(),
        "4 × 5:15 at controlled hard RPE 6–8; 2:00 very easy pedalling",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        writer.buffered(),
        "Total ride time: 43:30",
    ) != null);
}

test "race bicycle replacement states the specificity boundary" {
    const segments = [_]model.Segment{.{
        .kind = "distance",
        .label = "Half marathon",
        .distance_km = 21.0975,
        .pace_fast_seconds_per_km = 336,
        .pace_slow_seconds_per_km = 346,
    }};
    const value: model.Workout = .{
        .id = 1,
        .schedule_id = 1,
        .date = "2026-10-18",
        .week = 13,
        .day = "Sunday",
        .phase = "race",
        .kind = "race",
        .intensity = "Race effort",
        .distance_min_km = 21.0975,
        .distance_max_km = 21.0975,
        .details = "Half marathon.",
        .segments = &segments,
        .recorded_at = 0,
    };
    var output_buffer: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&output_buffer);

    try printBicycleReplacement(&writer, value, "");

    try std.testing.expect(std.mem.indexOf(
        u8,
        writer.buffered(),
        "none is scientifically equivalent",
    ) != null);
}
