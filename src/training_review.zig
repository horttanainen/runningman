const std = @import("std");
const date = @import("date.zig");
const model = @import("model.zig");
const store = @import("store.zig");
const workout_detail = @import("workout.zig");

const Io = std.Io;

pub const policy_id = "runningman-review";
pub const policy_version = 5;
pub const decision_window_days: i32 = 28;
pub const recent_wearable_days: i32 = 3;
pub const low_score_threshold: u8 = 70;
pub const minimum_recent_wearable_observations: u16 = 2;
pub const persistent_low_mornings: u16 = 2;
pub const pain_confirmation_threshold: u8 = 3;
pub const repeated_disruption_threshold: u16 = 2;
pub const progression_signal_threshold: u16 = 2;
pub const quality_progression_rpe_ceiling: u8 = 5;
const maximum_calibration_samples = 256;

pub const Classification = enum {
    hold,
    progress,
    reduce,
    replan,
    insufficient_data,
};

pub const WearablePattern = enum {
    balanced,
    sleep_limited,
    readiness_limited,
    both_limited,
    unavailable,
};

const CoreRole = enum {
    easy,
    quality,
    long_run,
    race,
};

pub const RoleProgress = struct {
    scheduled: u16 = 0,
    recorded: u16 = 0,
    completed: u16 = 0,
    modified: u16 = 0,
    skipped: u16 = 0,
    rested: u16 = 0,
    cycling_substitutions: u16 = 0,
};

pub const RoleCalibration = struct {
    target_rpe_min: u8,
    target_rpe_max: u8,
    sample_count: u16 = 0,
    heart_rate_low: ?u16 = null,
    heart_rate_high: ?u16 = null,
};

pub const Calibration = struct {
    easy: RoleCalibration = .{ .target_rpe_min = 2, .target_rpe_max = 4 },
    quality: RoleCalibration = .{ .target_rpe_min = 6, .target_rpe_max = 8 },
    long_run: RoleCalibration = .{ .target_rpe_min = 2, .target_rpe_max = 4 },
};

pub const Progress = struct {
    core: RoleProgress = .{},
    easy: RoleProgress = .{},
    quality: RoleProgress = .{},
    long_run: RoleProgress = .{},
    race: RoleProgress = .{},
    completed: u16 = 0,
    modified: u16 = 0,
    skipped: u16 = 0,
    rested: u16 = 0,
    cycling_substitutions: u16 = 0,
    planned_min_km: f64 = 0,
    planned_max_km: f64 = 0,
    plans_without_distance: u16 = 0,
    actual_running_distance_km: f64 = 0,
};

pub const Inputs = struct {
    scheduled_core_runs: u16 = 0,
    recorded_core_runs: u16 = 0,
    eligible_recovery_observations: u16 = 0,
    recorded_recovery_observations: u16 = 0,
    recent_wearable_expected: u16 = 0,
    recent_wearable_recorded: u16 = 0,
    modified_core_runs: u16 = 0,
    skipped_core_runs: u16 = 0,
    sickness_skips: u16 = 0,
    first_sickness_skip: ?date.Date = null,
    last_sickness_skip: ?date.Date = null,
    cycling_substitutions: u16 = 0,
    pain_reports: u16 = 0,
    pain_above_confirmation_threshold: u16 = 0,
    maximum_pain: u8 = 0,
    pain_affects_plan: ?bool = null,
    unusually_difficult_sessions: u16 = 0,
    easier_quality_sessions: u16 = 0,
    outperformed_sessions: u16 = 0,
    sleep_below_70: u16 = 0,
    readiness_below_70: u16 = 0,
    latest_wearable_date: ?date.Date = null,
    latest_sleep_score: ?u8 = null,
    latest_readiness_score: ?u8 = null,
    latest_wearable_pattern: WearablePattern = .unavailable,
};

pub const Result = struct {
    classification: Classification,
    inputs: Inputs,
    required_recovery_observations: u16,
    required_recent_wearable_observations: u16,
    activity_coverage_missing: bool,
    recovery_coverage_missing: bool,
    recent_wearable_coverage_missing: bool,
    adherence_rule_fired: bool,
    pain_constraint_fired: bool,
    difficulty_rule_fired: bool,
    recovery_persistence_rule_fired: bool,
    progression_rule_fired: bool,
    calibration: Calibration = .{},
};

pub const Snapshot = struct {
    as_of: date.Date,
    progress_start: date.Date,
    closed_activity_end: date.Date,
    decision_start: date.Date,
    recovery_end: date.Date,
    progress: Progress,
    result: Result,
};

pub fn evaluate(
    storage: *const store.Store,
    start: date.Date,
    end: date.Date,
) Result {
    var result = classify(collectInputs(storage, start, end, date.addDays(end, 1)));
    result.calibration = collectCalibration(storage, start, end);
    return result;
}

pub fn evaluateSnapshot(storage: *const store.Store, as_of: date.Date) !Snapshot {
    const progress_start = store.earliestScheduleDate(storage) orelse
        return error.NotInitialized;
    const closed_activity_end = latestClosedActivityDate(storage, as_of);
    if (date.compare(closed_activity_end, progress_start) == .lt) {
        return error.NoClosedReviewPeriod;
    }

    const candidate_start = date.addDays(closed_activity_end, -(decision_window_days - 1));
    const decision_start = laterDate(progress_start, candidate_start);
    const inputs = collectInputs(storage, decision_start, closed_activity_end, as_of);

    var result = classify(inputs);
    result.calibration = collectCalibration(storage, progress_start, closed_activity_end);
    return .{
        .as_of = as_of,
        .progress_start = progress_start,
        .closed_activity_end = closed_activity_end,
        .decision_start = decision_start,
        .recovery_end = as_of,
        .progress = collectProgress(storage, progress_start, closed_activity_end),
        .result = result,
    };
}

pub fn needsPainConfirmation(snapshot: Snapshot) bool {
    return snapshot.result.inputs.pain_above_confirmation_threshold > 0;
}

