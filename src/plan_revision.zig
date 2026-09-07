const std = @import("std");
const date = @import("date.zig");
const model = @import("model.zig");
const plan_provenance = @import("plan_provenance.zig");
const runner_profile = @import("runner_profile.zig");
const store = @import("store.zig");
const workout = @import("workout.zig");
const targeted_adjustment = @import("targeted_adjustment.zig");

const Io = std.Io;

pub const RevisionFile = struct {
    schema_version: u8,
    base_schedule_id: u64,
    effective_from: []const u8,
    reason: []const u8,
    name: []const u8 = "",
    goal: []const u8 = "",
    availability: []const u8 = "",
    intensity_guidance: []const u8 = "",
    pace_profile: []const u8 = "",
    race_date: []const u8 = "",
    provenance: plan_provenance.PlanProvenance,
    assessment: ProposedAssessment,
    weeks: []const ProposedWeek,
    workouts: []const ProposedWorkout,
};

pub const ProposedAssessment = plan_provenance.AssessmentSnapshot;

pub const ProposedWeek = plan_provenance.PlanWeek;

pub const ProposedWorkout = struct {
    date: []const u8,
    phase: []const u8,
    kind: []const u8,
    intensity: []const u8,
    details: []const u8,
    distance_min_km: ?f64 = null,
    distance_max_km: ?f64 = null,
    terrain: ?runner_profile.Surface = null,
    ascent_meters: ?u32 = null,
    descent_meters: ?u32 = null,
    segments: []const model.Segment,
    decision: ?plan_provenance.WorkoutDecision = null,
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
    if (revision.schema_version != 2) return error.UnsupportedRevisionSchema;
    if (revision.base_schedule_id != storage.max_schedule_id) return error.StaleRevision;
    if (revision.reason.len == 0) return error.RevisionReasonRequired;
    if (revision.workouts.len == 0) return error.EmptyRevision;

    const parent = storage.schedules.get(revision.base_schedule_id) orelse
        return error.StaleRevision;
    if (revision.provenance.adjustment) |context| {
        const parent_days = date.daysBetween(try date.parse(parent.start_date), try date.parse(parent.race_date)) + 1;
        if (parent_days <= 0 or context.parent.workouts.len != @as(usize, @intCast(parent_days))) return error.InvalidAdjustmentContext;
        if (context.parent.base_schedule_id != parent.id or
            !std.mem.eql(u8, context.parent.race_date, parent.race_date)) return error.InvalidAdjustmentContext;
        for (context.parent.workouts) |item| {
            const original = store.workoutForDate(storage, parent.id, try date.parse(item.date)) orelse return error.IncompleteParentSchedule;
            if (!samePrescription(original, item) or !sameWorkoutDecision(original.decision, item.decision)) return error.RevisionHistoricalWorkoutChanged;
        }
        const original_context = parent.plan_provenance orelse return error.AdjustmentNeedsGeneratedPlan;
        if (!std.mem.eql(u8, original_context.training_policy_sha256, context.parent.provenance.training_policy_sha256) or
            !std.mem.eql(u8, original_context.runner_profile_sha256, context.parent.provenance.runner_profile_sha256)) return error.InvalidAdjustmentContext;
    }
    const plan_start_text = revision.provenance.runner_profile.plan_start_date.value;
    if (!std.mem.eql(u8, parent.start_date, plan_start_text)) {
        return error.RevisionPlanStartMismatch;
    }
    const plan_start = try date.parse(plan_start_text);
    const effective_from = try date.parse(revision.effective_from);
    if (date.compare(effective_from, plan_start) == .lt) {
        return error.RevisionBeforePlanStart;
    }

    var expected_date = plan_start;
    for (revision.workouts) |proposed| {
        const proposed_date = try date.parse(proposed.date);
        if (date.compare(proposed_date, expected_date) != .eq) {
            return error.RevisionDatesNotConsecutive;
        }
        if (proposed.decision == null) return error.RevisionWorkoutDecisionRequired;
        try validateWorkout(proposed);
        if (date.compare(proposed_date, effective_from) == .lt) {
            const original = store.workoutForDate(storage, parent.id, proposed_date) orelse
                return error.IncompleteParentSchedule;
            if (!samePrescription(original, proposed) or
                !sameWorkoutDecision(original.decision, proposed.decision))
            {
                return error.RevisionHistoricalWorkoutChanged;
            }
        }
        expected_date = date.addDays(expected_date, 1);
    }

    const race_date_text = if (revision.race_date.len == 0)
        parent.race_date
    else
        revision.race_date;
    if (race_date_text.len == 0) return error.RevisionRaceDateRequired;
    const race_date = try date.parse(race_date_text);
    if (date.compare(effective_from, race_date) == .gt) {
        return error.RevisionEffectiveAfterRace;
    }
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
        .plan_provenance = revision.provenance,
        .plan_weeks = revision.weeks,
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
        if (date.compare(workout_date, effective_from) == .lt) continue;
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
            .terrain = proposed.terrain,
            .ascent_meters = proposed.ascent_meters,
            .descent_meters = proposed.descent_meters,
            .decision = proposed.decision,
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
    const plan_start = try date.parse(revision.workouts[0].date);
    const effective_from = try date.parse(revision.effective_from);
    const effective_index: usize = @intCast(date.daysBetween(plan_start, effective_from));
    try writer.print(
        "Replacement span: {s} through {s} ({d} daily entries)\n" ++
            "Validation context: complete {d}-day plan from {s}\n\n",
        .{
            revision.effective_from,
            revision.workouts[revision.workouts.len - 1].date,
            revision.workouts.len - effective_index,
            revision.workouts.len,
            revision.workouts[0].date,
        },
    );

    const provenance = revision.provenance;
    if (provenance.adjustment) |context| {
        try writer.print("Friel-inspired interruption adjustment (coaching guidance, not a validated recovery formula)\n  Target date: {s} -> {s} ({s})\n  Current return stage: {s}\n  Observed running: {d:.1} km/week; longest run {d:.1} km\n  Repeat source week {d}: completed {d:.1} km; long run {d:.1} km\n  Source: {s}\n", .{
            context.parent.race_date,   revision.race_date,           context.race_date_choice,   @tagName(context.stage),
            context.observed_weekly_km, context.observed_long_run_km, context.repeat_source_week, context.repeat_weekly_km,
            context.repeat_long_run_km, context.guidance_url,
        });
        if (context.stage == .base) {
            try writer.print("  Aerobic-return forecast: {d} calendar week(s), including any partial week.\n  This is a scheduling assumption, NOT a mandatory duration or measured fitness loss.\n  Repeat stage stays provisional until easy running and recovery feel normal.\n", .{context.base_weeks});
        }
        if (context.stage != .continuation) {
            try writer.writeAll("  Later progression stays provisional until the repeated loading week goes well.\n  The date does not advance stages automatically; confirm the response in a new adjustment.\n");
        }
        if (context.returned_weekly_km) |km| {
            try writer.print("  Completed return week: {d:.1} km; long run {d:.1} km. Subsequent growth uses this observed load.\n", .{ km, context.returned_long_run_km orelse 0 });
        }
        try writer.writeAll("  Original baseline evidence, performance assessment, and race prescription retained.\n  Schedule feasibility is not a prediction of the original finishing-time goal.\n");
        if (context.omitted_source_weeks.len == 0) {
            try writer.writeAll("  No source weeks omitted from the resumed progression.\n");
        } else {
            try writer.writeAll("  Fixed-date compromise: omitted source weeks");
            for (context.omitted_source_weeks) |number| try writer.print(" {d}", .{number});
            try writer.writeAll(". Less preparation remains; the finishing-time goal needs reassessment.\n");
        }
        try writer.writeByte('\n');
        try writer.writeAll("Remaining weekly running (old -> proposed):\n");
        for (revision.weeks, 0..) |week, index| {
            if (date.compare(try date.parse(week.start_date), effective_from) == .lt) continue;
            const old_km = if (index < context.parent.weeks.len) context.parent.weeks[index].target_core_distance_km else 0;
            const old_long = if (index < context.parent.weeks.len) context.parent.weeks[index].long_run_distance_km else 0;
            try writer.print("  {s}: {d:.1} -> {d:.1} km; long run {d:.1} -> {d:.1} km ({s})\n", .{
                week.start_date, old_km, week.target_core_distance_km, old_long, week.long_run_distance_km, week.phase,
            });
            for (context.week_changes) |change| {
                if (change.week != index + 1) continue;
                try writer.print("    {s}; source week {d}\n", .{ change.reason, change.source_week });
            }
        }
        try writer.writeByte('\n');
    }
    try writer.print(
        "Planner provenance\n" ++
            "  Generator: {s}\n" ++
            "  Runner profile: {s} ({s})\n" ++
            "  Training policy: {s} v{d} ({s})\n" ++
            "  Evidence ledger: {s} ({s})\n" ++
            "  Complete profile and policy snapshots are embedded in this proposal.\n\n",
        .{
            provenance.generator_version,
            provenance.runner_profile.profile_id,
            provenance.runner_profile_sha256,
            provenance.training_policy.policy_id,
            provenance.training_policy.policy_version,
            provenance.training_policy_sha256,
            provenance.evidence_ledger_id,
            provenance.evidence_ledger_sha256,
        },
    );

    const result = revision.assessment;
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

    try writer.writeAll("Macrocycle\n");
    for (revision.weeks) |week| {
        try writer.print("  Week {d} ({s}–{s}): {s}", .{
            week.week,
            week.start_date,
            week.end_date,
            week.phase,
        });
        if (week.target_core_duration_seconds) |duration_seconds| {
            try writer.writeAll(", ");
            try printDuration(writer, duration_seconds);
            try writer.writeAll(" planned running");
        } else {
            try writer.print(", {d:.1} km core", .{week.target_core_distance_km});
        }
        if (week.long_run_distance_km > 0) {
            try writer.print(", {d:.1} km long run", .{week.long_run_distance_km});
        }
        try writer.print(
            ", phase week {d}/{d}",
            .{
                week.decision.phase_week,
                week.decision.phase_week_count,
            },
        );
        try writer.writeByte('\n');
        const decision = week.decision;
        try writer.print(
            "    Basis: {s}; rules {s}, {s}, {s}\n",
            .{
                @tagName(decision.volume_method),
                decision.periodization_rule_id,
                decision.volume_rule_id,
                decision.long_run_rule_id,
            },
        );
    }
    try writer.writeByte('\n');

    var previous_week: ?u8 = null;
    const parent = storage.schedules.get(revision.base_schedule_id).?;
    const start = try date.parse(parent.start_date);
    for (revision.workouts) |proposed| {
        const proposed_date = try date.parse(proposed.date);
        if (date.compare(proposed_date, effective_from) == .lt) continue;
        const week: u8 = @intCast(@divFloor(date.daysBetween(start, proposed_date), 7) + 1);
        if (previous_week == null or previous_week.? != week) {
            try writer.print("Week {d} — {s}\n", .{ week, proposed.phase });
            if (revision.provenance.adjustment) |context| {
                if (try targeted_adjustment.pendingStage(context, proposed_date)) |stage| {
                    try writer.print("  PROVISIONAL {s} stage — requires a response-confirmed adjustment before use.\n", .{@tagName(stage)});
                }
            }
            previous_week = week;
        }
        const current = store.workoutForDate(storage, parent.id, proposed_date);
        const change_marker = if (current) |planned|
            if (sameVisiblePrescription(planned, proposed)) "unchanged" else "changed"
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
            .terrain = proposed.terrain,
            .ascent_meters = proposed.ascent_meters,
            .descent_meters = proposed.descent_meters,
            .recorded_at = 0,
        };
        try workout.printDetails(writer, preview_workout, "    ");
        const decision = proposed.decision.?;
        try writer.print(
            "    Basis: recipe {s}; distance {s}; pace {s}; rules ",
            .{
                decision.recipe_id,
                @tagName(decision.distance_method),
                @tagName(decision.pace_method),
            },
        );
        for (decision.rule_ids, 0..) |rule_id, index| {
            if (index != 0) try writer.writeAll(", ");
            try writer.writeAll(rule_id);
        }
        try writer.writeByte('\n');
        if (decision.quality_progression) |quality| {
            try writer.print(
                "    Progression: {s}; {s}; phase week {d}/{d}; {d:.1} km work",
                .{
                    quality.stage_id,
                    @tagName(quality.load_method),
                    quality.phase_week,
                    quality.phase_week_count,
                    quality.work_distance_km,
                },
            );
            if (quality.previous_work_distance_km) |previous| {
                try writer.print(
                    " after {d:.1} km in the previous quality session",
                    .{previous},
                );
            }
            try writer.writeByte('\n');
        }
    }
    try writer.writeAll("\nNo data was changed. Use `runningman plan apply FILE` after reviewing this preview.\n");
}

