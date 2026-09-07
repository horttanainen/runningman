const std = @import("std");
const runner_profile = @import("runner_profile.zig");
const training_policy = @import("training_policy.zig");
const plan_revision = @import("plan_revision.zig");

const Io = std.Io;

pub const generator_version = "runningman-planner-v2";

pub const AssessmentSnapshot = struct {
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

pub const SourceHashes = struct {
    runner_profile_sha256: []const u8,
    training_policy_sha256: []const u8,
    evidence_ledger_sha256: []const u8,
};

pub const PlanProvenance = struct {
    schema_version: u8 = 2,
    generator_version: []const u8,
    runner_profile_sha256: []const u8,
    training_policy_sha256: []const u8,
    evidence_ledger_id: []const u8,
    evidence_ledger_sha256: []const u8,
    runner_profile: runner_profile.RunnerProfile,
    training_policy: training_policy.Policy,
    assessment: AssessmentSnapshot,
    adjustment: ?Adjustment = null,
};

pub const Adjustment = struct {
    policy_version: u8 = 3,
    restart_date: []const u8,
    interruption_start: []const u8,
    skipped_workouts: u16,
    ready_to_resume: bool,
    // Retained only to parse and explicitly reject superseded proposals.
    return_load_percent: ?u8 = null,
    observed_weekly_km: f64,
    observed_long_run_km: f64,
    observed_peak_weekly_km: ?f64 = null,
    race_date_choice: []const u8,
    parent: *const plan_revision.RevisionFile,
    continuation: ?*const plan_revision.RevisionFile = null,
    week_changes: []const AdjustmentWeek = &.{},
    method: []const u8 = "friel-inspired",
    guidance_url: []const u8 = "https://joefrieltraining.com/missed-workouts/",
    stage: ReturnStage = .base,
    base_weeks: u8 = 1,
    repeat_source_week: u8 = 0,
    repeat_weekly_km: f64 = 0,
    repeat_long_run_km: f64 = 0,
    familiar_easy_km: f64 = 0,
    returned_weekly_km: ?f64 = null,
    returned_long_run_km: ?f64 = null,
    omitted_source_weeks: []const u8 = &.{},
};

pub const ReturnStage = enum { base, repeat, continuation };

pub const AdjustmentWeek = struct {
    week: u8,
    source_week: u8,
    distance_fraction: f64,
    reason: []const u8,
    stage: ReturnStage = .continuation,
};

pub const VolumeMethod = enum {
    baseline,
    aerobic_return,
    build_progression,
    recovery_reduction,
    race_specific_progression,
    taper_reduction,
    race_week,
};

pub const WeekDecision = struct {
    periodization_rule_id: []const u8,
    volume_rule_id: []const u8,
    long_run_rule_id: []const u8,
    recovery_rule_id: ?[]const u8 = null,
    taper_rule_id: ?[]const u8 = null,
    baseline_weekly_distance_km: f64,
    baseline_weekly_distance_source: runner_profile.Source,
    volume_method: VolumeMethod,
    previous_progression_distance_km: ?f64 = null,
    applied_volume_fraction: ?f64 = null,
    peak_volume_limit_km: f64,
    baseline_longest_run_km: f64,
    baseline_longest_run_source: runner_profile.Source,
    previous_long_run_distance_km: ?f64 = null,
    long_run_weekly_share_limit_km: f64,
    long_run_progression_limit_km: f64,
    phase_week: u8,
    phase_week_count: u8,
    target_core_duration_seconds: ?u32 = null,
    previous_long_run_duration_seconds: ?u32 = null,
    long_run_progression_limit_seconds: ?u32 = null,
    target_ascent_meters: ?u32 = null,
    previous_ascent_meters: ?u32 = null,
    ascent_progression_limit_meters: ?u32 = null,
    long_run_ascent_meters: ?u32 = null,
    trail_rule_id: ?[]const u8 = null,
    load_basis: runner_profile.TrainingLoadBasis = .distance,
};

pub const PlanWeek = struct {
    week: u8,
    start_date: []const u8,
    end_date: []const u8,
    phase: []const u8,
    target_core_distance_km: f64,
    long_run_distance_km: f64,
    target_core_duration_seconds: ?u32 = null,
    long_run_duration_seconds: ?u32 = null,
    target_ascent_meters: ?u32 = null,
    long_run_ascent_meters: ?u32 = null,
    decision: WeekDecision,
};

pub const AllocationRole = enum {
    rest,
    easy,
    optional_recovery,
    quality,
    long_run,
    race,
};

pub const DistanceMethod = enum {
    none,
    weekly_remainder,
    optional_weekly_fraction,
    quality_progression,
    weekly_long_run,
    race_distance,
    duration_progression,
};

pub const PaceMethod = enum {
    none,
    effort_only,
    easy_anchor_offset,
    quality_anchor_offset,
    race_anchor,
};

pub const QualityLoadMethod = enum {
    establish,
    progress_work,
    recovery_reduction,
    race_specific_progression,
    taper_reduction,
    race_sharpening,
};

pub const QualityProgressionDecision = struct {
    stage_id: []const u8,
    load_method: QualityLoadMethod,
    phase_week: u8,
    phase_week_count: u8,
    work_distance_km: f64,
    previous_work_distance_km: ?f64 = null,
    repetition_distance_km: ?f64 = null,
    repetitions: u8,
    recovery_seconds: ?u16 = null,
    work_duration_seconds: ?u32 = null,
    previous_work_duration_seconds: ?u32 = null,
};

pub const WorkoutDecision = struct {
    recipe_id: []const u8,
    rule_ids: []const []const u8,
    allocation_role: AllocationRole,
    distance_method: DistanceMethod,
    pace_method: PaceMethod,
    week_target_core_distance_km: f64,
    allocated_distance_km: f64,
    week_target_core_duration_seconds: ?u32 = null,
    allocated_duration_seconds: ?u32 = null,
    training_pace_anchor_seconds: ?u32 = null,
    scheduled_weekday: runner_profile.Weekday,
    preferred_weekday: ?runner_profile.Weekday = null,
    preference_honored: ?bool = null,
    quality_progression: ?QualityProgressionDecision = null,
    planned_ascent_meters: ?u32 = null,
    planned_descent_meters: ?u32 = null,
    terrain: ?runner_profile.Surface = null,
    load_basis: runner_profile.TrainingLoadBasis = .distance,
};

pub fn hashFile(
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
) ![]const u8 {
    const contents = try Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(16 * 1024 * 1024),
    );
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(contents, &digest, .{});
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &encoded);
}

pub fn validSha256(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |character| {
        if (!std.ascii.isHex(character)) return false;
    }
    return true;
}

test "hashes source bytes as lowercase SHA-256" {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("runningman", &digest, .{});
    const encoded = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expect(validSha256(&encoded));
    try std.testing.expect(!validSha256("not-a-hash"));
}

test "proposed plan schema is valid JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    _ = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        @embedFile("../schemas/proposed-plan.schema.json"),
        .{},
    );
}