pub fn applyPainConfirmation(snapshot: *Snapshot, pain_affects_plan: bool) void {
    var inputs = snapshot.result.inputs;
    inputs.pain_affects_plan = pain_affects_plan;
    const calibration = snapshot.result.calibration;
    snapshot.result = classify(inputs);
    snapshot.result.calibration = calibration;
}

pub fn classify(inputs: Inputs) Result {
    const required_recovery_observations =
        (inputs.eligible_recovery_observations + 1) / 2;
    const required_recent_wearable_observations = @min(
        inputs.recent_wearable_expected,
        minimum_recent_wearable_observations,
    );
    const activity_coverage_missing = inputs.scheduled_core_runs == 0 or
        inputs.recorded_core_runs < inputs.scheduled_core_runs;
    const recovery_coverage_missing =
        inputs.recorded_recovery_observations < required_recovery_observations;
    const recent_wearable_coverage_missing =
        inputs.recent_wearable_recorded < required_recent_wearable_observations;
    const adherence_rule_fired =
        inputs.modified_core_runs + inputs.skipped_core_runs >= repeated_disruption_threshold;
    const pain_constraint_fired = inputs.pain_affects_plan orelse false;
    const difficulty_rule_fired = inputs.unusually_difficult_sessions > 0;
    const recovery_persistence_rule_fired =
        inputs.sleep_below_70 >= persistent_low_mornings or
        inputs.readiness_below_70 >= persistent_low_mornings;
    const progression_rule_fired =
        inputs.easier_quality_sessions >= progression_signal_threshold or
        inputs.outperformed_sessions >= progression_signal_threshold;

    const classification: Classification = if (activity_coverage_missing or
        recovery_coverage_missing or
        recent_wearable_coverage_missing)
        .insufficient_data
    else if (pain_constraint_fired or
        difficulty_rule_fired or
        recovery_persistence_rule_fired)
        .reduce
    else if (adherence_rule_fired)
        .replan
    else if (progression_rule_fired)
        .progress
    else
        .hold;

    return .{
        .classification = classification,
        .inputs = inputs,
        .required_recovery_observations = required_recovery_observations,
        .required_recent_wearable_observations = required_recent_wearable_observations,
        .activity_coverage_missing = activity_coverage_missing,
        .recovery_coverage_missing = recovery_coverage_missing,
        .recent_wearable_coverage_missing = recent_wearable_coverage_missing,
        .adherence_rule_fired = adherence_rule_fired,
        .pain_constraint_fired = pain_constraint_fired,
        .difficulty_rule_fired = difficulty_rule_fired,
        .recovery_persistence_rule_fired = recovery_persistence_rule_fired,
        .progression_rule_fired = progression_rule_fired,
    };
}

pub fn printStatus(writer: *Io.Writer, storage: *const store.Store, snapshot: Snapshot) !void {
    try writer.writeAll("Schedule review as of ");
    try printDate(writer, snapshot.as_of);
    try writer.writeAll("\nClosed training through ");
    try printDate(writer, snapshot.closed_activity_end);
    try writer.writeAll("\nDecision window: ");
    try printDate(writer, snapshot.decision_start);
    try writer.writeAll(" through ");
    try printDate(writer, snapshot.closed_activity_end);
    try writer.print(" ({d} days maximum; policy `{s}` v{d})\n\n", .{
        decision_window_days,
        policy_id,
        policy_version,
    });

    const addressed = try historicalDisruptionAddressed(storage, snapshot);
    if (snapshot.result.classification == .replan and addressed) {
        try writer.writeAll("Current action: follow the applied return plan and its checkpoint.\nHistorical review signal: REPLAN; the earlier interruption already has an applied adjustment.\n");
    } else {
        try writer.print("Recommendation: {s}\n{s}\n", .{
            classificationName(snapshot.result.classification),
            recommendationText(snapshot.result.classification),
        });
    }
    try printCoverageGaps(writer, storage, snapshot);
    try printReplanContext(writer, snapshot.result, addressed);

    try writer.writeAll("\nProgress to date (since ");
    try printDate(writer, snapshot.progress_start);
    try writer.writeAll("):\n");
    try writer.print("- Core workouts recorded: {d}/{d}\n", .{
        snapshot.progress.core.recorded,
        snapshot.progress.core.scheduled,
    });
    try writer.print(
        "- Outcomes: {d} running completions, {d} modified, {d} skipped, {d} rested; {d} cycling substitutions\n",
        .{
            snapshot.progress.completed,
            snapshot.progress.modified,
            snapshot.progress.skipped,
            snapshot.progress.rested,
            snapshot.progress.cycling_substitutions,
        },
    );
    try printRoleProgress(writer, "Easy", snapshot.progress.easy);
    try printRoleProgress(writer, "Quality", snapshot.progress.quality);
    try printRoleProgress(writer, "Long run", snapshot.progress.long_run);
    try printRoleProgress(writer, "Race", snapshot.progress.race);
    try writer.print(
        "- Running distance: {d:.2} km actual; {d:.1}-{d:.1} km structured plan; {d} core workouts without a distance target\n",
        .{
            snapshot.progress.actual_running_distance_km,
            snapshot.progress.planned_min_km,
            snapshot.progress.planned_max_km,
            snapshot.progress.plans_without_distance,
        },
    );

    try writer.writeAll("\nPersonal intensity calibration:\n");
    try printRoleCalibration(writer, "Easy", snapshot.result.calibration.easy, false);
    try printRoleCalibration(writer, "Quality", snapshot.result.calibration.quality, true);
    try printRoleCalibration(writer, "Long run", snapshot.result.calibration.long_run, false);

    try writer.writeAll("\nOura recovery signals:\n");
    if (snapshot.result.inputs.latest_wearable_date) |wearable_date| {
        try writer.writeAll("- Latest morning (");
        try printDate(writer, wearable_date);
        try writer.print("): Sleep {d} ({s}); Readiness {d} ({s})\n", .{
            snapshot.result.inputs.latest_sleep_score.?,
            scoreCategory(snapshot.result.inputs.latest_sleep_score.?),
            snapshot.result.inputs.latest_readiness_score.?,
            scoreCategory(snapshot.result.inputs.latest_readiness_score.?),
        });
        try writer.print("- Current pattern: {s}\n", .{
            wearablePatternDescription(snapshot.result.inputs.latest_wearable_pattern),
        });
    } else {
        try writer.writeAll("- No Oura Sleep and Readiness observation is available in the latest three mornings.\n");
    }
    try writer.print(
        "- Latest {d} mornings: {d}/{d} recorded; Sleep below Good on {d}; Readiness below Good on {d}\n",
        .{
            recent_wearable_days,
            snapshot.result.inputs.recent_wearable_recorded,
            snapshot.result.inputs.recent_wearable_expected,
            snapshot.result.inputs.sleep_below_70,
            snapshot.result.inputs.readiness_below_70,
        },
    );

    try writer.print(
        "\nPain context:\n- {d} reports above zero; {d} above {d}/10; maximum {d}/10.\n",
        .{
            snapshot.result.inputs.pain_reports,
            snapshot.result.inputs.pain_above_confirmation_threshold,
            pain_confirmation_threshold,
            snapshot.result.inputs.maximum_pain,
        },
    );
    if (snapshot.result.inputs.pain_affects_plan) |affects_plan| {
        try writer.print("- User confirmation: pain {s} currently affect the plan.\n", .{
            if (affects_plan) "does" else "does not",
        });
    } else if (snapshot.result.inputs.pain_above_confirmation_threshold > 0) {
        try writer.writeAll("- Current impact was not confirmed; historical pain does not affect the recommendation.\n");
    } else {
        try writer.writeAll("- No confirmation was needed; scores of 0-3 are informational.\n");
    }

    try writer.writeAll("\nDecision details:\n");
    try printStatusDetails(writer, snapshot.result);
    try writer.writeAll(
        "\nThis review is read-only. No schedule changes were made. " ++
            "Any replacement still requires validation, preview, and explicit apply.\n",
    );
}

