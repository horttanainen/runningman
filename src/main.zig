const std = @import("std");
const activity = @import("activity.zig");
const assessment = @import("assessment.zig");
const check_in = @import("check_in.zig");
const date = @import("date.zig");
const evidence_ledger = @import("evidence_ledger.zig");
const model = @import("model.zig");
const plan_explanation = @import("plan_explanation.zig");
const plan_generator = @import("plan_generator.zig");
const plan_markdown = @import("plan_markdown.zig");
const plan_provenance = @import("plan_provenance.zig");
const plan_revision = @import("plan_revision.zig");
const plan_validator = @import("plan_validator.zig");
const report = @import("report.zig");
const runner_profile = @import("runner_profile.zig");
const schedule = @import("schedule.zig");
const store = @import("store.zig");
const training_policy = @import("training_policy.zig");
const workout_detail = @import("workout.zig");

const Io = std.Io;
const default_data_path = "runningman-data.jsonl";
const default_policy_path = "policies/half-marathon.json";
const default_evidence_path = "evidence/half-marathon.json";

const LogCommand = struct {
    target_date: date.Date,
    input: activity.Input = .{},
    interactive: bool = false,
};

const CompareCommand = struct {
    weeks: u8 = 4,
    ending: date.Date,
};

const ExportFormat = enum {
    jsonl,
    markdown,
};

const ExportCommand = struct {
    format: ExportFormat = .markdown,
    weeks: u8 = 4,
    ending: date.Date,
};

const CheckInCommand = struct {
    target_date: date.Date,
    sleep_score: ?u8 = null,
    readiness_score: ?u8 = null,
    notes: []const u8 = "",
    interactive: bool = false,
};

const ScheduleCommand = struct {
    weeks: u8 = 4,
    start: date.Date,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout_file_writer.flush() catch {};

    var stderr_buffer: [2048]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
    defer stderr_file_writer.flush() catch {};

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_file_reader: Io.File.Reader = .init(.stdin(), init.io, &stdin_buffer);
    const stdin = &stdin_file_reader.interface;

    run(allocator, init.io, stdin, stdout, args) catch |err| {
        try stderr.print("Error: {s}\n\n", .{friendlyError(err)});
        try printUsage(stderr);
        try stderr_file_writer.flush();
        std.process.exit(1);
    };
}

fn run(
    allocator: std.mem.Allocator,
    io: Io,
    reader: *Io.Reader,
    writer: *Io.Writer,
    args: []const []const u8,
) !void {
    var arg_index: usize = 1;
    var data_path: []const u8 = default_data_path;
    if (arg_index < args.len and std.mem.eql(u8, args[arg_index], "--data")) {
        arg_index += 1;
        if (arg_index >= args.len) return error.MissingDataPath;
        data_path = args[arg_index];
        arg_index += 1;
    }

    const command = if (arg_index < args.len) args[arg_index] else "today";
    if (arg_index < args.len) arg_index += 1;
    const command_args = args[arg_index..];

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) {
        try printUsage(writer);
        return;
    }
    if (std.mem.eql(u8, command, "init")) {
        try commandInit(allocator, io, writer, data_path, command_args);
        return;
    }
    if (std.mem.eql(u8, command, "profile")) {
        try commandProfile(allocator, io, writer, command_args);
        return;
    }
    if (std.mem.eql(u8, command, "evidence")) {
        try commandEvidence(allocator, io, writer, command_args);
        return;
    }
    if (std.mem.eql(u8, command, "policy")) {
        try commandPolicy(allocator, io, writer, command_args);
        return;
    }
    if (std.mem.eql(u8, command, "plan") and command_args.len != 0 and
        std.mem.eql(u8, command_args[0], "assess"))
    {
        try commandPlanAssessment(allocator, io, writer, command_args);
        return;
    }
    var storage: store.Store = .{};
    defer store.deinit(&storage, allocator);
    try store.load(&storage, allocator, io, data_path);
    if (storage.schedules.count() == 0) return error.NotInitialized;

    if (try date.maybeParseReference(command)) |target_date| {
        if (command_args.len != 0) return error.UnexpectedArgument;
        try printDay(writer, &storage, target_date);
    } else if (std.mem.eql(u8, command, "log")) {
        try commandLog(allocator, io, reader, writer, data_path, &storage, command_args);
    } else if (std.mem.eql(u8, command, "check-in")) {
        try commandCheckIn(allocator, io, reader, writer, data_path, &storage, command_args);
    } else if (std.mem.eql(u8, command, "schedule")) {
        try commandSchedule(writer, &storage, command_args);
    } else if (std.mem.eql(u8, command, "history")) {
        try commandHistory(allocator, writer, &storage, command_args);
    } else if (std.mem.eql(u8, command, "compare")) {
        try commandCompare(writer, &storage, command_args);
    } else if (std.mem.eql(u8, command, "plan")) {
        try commandPlan(allocator, io, writer, data_path, &storage, command_args);
    } else if (std.mem.eql(u8, command, "export")) {
        try commandExport(allocator, io, writer, data_path, &storage, command_args);
    } else if (std.mem.eql(u8, command, "review")) {
        try commandExport(allocator, io, writer, data_path, &storage, command_args);
    } else {
        return error.UnknownCommand;
    }
}

fn commandProfile(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    args: []const []const u8,
) !void {
    if (args.len != 2 or !std.mem.eql(u8, args[0], "validate")) {
        return error.InvalidProfileCommand;
    }
    const profile = try runner_profile.load(allocator, io, args[1]);
    const summary = try runner_profile.validate(profile);
    try runner_profile.printSummary(writer, profile, summary);
}

fn commandEvidence(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    args: []const []const u8,
) !void {
    if (args.len != 2 or !std.mem.eql(u8, args[0], "validate")) {
        return error.InvalidEvidenceCommand;
    }
    const ledger = try evidence_ledger.load(allocator, io, args[1]);
    try evidence_ledger.validate(ledger);
    try evidence_ledger.printSummary(writer, ledger);
}

fn commandPolicy(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    args: []const []const u8,
) !void {
    if (args.len < 2 or !std.mem.eql(u8, args[0], "validate")) {
        return error.InvalidPolicyCommand;
    }
    var evidence_path: []const u8 = default_evidence_path;
    try parsePlannerFileFlags(args[2..], null, &evidence_path);

    const ledger = try evidence_ledger.load(allocator, io, evidence_path);
    try evidence_ledger.validate(ledger);
    const policy = try training_policy.load(allocator, io, args[1]);
    try training_policy.validate(policy, ledger);
    try training_policy.printSummary(writer, policy);
}

fn commandPlanAssessment(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    args: []const []const u8,
) !void {
    if (args.len < 2) return error.PlanAssessmentProfileRequired;
    var policy_path: []const u8 = default_policy_path;
    var evidence_path: []const u8 = default_evidence_path;
    try parsePlannerFileFlags(args[2..], &policy_path, &evidence_path);

    const profile = try runner_profile.load(allocator, io, args[1]);
    _ = try runner_profile.validate(profile);
    const ledger = try evidence_ledger.load(allocator, io, evidence_path);
    try evidence_ledger.validate(ledger);
    const policy = try training_policy.load(allocator, io, policy_path);
    try training_policy.validate(policy, ledger);
    const result = try assessment.assess(profile, policy);
    try assessment.print(writer, profile, policy, result);
}

