const std = @import("std");
const assessment = @import("assessment.zig");
const date = @import("date.zig");
const model = @import("model.zig");
const store = @import("store.zig");
const training_review = @import("training_review.zig");
const workout_detail = @import("workout.zig");

const Io = std.Io;

pub const Summary = struct {
    planned_days: u32 = 0,
    completed: u32 = 0,
    modified: u32 = 0,
    skipped: u32 = 0,
    rested: u32 = 0,
    unrecorded: u32 = 0,
    actual_distance_km: f64 = 0,
    cycling_distance_km: f64 = 0,
    cycling_sessions: u32 = 0,
    actual_duration_seconds: u64 = 0,
    planned_min_km: f64 = 0,
    planned_max_km: f64 = 0,
    plans_without_distance: u32 = 0,
    easy_distance_km: f64 = 0,
    quality_distance_km: f64 = 0,
    long_distance_km: f64 = 0,
    rpe_sum: u32 = 0,
    rpe_count: u32 = 0,
    feeling_sum: u32 = 0,
    feeling_count: u32 = 0,
    heart_rate_sum: u64 = 0,
    heart_rate_count: u32 = 0,
    pain_reports: u32 = 0,
    max_pain: u8 = 0,
    sleep_score_sum: u32 = 0,
    sleep_score_count: u32 = 0,
    readiness_score_sum: u32 = 0,
    readiness_score_count: u32 = 0,
    sleep_below_70: u32 = 0,
    readiness_below_70: u32 = 0,
};

pub fn calculate(
    storage: *const store.Store,
    start: date.Date,
    end: date.Date,
) Summary {
    var summary: Summary = .{};
    var current = start;
    while (date.compare(current, end) != .gt) : (current = date.addDays(current, 1)) {
        const logged = store.latestActivityForDate(storage, current);
        const planned = workoutForReport(storage, current, logged);
        if (planned) |workout| {
            summary.planned_days += 1;
            if (workout.distance_min_km) |value| {
                summary.planned_min_km += value;
            } else {
                summary.plans_without_distance += 1;
            }
            if (workout.distance_max_km) |value| summary.planned_max_km += value;
        }

        if (logged) |activity| {
            if (activity.sport == .cycling) summary.cycling_sessions += 1;
            switch (activity.status) {
                .completed => summary.completed += 1,
                .modified => summary.modified += 1,
                .skipped => summary.skipped += 1,
                .rested => summary.rested += 1,
            }
            if (activity.distance_km) |distance_km| {
                if (activity.sport == .cycling) {
                    summary.cycling_distance_km += distance_km;
                } else {
                    summary.actual_distance_km += distance_km;
                    if (planned) |workout| addCategoryDistance(&summary, workout.kind, distance_km);
                }
            }
            if (activity.duration_seconds) |seconds| summary.actual_duration_seconds += seconds;
            if (activity.rpe) |value| {
                summary.rpe_sum += value;
                summary.rpe_count += 1;
            }
            if (activity.feeling) |value| {
                summary.feeling_sum += value;
                summary.feeling_count += 1;
            }
            if (activity.average_heart_rate) |value| {
                summary.heart_rate_sum += value;
                summary.heart_rate_count += 1;
            }
            if (activity.pain) |value| {
                if (value > 0) summary.pain_reports += 1;
                summary.max_pain = @max(summary.max_pain, value);
            }
        } else if (planned != null) {
            summary.unrecorded += 1;
        }

        if (store.latestCheckInForDate(storage, current)) |morning| {
            summary.sleep_score_sum += morning.sleep_score;
            summary.sleep_score_count += 1;
            summary.readiness_score_sum += morning.readiness_score;
            summary.readiness_score_count += 1;
            if (morning.sleep_score < 70) summary.sleep_below_70 += 1;
            if (morning.readiness_score < 70) summary.readiness_below_70 += 1;
        }
    }
    return summary;
}

