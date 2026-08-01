const std = @import("std");
const date = @import("date.zig");
const model = @import("model.zig");
const plan_revision = @import("plan_revision.zig");
const store = @import("store.zig");
const training_policy = @import("training_policy.zig");
const workout = @import("workout.zig");

const Io = std.Io;

pub fn saveProposal(io: Io, path: []const u8, revision: plan_revision.RevisionFile) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(file, io, &buffer);
    try printProposal(&file_writer.interface, revision);
    try file_writer.flush();
}

pub fn saveSchedule(
    io: Io,
    path: []const u8,
    storage: *const store.Store,
    schedule: model.Schedule,
) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(file, io, &buffer);
    try printSchedule(&file_writer.interface, storage, schedule);
    try file_writer.flush();
}

pub fn printProposal(writer: *Io.Writer, revision: plan_revision.RevisionFile) !void {
    if (revision.workouts.len == 0) return error.EmptyRevision;
    const plan_start = try date.parse(revision.workouts[0].date);
    const effective_from = try date.parse(revision.effective_from);

    try printHeader(
        writer,
        revision.race_date,
        revision.goal,
        revision.effective_from,
        revision.availability,
        revision.intensity_guidance,
        revision.pace_profile,
    );
    try printOverview(writer, revision.weeks, effective_from);

    var previous_week: ?u8 = null;
    for (revision.workouts) |proposed| {
        const workout_date = try date.parse(proposed.date);
        if (date.compare(workout_date, effective_from) == .lt) continue;

        const week_number: u8 = @intCast(
            @divFloor(date.daysBetween(plan_start, workout_date), 7) + 1,
        );
        if (previous_week == null or previous_week.? != week_number) {
            const week = weekForNumber(revision.weeks, week_number) orelse
                return error.GeneratedWeeklySummaryCountMismatch;
            try printWeekHeading(
                writer,
                revision.provenance.training_policy.periodization.phases,
                week,
            );
            previous_week = week_number;
        }
        try printWorkout(writer, proposedWorkout(proposed, workout_date, week_number));
    }

    try printRevisionGuidance(writer);
}

pub fn printSchedule(
    writer: *Io.Writer,
    storage: *const store.Store,
    schedule: model.Schedule,
) !void {
    const provenance = schedule.plan_provenance orelse return error.PlanExplanationUnavailable;
    if (schedule.plan_weeks.len == 0) return error.PlanExplanationUnavailable;
    if (schedule.race_date.len == 0) return error.RevisionRaceDateRequired;

    const plan_start = try date.parse(schedule.start_date);
    const race_date = try date.parse(schedule.race_date);
    try printHeader(
        writer,
        schedule.race_date,
        schedule.goal,
        schedule.start_date,
        schedule.availability,
        schedule.intensity_guidance,
        schedule.pace_profile,
    );
    try printOverview(writer, schedule.plan_weeks, plan_start);

    var previous_week: ?u8 = null;
    var current = plan_start;
    while (date.compare(current, race_date) != .gt) : (current = date.addDays(current, 1)) {
        const planned = store.workoutForDate(storage, schedule.id, current) orelse
            return error.IncompleteParentSchedule;
        if (previous_week == null or previous_week.? != planned.week) {
            const week = weekForNumber(schedule.plan_weeks, planned.week) orelse
                return error.GeneratedWeeklySummaryCountMismatch;
            try printWeekHeading(
                writer,
                provenance.training_policy.periodization.phases,
                week,
            );
            previous_week = planned.week;
        }
        try printWorkout(writer, planned);
    }

    try printRevisionGuidance(writer);
}

fn printHeader(
    writer: *Io.Writer,
    race_date: []const u8,
    goal: []const u8,
    plan_start: []const u8,
    availability: []const u8,
    intensity_guidance: []const u8,
    pace_profile: []const u8,
) !void {
    try writer.writeAll("# Half-marathon training plan\n\n");
    try writer.print("- **Race day:** {s}\n", .{race_date});
    try writer.print("- **Goal:** {s}\n", .{goal});
    try writer.print("- **Plan dates:** {s} to {s}\n", .{ plan_start, race_date });
    try writer.print("- **Usual availability:** {s}\n", .{availability});
    try writer.print("- **Easy-running guidance:** {s}\n", .{intensity_guidance});
    if (pace_profile.len != 0) {
        try writer.print("- **Pace guidance:** {s}\n", .{pace_profile});
    }

    try writer.writeAll(
        "\nChoose the scheduled run or its bicycle alternative, not both. " ++
            "Bicycle sessions preserve the planned time and effort as a conservative option, " ++
            "but they do not replace running-specific preparation. Optional recovery runs may " ++
            "always be replaced with rest.\n\n",
    );
}