fn parsePlannerFileFlags(
    args: []const []const u8,
    policy_path: ?*[]const u8,
    evidence_path: *[]const u8,
) !void {
    var index: usize = 0;
    while (index < args.len) {
        const flag = args[index];
        index += 1;
        if (index >= args.len) return error.MissingFlagValue;
        const value = args[index];
        index += 1;

        if (std.mem.eql(u8, flag, "--policy") and policy_path != null) {
            policy_path.?.* = value;
        } else if (std.mem.eql(u8, flag, "--evidence")) {
            evidence_path.* = value;
        } else {
            return error.UnknownFlag;
        }
    }
}

fn commandInit(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    data_path: []const u8,
    args: []const []const u8,
) !void {
    var existing: store.Store = .{};
    defer store.deinit(&existing, allocator);
    try store.load(&existing, allocator, io, data_path);
    if (existing.schedules.count() != 0) return error.AlreadyInitialized;

    const start = if (args.len == 0) date.today() else try date.parseReference(args[0]);
    if (args.len > 1) return error.UnexpectedArgument;
    if (date.weekday(start) != 0) return error.StartMustBeMonday;

    const events = try schedule.createInitialEvents(allocator, start, date.unixTimestamp());
    try store.append(io, data_path, events);
    const start_text = try date.format(allocator, start);
    try writer.print(
        "Created an immutable 13-week periodized running schedule starting {s}.\nData: {s}\n",
        .{ start_text, data_path },
    );
    try writer.writeAll("The plan ends with the half marathon on Sunday of week 13.\n\n");

    var initialized: store.Store = .{};
    defer store.deinit(&initialized, allocator);
    try store.load(&initialized, allocator, io, data_path);
    if (store.currentWorkout(&initialized, date.today()) != null) {
        try writer.writeAll("Today's schedule:\n");
        try printDay(writer, &initialized, date.today());
    }
}

fn commandLog(
    allocator: std.mem.Allocator,
    io: Io,
    reader: *Io.Reader,
    writer: *Io.Writer,
    data_path: []const u8,
    storage: *const store.Store,
    args: []const []const u8,
) !void {
    var command = try parseLogCommand(args);
    const previous = store.latestActivityForDate(storage, command.target_date);
    const schedule_id: u64 = if (previous) |existing|
        existing.schedule_id
    else
        (store.effectiveSchedule(storage, command.target_date) orelse
            return error.NoScheduleForDate).id;
    const workout = if (previous) |existing|
        storage.workouts.get(existing.workout_id) orelse return error.NoWorkoutForDate
    else
        store.workoutForDate(storage, schedule_id, command.target_date) orelse
            return error.NoWorkoutForDate;

    if (command.interactive) {
        try writer.print(
            "{s}, {s}: {s}\n{s}\n\n",
            .{ workout.day, workout.date, workout.kind, workout.details },
        );
        command.input = try promptForActivity(allocator, reader, writer);
    }

    const date_text = try date.format(allocator, command.target_date);
    const value = try activity.make(
        storage.max_activity_id + 1,
        if (previous) |existing| existing.id else null,
        schedule_id,
        workout.id,
        date_text,
        command.input,
        date.unixTimestamp(),
    );
    const events = [_]model.Event{model.activityEvent(value)};
    try store.append(io, data_path, &events);

    if (previous != null) {
        try writer.print(
            "Recorded correction #{d} for {s}; it supersedes activity #{d}.\n",
            .{ value.id, value.date, previous.?.id },
        );
    } else {
        try writer.print(
            "Recorded {s} for {s} against schedule #{d}, workout #{d}.\n",
            .{ @tagName(value.status), value.date, value.schedule_id, value.workout_id },
        );
    }
}

fn commandCheckIn(
    allocator: std.mem.Allocator,
    io: Io,
    reader: *Io.Reader,
    writer: *Io.Writer,
    data_path: []const u8,
    storage: *const store.Store,
    args: []const []const u8,
) !void {
    var command = try parseCheckInCommand(args);
    if (command.interactive) {
        const sleep_text = try prompt(allocator, reader, writer, "Oura Sleep Score, 0–100: ");
        const readiness_text = try prompt(allocator, reader, writer, "Oura Readiness Score, 0–100: ");
        command.sleep_score = try std.fmt.parseInt(u8, sleep_text, 10);
        command.readiness_score = try std.fmt.parseInt(u8, readiness_text, 10);
        command.notes = try prompt(allocator, reader, writer, "Morning notes (optional): ");
    }

    const previous = store.latestCheckInForDate(storage, command.target_date);
    const value = try check_in.make(
        storage.max_check_in_id + 1,
        if (previous) |existing| existing.id else null,
        try date.format(allocator, command.target_date),
        .{
            .sleep_score = command.sleep_score orelse return error.SleepScoreRequired,
            .readiness_score = command.readiness_score orelse return error.ReadinessScoreRequired,
            .notes = command.notes,
        },
        date.unixTimestamp(),
    );
    const events = [_]model.Event{model.morningCheckInEvent(value)};
    try store.append(io, data_path, &events);

    if (previous) |existing| {
        try writer.print(
            "Recorded morning check-in #{d} for {s}; it supersedes check-in #{d}.\n",
            .{ value.id, value.date, existing.id },
        );
    } else {
        try writer.print(
            "Recorded Oura Sleep {d} and Readiness {d} for {s}.\n",
            .{ value.sleep_score, value.readiness_score, value.date },
        );
    }
}

fn commandSchedule(
    writer: *Io.Writer,
    storage: *const store.Store,
    args: []const []const u8,
) !void {
    const command = try parseScheduleCommand(args);
    try report.printSchedule(writer, storage, command.start, command.weeks);
}

fn commandHistory(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    storage: *const store.Store,
    args: []const []const u8,
) !void {
    if (args.len > 2) return error.UnexpectedArgument;
    const start = if (args.len >= 1)
        try date.parseReference(args[0])
    else
        store.earliestScheduleDate(storage) orelse return error.NotInitialized;
    const end = if (args.len == 2) try date.parseReference(args[1]) else date.today();
    try validateRange(start, end);
    try report.printHistory(allocator, writer, storage, start, end);
}

fn commandCompare(
    writer: *Io.Writer,
    storage: *const store.Store,
    args: []const []const u8,
) !void {
    const command = try parseCompareCommand(args);
    const days: i32 = @as(i32, command.weeks) * 7;
    const start = date.addDays(command.ending, -(days - 1));
    const previous_end = date.addDays(start, -1);
    const previous_start = date.addDays(previous_end, -(days - 1));
    try report.printComparison(writer, storage, start, command.ending, previous_start, previous_end);
}