fn historicalDisruptionAddressed(storage: *const store.Store, snapshot: Snapshot) !bool {
    const latest = storage.schedules.get(storage.max_schedule_id) orelse return false;
    const source = latest.plan_provenance orelse return false;
    var context = source.adjustment orelse return false;
    if (context.policy_version != 3) return false;
    var depth: usize = 0;
    while (context.parent.provenance.adjustment) |previous| {
        depth += 1;
        if (depth > 24) return error.InvalidAdjustmentContext;
        context = previous;
    }
    const restart = try date.parse(context.restart_date);
    if (date.compare(snapshot.as_of, restart) == .lt) return false;
    var current = laterDate(restart, snapshot.decision_start);
    while (date.compare(current, snapshot.closed_activity_end) != .gt) : (current = date.addDays(current, 1)) {
        const logged = store.latestActivityForDate(storage, current) orelse continue;
        const workout = workoutForObservation(storage, current, logged) orelse continue;
        if (!isCoreRun(workout)) continue;
        if (logged.status == .modified or logged.status == .skipped or logged.status == .rested) return false;
    }
    return true;
}

fn printReplanContext(writer: *Io.Writer, result: Result, addressed: bool) !void {
    if (!result.adherence_rule_fired) return;
    try writer.writeAll("\nSchedule continuity:\n");
    try writer.print("- {d} core workouts skipped or rested; {d} modified in the decision window.\n", .{
        result.inputs.skipped_core_runs, result.inputs.modified_core_runs,
    });
    if (result.inputs.sickness_skips > 0) {
        const first = result.inputs.first_sickness_skip orelse return error.InvalidDataFile;
        const last = result.inputs.last_sickness_skip orelse return error.InvalidDataFile;
        try writer.print("- {d} core workouts recorded as skipped due to sickness: ", .{result.inputs.sickness_skips});
        try printDate(writer, first);
        try writer.writeAll(" through ");
        try printDate(writer, last);
        try writer.writeAll(" (dates of skipped workouts).\n");
    }
    if (addressed) {
        try writer.writeAll("- These historical disruptions are already addressed by the applied return plan. They alone do not require starting another adjustment.\n");
        return;
    }
    try writer.writeAll("- The next proposal should reconnect the remaining progression to completed training, rather than resume at the calendar's current workout.\n");
    if (result.classification == .replan) {
        try writer.writeAll("- No effort, Oura, or confirmed-pain reduction rule fired. The interruption alone does not determine a lower training load.\n");
    }
    try writer.writeAll("- How to shift the remaining workouts and handle the race date belongs to the next proposal.\n");
}