pub fn validateWorkout(proposed: ProposedWorkout) !void {
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

fn sameVisiblePrescription(current: model.Workout, proposed: ProposedWorkout) bool {
    var left = current;
    var right = proposed;
    // Phase and explicit default terrain are planning metadata; the race's
    // distance, effort, pace and instructions determine its visible change.
    left.phase = right.phase;
    left.terrain = left.terrain orelse .road;
    right.terrain = right.terrain orelse .road;
    if (std.mem.eql(u8, left.kind, "rest") and std.mem.eql(u8, right.kind, "rest")) {
        left.distance_min_km = 0;
        left.distance_max_km = 0;
        right.distance_min_km = 0;
        right.distance_max_km = 0;
    }
    return samePrescription(left, right);
}

fn samePrescription(current: model.Workout, proposed: ProposedWorkout) bool {
    const range = proposedDistanceRange(proposed);
    if (!std.mem.eql(u8, current.phase, proposed.phase) or
        !std.mem.eql(u8, current.kind, proposed.kind) or
        !std.mem.eql(u8, current.intensity, proposed.intensity) or
        !std.mem.eql(u8, current.details, proposed.details) or
        current.distance_min_km != range.minimum_km or
        current.distance_max_km != range.maximum_km or
        current.terrain != proposed.terrain or
        current.ascent_meters != proposed.ascent_meters or
        current.descent_meters != proposed.descent_meters or
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

fn sameWorkoutDecision(
    left: ?plan_provenance.WorkoutDecision,
    right: ?plan_provenance.WorkoutDecision,
) bool {
    if (left == null or right == null) return left == null and right == null;
    const left_value = left.?;
    const right_value = right.?;
    if (!std.mem.eql(u8, left_value.recipe_id, right_value.recipe_id) or
        left_value.rule_ids.len != right_value.rule_ids.len or
        left_value.allocation_role != right_value.allocation_role or
        left_value.distance_method != right_value.distance_method or
        left_value.pace_method != right_value.pace_method or
        left_value.week_target_core_distance_km != right_value.week_target_core_distance_km or
        left_value.allocated_distance_km != right_value.allocated_distance_km or
        left_value.week_target_core_duration_seconds != right_value.week_target_core_duration_seconds or
        left_value.allocated_duration_seconds != right_value.allocated_duration_seconds or
        left_value.training_pace_anchor_seconds != right_value.training_pace_anchor_seconds or
        left_value.scheduled_weekday != right_value.scheduled_weekday or
        left_value.preferred_weekday != right_value.preferred_weekday or
        left_value.preference_honored != right_value.preference_honored or
        left_value.planned_ascent_meters != right_value.planned_ascent_meters or
        left_value.planned_descent_meters != right_value.planned_descent_meters or
        left_value.terrain != right_value.terrain or
        left_value.load_basis != right_value.load_basis or
        !sameQualityProgression(
            left_value.quality_progression,
            right_value.quality_progression,
        ))
    {
        return false;
    }
    for (left_value.rule_ids, right_value.rule_ids) |left_rule, right_rule| {
        if (!std.mem.eql(u8, left_rule, right_rule)) return false;
    }
    return true;
}

fn sameQualityProgression(
    left: ?plan_provenance.QualityProgressionDecision,
    right: ?plan_provenance.QualityProgressionDecision,
) bool {
    if (left == null or right == null) return left == null and right == null;
    const left_value = left.?;
    const right_value = right.?;
    return std.mem.eql(u8, left_value.stage_id, right_value.stage_id) and
        left_value.load_method == right_value.load_method and
        left_value.phase_week == right_value.phase_week and
        left_value.phase_week_count == right_value.phase_week_count and
        left_value.work_distance_km == right_value.work_distance_km and
        left_value.previous_work_distance_km == right_value.previous_work_distance_km and
        left_value.repetition_distance_km == right_value.repetition_distance_km and
        left_value.repetitions == right_value.repetitions and
        left_value.recovery_seconds == right_value.recovery_seconds and
        left_value.work_duration_seconds == right_value.work_duration_seconds and
        left_value.previous_work_duration_seconds == right_value.previous_work_duration_seconds;
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