fn commandPlan(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    data_path: []const u8,
    storage: *const store.Store,
    args: []const []const u8,
) !void {
    if (args.len == 0) return error.MissingPlanAction;
    const action = args[0];

    if (std.mem.eql(u8, action, "periodize")) {
        if (args.len != 1) return error.UnexpectedArgument;
        const parent = storage.schedules.get(storage.max_schedule_id) orelse
            return error.NoScheduleForDate;
        if (std.mem.eql(u8, parent.name, schedule.initial_name)) {
            return error.PlanAlreadyPeriodized;
        }
        const events = try schedule.createPeriodizedRevisionEvents(
            allocator,
            parent,
            storage.max_schedule_id + 1,
            storage.max_workout_id + 1,
            date.unixTimestamp(),
        );
        try store.append(io, data_path, events);
        try writer.print(
            "Created periodized schedule #{d} with {d} daily entries through race day.\n",
            .{ storage.max_schedule_id + 1, events.len - 1 },
        );
        return;
    }

    if (std.mem.eql(u8, action, "generate")) {
        try commandPlanGenerate(allocator, io, writer, data_path, storage, args[1..]);
        return;
    }
    if (std.mem.eql(u8, action, "explain")) {
        try commandPlanExplain(allocator, io, writer, storage, args[1..]);
        return;
    }
    if (std.mem.eql(u8, action, "markdown")) {
        try commandPlanMarkdown(allocator, io, writer, storage, args[1..]);
        return;
    }

    if (args.len != 2) return error.PlanFileRequired;
    const revision = try plan_revision.load(allocator, io, args[1]);
    try plan_revision.validate(storage, revision);
    const validation = try plan_validator.validateEmbedded(allocator, revision);
    if (std.mem.eql(u8, action, "preview")) {
        try writer.print(
            "Validation passed\n" ++
                "  Embedded profile, policy, provenance, and assessment are consistent.\n" ++
                "  {d} weeks and {d} workouts satisfy {d} policy rules and plan invariants.\n\n",
            .{ validation.weeks, validation.workouts, validation.policy_rules },
        );
        try plan_revision.printPreview(writer, storage, revision);
    } else if (std.mem.eql(u8, action, "apply")) {
        const events = try plan_revision.createEvents(
            allocator,
            storage,
            revision,
            date.unixTimestamp(),
        );
        try store.append(io, data_path, events);
        try writer.print(
            "Applied schedule #{d}, effective {s}, as a complete {d}-day snapshot.\n",
            .{ storage.max_schedule_id + 1, revision.effective_from, events.len - 1 },
        );
    } else {
        return error.UnknownPlanAction;
    }
}

fn commandPlanMarkdown(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    storage: *const store.Store,
    args: []const []const u8,
) !void {
    var proposal_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    var index: usize = 0;
    if (args.len != 0 and !std.mem.startsWith(u8, args[0], "--")) {
        proposal_path = args[0];
        index = 1;
    }
    while (index < args.len) {
        const flag = args[index];
        index += 1;
        if (index >= args.len) return error.MissingFlagValue;
        const value = args[index];
        index += 1;

        if (std.mem.eql(u8, flag, "--output")) {
            output_path = value;
        } else {
            return error.UnknownFlag;
        }
    }

    if (proposal_path) |path| {
        const revision = try plan_revision.load(allocator, io, path);
        try plan_revision.validate(storage, revision);
        _ = try plan_validator.validateEmbedded(allocator, revision);
        if (output_path) |destination| {
            try plan_markdown.saveProposal(io, destination, revision);
            try writer.print(
                "Wrote a friendly {d}-week training plan to {s}.\n",
                .{ revision.weeks.len, destination },
            );
            return;
        }
        try plan_markdown.printProposal(writer, revision);
        return;
    }

    const active_schedule = storage.schedules.get(storage.max_schedule_id) orelse
        return error.NoScheduleForDate;
    if (output_path) |destination| {
        try plan_markdown.saveSchedule(io, destination, storage, active_schedule);
        try writer.print(
            "Wrote a friendly {d}-week training plan to {s}.\n",
            .{ active_schedule.plan_weeks.len, destination },
        );
        return;
    }
    try plan_markdown.printSchedule(writer, storage, active_schedule);
}

fn commandPlanExplain(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    storage: *const store.Store,
    args: []const []const u8,
) !void {
    if (args.len > 2) return error.InvalidPlanExplainCommand;

    var proposal_path: ?[]const u8 = null;
    var target_date: ?date.Date = null;
    if (args.len == 1) {
        if (try date.maybeParseReference(args[0])) |parsed_date| {
            target_date = parsed_date;
        } else {
            proposal_path = args[0];
        }
    } else if (args.len == 2) {
        if (try date.maybeParseReference(args[0]) != null) return error.InvalidPlanExplainCommand;

        proposal_path = args[0];
        target_date = (try date.maybeParseReference(args[1])) orelse
            return error.InvalidPlanExplainCommand;
    }

    if (proposal_path) |path| {
        const revision = try plan_revision.load(allocator, io, path);
        try plan_revision.validate(storage, revision);
        _ = try plan_validator.validateEmbedded(allocator, revision);
        try plan_explanation.printProposal(writer, revision, target_date);
        return;
    }

    const schedule_value = if (target_date) |target|
        store.effectiveSchedule(storage, target) orelse return error.NoScheduleForDate
    else
        storage.schedules.get(storage.max_schedule_id) orelse return error.NoScheduleForDate;
    try plan_explanation.printSchedule(writer, storage, schedule_value, target_date);
}

fn commandPlanGenerate(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    data_path: []const u8,
    storage: *const store.Store,
    args: []const []const u8,
) !void {
    if (args.len == 0) return error.PlanGenerationProfileRequired;
    const profile_path = args[0];
    var policy_path: []const u8 = default_policy_path;
    var evidence_path: []const u8 = default_evidence_path;
    var output_path: ?[]const u8 = null;

    var index: usize = 1;
    while (index < args.len) {
        const flag = args[index];
        index += 1;
        if (index >= args.len) return error.MissingFlagValue;
        const value = args[index];
        index += 1;

        if (std.mem.eql(u8, flag, "--policy")) {
            policy_path = value;
        } else if (std.mem.eql(u8, flag, "--evidence")) {
            evidence_path = value;
        } else if (std.mem.eql(u8, flag, "--output")) {
            output_path = value;
        } else {
            return error.UnknownFlag;
        }
    }
    const destination = output_path orelse return error.PlanGenerationOutputRequired;

    const profile = try runner_profile.load(allocator, io, profile_path);
    _ = try runner_profile.validate(profile);
    const ledger = try evidence_ledger.load(allocator, io, evidence_path);
    try evidence_ledger.validate(ledger);
    const policy = try training_policy.load(allocator, io, policy_path);
    try training_policy.validate(policy, ledger);
    const result = try assessment.assess(profile, policy);
    const source_hashes: plan_provenance.SourceHashes = .{
        .runner_profile_sha256 = try plan_provenance.hashFile(allocator, io, profile_path),
        .training_policy_sha256 = try plan_provenance.hashFile(allocator, io, policy_path),
        .evidence_ledger_sha256 = try plan_provenance.hashFile(allocator, io, evidence_path),
    };
    const revision = try plan_generator.generate(
        allocator,
        profile,
        policy,
        result,
        ledger.ledger_id,
        source_hashes,
        storage.max_schedule_id,
    );
    try plan_generator.save(io, destination, revision);
    try writer.print(
        "Generated a validated {d}-day plan through {s}.\n" ++
            "Proposal: {s}\n",
        .{ revision.workouts.len, revision.race_date, destination },
    );
    if (std.mem.eql(u8, data_path, default_data_path)) {
        try writer.print(
            "Review it with: runningman plan preview {s}\n",
            .{destination},
        );
    } else {
        try writer.print(
            "Review it with: runningman --data {s} plan preview {s}\n",
            .{ data_path, destination },
        );
    }
}