fn printCoverageGaps(writer: *Io.Writer, storage: *const store.Store, snapshot: Snapshot) !void {
    const result = snapshot.result;
    if (result.classification != .insufficient_data) return;

    try writer.writeAll("\nMissing information blocking this recommendation:\n");
    if (result.activity_coverage_missing) {
        const missing = result.inputs.scheduled_core_runs - result.inputs.recorded_core_runs;
        if (result.inputs.scheduled_core_runs == 0) {
            try writer.writeAll("- No closed core workouts are scheduled in the decision window.\n");
        } else {
            try writer.print("- Workout outcomes: {d} missing ({d}/{d} recorded).\n", .{
                missing, result.inputs.recorded_core_runs, result.inputs.scheduled_core_runs,
            });
        }
        var current = snapshot.decision_start;
        while (date.compare(current, snapshot.closed_activity_end) != .gt) : (current = date.addDays(current, 1)) {
            if (store.latestActivityForDate(storage, current) != null) continue;
            const planned = workoutForObservation(storage, current, null) orelse continue;
            if (!isCoreRun(planned)) continue;
            try writer.print("  - {s}: {s}\n", .{
                planned.date, planned.kind,
            });
        }
    }

    if (!result.recovery_coverage_missing and !result.recent_wearable_coverage_missing) {
        try writer.writeAll("- Oura coverage is sufficient; no additional Oura entries are required for this review.\n");
        return;
    }
    if (result.recovery_coverage_missing) {
        try writer.print("- Next-morning Oura: add at least {d} check-in(s) from the missing dates below ({d}/{d} required recorded).\n", .{
            result.required_recovery_observations - result.inputs.recorded_recovery_observations,
            result.inputs.recorded_recovery_observations,
            result.required_recovery_observations,
        });
        var current = snapshot.decision_start;
        while (date.compare(current, snapshot.closed_activity_end) != .gt) : (current = date.addDays(current, 1)) {
            const logged = store.latestActivityForDate(storage, current);
            const planned = workoutForObservation(storage, current, logged) orelse continue;
            if (!isCoreRun(planned)) continue;
            const morning = date.addDays(current, 1);
            if (date.compare(morning, snapshot.recovery_end) == .gt) continue;
            if (store.latestCheckInForDate(storage, morning) != null) continue;
            try writer.writeAll("  - ");
            try printDate(writer, morning);
            try writer.print(" (morning after {s}, {s})\n", .{ planned.date, planned.kind });
        }
    }
    if (result.recent_wearable_coverage_missing) {
        try writer.print("- Recent Oura: add at least {d} check-in(s) from the missing dates below ({d}/{d} required recorded).\n", .{
            result.required_recent_wearable_observations - result.inputs.recent_wearable_recorded,
            result.inputs.recent_wearable_recorded,
            result.required_recent_wearable_observations,
        });
        var morning = laterDate(snapshot.decision_start, date.addDays(snapshot.recovery_end, -(recent_wearable_days - 1)));
        while (date.compare(morning, snapshot.recovery_end) != .gt) : (morning = date.addDays(morning, 1)) {
            if (store.latestCheckInForDate(storage, morning) != null) continue;
            try writer.writeAll("  - ");
            try printDate(writer, morning);
            try writer.writeByte('\n');
        }
    }
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
    try writer.print("- Recommendation: **{s}**\n", .{classificationName(result.classification)});
    try writer.print("{s}\n", .{recommendationText(result.classification)});
    try printReplanContext(writer, result, false);
    try writer.print(
        "- Core-run activity coverage: {d}/{d}; next-morning recovery coverage: {d}/{d} eligible " ++
            "({d} required); recent Oura coverage: {d}/{d} ({d} required)\n",
        .{
            result.inputs.recorded_core_runs,
            result.inputs.scheduled_core_runs,
            result.inputs.recorded_recovery_observations,
            result.inputs.eligible_recovery_observations,
            result.required_recovery_observations,
            result.inputs.recent_wearable_recorded,
            result.inputs.recent_wearable_expected,
            result.required_recent_wearable_observations,
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
        "at least half of eligible core runs need a next-morning Oura Sleep and Readiness check-in",
        "conservative product assumption",
    );
    try printRule(
        writer,
        "REVIEW-COVERAGE-CURRENT-01",
        result.recent_wearable_coverage_missing,
        "at least two of the latest three mornings need Oura Sleep and Readiness scores",
        "conservative current-state coverage assumption",
    );

    try writer.writeAll("\n### Direction rules\n\n");
    try printRule(
        writer,
        "REVIEW-ADHERENCE-01",
        result.adherence_rule_fired,
        "at least two core runs were modified, skipped, or rested: request replanning, not an automatic load reduction; isolated changes and cycling substitutions remain context",
        "conservative product assumption linked to MISSED-01",
    );
    try printRule(
        writer,
        "REVIEW-PAIN-CONFIRMED-01",
        result.pain_constraint_fired,
        "pain reduces the plan only when a score above 3 prompted the user and the user confirmed it currently affects the plan",
        "user-confirmed constraint; historical pain alone is informational",
    );
    try printRule(
        writer,
        "REVIEW-DIFFICULTY-01",
        result.difficulty_rule_fired,
        "a non-race session had RPE 9-10 and was unusually difficult",
        "conservative product assumption",
    );
    try printRule(
        writer,
        "REVIEW-RECOVERY-PERSISTENCE-01",
        result.recovery_persistence_rule_fired,
        "Oura Sleep or Readiness was below its Good category on at least two of the latest three mornings",
        "Oura score categories plus conservative persistence assumption",
    );
    try printRule(
        writer,
        "REVIEW-PROGRESSION-01",
        result.progression_rule_fired,
        "at least two completed sessions were easier than their prescribed quality RPE or faster than their complete pace prescription at the intended RPE",
        "conservative calibration assumption; suppressed by any reduction signal",
    );

    try writer.writeAll("\n### Personal intensity calibration\n\n");
    try printRoleCalibration(writer, "Easy", result.calibration.easy, false);
    try printRoleCalibration(writer, "Quality", result.calibration.quality, true);
    try printRoleCalibration(writer, "Long run", result.calibration.long_run, false);
    try writer.print(
        "- Pain observations: {d} above zero; {d} above {d}/10; maximum {d}/10. " ++
            "A detailed report cannot answer the interactive current-impact question, so pain scores alone do not select REDUCE.\n",
        .{
            result.inputs.pain_reports,
            result.inputs.pain_above_confirmation_threshold,
            pain_confirmation_threshold,
            result.inputs.maximum_pain,
        },
    );

    try writer.writeAll(
        "\nThis recommendation is read-only. It does not automatically reduce, hold, progress, " ++
            "or replace the schedule. A replacement still requires proposed-plan " ++
            "validation, preview, and explicit apply.\n",
    );
}

fn collectInputs(
    storage: *const store.Store,
    start: date.Date,
    end: date.Date,
    recovery_end: date.Date,
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
                            if (logged.sport == .cycling) {
                                inputs.cycling_substitutions += 1;
                            } else {
                                const role = coreRole(planned).?;
                                if (role == .quality) {
                                    if (logged.rpe) |rpe| {
                                        if (rpe <= quality_progression_rpe_ceiling) {
                                            inputs.easier_quality_sessions += 1;
                                        }
                                    }
                                }
                                if (outperformedPrescription(planned, logged, role)) {
                                    inputs.outperformed_sessions += 1;
                                }
                            }
                        },
                        .modified => inputs.modified_core_runs += 1,
                        .skipped, .rested => {
                            inputs.skipped_core_runs += 1;
                            if (logged.status == .skipped and std.ascii.eqlIgnoreCase(logged.deviation_reason, "sickness")) {
                                inputs.sickness_skips += 1;
                                if (inputs.first_sickness_skip == null) inputs.first_sickness_skip = current;
                                inputs.last_sickness_skip = current;
                            }
                        },
                    }
                }

                const next_morning = date.addDays(current, 1);
                if (date.compare(next_morning, recovery_end) != .gt) {
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
                if (pain > pain_confirmation_threshold) {
                    inputs.pain_above_confirmation_threshold += 1;
                }
                inputs.maximum_pain = @max(inputs.maximum_pain, pain);
            }
            if (logged.rpe) |rpe| {
                const race = if (workout) |planned|
                    coreRole(planned) == .race
                else
                    false;
                if (!race and rpe >= 9) inputs.unusually_difficult_sessions += 1;
            }
        }
    }

    collectRecentWearable(storage, start, recovery_end, &inputs);
    return inputs;
}

