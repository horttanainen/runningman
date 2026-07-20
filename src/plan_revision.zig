const std = @import("std");
const date = @import("date.zig");
const model = @import("model.zig");
const store = @import("store.zig");
const workout = @import("workout.zig");

const Io = std.Io;

pub const RevisionFile = struct {
    schema_version: u8 = 1,
    base_schedule_id: u64,
    effective_from: []const u8,
    reason: []const u8,
    name: []const u8 = "",
    goal: []const u8 = "",
    availability: []const u8 = "",
    intensity_guidance: []const u8 = "",
    pace_profile: []const u8 = "",
    race_date: []const u8 = "",
    assessment: ?ProposedAssessment = null,
    weeks: ?[]const ProposedWeek = null,
    workouts: []const ProposedWorkout,
};

pub const ProposedAssessment = struct {
    profile_id: []const u8,
    policy_id: []const u8,
    policy_version: u16,
    confidence: []const u8,
    feasibility: []const u8,
    recommended_target_seconds: ?u32 = null,
    requested_target_seconds: ?u32 = null,
    training_pace_anchor_seconds: ?u32 = null,
    expected_shortfall_seconds: ?u32 = null,
};

pub const ProposedWeek = struct {
    week: u8,
    start_date: []const u8,
    end_date: []const u8,
    phase: []const u8,
    target_core_distance_km: f64,
    long_run_distance_km: f64,
};

pub const ProposedWorkout = struct {
    date: []const u8,
    phase: []const u8,
    kind: []const u8,
    intensity: []const u8,
    details: []const u8,
    distance_min_km: ?f64 = null,
    distance_max_km: ?f64 = null,
    segments: []const model.Segment,
};

const DistanceRange = struct {
    minimum_km: ?f64,
    maximum_km: ?f64,
};

pub fn load(
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
) !RevisionFile {
    const contents = Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(16 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.RevisionFileNotFound,
        else => return err,
    };
    return std.json.parseFromSliceLeaky(
        RevisionFile,
        allocator,
        contents,
        .{ .ignore_unknown_fields = false },
    ) catch error.InvalidRevisionFile;
}

pub fn validate(storage: *const store.Store, revision: RevisionFile) !void {
    if (revision.schema_version != 1) return error.UnsupportedRevisionSchema;
    if (revision.base_schedule_id != storage.max_schedule_id) return error.StaleRevision;
    if (revision.reason.len == 0) return error.RevisionReasonRequired;
    if (revision.workouts.len == 0) return error.EmptyRevision;

    const parent = storage.schedules.get(revision.base_schedule_id) orelse
        return error.StaleRevision;
    const parent_start = try date.parse(parent.start_date);
    const effective_from = try date.parse(revision.effective_from);
    if (date.compare(effective_from, parent_start) == .lt) {
        return error.RevisionBeforePlanStart;
    }

    var expected_date = effective_from;
    for (revision.workouts) |proposed| {
        const proposed_date = try date.parse(proposed.date);
        if (date.compare(proposed_date, expected_date) != .eq) {
            return error.RevisionDatesNotConsecutive;
        }
        try validateWorkout(proposed);
        expected_date = date.addDays(expected_date, 1);
    }

    const race_date_text = if (revision.race_date.len == 0)
        parent.race_date
    else
        revision.race_date;
    if (race_date_text.len == 0) return error.RevisionRaceDateRequired;
    const race_date = try date.parse(race_date_text);
    const final_date = try date.parse(revision.workouts[revision.workouts.len - 1].date);
    if (date.compare(final_date, race_date) != .eq) {
        return error.RevisionMustEndOnRaceDate;
    }
}

