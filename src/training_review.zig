const std = @import("std");
const date = @import("date.zig");
const model = @import("model.zig");
const store = @import("store.zig");

const Io = std.Io;

pub const policy_id = "runningman-review";
pub const policy_version = 2;

pub const Classification = enum {
    keep_plan,
    review_required,
    insufficient_data,
};

pub const Inputs = struct {
    scheduled_core_runs: u16 = 0,
    recorded_core_runs: u16 = 0,
    eligible_recovery_observations: u16 = 0,
    recorded_recovery_observations: u16 = 0,
    modified_core_runs: u16 = 0,
    skipped_core_runs: u16 = 0,
    pain_reports: u16 = 0,
    maximum_pain: u8 = 0,
    unusually_difficult_sessions: u16 = 0,
    sleep_below_70: u16 = 0,
    readiness_below_70: u16 = 0,
};

pub const Result = struct {
    classification: Classification,
    inputs: Inputs,
    required_recovery_observations: u16,
    activity_coverage_missing: bool,
    recovery_coverage_missing: bool,
    adherence_rule_fired: bool,
    pain_rule_fired: bool,
    difficulty_rule_fired: bool,
    recovery_persistence_rule_fired: bool,
};

pub fn evaluate(
    storage: *const store.Store,
    start: date.Date,
    end: date.Date,
) Result {
    return classify(collectInputs(storage, start, end));
}

pub fn classify(inputs: Inputs) Result {
    const required_recovery_observations =
        (inputs.eligible_recovery_observations + 1) / 2;
    const activity_coverage_missing = inputs.scheduled_core_runs == 0 or
        inputs.recorded_core_runs < inputs.scheduled_core_runs;
    const recovery_coverage_missing =
        inputs.recorded_recovery_observations < required_recovery_observations;
    const adherence_rule_fired =
        inputs.modified_core_runs > 0 or inputs.skipped_core_runs > 0;
    const pain_rule_fired = inputs.pain_reports > 0;
    const difficulty_rule_fired = inputs.unusually_difficult_sessions > 0;
    const recovery_persistence_rule_fired =
        inputs.sleep_below_70 >= 2 or inputs.readiness_below_70 >= 2;

    const classification: Classification = if (activity_coverage_missing or
        recovery_coverage_missing)
        .insufficient_data
    else if (adherence_rule_fired or
        pain_rule_fired or
        difficulty_rule_fired or
        recovery_persistence_rule_fired)
        .review_required
    else
        .keep_plan;

    return .{
        .classification = classification,
        .inputs = inputs,
        .required_recovery_observations = required_recovery_observations,
        .activity_coverage_missing = activity_coverage_missing,
        .recovery_coverage_missing = recovery_coverage_missing,
        .adherence_rule_fired = adherence_rule_fired,
        .pain_rule_fired = pain_rule_fired,
        .difficulty_rule_fired = difficulty_rule_fired,
        .recovery_persistence_rule_fired = recovery_persistence_rule_fired,
    };
}

pub fn printMarkdown(
    writer: *Io.Writer,
    result: Result,
    start_text: []const u8,
    end_text: []const u8,
) !void {
    try writer.writeAll("## Local review classification\n\n");
    try writer.print(
        "- Review policy: `{s}` version {d}\n",
        .{ policy_id, policy_version },
    );
    try writer.print("- Observation window: {s} through {s}\n", .{ start_text, end_text });
    try writer.print("- Classification: **{s}**\n", .{classificationName(result.classification)});
    try writer.print(
        "- Core-run activity coverage: {d}/{d}; next-morning recovery coverage: {d}/{d} eligible " ++
            "({d} required)\n",
        .{
            result.inputs.recorded_core_runs,
            result.inputs.scheduled_core_runs,
            result.inputs.recorded_recovery_observations,
            result.inputs.eligible_recovery_observations,
            result.required_recovery_observations,
        },
    );

    try writer.writeAll("\n### Coverage rules\n\n");
    try printRule(
        writer,
        "REVIEW-COVERAGE-ACTIVITY-01",
        result.activity_coverage_missing,
        "every scheduled core run in the closed observation window needs an explicit outcome; missing activity is not rest",
        "conservative product assumption",
    );
    try printRule(
        writer,
        "REVIEW-COVERAGE-RECOVERY-01",
        result.recovery_coverage_missing,
        "at least half of eligible core runs need a next-morning Sleep and Readiness check-in inside the observation window",
        "conservative product assumption",
    );

    try writer.writeAll("\n### Review rules\n\n");
    try printRule(
        writer,
        "REVIEW-ADHERENCE-01",
        result.adherence_rule_fired,
        "one or more core runs were modified, skipped, or recorded as rest; review without stacking missed work",
        "conservative product assumption linked to MISSED-01",
    );
    try printRule(
        writer,
        "REVIEW-PAIN-01",
        result.pain_rule_fired,
        "pain above zero was recorded; the classifier flags it for human review but does not diagnose or prescribe",
        "safety-oriented product assumption",
    );
    try printRule(
        writer,
        "REVIEW-DIFFICULTY-01",
        result.difficulty_rule_fired,
        "a non-race session had RPE 9–10 and was unusually difficult",
        "conservative product assumption",
    );
    try printRule(
        writer,
        "REVIEW-RECOVERY-PERSISTENCE-01",
        result.recovery_persistence_rule_fired,
        "Sleep or Readiness was below 70 on at least two mornings; one unusual score never fires this rule",
        "device-score threshold plus conservative persistence assumption",
    );

    try writer.writeAll(
        "\nThis deterministic classification is read-only. It does not automatically reduce, " ++
            "hold, progress, or replace the schedule. A replacement still requires proposed-plan " ++
            "validation, preview, and explicit apply.\n",
    );
}