fn commandExport(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    data_path: []const u8,
    storage: *const store.Store,
    args: []const []const u8,
) !void {
    const command = try parseExportCommand(args);
    if (command.format == .jsonl) {
        try exportJsonl(allocator, io, writer, data_path);
        return;
    }

    const days: i32 = @as(i32, command.weeks) * 7;
    const start = date.addDays(command.ending, -(days - 1));
    try report.printMarkdown(allocator, writer, storage, start, command.ending);
}

fn exportJsonl(
    allocator: std.mem.Allocator,
    io: Io,
    writer: *Io.Writer,
    data_path: []const u8,
) !void {
    const contents = Io.Dir.cwd().readFileAlloc(
        io,
        data_path,
        allocator,
        .limited(16 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.NotInitialized,
        else => return err,
    };
    try writer.writeAll(contents);
}

fn printDay(writer: *Io.Writer, storage: *const store.Store, target_date: date.Date) !void {
    const active_schedule = store.effectiveSchedule(storage, target_date) orelse
        return error.NoScheduleForDate;
    const planned = store.workoutForDate(storage, active_schedule.id, target_date) orelse
        return error.NoWorkoutForDate;

    try writer.print(
        "{s}, {s} — week {d}, {s} phase\n{s}\nIntensity: {s}",
        .{
            planned.day,
            planned.date,
            planned.week,
            planned.phase,
            planned.details,
            planned.intensity,
        },
    );
    if (planned.distance_min_km != null or planned.distance_max_km != null) {
        try writer.writeAll("\nPlanned distance: ");
        try printDistanceRange(writer, planned.distance_min_km, planned.distance_max_km);
    }
    try writer.writeByte('\n');
    try workout_detail.printDetails(writer, planned, "");
    try writer.print("Schedule #{d}, workout #{d}\n", .{ active_schedule.id, planned.id });

    if (store.latestActivityForDate(storage, target_date)) |logged| {
        try writer.writeAll("Recorded: ");
        try report.printActivity(writer, logged);
    } else {
        try writer.print(
            "\nRecord it interactively:\n  runningman log {s}\n\n" ++
                "Or record the bicycle replacement:\n  runningman log {s} --sport cycling --duration MM:SS --avg-hr BPM --rpe 1-10 --pain 0-10 --notes \"...\"\n\n" ++
                "Or record the run with flags:\n  runningman log {s} --distance KM --duration MM:SS --avg-hr BPM --rpe 1-10 --pain 0-10 --notes \"...\"\n",
            .{ planned.date, planned.date, planned.date },
        );
    }

    if (store.latestCheckInForDate(storage, target_date)) |morning| {
        try writer.print(
            "Morning Oura: Sleep {d}/100, Readiness {d}/100",
            .{ morning.sleep_score, morning.readiness_score },
        );
        if (morning.notes.len != 0) try writer.print(", {s}", .{morning.notes});
        try writer.writeByte('\n');
    } else {
        try writer.print(
            "\nRecord this morning's Oura scores:\n  runningman check-in {s}\n",
            .{planned.date},
        );
    }
}

fn parseLogCommand(args: []const []const u8) !LogCommand {
    var result: LogCommand = .{ .target_date = date.today() };
    var index: usize = 0;
    if (args.len > 0 and !std.mem.startsWith(u8, args[0], "--")) {
        result.target_date = try date.parseReference(args[0]);
        index = 1;
    }
    if (index == args.len) {
        result.interactive = true;
        return result;
    }

    while (index < args.len) {
        const flag = args[index];
        index += 1;
        if (std.mem.eql(u8, flag, "--skipped")) {
            result.input.status = .skipped;
            continue;
        }
        if (std.mem.eql(u8, flag, "--rested")) {
            result.input.status = .rested;
            continue;
        }
        if (std.mem.eql(u8, flag, "--modified")) {
            result.input.status = .modified;
            continue;
        }
        if (index >= args.len) return error.MissingFlagValue;
        const value = args[index];
        index += 1;

        if (std.mem.eql(u8, flag, "--outcome")) {
            result.input.status = try activity.parseStatus(value);
        } else if (std.mem.eql(u8, flag, "--sport")) {
            result.input.sport = try activity.parseSport(value);
        } else if (std.mem.eql(u8, flag, "--distance")) {
            result.input.distance_km = try parseFloat(value);
        } else if (std.mem.eql(u8, flag, "--duration")) {
            result.input.duration_seconds = try activity.parseDuration(value);
        } else if (std.mem.eql(u8, flag, "--avg-hr")) {
            result.input.average_heart_rate = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, flag, "--ascent-m")) {
            result.input.ascent_meters = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--descent-m")) {
            result.input.descent_meters = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--rpe")) {
            result.input.rpe = try std.fmt.parseInt(u8, value, 10);
        } else if (std.mem.eql(u8, flag, "--pain")) {
            result.input.pain = try std.fmt.parseInt(u8, value, 10);
        } else if (std.mem.eql(u8, flag, "--pain-location")) {
            result.input.pain_location = value;
        } else if (std.mem.eql(u8, flag, "--reason")) {
            result.input.deviation_reason = value;
        } else if (std.mem.eql(u8, flag, "--notes")) {
            result.input.notes = value;
        } else {
            return error.UnknownFlag;
        }
    }
    return result;
}

fn promptForActivity(
    allocator: std.mem.Allocator,
    reader: *Io.Reader,
    writer: *Io.Writer,
) !activity.Input {
    var result: activity.Input = .{};

    const sport_text = try prompt(allocator, reader, writer, "Sport [running/cycling] (running): ");
    if (sport_text.len != 0) result.sport = try activity.parseSport(sport_text);

    const status_text = try prompt(allocator, reader, writer, "Outcome [completed/modified/skipped/rested] (completed): ");
    if (status_text.len != 0) result.status = try activity.parseStatus(status_text);

    const distance_text = try prompt(allocator, reader, writer, "Distance in km (blank if none): ");
    if (distance_text.len != 0) result.distance_km = try parseFloat(distance_text);

    const duration_text = try prompt(allocator, reader, writer, "Duration MINUTES, MM:SS, or HH:MM:SS (blank if none): ");
    if (duration_text.len != 0) result.duration_seconds = try activity.parseDuration(duration_text);

    const heart_rate_text = try prompt(allocator, reader, writer, "Average heart rate (blank if unknown): ");
    if (heart_rate_text.len != 0) result.average_heart_rate = try std.fmt.parseInt(u16, heart_rate_text, 10);

    const ascent_text = try prompt(allocator, reader, writer, "Ascent in metres (blank if unknown): ");
    if (ascent_text.len != 0) result.ascent_meters = try std.fmt.parseInt(u32, ascent_text, 10);

    const descent_text = try prompt(allocator, reader, writer, "Descent in metres (blank if unknown): ");
    if (descent_text.len != 0) result.descent_meters = try std.fmt.parseInt(u32, descent_text, 10);

    const rpe_text = try prompt(allocator, reader, writer, "RPE 1–10 (blank if unknown): ");
    if (rpe_text.len != 0) result.rpe = try std.fmt.parseInt(u8, rpe_text, 10);

    const pain_text = try prompt(allocator, reader, writer, "Pain or discomfort 0–10 (blank means 0): ");
    result.pain = if (pain_text.len == 0) 0 else try std.fmt.parseInt(u8, pain_text, 10);
    if (result.pain.? > 0) {
        result.pain_location = try prompt(allocator, reader, writer, "Pain location (optional): ");
    }

    if (result.status == .modified or result.status == .skipped) {
        result.deviation_reason = try prompt(allocator, reader, writer, "Reason for modifying/skipping: ");
    }
    result.notes = try prompt(allocator, reader, writer, "Notes (optional): ");
    return result;
}