pub fn printSchedule(
    writer: *Io.Writer,
    storage: *const store.Store,
    start: date.Date,
    weeks: u8,
) !void {
    const days: i32 = @as(i32, weeks) * 7;
    const end = date.addDays(start, days - 1);
    try writer.writeAll("Upcoming running schedule: ");
    try printDate(writer, start);
    try writer.writeAll(" through ");
    try printDate(writer, end);
    try writer.writeByte('\n');

    var previous_week: ?u8 = null;
    var current = start;
    while (date.compare(current, end) != .gt) : (current = date.addDays(current, 1)) {
        const active_schedule = store.effectiveSchedule(storage, current);
        const workout = store.currentWorkout(storage, current);
        if (workout) |planned| {
            if (previous_week == null or previous_week.? != planned.week) {
                try writer.print("\nWeek {d} — {s} phase — schedule #{d}\n", .{
                    planned.week,
                    planned.phase,
                    active_schedule.?.id,
                });
                previous_week = planned.week;
            }
            try writer.print("{s} {s}: {s}", .{ planned.date, planned.day, planned.kind });
            if (planned.distance_min_km != null or planned.distance_max_km != null) {
                try writer.writeAll(" — ");
                try printDistanceRange(writer, planned.distance_min_km, planned.distance_max_km);
            }
            try writer.print("\n  Intensity: {s}\n  {s}\n", .{ planned.intensity, planned.details });
            try workout_detail.printDetails(writer, planned, "  ");
        } else {
            try printDate(writer, current);
            try writer.writeAll(": no planned workout\n");
        }
    }
}

pub fn printHistory(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    storage: *const store.Store,
    start: date.Date,
    end: date.Date,
) !void {
    try writer.writeAll(
        "DATE        PLAN (schedule/workout)                 ACTUAL\n" ++
            "----------  --------------------------------------  ----------------------------------------\n",
    );

    var current = start;
    while (date.compare(current, end) != .gt) : (current = date.addDays(current, 1)) {
        const date_text = try date.format(allocator, current);
        const logged = store.latestActivityForDate(storage, current);
        const planned = workoutForReport(storage, current, logged);
        const schedule_id = scheduleIdForReport(storage, current, logged);

        if (planned) |workout| {
            try writer.print(
                "{s}  {s} [s{d}/w{d}]",
                .{ date_text, workout.kind, schedule_id, workout.id },
            );
            try padTo(writer, workout.kind.len + digits(schedule_id) + digits(workout.id) + 9, 38);
        } else {
            try writer.print("{s}  —", .{date_text});
            try padTo(writer, 1, 38);
        }

        if (logged) |activity| {
            try printActivity(writer, activity);
            if (store.latestCheckInForDate(storage, date.addDays(current, 1))) |morning| {
                try writer.print(
                    "            Next morning Oura: Sleep {d}, Readiness {d}",
                    .{ morning.sleep_score, morning.readiness_score },
                );
                if (morning.notes.len != 0) try writer.print(", {s}", .{morning.notes});
                try writer.writeByte('\n');
            }
        } else {
            try writer.writeAll("—\n");
        }
    }
}

pub fn printComparison(
    writer: *Io.Writer,
    storage: *const store.Store,
    start: date.Date,
    end: date.Date,
    previous_start: date.Date,
    previous_end: date.Date,
) !void {
    const current = calculate(storage, start, end);
    const previous = calculate(storage, previous_start, previous_end);

    try writer.print("Running comparison: {d} days\n\n", .{date.daysBetween(start, end) + 1});
    try printSummary(writer, current);
    try writer.writeAll("\nSignals for review:\n");
    try printSignals(writer, current, previous);
}