fn collectRecentWearable(
    storage: *const store.Store,
    review_start: date.Date,
    recovery_end: date.Date,
    inputs: *Inputs,
) void {
    const candidate_start = date.addDays(recovery_end, -(recent_wearable_days - 1));
    const wearable_start = laterDate(review_start, candidate_start);
    if (date.compare(wearable_start, recovery_end) == .gt) return;

    var current = wearable_start;
    while (date.compare(current, recovery_end) != .gt) : (current = date.addDays(current, 1)) {
        inputs.recent_wearable_expected += 1;
        const check_in = store.latestCheckInForDate(storage, current) orelse continue;
        inputs.recent_wearable_recorded += 1;
        if (check_in.sleep_score < low_score_threshold) inputs.sleep_below_70 += 1;
        if (check_in.readiness_score < low_score_threshold) inputs.readiness_below_70 += 1;
        inputs.latest_wearable_date = current;
        inputs.latest_sleep_score = check_in.sleep_score;
        inputs.latest_readiness_score = check_in.readiness_score;
        inputs.latest_wearable_pattern = wearablePattern(
            check_in.sleep_score,
            check_in.readiness_score,
        );
    }
}

fn collectProgress(
    storage: *const store.Store,
    start: date.Date,
    end: date.Date,
) Progress {
    var progress: Progress = .{};
    var current = start;
    while (date.compare(current, end) != .gt) : (current = date.addDays(current, 1)) {
        const activity = store.latestActivityForDate(storage, current);
        const workout = workoutForObservation(storage, current, activity) orelse continue;
        const role = coreRole(workout) orelse continue;

        progress.core.scheduled += 1;
        roleProgress(&progress, role).scheduled += 1;
        if (workout.distance_min_km) |minimum| {
            progress.planned_min_km += minimum;
            progress.planned_max_km += workout.distance_max_km orelse minimum;
        } else if (workout.distance_max_km) |maximum| {
            progress.planned_min_km += maximum;
            progress.planned_max_km += maximum;
        } else {
            progress.plans_without_distance += 1;
        }

        const logged = activity orelse continue;
        progress.core.recorded += 1;
        const role_progress = roleProgress(&progress, role);
        role_progress.recorded += 1;
        switch (logged.status) {
            .completed => {
                if (logged.sport == .cycling) {
                    progress.cycling_substitutions += 1;
                    role_progress.cycling_substitutions += 1;
                } else {
                    progress.completed += 1;
                    role_progress.completed += 1;
                }
            },
            .modified => {
                progress.modified += 1;
                role_progress.modified += 1;
            },
            .skipped => {
                progress.skipped += 1;
                role_progress.skipped += 1;
            },
            .rested => {
                progress.rested += 1;
                role_progress.rested += 1;
            },
        }
        if (logged.sport == .running) {
            if (logged.distance_km) |distance_km| {
                progress.actual_running_distance_km += distance_km;
            }
        }
    }
    return progress;
}

const RpeRange = struct {
    minimum: u8,
    maximum: u8,
};

const HeartRateSamples = struct {
    values: [maximum_calibration_samples]u16 = undefined,
    len: usize = 0,
};

fn collectCalibration(
    storage: *const store.Store,
    start: date.Date,
    end: date.Date,
) Calibration {
    var easy: HeartRateSamples = .{};
    var quality: HeartRateSamples = .{};
    var long_run: HeartRateSamples = .{};

    var current = start;
    while (date.compare(current, end) != .gt) : (current = date.addDays(current, 1)) {
        const logged = store.latestActivityForDate(storage, current) orelse continue;
        if (logged.status != .completed or logged.sport != .running) continue;
        const heart_rate = logged.average_heart_rate orelse continue;
        const rpe = logged.rpe orelse continue;
        const planned = workoutForObservation(storage, current, logged) orelse continue;
        const role = coreRole(planned) orelse continue;
        const rpe_range = targetRpeRange(role) orelse continue;
        if (rpe < rpe_range.minimum or rpe > rpe_range.maximum) continue;

        const samples = calibrationSamplesForRole(&easy, &quality, &long_run, role) orelse
            continue;
        appendHeartRateSample(samples, heart_rate, role);
    }

    return .{
        .easy = summarizeCalibration(&easy, .{ .minimum = 2, .maximum = 4 }),
        .quality = summarizeCalibration(&quality, .{ .minimum = 6, .maximum = 8 }),
        .long_run = summarizeCalibration(&long_run, .{ .minimum = 2, .maximum = 4 }),
    };
}

fn calibrationSamplesForRole(
    easy: *HeartRateSamples,
    quality: *HeartRateSamples,
    long_run: *HeartRateSamples,
    role: CoreRole,
) ?*HeartRateSamples {
    return switch (role) {
        .easy => easy,
        .quality => quality,
        .long_run => long_run,
        .race => null,
    };
}

