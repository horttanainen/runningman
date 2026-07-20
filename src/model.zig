pub const EventType = enum {
    schedule,
    workout,
    activity,
    morning_check_in,
};

pub const ActivityStatus = enum {
    completed,
    modified,
    skipped,
    rested,
};

pub const Schedule = struct {
    id: u64,
    parent_schedule_id: ?u64,
    effective_from: []const u8,
    start_date: []const u8,
    name: []const u8,
    reason: []const u8,
    goal: []const u8,
    baseline: []const u8,
    availability: []const u8,
    intensity_guidance: []const u8,
    pace_profile: []const u8,
    race_date: []const u8,
    source: []const u8,
    recorded_at: i64,
};

pub const Segment = struct {
    kind: []const u8,
    label: []const u8,
    repetitions: u8 = 1,
    distance_km: ?f64 = null,
    duration_seconds: ?u32 = null,
    pace_fast_seconds_per_km: ?u16 = null,
    pace_slow_seconds_per_km: ?u16 = null,
    recovery_seconds: ?u16 = null,
    notes: []const u8 = "",
};

pub const Workout = struct {
    id: u64,
    schedule_id: u64,
    date: []const u8,
    week: u8,
    day: []const u8,
    phase: []const u8,
    kind: []const u8,
    intensity: []const u8,
    distance_min_km: ?f64,
    distance_max_km: ?f64,
    details: []const u8,
    segments: []const Segment,
    recorded_at: i64,
};

pub const Activity = struct {
    id: u64,
    supersedes_activity_id: ?u64,
    schedule_id: u64,
    workout_id: u64,
    date: []const u8,
    status: ActivityStatus,
    distance_km: ?f64,
    duration_seconds: ?u32,
    average_heart_rate: ?u16,
    rpe: ?u8,
    feeling: ?u8,
    pain: ?u8,
    pain_location: []const u8,
    deviation_reason: []const u8,
    notes: []const u8,
    recorded_at: i64,
};

pub const MorningCheckIn = struct {
    id: u64,
    supersedes_check_in_id: ?u64,
    date: []const u8,
    sleep_score: u8,
    readiness_score: u8,
    notes: []const u8,
    recorded_at: i64,
};

pub const Event = struct {
    schema_version: u8 = 1,
    type: EventType,

    id: u64,
    parent_schedule_id: ?u64 = null,
    effective_from: ?[]const u8 = null,
    start_date: ?[]const u8 = null,
    name: ?[]const u8 = null,
    reason: ?[]const u8 = null,
    goal: ?[]const u8 = null,
    baseline: ?[]const u8 = null,
    availability: ?[]const u8 = null,
    intensity_guidance: ?[]const u8 = null,
    pace_profile: ?[]const u8 = null,
    race_date: ?[]const u8 = null,
    source: ?[]const u8 = null,

    schedule_id: ?u64 = null,
    workout_id: ?u64 = null,
    date: ?[]const u8 = null,
    week: ?u8 = null,
    day: ?[]const u8 = null,
    phase: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    intensity: ?[]const u8 = null,
    distance_min_km: ?f64 = null,
    distance_max_km: ?f64 = null,
    details: ?[]const u8 = null,
    segments: ?[]const Segment = null,

    status: ?ActivityStatus = null,
    supersedes_activity_id: ?u64 = null,
    distance_km: ?f64 = null,
    duration_seconds: ?u32 = null,
    average_heart_rate: ?u16 = null,
    rpe: ?u8 = null,
    feeling: ?u8 = null,
    pain: ?u8 = null,
    pain_location: ?[]const u8 = null,
    deviation_reason: ?[]const u8 = null,
    notes: ?[]const u8 = null,

    supersedes_check_in_id: ?u64 = null,
    sleep_score: ?u8 = null,
    readiness_score: ?u8 = null,
    recorded_at: i64,
};

pub fn scheduleEvent(value: Schedule) Event {
    return .{
        .type = .schedule,
        .id = value.id,
        .parent_schedule_id = value.parent_schedule_id,
        .effective_from = value.effective_from,
        .start_date = value.start_date,
        .name = value.name,
        .reason = value.reason,
        .goal = value.goal,
        .baseline = value.baseline,
        .availability = value.availability,
        .intensity_guidance = value.intensity_guidance,
        .pace_profile = value.pace_profile,
        .race_date = value.race_date,
        .source = value.source,
        .recorded_at = value.recorded_at,
    };
}

pub fn workoutEvent(value: Workout) Event {
    return .{
        .type = .workout,
        .id = value.id,
        .schedule_id = value.schedule_id,
        .date = value.date,
        .week = value.week,
        .day = value.day,
        .phase = value.phase,
        .kind = value.kind,
        .intensity = value.intensity,
        .distance_min_km = value.distance_min_km,
        .distance_max_km = value.distance_max_km,
        .details = value.details,
        .segments = value.segments,
        .recorded_at = value.recorded_at,
    };
}

pub fn activityEvent(value: Activity) Event {
    return .{
        .type = .activity,
        .id = value.id,
        .supersedes_activity_id = value.supersedes_activity_id,
        .schedule_id = value.schedule_id,
        .workout_id = value.workout_id,
        .date = value.date,
        .status = value.status,
        .distance_km = value.distance_km,
        .duration_seconds = value.duration_seconds,
        .average_heart_rate = value.average_heart_rate,
        .rpe = value.rpe,
        .feeling = value.feeling,
        .pain = value.pain,
        .pain_location = value.pain_location,
        .deviation_reason = value.deviation_reason,
        .notes = value.notes,
        .recorded_at = value.recorded_at,
    };
}

pub fn morningCheckInEvent(value: MorningCheckIn) Event {
    return .{
        .type = .morning_check_in,
        .id = value.id,
        .supersedes_check_in_id = value.supersedes_check_in_id,
        .date = value.date,
        .sleep_score = value.sleep_score,
        .readiness_score = value.readiness_score,
        .notes = value.notes,
        .recorded_at = value.recorded_at,
    };
}