pub fn printMarkdown(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    storage: *const store.Store,
    start: date.Date,
    end: date.Date,
) !void {
    const current = calculate(storage, start, end);
    const period_days = date.daysBetween(start, end) + 1;
    const previous_end = date.addDays(start, -1);
    const previous_start = date.addDays(previous_end, -(period_days - 1));
    const previous = calculate(storage, previous_start, previous_end);
    const start_text = try date.format(allocator, start);
    const end_text = try date.format(allocator, end);

    try writer.writeAll("# Running training check-in\n\n");
    try writer.print("Period: {s} through {s}\n\n", .{ start_text, end_text });

    if (store.effectiveSchedule(storage, end)) |active_schedule| {
        try writer.writeAll("## Training context\n\n");
        try writer.print("- Goal: {s}\n", .{active_schedule.goal});
        try writer.print("- Baseline: {s}\n", .{active_schedule.baseline});
        try writer.print("- Availability: {s}\n", .{active_schedule.availability});
        try writer.print("- Intensity guidance: {s}\n", .{active_schedule.intensity_guidance});
        if (active_schedule.pace_profile.len != 0) {
            try writer.print("- Pace profile: {s}\n", .{active_schedule.pace_profile});
        }
        if (active_schedule.race_date.len != 0) {
            try writer.print("- Race date: {s}\n", .{active_schedule.race_date});
            const race_date = try date.parse(active_schedule.race_date);
            try writer.print("- Time from period end to race: {d} days\n", .{
                @max(0, date.daysBetween(end, race_date)),
            });
        }
        try writer.print("- Active schedule at period end: #{d} — {s}\n", .{
            active_schedule.id,
            active_schedule.name,
        });
        if (active_schedule.plan_provenance) |provenance| {
            try writer.print(
                "- Planner: {s}; profile `{s}`; policy `{s}` v{d}; evidence `{s}`\n",
                .{
                    provenance.generator_version,
                    provenance.assessment.profile_id,
                    provenance.assessment.policy_id,
                    provenance.assessment.policy_version,
                    provenance.evidence_ledger_id,
                },
            );
            try writer.print(
                "- Source hashes: profile `{s}`; policy `{s}`; evidence `{s}`\n",
                .{
                    provenance.runner_profile_sha256,
                    provenance.training_policy_sha256,
                    provenance.evidence_ledger_sha256,
                },
            );
            try writer.print(
                "- Assessment: confidence {s}; feasibility {s}",
                .{
                    provenance.assessment.confidence,
                    provenance.assessment.feasibility,
                },
            );
            if (provenance.assessment.training_pace_anchor_seconds) |anchor| {
                try writer.writeAll("; training anchor ");
                try printDurationOnly(writer, anchor);
            }
            try writer.writeByte('\n');
            if (assessment.assess(
                provenance.runner_profile,
                provenance.training_policy,
            )) |recomputed| {
                if (recomputed.supported_fast_seconds != null and
                    recomputed.supported_slow_seconds != null)
                {
                    try writer.writeAll("- Supported race-date outcome range: ");
                    try printDurationOnly(writer, recomputed.supported_fast_seconds.?);
                    try writer.writeAll("–");
                    try printDurationOnly(writer, recomputed.supported_slow_seconds.?);
                    try writer.writeByte('\n');
                }
            } else |_| {}
        }
        if (storage.schedules.get(storage.max_schedule_id)) |latest_schedule| {
            try writer.print("- Latest known schedule revision at export time: #{d}, effective {s}\n\n", .{
                latest_schedule.id,
                latest_schedule.effective_from,
            });
        }
    }

    try writer.writeAll("## Schedule revisions\n\n");
    for (storage.schedules.values()) |schedule_revision| {
        const effective = date.parse(schedule_revision.effective_from) catch continue;
        const recorded_on = date.fromUnixTimestampLocal(schedule_revision.recorded_at);
        const timing = if (date.compare(recorded_on, end) == .gt)
            "recorded after this period"
        else if (date.compare(effective, end) == .gt)
            "known upcoming at period end"
        else
            "active by period end";
        try writer.print(
            "- Revision #{d}, effective {s} ({s}): {s}\n",
            .{ schedule_revision.id, schedule_revision.effective_from, timing, schedule_revision.reason },
        );
    }

    try writer.writeAll("\n## Summary\n\n");
    try printSummaryMarkdown(writer, current);
    const review_result = training_review.evaluate(storage, start, end);
    try writer.writeByte('\n');
    try training_review.printMarkdown(
        writer,
        review_result,
        start_text,
        end_text,
    );
    try writer.writeAll("\n## Signals for review\n\n");
    try printSignalsMarkdown(writer, current, previous);
    try writer.writeAll("\n## Daily plan versus reality\n\n");
    try writer.writeAll("| Date | Planned | Actual | Workout signals | Next morning Oura |\n");
    try writer.writeAll("|---|---|---|---|---|\n");

    var current_date = start;
    while (date.compare(current_date, end) != .gt) : (current_date = date.addDays(current_date, 1)) {
        const date_text = try date.format(allocator, current_date);
        const logged = store.latestActivityForDate(storage, current_date);
        const planned = workoutForReport(storage, current_date, logged);

        try writer.print("| {s} | ", .{date_text});
        if (planned) |workout| {
            try writeMarkdownCell(writer, workout.kind);
            try writer.writeAll(": ");
            try writeMarkdownCell(writer, workout.details);
            try writer.print(" (schedule #{d}, workout #{d})", .{
                scheduleIdForReport(storage, current_date, logged),
                workout.id,
            });
        } else {
            try writer.writeAll("No plan");
        }
        try writer.writeAll(" | ");
        if (logged) |activity| {
            try printActivityMarkdown(writer, activity);
            try writer.writeAll(" | ");
            try printSignalsForActivity(writer, activity);
        } else {
            try writer.writeAll("Not recorded | Missing data");
        }
        try writer.writeAll(" | ");
        if (store.latestCheckInForDate(storage, date.addDays(current_date, 1))) |morning| {
            try printCheckInMarkdown(writer, morning);
        } else {
            try writer.writeAll("Not recorded");
        }
        try writer.writeAll(" |\n");
    }

    if (store.effectiveSchedule(storage, end)) |active_schedule| {
        if (active_schedule.plan_provenance) |provenance| {
            const policy = provenance.training_policy;
            try writer.writeAll("\n## Applicable planning guardrails\n\n");
            try writer.print(
                "- `{s}` volume: build increases at most {d:.0}%; peak at most {d:.2} × baseline.\n",
                .{
                    policy.volume_progression.rule_id,
                    policy.volume_progression.maximum_build_increase_fraction * 100,
                    policy.volume_progression.maximum_peak_relative_to_baseline,
                },
            );
            try writer.print(
                "- `{s}` recovery: after {d}–{d} build weeks at {d:.0}–{d:.0}% of prior build volume.\n",
                .{
                    policy.recovery.rule_id,
                    policy.recovery.minimum_build_weeks_between_recovery,
                    policy.recovery.maximum_build_weeks_between_recovery,
                    policy.recovery.minimum_volume_fraction * 100,
                    policy.recovery.maximum_volume_fraction * 100,
                },
            );
            try writer.print(
                "- `{s}` intensity: {d:.0}–{d:.0}% low intensity; at most {d} quality sessions per week.\n",
                .{
                    policy.intensity_distribution.rule_id,
                    policy.intensity_distribution.minimum_low_intensity_fraction * 100,
                    policy.intensity_distribution.maximum_low_intensity_fraction * 100,
                    policy.intensity_distribution.maximum_quality_sessions_per_week,
                },
            );
            const quality = policy.quality_progression;
            try writer.print(
                "- `{s}` quality: at most {d:.0}% of core weekly distance and {d:.1} km per session; progression decisions must remain explicit.\n",
                .{
                    quality.rule_id,
                    quality.maximum_weekly_distance_fraction * 100,
                    quality.maximum_session_distance_km,
                },
            );
            try writer.print(
                "- `{s}` long run: increase at most {d:.1} km; at most {d:.0}% of weekly distance and {d:.1} km.\n",
                .{
                    policy.long_run.rule_id,
                    policy.long_run.maximum_weekly_increase_km,
                    policy.long_run.maximum_weekly_distance_fraction * 100,
                    policy.long_run.maximum_peak_distance_km,
                },
            );
            try writer.print(
                "- `{s}` spacing: at least {d} easy/rest day between demanding sessions; `{s}` optional running remains removable; `{s}` missed work is never stacked.\n",
                .{
                    policy.scheduling.rule_id,
                    policy.scheduling.minimum_easy_or_rest_days_between_demanding_sessions,
                    policy.optional_run.rule_id,
                    policy.missed_workout.rule_id,
                },
            );
            try writer.print(
                "- `{s}` taper: {d}–{d} days with {d:.0}–{d:.0}% volume reduction while retaining frequency and controlled intensity.\n",
                .{
                    policy.taper.rule_id,
                    policy.taper.minimum_days,
                    policy.taper.maximum_days,
                    policy.taper.minimum_volume_reduction_fraction * 100,
                    policy.taper.maximum_volume_reduction_fraction * 100,
                },
            );
        }
    }

    try writer.writeAll("\n## Complete remaining program\n\n");
    try writer.writeAll(
        "This is the full plan after the reporting period, including rest days. " ++
            "Use it together with the evidence above when proposing a replacement program.\n\n",
    );
    var upcoming_date = date.addDays(end, 1);
    const latest_schedule = storage.schedules.get(storage.max_schedule_id);
    const upcoming_end = if (latest_schedule) |latest|
        if (latest.race_date.len != 0) try date.parse(latest.race_date) else end
    else
        end;
    var previous_week: ?u8 = null;
    while (date.compare(upcoming_date, upcoming_end) != .gt) : (upcoming_date = date.addDays(upcoming_date, 1)) {
        if (store.currentWorkout(storage, upcoming_date)) |planned| {
            if (previous_week == null or previous_week.? != planned.week) {
                try writer.print("### Week {d} — {s}\n\n", .{ planned.week, planned.phase });
                previous_week = planned.week;
            }
            try writer.print(
                "#### {s} {s} — {s}\n\n{s}\n\n- Intensity: {s}\n",
                .{ planned.date, planned.day, planned.kind, planned.details, planned.intensity },
            );
            try workout_detail.printDetails(writer, planned, "");
            try writer.print("- Schedule #{d}; workout #{d}\n\n", .{
                planned.schedule_id,
                planned.id,
            });
        } else {
            const upcoming_text = try date.format(allocator, upcoming_date);
            try writer.print("#### {s} — no planned workout\n\n", .{upcoming_text});
        }
    }

    try writer.writeAll(
        "## Whole-program revision contract\n\n" ++
            "If the evidence warrants a change, revise a fresh plan generated by `runningman plan generate`, " ++
            "then save one JSON object for `runningman plan preview FILE`. It must use `schema_version: 2`, " ++
            "preserve the generated `provenance` and `assessment`, include the complete `weeks` macrocycle " ++
            "with a structured `decision` for every week, target the latest schedule with `base_schedule_id`, " ++
            "state `effective_from` and `reason`, and contain `workouts` for every consecutive date " ++
            "from the embedded profile's plan start through race day. Workouts before `effective_from` " ++
            "must remain unchanged. Each workout needs `date`, `phase`, `kind`, " ++
            "`intensity`, `details`, `segments`, and a structured `decision`. Segment pace values are integer seconds per km. " ++
            "A distance segment uses `kind`, `label`, `distance_km`, " ++
            "`pace_fast_seconds_per_km`, and `pace_slow_seconds_per_km`; a timed segment uses " ++
            "`duration_seconds`; repetitions may add `repetitions` and `recovery_seconds`; a rest " ++
            "segment needs `kind: \"rest\"` and `label`. Optional workouts may set workout-level " ++
            "`distance_min_km` and `distance_max_km`. Preview the file before applying it with " ++
            "`runningman plan apply FILE`.\n",
    );
}