fn prompt(
    allocator: std.mem.Allocator,
    reader: *Io.Reader,
    writer: *Io.Writer,
    label: []const u8,
) ![]const u8 {
    try writer.writeAll(label);
    try writer.flush();
    const line = (try reader.takeDelimiter('\n')) orelse return error.EndOfInput;
    return allocator.dupe(u8, std.mem.trim(u8, line, " \r\t"));
}

fn parseCheckInCommand(args: []const []const u8) !CheckInCommand {
    var result: CheckInCommand = .{ .target_date = date.today() };
    var index: usize = 0;
    if (args.len > 0 and !std.mem.startsWith(u8, args[0], "--")) {
        result.target_date = try date.parseReference(args[0]);
        index = 1;
    }
    if (index == args.len) {
        result.interactive = true;
        return result;
    }

    while (index < args.len) {
        const flag = args[index];
        index += 1;
        if (index >= args.len) return error.MissingFlagValue;
        const value = args[index];
        index += 1;
        if (std.mem.eql(u8, flag, "--sleep")) {
            result.sleep_score = try std.fmt.parseInt(u8, value, 10);
        } else if (std.mem.eql(u8, flag, "--readiness")) {
            result.readiness_score = try std.fmt.parseInt(u8, value, 10);
        } else if (std.mem.eql(u8, flag, "--notes")) {
            result.notes = value;
        } else {
            return error.UnknownFlag;
        }
    }
    return result;
}

fn parseScheduleCommand(args: []const []const u8) !ScheduleCommand {
    var result: ScheduleCommand = .{ .start = date.today() };
    var index: usize = 0;
    while (index < args.len) {
        const flag = args[index];
        index += 1;
        if (index >= args.len) return error.MissingFlagValue;
        const value = args[index];
        index += 1;
        if (std.mem.eql(u8, flag, "--weeks")) {
            result.weeks = try std.fmt.parseInt(u8, value, 10);
            if (result.weeks < 1 or result.weeks > 52) return error.InvalidWeekCount;
        } else if (std.mem.eql(u8, flag, "--from")) {
            result.start = try date.parseReference(value);
        } else {
            return error.UnknownFlag;
        }
    }
    return result;
}

fn parseCompareCommand(args: []const []const u8) !CompareCommand {
    var result: CompareCommand = .{ .ending = date.today() };
    var index: usize = 0;
    while (index < args.len) {
        const flag = args[index];
        index += 1;
        if (index >= args.len) return error.MissingFlagValue;
        const value = args[index];
        index += 1;
        if (std.mem.eql(u8, flag, "--weeks")) {
            result.weeks = try std.fmt.parseInt(u8, value, 10);
            if (result.weeks < 1 or result.weeks > 52) return error.InvalidWeekCount;
        } else if (std.mem.eql(u8, flag, "--ending")) {
            result.ending = try date.parseReference(value);
        } else {
            return error.UnknownFlag;
        }
    }
    return result;
}

fn parseExportCommand(args: []const []const u8) !ExportCommand {
    var result: ExportCommand = .{ .ending = date.today() };
    var index: usize = 0;
    while (index < args.len) {
        const flag = args[index];
        index += 1;
        if (index >= args.len) return error.MissingFlagValue;
        const value = args[index];
        index += 1;
        if (std.mem.eql(u8, flag, "--format")) {
            if (std.mem.eql(u8, value, "jsonl")) {
                result.format = .jsonl;
            } else if (std.mem.eql(u8, value, "markdown")) {
                result.format = .markdown;
            } else {
                return error.InvalidExportFormat;
            }
        } else if (std.mem.eql(u8, flag, "--weeks")) {
            result.weeks = try std.fmt.parseInt(u8, value, 10);
            if (result.weeks < 1 or result.weeks > 52) return error.InvalidWeekCount;
        } else if (std.mem.eql(u8, flag, "--ending")) {
            result.ending = try date.parseReference(value);
        } else {
            return error.UnknownFlag;
        }
    }
    return result;
}

fn validateRange(start: date.Date, end: date.Date) !void {
    if (date.compare(start, end) == .gt) return error.InvalidDateRange;
    if (date.daysBetween(start, end) > 366) return error.DateRangeTooLarge;
}

fn parseFloat(text: []const u8) !f64 {
    const value = try std.fmt.parseFloat(f64, text);
    if (value <= 0 or !std.math.isFinite(value)) return error.InvalidDistance;
    return value;
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
    } else {
        try writer.writeAll("not specified");
    }
}

fn printUsage(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\runningman — daily running plan and append-only training log
        \\
        \\Usage:
        \\  runningman [--data PATH] [DATE_REFERENCE]
        \\  runningman [--data PATH] init [START_MONDAY]
        \\  runningman [--data PATH] schedule [--weeks N] [--from DATE]
        \\  runningman [--data PATH] check-in [DATE] [--sleep 0-100 --readiness 0-100]
        \\  runningman [--data PATH] log [DATE]
        \\  runningman [--data PATH] log [DATE] --distance KM [options]
        \\  runningman [--data PATH] history [FROM_DATE] [TO_DATE]
        \\  runningman [--data PATH] compare [--weeks N] [--ending DATE]
        \\  runningman profile validate RUNNER_PROFILE.json
        \\  runningman evidence validate EVIDENCE_LEDGER.json
        \\  runningman policy validate POLICY.json [--evidence EVIDENCE_LEDGER.json]
        \\  runningman plan assess RUNNER_PROFILE.json [--policy POLICY.json] [--evidence EVIDENCE_LEDGER.json]
        \\  runningman [--data PATH] plan generate RUNNER_PROFILE.json --output PROPOSED_PLAN.json [--policy POLICY.json] [--evidence EVIDENCE_LEDGER.json]
        \\  runningman [--data PATH] plan preview REVISION.json
        \\  runningman [--data PATH] plan apply REVISION.json
        \\  runningman [--data PATH] plan markdown [REVISION.json] [--output TRAINING_PLAN.md]
        \\  runningman [--data PATH] plan explain [DATE_REFERENCE|REVISION.json [DATE_REFERENCE]]
        \\  runningman [--data PATH] review [--weeks N] [--ending DATE]
        \\  runningman [--data PATH] export [--format markdown|jsonl] [--weeks N] [--ending DATE]
        \\
        \\Log options:
        \\  --sport running|cycling
        \\  --outcome completed|modified|skipped|rested
        \\  --modified | --skipped | --rested
        \\  --distance KM  --duration MINUTES|MM:SS|HH:MM:SS  --avg-hr BPM
        \\  --ascent-m METERS  --descent-m METERS
        \\  --rpe 1-10  --pain 0-10  --pain-location TEXT
        \\  --reason TEXT  --notes TEXT
        \\
        \\Date references accept YYYY-MM-DD, a day in the current month, today, or tomorrow.
        \\
        \\Default data file: runningman-data.jsonl
        \\
    );
}