fn appendHeartRateSample(samples: *HeartRateSamples, heart_rate: u16, role: CoreRole) void {
    if (samples.len >= samples.values.len) {
        std.log.warn(
            "appendHeartRateSample: calibration capacity reached for {s}; ignoring HR {d}",
            .{ @tagName(role), heart_rate },
        );
        return;
    }
    samples.values[samples.len] = heart_rate;
    samples.len += 1;
}

fn summarizeCalibration(samples: *HeartRateSamples, rpe_range: RpeRange) RoleCalibration {
    var result: RoleCalibration = .{
        .target_rpe_min = rpe_range.minimum,
        .target_rpe_max = rpe_range.maximum,
        .sample_count = @intCast(samples.len),
    };
    if (samples.len < 2) return result;

    insertionSort(samples.values[0..samples.len]);
    const low_index = if (samples.len >= 4) samples.len / 4 else 0;
    const high_index = if (samples.len >= 4)
        (3 * samples.len - 1) / 4
    else
        samples.len - 1;
    result.heart_rate_low = samples.values[low_index];
    result.heart_rate_high = samples.values[high_index];
    return result;
}

fn insertionSort(values: []u16) void {
    var index: usize = 1;
    while (index < values.len) : (index += 1) {
        const value = values[index];
        var insertion_index = index;
        while (insertion_index > 0 and values[insertion_index - 1] > value) {
            values[insertion_index] = values[insertion_index - 1];
            insertion_index -= 1;
        }
        values[insertion_index] = value;
    }
}

fn targetRpeRange(role: CoreRole) ?RpeRange {
    return switch (role) {
        .easy, .long_run => .{ .minimum = 2, .maximum = 4 },
        .quality => .{ .minimum = 6, .maximum = 8 },
        .race => null,
    };
}

fn outperformedPrescription(
    planned: model.Workout,
    logged: model.Activity,
    role: CoreRole,
) bool {
    const rpe_range = targetRpeRange(role) orelse return false;
    const rpe = logged.rpe orelse return false;
    if (rpe > rpe_range.maximum) return false;
    const actual_distance = logged.distance_km orelse return false;
    const actual_duration = logged.duration_seconds orelse return false;
    const planned_minimum = planned.distance_min_km orelse return false;
    const planned_maximum = planned.distance_max_km orelse planned_minimum;
    if (actual_distance < planned_minimum * 0.98 or
        actual_distance > planned_maximum * 1.02)
    {
        return false;
    }

    const estimate = workout_detail.durationEstimate(planned.segments);
    if (!estimate.complete or estimate.minimum_seconds == 0) return false;
    return @as(u64, actual_duration) * 100 <
        @as(u64, estimate.minimum_seconds) * 98;
}

fn latestClosedActivityDate(storage: *const store.Store, as_of: date.Date) date.Date {
    const planned = store.currentWorkout(storage, as_of) orelse return as_of;
    if (!isCoreRun(planned)) return as_of;
    if (store.latestActivityForDate(storage, as_of) != null) return as_of;
    return date.addDays(as_of, -1);
}

fn workoutForObservation(
    storage: *const store.Store,
    target_date: date.Date,
    activity: ?model.Activity,
) ?model.Workout {
    if (activity) |logged| {
        return storage.workouts.get(logged.workout_id) orelse {
            std.log.warn(
                "workoutForObservation: workout {d} referenced by activity {d} on {s} is missing",
                .{ logged.workout_id, logged.id, logged.date },
            );
            return null;
        };
    }
    return store.currentWorkout(storage, target_date);
}

fn isCoreRun(workout: model.Workout) bool {
    return coreRole(workout) != null;
}

fn coreRole(workout: model.Workout) ?CoreRole {
    if (workout.decision) |decision| {
        return switch (decision.allocation_role) {
            .easy => .easy,
            .quality => .quality,
            .long_run => .long_run,
            .race => .race,
            .rest, .optional_recovery => null,
        };
    }
    if (std.mem.eql(u8, workout.kind, "rest") or
        std.mem.eql(u8, workout.kind, "optional-recovery") or
        std.mem.eql(u8, workout.kind, "recovery-or-rest") or
        std.mem.eql(u8, workout.kind, "shakeout"))
    {
        return null;
    }
    if (std.mem.eql(u8, workout.kind, "race")) return .race;
    if (std.mem.eql(u8, workout.kind, "long")) return .long_run;
    if (std.mem.eql(u8, workout.kind, "intervals") or
        std.mem.eql(u8, workout.kind, "tempo") or
        std.mem.eql(u8, workout.kind, "hills") or
        std.mem.eql(u8, workout.kind, "quality") or
        std.mem.eql(u8, workout.kind, "race-pace"))
    {
        return .quality;
    }
    return .easy;
}

fn roleProgress(progress: *Progress, role: CoreRole) *RoleProgress {
    return switch (role) {
        .easy => &progress.easy,
        .quality => &progress.quality,
        .long_run => &progress.long_run,
        .race => &progress.race,
    };
}

pub fn wearablePattern(sleep_score: u8, readiness_score: u8) WearablePattern {
    const sleep_low = sleep_score < low_score_threshold;
    const readiness_low = readiness_score < low_score_threshold;
    if (sleep_low and readiness_low) return .both_limited;
    if (sleep_low) return .sleep_limited;
    if (readiness_low) return .readiness_limited;
    return .balanced;
}

fn laterDate(left: date.Date, right: date.Date) date.Date {
    if (date.compare(left, right) == .gt) return left;
    return right;
}

fn classificationName(classification: Classification) []const u8 {
    return switch (classification) {
        .hold => "HOLD",
        .progress => "PROGRESS",
        .reduce => "REDUCE",
        .replan => "REPLAN",
        .insufficient_data => "INSUFFICIENT_DATA",
    };
}

fn recommendationText(classification: Classification) []const u8 {
    return switch (classification) {
        .hold => "The accumulated data supports continuing the current schedule.",
        .progress => "Repeated low-strain performance suggests the next schedule proposal can progress within policy limits.",
        .reduce => "Effort, recovery, or confirmed-pain signals should constrain the next schedule proposal downward.",
        .replan => "Training disruption has interrupted the planned progression. Reassess the remaining schedule from completed training.",
        .insufficient_data => "There is not enough complete data for a trustworthy adjustment decision.",
    };
}