pub fn printActivity(writer: *Io.Writer, activity: model.Activity) !void {
    try writer.print("{s}", .{@tagName(activity.status)});
    if (activity.sport == .cycling) try writer.writeAll(", cycling");
    if (activity.distance_km) |value| try writer.print(", {d:.2} km", .{value});
    if (activity.duration_seconds) |value| try printDuration(writer, value);
    if (activity.average_heart_rate) |value| try writer.print(", avg HR {d}", .{value});
    if (activity.rpe) |value| try writer.print(", RPE {d}/10", .{value});
    if (activity.feeling) |value| try writer.print(", feel {d}/5", .{value});
    if (activity.pain) |value| try writer.print(", pain {d}/10", .{value});
    if (activity.deviation_reason.len != 0) try writer.print(", reason: {s}", .{activity.deviation_reason});
    if (activity.notes.len != 0) try writer.print(", {s}", .{activity.notes});
    try writer.writeByte('\n');
}

fn printSummary(writer: *Io.Writer, summary: Summary) !void {
    try writer.print(
        "Outcomes: {d} completed, {d} modified, {d} skipped, {d} rested, {d} unrecorded\n",
        .{ summary.completed, summary.modified, summary.skipped, summary.rested, summary.unrecorded },
    );
    try writer.print("Actual running distance: {d:.2} km\n", .{summary.actual_distance_km});
    if (summary.cycling_sessions > 0) {
        try writer.print(
            "Cycling substitutions: {d} sessions, {d:.2} recorded km\n",
            .{ summary.cycling_sessions, summary.cycling_distance_km },
        );
    }
    try writer.print(
        "Planned distance represented in structured fields: {d:.1}–{d:.1} km ({d} workouts have no numeric target)\n",
        .{ summary.planned_min_km, summary.planned_max_km, summary.plans_without_distance },
    );
    try writer.print(
        "Actual distribution: easy {d:.2} km, quality {d:.2} km, long {d:.2} km\n",
        .{ summary.easy_distance_km, summary.quality_distance_km, summary.long_distance_km },
    );
    try writer.print("Actual duration: ", .{});
    try printDurationOnly(writer, summary.actual_duration_seconds);
    try writer.writeByte('\n');
    try printAverages(writer, summary);
}