fn friendlyError(err: anyerror) []const u8 {
    return switch (err) {
        error.NotInitialized => "no plan found; run `runningman init YYYY-MM-DD` with a Monday start date",
        error.AlreadyInitialized => "the data file already contains a plan",
        error.StartMustBeMonday => "the 13-week plan must start on a Monday",
        error.InvalidDate => "date must be a real calendar date in YYYY-MM-DD form",
        error.NoScheduleForDate => "no schedule applies to that date",
        error.NoWorkoutForDate, error.WorkoutNotFound => "the active schedule has no workout for that date",
        error.InvalidDistance => "distance must be a finite positive number",
        error.InvalidDistanceRange => "minimum distance cannot exceed maximum distance",
        error.InvalidHeartRate => "average heart rate must be greater than zero",
        error.RpeOutOfRange => "RPE must be from 1 to 10",
        error.PainOutOfRange => "pain must be from 0 to 10",
        error.SleepScoreOutOfRange => "Oura Sleep Score must be from 0 to 100",
        error.ReadinessScoreOutOfRange => "Oura Readiness Score must be from 0 to 100",
        error.SleepScoreRequired => "a morning check-in requires --sleep 0-100",
        error.ReadinessScoreRequired => "a morning check-in requires --readiness 0-100",
        error.ModifiedReasonRequired => "a modified activity requires a reason",
        error.InvalidStatus => "outcome must be completed, modified, skipped, or rested",
        error.InvalidSport => "sport must be running or cycling",
        error.InvalidDuration => "duration must be positive whole minutes, MM:SS, or HH:MM:SS",
        error.InvalidProfileCommand => "profile requires `validate RUNNER_PROFILE.json`",
        error.RunnerProfileFileNotFound => "the runner profile JSON file was not found",
        error.InvalidRunnerProfileFile => "the runner profile is not valid JSON in the expected format",
        error.UnsupportedRunnerProfileSchema => "runner profile schema_version must be 2",
        error.RunnerProfileIdRequired => "runner profile field `profile_id` cannot be empty",
        error.InvalidPlanStartDate => "runner profile field `plan_start_date.value` must be a real YYYY-MM-DD date",
        error.InvalidRaceDate => "runner profile field `goal.race_date.value` must be a real YYYY-MM-DD date",
        error.UnsupportedPlanLength => "the inclusive span from `plan_start_date.value` through `goal.race_date.value` must be 55–168 days",
        error.InvalidTargetTime => "runner profile field `goal.target_time_seconds.value` must be greater than zero",
        error.InvalidRunningDayCount => "runner profile field `availability.running_days.value` must contain 2–6 core days",
        error.DuplicateRunningDay => "runner profile field `availability.running_days.value` contains a duplicate day",
        error.LongRunDayUnavailable => "runner profile field `preferred_long_run_day.value` must be one of the core running days",
        error.QualityDayUnavailable => "runner profile field `preferred_quality_day.value` must be one of the core running days",
        error.QualityDayMatchesLongRunDay => "preferred quality and long-run days must be different",
        error.OptionalDayIsCoreDay => "runner profile field `optional_recovery_day.value` must not duplicate a core running day",
        error.InvalidAverageWeeklyDistance => "runner profile field `average_weekly_distance_km.value` must be finite and non-negative",
        error.InvalidLongestRun => "runner profile field `longest_run_km.value` must be finite and non-negative",
        error.DurationLoadBaselineRequired => "duration-based planning requires `baseline.longest_run_duration_seconds`",
        error.InvalidLongestRunDuration => "runner profile field `baseline.longest_run_duration_seconds.value` must be greater than zero",
        error.TrailCourseAscentRequired => "a trail goal requires `goal.course.total_ascent_meters`",
        error.TrailCourseDescentRequired => "a trail goal requires `goal.course.total_descent_meters`",
        error.TrailCourseTechnicalityRequired => "a trail goal requires `goal.course.technicality`",
        error.TrailBaselineAscentRequired => "a trail goal requires `baseline.average_weekly_ascent_meters`",
        error.TrailLongestRunAscentRequired => "a trail goal requires `baseline.longest_run_ascent_meters`",
        error.EmptyWeeklyDistanceHistory => "runner profile field `weekly_distance_history_km.value` cannot be an empty list",
        error.InvalidWeeklyDistanceHistory => "runner profile field `weekly_distance_history_km.value` contains an invalid distance",
        error.InvalidPerformanceDate => "a recent performance has an invalid `date`",
        error.PerformanceAfterPlanStart => "a recent performance date cannot be after `plan_start_date.value`",
        error.InvalidPerformanceTime => "a recent performance `duration_seconds` must be greater than zero",
        error.InvalidUnavailableDate => "runner profile field `unavailable_dates.value` contains an invalid date",
        error.UnavailableDateOutsidePlan => "every unavailable date must fall within the requested plan",
        error.InvalidEvidenceCommand => "evidence requires `validate EVIDENCE_LEDGER.json`",
        error.EvidenceLedgerFileNotFound => "the evidence ledger JSON file was not found",
        error.InvalidEvidenceLedgerFile => "the evidence ledger is not valid JSON in the expected format",
        error.UnsupportedEvidenceLedgerSchema => "evidence ledger schema_version must be 2",
        error.EvidenceLedgerIdRequired => "evidence ledger field `ledger_id` cannot be empty",
        error.EvidenceIdRequired => "every evidence entry needs a non-empty `evidence_id`",
        error.DuplicateEvidenceId => "evidence ledger field `evidence_id` must be unique",
        error.InvalidEvidenceCitation => "every evidence entry needs a title, authors, year, and HTTP(S) URL",
        error.EvidencePopulationRequired => "every evidence entry needs a `population`",
        error.EvidenceTrainingStatusRequired => "every evidence entry needs a `training_status`",
        error.EvidenceInterventionRequired => "every evidence entry needs an `intervention`",
        error.EvidenceComparisonRequired => "every evidence entry needs a `comparison`",
        error.EvidenceOutcomesRequired => "every evidence entry needs at least one outcome",
        error.EmptyEvidenceOutcome => "evidence outcomes cannot contain an empty value",
        error.EvidenceLimitationsRequired => "every evidence entry needs at least one limitation",
        error.EmptyEvidenceLimitation => "evidence limitations cannot contain an empty value",
        error.EvidencePlanningImplicationRequired => "every evidence entry needs a `planning_implication`",
        error.EmptyPolicyRuleId => "policy rule IDs cannot be empty",
        error.DuplicatePolicyRuleId => "policy rule IDs within an evidence entry must be unique",
        error.InvalidPolicyCommand => "policy requires `validate POLICY.json [--evidence EVIDENCE_LEDGER.json]`",
        error.TrainingPolicyFileNotFound => "the training policy JSON file was not found",
        error.InvalidTrainingPolicyFile => "the training policy is not valid JSON in the expected format",
        error.UnsupportedTrainingPolicySchema => "training policy schema_version must be 2",
        error.UnsupportedTrainingPolicyVersion => "only training policy version 2 is supported",
        error.TrainingPolicyIdentityRequired => "training policy needs a non-empty policy_id and positive policy_version",
        error.TrainingPolicyEvidenceLedgerRequired => "training policy needs a non-empty evidence_ledger_id",
        error.TrainingPolicyEvidenceLedgerMismatch => "the policy and evidence ledger IDs do not match",
        error.TrainingPolicyNeedsRules => "the training policy needs at least one rule",
        error.IncompleteTrainingPolicyRule => "every policy rule needs an ID, category, and summary",
        error.DuplicateTrainingPolicyRuleId => "training policy rule IDs must be unique",
        error.UnjustifiedTrainingPolicyRule => "every policy rule needs evidence or an explicit product assumption",
        error.EmptyTrainingPolicyEvidenceId => "policy rule evidence IDs cannot be empty",
        error.DuplicateTrainingPolicyEvidenceId => "evidence IDs within a policy rule must be unique",
        error.UnknownTrainingPolicyEvidenceId => "a policy rule refers to unknown evidence",
        error.InvalidTrainingPolicySupport => "the policy contains invalid scope boundaries",
        error.InvalidTrainingPolicyPeriodization => "the policy contains invalid periodization boundaries",
        error.InvalidTrainingPolicyPhase => "every policy phase needs an ID and purpose",
        error.DuplicateTrainingPolicyPhase => "policy phase IDs must be unique",
        error.InvalidBaselineAssessmentPolicy => "the policy contains invalid baseline-assessment parameters",
        error.InvalidVolumeProgressionPolicy => "the policy contains invalid volume-progression parameters",
        error.InvalidRecoveryPolicy => "the policy contains invalid recovery-week parameters",
        error.InvalidIntensityDistributionPolicy => "the policy contains invalid intensity-distribution parameters",
        error.InvalidLongRunPolicy => "the policy contains invalid long-run parameters",
        error.InvalidTaperPolicy => "the taper must have valid duration and reduction ranges while retaining intensity and core frequency",
        error.InvalidSchedulingPolicy => "the policy needs at least one easy or rest day between demanding sessions",
        error.InvalidOptionalRunPolicy => "optional runs must be bounded and removable without rescheduling",
        error.InvalidMissedWorkoutPolicy => "missed workouts cannot be stacked and must preserve hard-session spacing",
        error.TrainingPolicyNeedsWorkoutRecipes => "the policy needs workout categories and recipes",
        error.InvalidWorkoutCategory => "every workout category needs an ID, intensity class, and description",
        error.DuplicateWorkoutCategory => "workout category IDs must be unique",
        error.InvalidWorkoutRecipe => "every workout recipe needs an ID, description, and at least one phase",
        error.InvalidQualityProgressionPolicy => "quality-progression values are incomplete, inconsistent, or outside supported bounds",
        error.InvalidTrailSpecificPolicy => "the policy contains invalid trail-specific progression parameters",
        error.InvalidDurationProgressionPolicy => "the policy contains invalid duration-progression parameters",
        error.TrailPolicyRequiresEffortOnlyPacing => "trail policy must use effort-only pacing",
        error.DuplicateWorkoutRecipe => "workout recipe IDs must be unique",
        error.UnknownWorkoutCategory => "a workout recipe refers to an unknown category",
        error.UnknownWorkoutPhase => "a workout recipe refers to an unknown phase",
        error.UnknownTrainingPolicyRuleReference => "a policy section or workout recipe refers to an unknown rule",
        error.MissingEvidencePolicyBacklink => "a cited evidence entry does not link back to its policy rule",
        error.UnknownEvidencePolicyRule => "the evidence ledger links to an unknown policy rule",
        error.MissingPolicyEvidenceBacklink => "an evidence policy link is missing from the corresponding rule",
        error.PlanAssessmentProfileRequired => "plan assess requires a runner profile JSON file",
        error.ProfileOutsidePolicyScope => "the runner profile is outside the selected policy's supported scope",
        error.TrailCourseOutsidePolicyScope => "the trail course exceeds the selected policy's supported ascent",
        error.TrailPolicyRulesRequired => "the selected policy does not contain trail-specific rules",
        error.MissingAssessmentPolicyRule => "the policy is missing a rule required to explain the assessment",
        error.MissingPlanAction => "plan requires `assess`, `generate`, `preview`, `markdown`, or `apply`",
        error.PlanGenerationProfileRequired => "plan generate requires a runner profile JSON file",
        error.PlanGenerationOutputRequired => "plan generate requires `--output PROPOSED_PLAN.json`",
        error.RaceDateUnavailable => "the race date cannot be listed as unavailable",
        error.PlanTooShortForPolicyPhases => "the plan is too short for the policy's required phases",
        error.NotEnoughAvailableRunningDays => "a week has fewer than the required available core running days",
        error.DurationProgressionPolicyRequired => "duration-based generation requires duration progression rules in the selected policy",
        error.DurationProgressionIncomplete => "duration-based generation produced an incomplete duration prescription",
        error.LongRunCannotBeScheduled => "a long run cannot be placed on an available core day",
        error.QualityWorkoutCannotBeScheduled => "a quality workout cannot be placed with the required demanding-session spacing",
        error.GeneratedPlanStartMismatch => "generated plan start does not match the runner profile",
        error.GeneratedRaceDateMismatch => "generated race date does not match the runner profile",
        error.GeneratedPlanMissingDays => "generated plan must represent every calendar day",
        error.GeneratedPlanProvenanceMismatch => "generated plan provenance does not match its planner inputs",
        error.GeneratedAssessmentMismatch => "generated assessment does not match the planner inputs",
        error.GeneratedWeeklySummaryCountMismatch => "generated weekly summary count does not match its daily schedule",
        error.GeneratedWeeklySummaryDatesMismatch => "generated weekly summary dates do not match its daily schedule",
        error.GeneratedWeeklySummaryMismatch => "generated weekly summary does not match its daily schedule",
        error.GeneratedWeekDecisionMismatch => "a generated weekly decision does not match the selected policy",
        error.GeneratedTrailWeekMismatch => "generated trail vertical targets do not match their daily workouts or planner decision",
        error.GeneratedPlanDatesNotConsecutive => "generated plan dates are not consecutive",
        error.GeneratedWeekHasMultiplePhases => "a generated week contains more than one phase",
        error.GeneratedPhaseOrderInvalid => "generated phases are out of order",
        error.GeneratedUnknownPhase => "generated plan contains an unknown phase",
        error.GeneratedPlanNeedsOneRace => "generated plan must contain exactly one race",
        error.GeneratedRaceOnWrongDate => "generated race is not on the goal date",
        error.GeneratedWorkoutOnUnavailableDate => "generated plan schedules running on an unavailable date",
        error.GeneratedWorkoutOutsideAvailability => "generated plan schedules a core run outside the allowed weekdays",
        error.GeneratedOptionalRunWithoutOptionalDay => "generated plan has an optional run without an optional recovery day",
        error.GeneratedOptionalRunOnWrongDay => "generated optional run is on the wrong weekday",
        error.GeneratedWorkoutNeedsDistance => "generated running workouts must have explicit distance segments",
        error.GeneratedWorkoutNeedsDecision => "every generated workout must include its recipe and allocation decision",
        error.GeneratedWorkoutDecisionWeekdayMismatch => "a generated workout decision records the wrong weekday",
        error.GeneratedWorkoutDecisionRecipeMismatch => "a generated workout recipe is not valid for its phase",
        error.GeneratedWorkoutDecisionRuleMismatch => "a generated workout decision refers to missing policy rules",
        error.GeneratedWorkoutDecisionDistanceMismatch => "a generated workout decision records the wrong distance",
        error.GeneratedWorkoutDecisionDurationMismatch => "a generated workout decision records the wrong duration",
        error.GeneratedWorkoutLoadBasisMismatch => "a generated workout decision records the wrong training-load basis",
        error.GeneratedWorkoutTrailDecisionMismatch => "a generated workout decision records the wrong terrain or vertical target",
        error.GeneratedTrailWorkoutInvalid => "every core trail workout must use trail terrain and effort-only pacing",
        error.UnknownGeneratedWorkoutKind => "the generator produced an unknown workout kind",
        error.GeneratedWorkoutRecipeNotFound => "the generator selected a workout recipe missing from the policy",
        error.GeneratedQualityProgressionDecisionRequired => "every generated quality workout needs a structured progression decision",
        error.GeneratedQualityProgressionOnNonQualityWorkout => "a non-quality workout contains a quality-progression decision",
        error.GeneratedQualityProgressionDecisionInvalid => "a generated quality-progression decision is incomplete or invalid",
        error.GeneratedQualityProgressionDecisionMismatch => "a generated quality-progression decision does not match its workout segments",
        error.GeneratedQualitySessionTooLong => "a generated quality session exceeds its weekly-distance allowance",
        error.GeneratedQualityProgressionInvalid => "generated quality work regresses during a loading progression",
        error.GeneratedQualityRecoveryNotReduced => "generated recovery-week quality work is not reduced",
        error.GeneratedQualityDensityRegressed => "generated interval density regresses without a stage transition",
        error.GeneratedDemandingSessionsTooClose => "generated demanding sessions do not have enough easy or rest days between them",
        error.GeneratedTooManyQualitySessions => "generated week exceeds the policy's quality-session limit",
        error.GeneratedIntensityDistributionInvalid => "generated low-intensity share is outside policy bounds",
        error.GeneratedOptionalRunTooLong => "generated optional run exceeds its weekly-volume allowance",
        error.GeneratedWeeklyVolumeAbovePeak => "generated weekly volume exceeds the baseline-relative peak limit",
        error.GeneratedWeeklyVolumeIncreaseTooLarge => "generated weekly volume increases too quickly",
        error.GeneratedWeeklyAscentIncreaseTooLarge => "generated weekly ascent increases too quickly",
        error.GeneratedWeeklyAscentAbovePeak => "generated weekly ascent exceeds the trail policy peak",
        error.GeneratedLongRunAscentTooHigh => "generated long-run ascent exceeds its race or weekly share limit",
        error.GeneratedLongRunAscentIncreaseTooLarge => "generated long-run ascent increases too quickly",
        error.GeneratedTrailSpecificityMissing => "generated trail week does not include enough trail-specific sessions",
        error.GeneratedDurationWeekCountMismatch => "a duration-based week does not match the profile's planned running frequency",
        error.GeneratedDurationQualityMissing => "a duration-based week must contain one explicit quality session",
        error.GeneratedDurationRaceWeekInvalid => "the generated duration-based race week has an invalid sharpening run, long run, or race ascent",
        error.GeneratedDurationInvalid => "a generated week has invalid regular-run or long-run duration",
        error.GeneratedDurationIncreaseTooLarge => "a generated running duration increases too quickly",
        error.GeneratedDurationAbovePeak => "a generated running duration exceeds the policy maximum",
        error.GeneratedLongRunShareTooHigh => "generated long run exceeds its allowed share of weekly volume",
        error.GeneratedLongRunTooLong => "generated long run exceeds the policy maximum",
        error.GeneratedLongRunIncreaseTooLarge => "generated long run increases too quickly",
        error.GeneratedRecoveryWithoutBuild => "generated recovery week has no preceding build volume",
        error.GeneratedRecoveryTimingInvalid => "generated recovery week is not after the policy-required number of build weeks",
        error.GeneratedRecoveryVolumeInvalid => "generated recovery-week volume is outside policy bounds",
        error.GeneratedRequiredPhaseTooShort => "generated foundation or race-specific phase is shorter than policy allows",
        error.GeneratedTaperLengthInvalid => "generated taper length is outside policy bounds",
        error.GeneratedPlanMustEndInRacePhase => "generated plan must end in the race phase",
        error.GeneratedTaperWithoutPeak => "generated taper has no preceding peak volume",
        error.GeneratedTaperVolumeInvalid => "generated taper reduction is outside policy bounds",
        error.GeneratedTaperMissingIntensity => "generated taper does not retain a quality session",
        error.PlanFileRequired => "plan preview or apply requires exactly one revision JSON file",
        error.UnknownPlanAction => "plan action must be generate, preview, markdown, apply, or explain",
        error.InvalidPlanExplainCommand => "plan explain accepts no arguments, DATE_REFERENCE, REVISION.json, or REVISION.json DATE_REFERENCE",
        error.PlanAlreadyPeriodized => "the latest schedule is already periodized",
        error.RevisionFileNotFound => "the revision JSON file was not found",
        error.InvalidRevisionFile => "the revision file is not valid JSON in the expected format",
        error.UnsupportedRevisionSchema => "the revision file schema_version must be 2",
        error.StaleRevision => "the revision targets an older schedule; export a fresh review first",
        error.RevisionReasonRequired => "the revision needs a non-empty reason",
        error.EmptyRevision => "the revision contains no workouts",
        error.RevisionWorkoutDecisionRequired => "every revised workout must include its recipe and allocation decision",
        error.RevisionBeforePlanStart => "the revision cannot begin before the plan",
        error.RevisionPlanStartMismatch => "the proposal plan start does not match the schedule being revised",
        error.RevisionEffectiveAfterRace => "the revision cannot become effective after race day",
        error.RevisionHistoricalWorkoutChanged => "workouts before effective_from must exactly match the current schedule",
        error.PlanExplanationUnavailable => "this schedule predates planner provenance and cannot be explained",
        error.PlanWorkoutExplanationUnavailable => "this workout has no persisted planner decision to explain",
        error.RevisionDatesNotConsecutive => "the revision must contain one entry for every consecutive day",
        error.RevisionRaceDateRequired => "the schedule needs a race date",
        error.RevisionMustEndOnRaceDate => "the complete remaining program must end on race day",
        error.IncompleteParentSchedule => "the parent schedule is missing a day before the revision",
        error.IncompleteProposedWorkout => "each revised workout needs phase, kind, intensity, and details",
        error.ProposedWorkoutNeedsSegments => "each revised workout needs at least one structured segment",
        error.InvalidSegment => "a revised workout contains an invalid segment",
        error.InvalidPaceRange => "a pace range needs fast and slow values with fast no slower than slow",
        error.InvalidDateRange => "the history start date is after its end date",
        error.DateRangeTooLarge => "history is limited to 366 days at a time",
        error.InvalidWeekCount => "--weeks must be from 1 to 52",
        error.InvalidExportFormat => "export format must be markdown or jsonl",
        error.InvalidDataFile => "the data file contains an invalid event",
        error.UnknownCommand => "unknown command",
        error.UnknownFlag => "unknown option",
        error.MissingFlagValue => "an option is missing its value",
        error.MissingDate => "a date is required",
        error.MissingDataPath => "--data requires a path",
        error.EndOfInput => "interactive input ended before logging was complete",
        error.UnexpectedArgument => "too many arguments",
        else => @errorName(err),
    };
}