pub fn createEvents(
    allocator: std.mem.Allocator,
    storage: *const store.Store,
    revision: RevisionFile,
    recorded_at: i64,
) ![]model.Event {
    try validate(storage, revision);
    const parent = storage.schedules.get(revision.base_schedule_id) orelse
        return error.StaleRevision;
    const schedule_id = storage.max_schedule_id + 1;
    var next_workout_id = storage.max_workout_id + 1;

    var events: std.ArrayList(model.Event) = .empty;
    errdefer events.deinit(allocator);

    const schedule_value: model.Schedule = .{
        .id = schedule_id,
        .parent_schedule_id = parent.id,
        .effective_from = revision.effective_from,
        .start_date = parent.start_date,
        .name = valueOrFallback(revision.name, "Reviewed half-marathon program"),
        .reason = revision.reason,
        .goal = valueOrFallback(revision.goal, parent.goal),
        .baseline = parent.baseline,
        .availability = valueOrFallback(revision.availability, parent.availability),
        .intensity_guidance = valueOrFallback(
            revision.intensity_guidance,
            parent.intensity_guidance,
        ),
        .pace_profile = valueOrFallback(revision.pace_profile, parent.pace_profile),
        .race_date = valueOrFallback(revision.race_date, parent.race_date),
        .source = "Complete remaining-program revision imported from a reviewed JSON file.",
        .recorded_at = recorded_at,
    };
    try events.append(allocator, model.scheduleEvent(schedule_value));

    const start = try date.parse(parent.start_date);
    const effective_from = try date.parse(revision.effective_from);
    var current = start;
    while (date.compare(current, effective_from) == .lt) : (current = date.addDays(current, 1)) {
        const original = store.workoutForDate(storage, parent.id, current) orelse
            return error.IncompleteParentSchedule;
        var copied = original;
        copied.id = next_workout_id;
        copied.schedule_id = schedule_id;
        copied.recorded_at = recorded_at;
        try events.append(allocator, model.workoutEvent(copied));
        next_workout_id += 1;
    }

    for (revision.workouts) |proposed| {
        const workout_date = try date.parse(proposed.date);
        const days_from_start = date.daysBetween(start, workout_date);
        if (days_from_start < 0) return error.RevisionBeforePlanStart;
        const range = proposedDistanceRange(proposed);
        const value: model.Workout = .{
            .id = next_workout_id,
            .schedule_id = schedule_id,
            .date = proposed.date,
            .week = @intCast(@divFloor(days_from_start, 7) + 1),
            .day = date.weekdayName(workout_date),
            .phase = proposed.phase,
            .kind = proposed.kind,
            .intensity = proposed.intensity,
            .distance_min_km = range.minimum_km,
            .distance_max_km = range.maximum_km,
            .details = proposed.details,
            .segments = proposed.segments,
            .recorded_at = recorded_at,
        };
        try events.append(allocator, model.workoutEvent(value));
        next_workout_id += 1;
    }
    return events.toOwnedSlice(allocator);
}

pub fn printPreview(
    writer: *Io.Writer,
    storage: *const store.Store,
    revision: RevisionFile,
) !void {
    try validate(storage, revision);
    try writer.print(
        "Revision preview: schedule #{d} → #{d}\nEffective: {s}\nReason: {s}\n",
        .{
            revision.base_schedule_id,
            storage.max_schedule_id + 1,
            revision.effective_from,
            revision.reason,
        },
    );
    try writer.print(
        "Replacement span: {s} through {s} ({d} daily entries)\n\n",
        .{
            revision.workouts[0].date,
            revision.workouts[revision.workouts.len - 1].date,
            revision.workouts.len,
        },
    );

    if (revision.assessment) |result| {
        try writer.print(
            "Assessment: {s}; {s} v{d}; {s} confidence; {s}\n",
            .{
                result.profile_id,
                result.policy_id,
                result.policy_version,
                result.confidence,
                result.feasibility,
            },
        );
        if (result.training_pace_anchor_seconds) |target| {
            try writer.writeAll("Training pace anchor: ");
            try printDuration(writer, target);
            try writer.writeByte('\n');
        } else {
            try writer.writeAll("Training pace anchor: none; effort guidance is used\n");
        }
        try writer.writeByte('\n');
    }
    if (revision.weeks) |weeks| {
        try writer.writeAll("Macrocycle\n");
        for (weeks) |week| {
            try writer.print(
                "  Week {d} ({s}–{s}): {s}, {d:.1} km core",
                .{
                    week.week,
                    week.start_date,
                    week.end_date,
                    week.phase,
                    week.target_core_distance_km,
                },
            );
            if (week.long_run_distance_km > 0) {
                try writer.print(", {d:.1} km long run", .{week.long_run_distance_km});
            }
            try writer.writeByte('\n');
        }
        try writer.writeByte('\n');
    }

    var previous_week: ?u8 = null;
    const parent = storage.schedules.get(revision.base_schedule_id).?;
    const start = try date.parse(parent.start_date);
    for (revision.workouts) |proposed| {
        const proposed_date = try date.parse(proposed.date);
        const week: u8 = @intCast(@divFloor(date.daysBetween(start, proposed_date), 7) + 1);
        if (previous_week == null or previous_week.? != week) {
            try writer.print("Week {d} — {s}\n", .{ week, proposed.phase });
            previous_week = week;
        }
        const current = store.workoutForDate(storage, parent.id, proposed_date);
        const change_marker = if (current) |planned|
            if (samePrescription(planned, proposed)) "unchanged" else "changed"
        else
            "new";
        try writer.print(
            "  {s} {s}: {s} [{s}]\n    {s}\n",
            .{
                proposed.date,
                date.weekdayName(proposed_date),
                proposed.kind,
                change_marker,
                proposed.details,
            },
        );
        const preview_workout: model.Workout = .{
            .id = 0,
            .schedule_id = 0,
            .date = proposed.date,
            .week = week,
            .day = date.weekdayName(proposed_date),
            .phase = proposed.phase,
            .kind = proposed.kind,
            .intensity = proposed.intensity,
            .distance_min_km = proposed.distance_min_km,
            .distance_max_km = proposed.distance_max_km,
            .details = proposed.details,
            .segments = proposed.segments,
            .recorded_at = 0,
        };
        try workout.printDetails(writer, preview_workout, "    ");
    }
    try writer.writeAll("\nNo data was changed. Use `runningman plan apply FILE` after reviewing this preview.\n");
}