fn printSummaryMarkdown(writer: *Io.Writer, summary: Summary) !void {
    try writer.print(
        "- Outcomes: {d} completed, {d} modified, {d} skipped, {d} rested, {d} unrecorded\n",
        .{ summary.completed, summary.modified, summary.skipped, summary.rested, summary.unrecorded },
    );
    try writer.print("- Actual running distance: {d:.2} km\n", .{summary.actual_distance_km});
    if (summary.cycling_sessions > 0) {
        try writer.print(
            "- Cycling substitutions: {d} sessions; {d:.2} recorded km\n",
            .{ summary.cycling_sessions, summary.cycling_distance_km },
        );
    }
    try writer.print(
        "- Structured planned distance: {d:.1}–{d:.1} km; {d} workouts have no numeric target\n",
        .{ summary.planned_min_km, summary.planned_max_km, summary.plans_without_distance },
    );
    try writer.print(
        "- Actual distance distribution: easy {d:.2} km; quality {d:.2} km; long {d:.2} km\n",
        .{ summary.easy_distance_km, summary.quality_distance_km, summary.long_distance_km },
    );
    try writer.writeAll("- Actual duration: ");
    try printDurationOnly(writer, summary.actual_duration_seconds);
    try writer.writeByte('\n');
    if (summary.rpe_count > 0) try writer.print(
        "- Average RPE: {d:.1}/10\n",
        .{@as(f64, @floatFromInt(summary.rpe_sum)) / @as(f64, @floatFromInt(summary.rpe_count))},
    );
    if (summary.feeling_count > 0) try writer.print(
        "- Average post-run feeling: {d:.1}/5\n",
        .{@as(f64, @floatFromInt(summary.feeling_sum)) / @as(f64, @floatFromInt(summary.feeling_count))},
    );
    if (summary.heart_rate_count > 0) try writer.print(
        "- Average of recorded average heart rates: {d:.0} bpm\n",
        .{@as(f64, @floatFromInt(summary.heart_rate_sum)) / @as(f64, @floatFromInt(summary.heart_rate_count))},
    );
    try writer.print("- Pain reports above zero: {d}; maximum {d}/10\n", .{
        summary.pain_reports,
        summary.max_pain,
    });
    if (summary.sleep_score_count > 0) try writer.print(
        "- Average Oura Sleep Score: {d:.1}/100; {d} mornings below 70\n",
        .{
            @as(f64, @floatFromInt(summary.sleep_score_sum)) /
                @as(f64, @floatFromInt(summary.sleep_score_count)),
            summary.sleep_below_70,
        },
    );
    if (summary.readiness_score_count > 0) try writer.print(
        "- Average Oura Readiness Score: {d:.1}/100; {d} mornings below 70\n",
        .{
            @as(f64, @floatFromInt(summary.readiness_score_sum)) /
                @as(f64, @floatFromInt(summary.readiness_score_count)),
            summary.readiness_below_70,
        },
    );
}