fn scoreCategory(score: u8) []const u8 {
    if (score >= 85) return "Optimal";
    if (score >= 70) return "Good";
    if (score >= 60) return "Fair";
    return "Pay attention";
}

fn wearablePatternDescription(pattern: WearablePattern) []const u8 {
    return switch (pattern) {
        .balanced => "BALANCED - Sleep and Readiness are both Good or better",
        .sleep_limited => "SLEEP_LIMITED - Sleep is below Good while Readiness remains Good or better",
        .readiness_limited => "READINESS_LIMITED - Readiness is below Good despite adequate Sleep",
        .both_limited => "BOTH_LIMITED - Sleep and Readiness are both below Good",
        .unavailable => "UNAVAILABLE - no complete Oura observation",
    };
}

fn printStatusDetails(writer: *Io.Writer, result: Result) !void {
    var wrote = false;
    if (result.activity_coverage_missing) {
        try writer.print("- Missing core workout outcomes: {d}/{d} recorded.\n", .{
            result.inputs.recorded_core_runs,
            result.inputs.scheduled_core_runs,
        });
        wrote = true;
    }
    if (result.recovery_coverage_missing) {
        try writer.print("- Missing next-morning Oura coverage: {d}/{d} eligible; {d} required.\n", .{
            result.inputs.recorded_recovery_observations,
            result.inputs.eligible_recovery_observations,
            result.required_recovery_observations,
        });
        wrote = true;
    }
    if (result.recent_wearable_coverage_missing) {
        try writer.print("- Current Oura coverage is incomplete: {d}/{d} mornings; {d} required.\n", .{
            result.inputs.recent_wearable_recorded,
            result.inputs.recent_wearable_expected,
            result.required_recent_wearable_observations,
        });
        wrote = true;
    }
    if (result.adherence_rule_fired) {
        try writer.print("- Repeated core-run disruption: {d} modified; {d} skipped or rested.\n", .{
            result.inputs.modified_core_runs,
            result.inputs.skipped_core_runs,
        });
        wrote = true;
    }
    if (result.inputs.cycling_substitutions > 0) {
        try writer.print("- Cycling substitutions: {d}; retained as context, not an automatic reduction signal.\n", .{
            result.inputs.cycling_substitutions,
        });
        wrote = true;
    }
    if (result.pain_constraint_fired) {
        try writer.writeAll("- You confirmed that current pain affects your ability to follow the plan.\n");
        wrote = true;
    }
    if (result.difficulty_rule_fired) {
        try writer.print("- {d} non-race session(s) had RPE 9-10.\n", .{
            result.inputs.unusually_difficult_sessions,
        });
        wrote = true;
    }
    if (result.recovery_persistence_rule_fired) {
        try writer.print(
            "- Persistent Oura signal: Sleep below Good on {d} and Readiness below Good on {d} of the latest {d} mornings.\n",
            .{
                result.inputs.sleep_below_70,
                result.inputs.readiness_below_70,
                recent_wearable_days,
            },
        );
        wrote = true;
    }
    if (result.progression_rule_fired) {
        try writer.print(
            "- Progression evidence: {d} quality sessions below prescribed RPE and {d} sessions faster than the complete pace prescription at intended RPE.\n",
            .{
                result.inputs.easier_quality_sessions,
                result.inputs.outperformed_sessions,
            },
        );
        wrote = true;
    }
    if (!wrote) try writer.writeAll("- Coverage is sufficient; no reduction or progression rule fired.\n");
}

fn printRoleProgress(writer: *Io.Writer, label: []const u8, progress: RoleProgress) !void {
    if (progress.scheduled == 0) return;
    try writer.print(
        "- {s}: {d} running completions, {d} cycling, {d} modified, {d} skipped, {d} rested / {d} scheduled ({d} outcomes recorded)\n",
        .{
            label,
            progress.completed,
            progress.cycling_substitutions,
            progress.modified,
            progress.skipped,
            progress.rested,
            progress.scheduled,
            progress.recorded,
        },
    );
}

fn printRoleCalibration(
    writer: *Io.Writer,
    label: []const u8,
    calibration: RoleCalibration,
    mixed_session: bool,
) !void {
    if (calibration.heart_rate_low == null or calibration.heart_rate_high == null) {
        try writer.print("- {s}: RPE {d}-{d}; {d} usable HR/RPE sample(s), at least 2 required for an observed HR band.\n", .{
            label,
            calibration.target_rpe_min,
            calibration.target_rpe_max,
            calibration.sample_count,
        });
        return;
    }
    try writer.print("- {s}: RPE {d}-{d}; observed session-average HR {d}-{d} bpm from {d} matching runs", .{
        label,
        calibration.target_rpe_min,
        calibration.target_rpe_max,
        calibration.heart_rate_low.?,
        calibration.heart_rate_high.?,
        calibration.sample_count,
    });
    if (mixed_session) {
        try writer.writeAll(" (whole-session only, not the hard repetitions)");
    }
    try writer.writeAll(".\n");
}

fn printDate(writer: *Io.Writer, value: date.Date) !void {
    try writer.print("{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u32, @intCast(value.year)),
        value.month,
        value.day,
    });
}

fn printRule(
    writer: *Io.Writer,
    rule_id: []const u8,
    fired: bool,
    explanation: []const u8,
    basis: []const u8,
) !void {
    try writer.print(
        "- `{s}` - {s}: {s}. Basis: {s}.\n",
        .{
            rule_id,
            if (fired) "FIRED" else "passed",
            explanation,
            basis,
        },
    );
}

test "complete neutral inputs hold the plan" {
    const result = classify(.{
        .scheduled_core_runs = 4,
        .recorded_core_runs = 4,
        .eligible_recovery_observations = 4,
        .recorded_recovery_observations = 2,
        .recent_wearable_expected = 3,
        .recent_wearable_recorded = 3,
    });

    try std.testing.expectEqual(Classification.hold, result.classification);
}