fn validateWorkout(proposed: ProposedWorkout) !void {
    if (proposed.phase.len == 0 or proposed.kind.len == 0 or
        proposed.intensity.len == 0 or proposed.details.len == 0)
    {
        return error.IncompleteProposedWorkout;
    }
    if (proposed.distance_min_km) |minimum| {
        if (minimum < 0 or !std.math.isFinite(minimum)) return error.InvalidDistanceRange;
    }
    if (proposed.distance_max_km) |maximum| {
        if (maximum < 0 or !std.math.isFinite(maximum)) return error.InvalidDistanceRange;
    }
    if (proposed.distance_min_km != null and proposed.distance_max_km != null and
        proposed.distance_min_km.? > proposed.distance_max_km.?)
    {
        return error.InvalidDistanceRange;
    }
    if (proposed.segments.len == 0) return error.ProposedWorkoutNeedsSegments;

    for (proposed.segments) |segment| {
        if (segment.kind.len == 0 or segment.label.len == 0 or segment.repetitions == 0) {
            return error.InvalidSegment;
        }
        if (segment.distance_km) |distance_km| {
            if (distance_km <= 0 or !std.math.isFinite(distance_km)) {
                return error.InvalidSegment;
            }
        }
        if (segment.duration_seconds != null and segment.duration_seconds.? == 0) {
            return error.InvalidSegment;
        }
        if (segment.distance_km != null and segment.duration_seconds != null) {
            return error.InvalidSegment;
        }
        if ((segment.pace_fast_seconds_per_km == null) !=
            (segment.pace_slow_seconds_per_km == null))
        {
            return error.InvalidPaceRange;
        }
        if (segment.pace_fast_seconds_per_km != null and
            segment.pace_fast_seconds_per_km.? > segment.pace_slow_seconds_per_km.?)
        {
            return error.InvalidPaceRange;
        }
        if (std.mem.eql(u8, segment.kind, "distance") and
            (segment.distance_km == null or segment.pace_fast_seconds_per_km == null))
        {
            return error.InvalidSegment;
        }
        if (!std.mem.eql(u8, segment.kind, "rest") and
            segment.distance_km == null and segment.duration_seconds == null)
        {
            return error.InvalidSegment;
        }
    }
}

fn proposedDistanceRange(proposed: ProposedWorkout) DistanceRange {
    if (proposed.distance_min_km != null or proposed.distance_max_km != null) {
        return .{
            .minimum_km = proposed.distance_min_km,
            .maximum_km = proposed.distance_max_km,
        };
    }

    var total_km: f64 = 0;
    for (proposed.segments) |segment| {
        if (segment.distance_km) |distance_km| {
            total_km += distance_km * @as(f64, @floatFromInt(segment.repetitions));
        } else if (!std.mem.eql(u8, segment.kind, "rest")) {
            return .{ .minimum_km = null, .maximum_km = null };
        }
    }
    return .{ .minimum_km = total_km, .maximum_km = total_km };
}

fn samePrescription(current: model.Workout, proposed: ProposedWorkout) bool {
    const range = proposedDistanceRange(proposed);
    if (!std.mem.eql(u8, current.phase, proposed.phase) or
        !std.mem.eql(u8, current.kind, proposed.kind) or
        !std.mem.eql(u8, current.intensity, proposed.intensity) or
        !std.mem.eql(u8, current.details, proposed.details) or
        current.distance_min_km != range.minimum_km or
        current.distance_max_km != range.maximum_km or
        current.segments.len != proposed.segments.len)
    {
        return false;
    }
    for (current.segments, proposed.segments) |left, right| {
        if (!sameSegment(left, right)) return false;
    }
    return true;
}

fn sameSegment(left: model.Segment, right: model.Segment) bool {
    return std.mem.eql(u8, left.kind, right.kind) and
        std.mem.eql(u8, left.label, right.label) and
        left.repetitions == right.repetitions and
        left.distance_km == right.distance_km and
        left.duration_seconds == right.duration_seconds and
        left.pace_fast_seconds_per_km == right.pace_fast_seconds_per_km and
        left.pace_slow_seconds_per_km == right.pace_slow_seconds_per_km and
        left.recovery_seconds == right.recovery_seconds and
        std.mem.eql(u8, left.notes, right.notes);
}

fn valueOrFallback(value: []const u8, fallback: []const u8) []const u8 {
    return if (value.len == 0) fallback else value;
}

fn printDuration(writer: *Io.Writer, total_seconds: u32) !void {
    const hours = total_seconds / 3600;
    const minutes = total_seconds % 3600 / 60;
    const seconds = total_seconds % 60;
    try writer.print("{d}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds });
}