fn printAverages(writer: *Io.Writer, summary: Summary) !void {
    if (summary.rpe_count > 0) try writer.print(
        "Average RPE: {d:.1}/10\n",
        .{@as(f64, @floatFromInt(summary.rpe_sum)) / @as(f64, @floatFromInt(summary.rpe_count))},
    );
    if (summary.feeling_count > 0) try writer.print(
        "Average feeling: {d:.1}/5\n",
        .{@as(f64, @floatFromInt(summary.feeling_sum)) / @as(f64, @floatFromInt(summary.feeling_count))},
    );
    if (summary.heart_rate_count > 0) try writer.print(
        "Average of average heart rates: {d:.0} bpm\n",
        .{@as(f64, @floatFromInt(summary.heart_rate_sum)) / @as(f64, @floatFromInt(summary.heart_rate_count))},
    );
    try writer.print("Pain reports: {d}, maximum pain {d}/10\n", .{
        summary.pain_reports,
        summary.max_pain,
    });
    if (summary.sleep_score_count > 0) try writer.print(
        "Average Oura Sleep Score: {d:.1}/100\n",
        .{@as(f64, @floatFromInt(summary.sleep_score_sum)) /
            @as(f64, @floatFromInt(summary.sleep_score_count))},
    );
    if (summary.readiness_score_count > 0) try writer.print(
        "Average Oura Readiness Score: {d:.1}/100\n",
        .{@as(f64, @floatFromInt(summary.readiness_score_sum)) /
            @as(f64, @floatFromInt(summary.readiness_score_count))},
    );
}