test "historical pain does not select a direction without user confirmation" {
    const unconfirmed = classify(.{
        .scheduled_core_runs = 4,
        .recorded_core_runs = 4,
        .eligible_recovery_observations = 4,
        .recorded_recovery_observations = 4,
        .recent_wearable_expected = 3,
        .recent_wearable_recorded = 3,
        .pain_reports = 1,
        .pain_above_confirmation_threshold = 1,
        .maximum_pain = 5,
    });
    try std.testing.expectEqual(Classification.hold, unconfirmed.classification);
    try std.testing.expect(!unconfirmed.pain_constraint_fired);

    const confirmed = classify(.{
        .scheduled_core_runs = 4,
        .recorded_core_runs = 4,
        .eligible_recovery_observations = 4,
        .recorded_recovery_observations = 4,
        .recent_wearable_expected = 3,
        .recent_wearable_recorded = 3,
        .pain_reports = 1,
        .pain_above_confirmation_threshold = 1,
        .maximum_pain = 5,
        .pain_affects_plan = true,
    });
    try std.testing.expectEqual(Classification.reduce, confirmed.classification);
    try std.testing.expect(confirmed.pain_constraint_fired);
}

test "missing coverage takes precedence over warning signals" {
    const result = classify(.{
        .scheduled_core_runs = 4,
        .recorded_core_runs = 3,
        .eligible_recovery_observations = 4,
        .recorded_recovery_observations = 1,
        .recent_wearable_expected = 3,
        .recent_wearable_recorded = 1,
        .modified_core_runs = 2,
    });

    try std.testing.expectEqual(Classification.insufficient_data, result.classification);
    try std.testing.expect(result.activity_coverage_missing);
    try std.testing.expect(result.recovery_coverage_missing);
    try std.testing.expect(result.recent_wearable_coverage_missing);
    try std.testing.expect(result.adherence_rule_fired);
}

test "one low wearable score does not trigger review" {
    const result = classify(.{
        .scheduled_core_runs = 4,
        .recorded_core_runs = 4,
        .eligible_recovery_observations = 4,
        .recorded_recovery_observations = 4,
        .recent_wearable_expected = 3,
        .recent_wearable_recorded = 3,
        .readiness_below_70 = 1,
    });

    try std.testing.expectEqual(Classification.hold, result.classification);
}

test "repeated low sleep or readiness selects reduction" {
    const result = classify(.{
        .scheduled_core_runs = 4,
        .recorded_core_runs = 4,
        .eligible_recovery_observations = 4,
        .recorded_recovery_observations = 4,
        .recent_wearable_expected = 3,
        .recent_wearable_recorded = 3,
        .sleep_below_70 = 2,
    });

    try std.testing.expectEqual(Classification.reduce, result.classification);
    try std.testing.expect(result.recovery_persistence_rule_fired);
}

test "repeated easier sessions select progression" {
    const result = classify(.{
        .scheduled_core_runs = 8,
        .recorded_core_runs = 8,
        .eligible_recovery_observations = 8,
        .recorded_recovery_observations = 6,
        .recent_wearable_expected = 3,
        .recent_wearable_recorded = 3,
        .easier_quality_sessions = 2,
    });

    try std.testing.expectEqual(Classification.progress, result.classification);
    try std.testing.expect(result.progression_rule_fired);
}

test "disruption requests replanning without assuming reduced load" {
    var inputs: Inputs = .{
        .scheduled_core_runs = 16,
        .recorded_core_runs = 16,
        .eligible_recovery_observations = 16,
        .recorded_recovery_observations = 16,
        .recent_wearable_expected = 3,
        .recent_wearable_recorded = 3,
        .skipped_core_runs = 8,
        .easier_quality_sessions = 2,
    };
    try std.testing.expectEqual(Classification.replan, classify(inputs).classification);
    inputs.readiness_below_70 = 2;
    try std.testing.expectEqual(Classification.reduce, classify(inputs).classification);
    inputs.recorded_core_runs = 15;
    try std.testing.expectEqual(Classification.insufficient_data, classify(inputs).classification);
    inputs.recorded_core_runs = 16;
    inputs.readiness_below_70 = 0;
    inputs.skipped_core_runs = 1;
    inputs.easier_quality_sessions = 0;
    try std.testing.expectEqual(Classification.hold, classify(inputs).classification);
    inputs.skipped_core_runs = 0;
    inputs.modified_core_runs = 2;
    try std.testing.expectEqual(Classification.replan, classify(inputs).classification);
}

test "reduction signals take precedence over progression" {
    const result = classify(.{
        .scheduled_core_runs = 8,
        .recorded_core_runs = 8,
        .eligible_recovery_observations = 8,
        .recorded_recovery_observations = 6,
        .recent_wearable_expected = 3,
        .recent_wearable_recorded = 3,
        .easier_quality_sessions = 2,
        .readiness_below_70 = 2,
    });

    try std.testing.expectEqual(Classification.reduce, result.classification);
}

test "heart rate calibration uses a central observed band" {
    var samples: HeartRateSamples = .{};
    for ([_]u16{ 150, 120, 145, 140, 155, 135, 148, 142 }) |heart_rate| {
        appendHeartRateSample(&samples, heart_rate, .easy);
    }
    const calibration = summarizeCalibration(&samples, .{ .minimum = 2, .maximum = 4 });

    try std.testing.expectEqual(@as(?u16, 140), calibration.heart_rate_low);
    try std.testing.expectEqual(@as(?u16, 150), calibration.heart_rate_high);
    try std.testing.expectEqual(@as(u16, 8), calibration.sample_count);
}

test "wearable patterns preserve sleep and readiness disagreement" {
    try std.testing.expectEqual(WearablePattern.balanced, wearablePattern(80, 80));
    try std.testing.expectEqual(WearablePattern.sleep_limited, wearablePattern(65, 80));
    try std.testing.expectEqual(WearablePattern.readiness_limited, wearablePattern(80, 65));
    try std.testing.expectEqual(WearablePattern.both_limited, wearablePattern(65, 65));
}