fn printRevisionGuidance(writer: *Io.Writer) !void {
    try writer.writeAll(
        "## If the plan needs to change\n\n" ++
            "Do not squeeze a missed workout into the next day. Keep the structured proposal or " ++
            "runningman data file with this document. After exporting completed activities from " ++
            "Garmin Connect, share the plan, the Garmin activities, and any relevant recovery or " ++
            "pain notes when requesting a revised schedule. Validate the revised JSON before " ++
            "applying it.\n",
    );
}

fn printOverview(
    writer: *Io.Writer,
    weeks: []const plan_revision.ProposedWeek,
    effective_from: date.Date,
) !void {
    try writer.writeAll(
        "## Plan at a glance\n\n" ++
            "| Week | Dates | Phase | Core running | Long run |\n" ++
            "|---:|---|---|---:|---:|\n",
    );
    for (weeks) |week| {
        const week_end = try date.parse(week.end_date);
        if (date.compare(week_end, effective_from) == .lt) continue;

        try writer.print("| {d} | {s}–{s} | ", .{ week.week, week.start_date, week.end_date });
        try printLabel(writer, week.phase);
        try writer.print(" | {d:.1} km | ", .{week.target_core_distance_km});
        if (week.long_run_distance_km > 0) {
            try writer.print("{d:.1} km", .{week.long_run_distance_km});
        } else {
            try writer.writeAll("—");
        }
        try writer.writeAll(" |\n");
    }
    try writer.writeByte('\n');
}

fn printWeekHeading(
    writer: *Io.Writer,
    phases: []const training_policy.Phase,
    week: plan_revision.ProposedWeek,
) !void {
    try writer.print("## Week {d}: ", .{week.week});
    try printLabel(writer, week.phase);
    try writer.print(" ({s}–{s})\n\n", .{ week.start_date, week.end_date });

    const purpose = try phasePurpose(phases, week.phase);
    try writer.print("**Focus:** {s}\n\n", .{purpose});
    try writer.print("Planned core running: **{d:.1} km**", .{week.target_core_distance_km});
    if (week.long_run_distance_km > 0) {
        try writer.print("; long run: **{d:.1} km**", .{week.long_run_distance_km});
    }
    try writer.writeAll(".\n\n");
}

fn proposedWorkout(
    proposed: plan_revision.ProposedWorkout,
    workout_date: date.Date,
    week_number: u8,
) model.Workout {
    return .{
        .id = 0,
        .schedule_id = 0,
        .date = proposed.date,
        .week = week_number,
        .day = date.weekdayName(workout_date),
        .phase = proposed.phase,
        .kind = proposed.kind,
        .intensity = proposed.intensity,
        .distance_min_km = proposed.distance_min_km,
        .distance_max_km = proposed.distance_max_km,
        .details = proposed.details,
        .segments = proposed.segments,
        .decision = proposed.decision,
        .recorded_at = 0,
    };
}

fn printWorkout(writer: *Io.Writer, value: model.Workout) !void {
    try writer.print("### {s}, {s} — ", .{ value.day, value.date });
    try printLabel(writer, value.kind);
    try writer.writeAll("\n\n");
    try writer.print("{s}\n\n", .{value.details});

    if (std.mem.eql(u8, value.kind, "rest")) return;

    try writer.print("**Intensity:** {s}\n\n", .{value.intensity});
    try writer.writeAll("**Run**\n\n");
    try workout.printRunningDetails(writer, value, "");
    try writer.writeAll("\n**Bicycle instead**\n\n");
    try workout.printBicycleDetails(writer, value, "");
    try writer.writeByte('\n');
}

fn weekForNumber(
    weeks: []const plan_revision.ProposedWeek,
    week_number: u8,
) ?plan_revision.ProposedWeek {
    for (weeks) |week| {
        if (week.week == week_number) return week;
    }
    return null;
}

fn phasePurpose(phases: []const training_policy.Phase, phase: []const u8) ![]const u8 {
    for (phases) |candidate| {
        if (std.mem.eql(u8, candidate.phase_id, phase)) return candidate.purpose;
    }
    return error.GeneratedUnknownPhase;
}

fn printLabel(writer: *Io.Writer, value: []const u8) !void {
    var capitalize_next = true;
    for (value) |character| {
        if (character == '_' or character == '-') {
            try writer.writeByte(' ');
            capitalize_next = false;
            continue;
        }
        if (capitalize_next) {
            try writer.writeByte(std.ascii.toUpper(character));
            capitalize_next = false;
        } else {
            try writer.writeByte(character);
        }
    }
}