fn printSignals(writer: *Io.Writer, current: Summary, previous: Summary) !void {
    var signal_count: u8 = 0;
    if (previous.actual_distance_km > 0) {
        const change = (current.actual_distance_km - previous.actual_distance_km) /
            previous.actual_distance_km * 100;
        try writer.print("- Mileage changed {d:.1}% from the preceding equal-length period.\n", .{change});
        signal_count += 1;
    }
    if (current.modified + current.skipped > 0) {
        try writer.print("- {d} workouts were modified or skipped.\n", .{current.modified + current.skipped});
        signal_count += 1;
    }
    if (current.pain_reports > 0) {
        try writer.print("- Pain was reported {d} times; maximum {d}/10.\n", .{
            current.pain_reports,
            current.max_pain,
        });
        signal_count += 1;
    }
    if (current.unrecorded > 0) {
        try writer.print("- {d} planned days have no record; do not assume they were rest days.\n", .{current.unrecorded});
        signal_count += 1;
    }
    if (current.readiness_below_70 > 0) {
        try writer.print("- Oura Readiness was below 70 on {d} mornings.\n", .{current.readiness_below_70});
        signal_count += 1;
    }
    if (current.sleep_below_70 > 0) {
        try writer.print("- Oura Sleep Score was below 70 on {d} mornings.\n", .{current.sleep_below_70});
        signal_count += 1;
    }
    if (signal_count == 0) try writer.writeAll("- No automatic warning signal was identified; review the daily notes and context.\n");
}

fn printSignalsMarkdown(writer: *Io.Writer, current: Summary, previous: Summary) !void {
    try printSignals(writer, current, previous);
    try writer.writeAll("- Heart rate should be interpreted with pace, workout type, terrain, conditions, and RPE; average HR alone is not a recovery verdict.\n");
}

fn printActivityMarkdown(writer: *Io.Writer, activity: model.Activity) !void {
    try writer.print("{s}", .{@tagName(activity.status)});
    if (activity.sport == .cycling) try writer.writeAll("; cycling");
    if (activity.distance_km) |value| try writer.print("; {d:.2} km", .{value});
    if (activity.duration_seconds) |value| {
        try writer.writeAll("; ");
        try printDurationOnly(writer, value);
    }
}

fn printCheckInMarkdown(writer: *Io.Writer, morning: model.MorningCheckIn) !void {
    try writer.print(
        "Sleep {d}/100; Readiness {d}/100",
        .{ morning.sleep_score, morning.readiness_score },
    );
    if (morning.notes.len != 0) {
        try writer.writeAll("; ");
        try writeMarkdownCell(writer, morning.notes);
    }
}