fn collectInputs(
    storage: *const store.Store,
    start: date.Date,
    end: date.Date,
) Inputs {
    var inputs: Inputs = .{};
    var current = start;
    while (date.compare(current, end) != .gt) : (current = date.addDays(current, 1)) {
        const activity = store.latestActivityForDate(storage, current);
        const workout = workoutForObservation(storage, current, activity);
        if (workout) |planned| {
            if (isCoreRun(planned)) {
                inputs.scheduled_core_runs += 1;
                if (activity) |logged| {
                    inputs.recorded_core_runs += 1;
                    switch (logged.status) {
                        .completed => {
                            if (logged.sport == .cycling) inputs.modified_core_runs += 1;
                        },
                        .modified => inputs.modified_core_runs += 1,
                        .skipped, .rested => inputs.skipped_core_runs += 1,
                    }
                }

                const next_morning = date.addDays(current, 1);
                if (date.compare(next_morning, end) != .gt) {
                    inputs.eligible_recovery_observations += 1;
                    if (store.latestCheckInForDate(storage, next_morning) != null) {
                        inputs.recorded_recovery_observations += 1;
                    }
                }
            }
        }

        if (activity) |logged| {
            if (logged.pain) |pain| {
                if (pain > 0) inputs.pain_reports += 1;
                inputs.maximum_pain = @max(inputs.maximum_pain, pain);
            }
            if (logged.rpe) |rpe| {
                const race = if (workout) |planned|
                    std.mem.eql(u8, planned.kind, "race")
                else
                    false;
                if (!race and rpe >= 9) inputs.unusually_difficult_sessions += 1;
            }
        }
        if (store.latestCheckInForDate(storage, current)) |check_in| {
            if (check_in.sleep_score < 70) inputs.sleep_below_70 += 1;
            if (check_in.readiness_score < 70) inputs.readiness_below_70 += 1;
        }
    }
    return inputs;
}

fn workoutForObservation(
    storage: *const store.Store,
    target_date: date.Date,
    activity: ?model.Activity,
) ?model.Workout {
    if (activity) |logged| {
        if (storage.workouts.get(logged.workout_id)) |workout| return workout;
    }
    return store.currentWorkout(storage, target_date);
}

fn isCoreRun(workout: model.Workout) bool {
    if (workout.decision) |decision| {
        return switch (decision.allocation_role) {
            .easy, .quality, .long_run, .race => true,
            .rest, .optional_recovery => false,
        };
    }
    return !std.mem.eql(u8, workout.kind, "rest") and
        !std.mem.eql(u8, workout.kind, "optional-recovery") and
        !std.mem.eql(u8, workout.kind, "recovery-or-rest") and
        !std.mem.eql(u8, workout.kind, "shakeout");
}

fn classificationName(classification: Classification) []const u8 {
    return switch (classification) {
        .keep_plan => "KEEP_PLAN",
        .review_required => "REVIEW_REQUIRED",
        .insufficient_data => "INSUFFICIENT_DATA",
    };
}

fn printRule(
    writer: *Io.Writer,
    rule_id: []const u8,
    fired: bool,
    explanation: []const u8,
    basis: []const u8,
) !void {
    try writer.print(
        "- `{s}` — {s}: {s}. Basis: {s}.\n",
        .{
            rule_id,
            if (fired) "FIRED" else "passed",
            explanation,
            basis,
        },
    );
}

test "complete neutral inputs keep the plan" {
    const result = classify(.{
        .scheduled_core_runs = 4,
        .recorded_core_runs = 4,
        .eligible_recovery_observations = 4,
        .recorded_recovery_observations = 2,
    });

    try std.testing.expectEqual(Classification.keep_plan, result.classification);
}

test "a review signal requires review when coverage is complete" {
    const result = classify(.{
        .scheduled_core_runs = 4,
        .recorded_core_runs = 4,
        .eligible_recovery_observations = 4,
        .recorded_recovery_observations = 4,
        .pain_reports = 1,
        .maximum_pain = 2,
    });

    try std.testing.expectEqual(Classification.review_required, result.classification);
    try std.testing.expect(result.pain_rule_fired);
}

test "missing coverage takes precedence over warning signals" {
    const result = classify(.{
        .scheduled_core_runs = 4,
        .recorded_core_runs = 3,
        .eligible_recovery_observations = 4,
        .recorded_recovery_observations = 1,
        .modified_core_runs = 1,
    });

    try std.testing.expectEqual(Classification.insufficient_data, result.classification);
    try std.testing.expect(result.activity_coverage_missing);
    try std.testing.expect(result.recovery_coverage_missing);
    try std.testing.expect(result.adherence_rule_fired);
}

test "one low wearable score does not trigger review" {
    const result = classify(.{
        .scheduled_core_runs = 4,
        .recorded_core_runs = 4,
        .eligible_recovery_observations = 4,
        .recorded_recovery_observations = 4,
        .readiness_below_70 = 1,
    });

    try std.testing.expectEqual(Classification.keep_plan, result.classification);
}