fn printSignalsForActivity(writer: *Io.Writer, activity: model.Activity) !void {
    var wrote = false;
    if (activity.rpe) |value| {
        try writer.print("RPE {d}/10", .{value});
        wrote = true;
    }
    if (activity.feeling) |value| {
        if (wrote) try writer.writeAll("; ");
        try writer.print("feeling {d}/5", .{value});
        wrote = true;
    }
    if (activity.average_heart_rate) |value| {
        if (wrote) try writer.writeAll("; ");
        try writer.print("avg HR {d}", .{value});
        wrote = true;
    }
    if (activity.pain) |value| {
        if (wrote) try writer.writeAll("; ");
        try writer.print("pain {d}/10", .{value});
        if (activity.pain_location.len != 0) {
            try writer.writeAll(" (");
            try writeMarkdownCell(writer, activity.pain_location);
            try writer.writeByte(')');
        }
        wrote = true;
    }
    if (activity.deviation_reason.len != 0) {
        if (wrote) try writer.writeAll("; ");
        try writer.writeAll("reason: ");
        try writeMarkdownCell(writer, activity.deviation_reason);
        wrote = true;
    }
    if (activity.notes.len != 0) {
        if (wrote) try writer.writeAll("; ");
        try writeMarkdownCell(writer, activity.notes);
        wrote = true;
    }
    if (!wrote) try writer.writeAll("No subjective signals recorded");
}

fn workoutForReport(
    storage: *const store.Store,
    target_date: date.Date,
    logged: ?model.Activity,
) ?model.Workout {
    if (logged) |activity| return storage.workouts.get(activity.workout_id);
    return store.currentWorkout(storage, target_date);
}

fn scheduleIdForReport(
    storage: *const store.Store,
    target_date: date.Date,
    logged: ?model.Activity,
) u64 {
    if (logged) |activity| return activity.schedule_id;
    const active_schedule = store.effectiveSchedule(storage, target_date) orelse return 0;
    return active_schedule.id;
}

fn addCategoryDistance(summary: *Summary, kind: []const u8, distance_km: f64) void {
    if (std.mem.eql(u8, kind, "long")) {
        summary.long_distance_km += distance_km;
    } else if (std.mem.eql(u8, kind, "intervals") or
        std.mem.eql(u8, kind, "hills") or
        std.mem.eql(u8, kind, "tempo"))
    {
        summary.quality_distance_km += distance_km;
    } else {
        summary.easy_distance_km += distance_km;
    }
}

fn printDuration(writer: *Io.Writer, seconds: u64) !void {
    try writer.writeAll(", ");
    try printDurationOnly(writer, seconds);
}

fn printDurationOnly(writer: *Io.Writer, seconds: u64) !void {
    try writer.print(
        "{d}:{d:0>2}:{d:0>2}",
        .{ seconds / 3600, @mod(seconds / 60, 60), @mod(seconds, 60) },
    );
}

fn printDistanceRange(writer: *Io.Writer, minimum: ?f64, maximum: ?f64) !void {
    if (minimum != null and maximum != null and minimum.? == maximum.?) {
        try writer.print("{d:.1} km", .{minimum.?});
    } else if (minimum != null and maximum != null) {
        try writer.print("{d:.1}–{d:.1} km", .{ minimum.?, maximum.? });
    } else if (minimum) |value| {
        try writer.print("at least {d:.1} km", .{value});
    } else if (maximum) |value| {
        try writer.print("up to {d:.1} km", .{value});
    }
}

fn printDate(writer: *Io.Writer, value: date.Date) !void {
    try writer.print("{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u32, @intCast(value.year)),
        value.month,
        value.day,
    });
}

fn padTo(writer: *Io.Writer, current: usize, target: usize) !void {
    if (current >= target) {
        try writer.writeByte(' ');
        return;
    }
    for (current..target) |_| try writer.writeByte(' ');
}

fn digits(value: u64) usize {
    if (value == 0) return 1;
    return std.math.log10_int(value) + 1;
}

fn writeMarkdownCell(writer: *Io.Writer, text: []const u8) !void {
    for (text) |character| {
        switch (character) {
            '|' => try writer.writeAll("\\|"),
            '\n' => try writer.writeAll("<br>"),
            '\r' => {},
            else => try writer.writeByte(character),
        }
    }
}
