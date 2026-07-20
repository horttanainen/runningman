const std = @import("std");

const Io = std.Io;

pub const Confidence = enum {
    low,
    moderate,
    high,
};

pub const Citation = struct {
    title: []const u8,
    authors: []const u8,
    year: u16,
    url: []const u8,
};

pub const Entry = struct {
    evidence_id: []const u8,
    citation: Citation,
    population: []const u8,
    training_status: []const u8,
    intervention: []const u8,
    comparison: []const u8,
    outcomes: []const []const u8,
    limitations: []const []const u8,
    planning_implication: []const u8,
    confidence: Confidence,
    policy_rule_ids: []const []const u8,
};

pub const Ledger = struct {
    schema_version: u8,
    ledger_id: []const u8,
    entries: []const Entry,
};

pub fn load(
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
) !Ledger {
    const contents = Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(4 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.EvidenceLedgerFileNotFound,
        else => return err,
    };
    return std.json.parseFromSliceLeaky(
        Ledger,
        allocator,
        contents,
        .{ .ignore_unknown_fields = false },
    ) catch error.InvalidEvidenceLedgerFile;
}

pub fn validate(ledger: Ledger) !void {
    if (ledger.schema_version != 1) return error.UnsupportedEvidenceLedgerSchema;
    if (ledger.ledger_id.len == 0) return error.EvidenceLedgerIdRequired;

    for (ledger.entries, 0..) |entry, index| {
        if (entry.evidence_id.len == 0) return error.EvidenceIdRequired;
        for (ledger.entries[0..index]) |previous| {
            if (std.mem.eql(u8, previous.evidence_id, entry.evidence_id)) {
                return error.DuplicateEvidenceId;
            }
        }
        if (entry.citation.title.len == 0 or entry.citation.authors.len == 0 or
            entry.citation.year == 0 or !isWebUrl(entry.citation.url))
        {
            return error.InvalidEvidenceCitation;
        }
        if (entry.population.len == 0) return error.EvidencePopulationRequired;
        if (entry.training_status.len == 0) return error.EvidenceTrainingStatusRequired;
        if (entry.intervention.len == 0) return error.EvidenceInterventionRequired;
        if (entry.comparison.len == 0) return error.EvidenceComparisonRequired;
        if (entry.outcomes.len == 0) return error.EvidenceOutcomesRequired;
        for (entry.outcomes) |outcome| {
            if (outcome.len == 0) return error.EmptyEvidenceOutcome;
        }
        if (entry.limitations.len == 0) return error.EvidenceLimitationsRequired;
        for (entry.limitations) |limitation| {
            if (limitation.len == 0) return error.EmptyEvidenceLimitation;
        }
        if (entry.planning_implication.len == 0) {
            return error.EvidencePlanningImplicationRequired;
        }
        for (entry.policy_rule_ids, 0..) |rule_id, rule_index| {
            if (rule_id.len == 0) return error.EmptyPolicyRuleId;
            for (entry.policy_rule_ids[0..rule_index]) |previous| {
                if (std.mem.eql(u8, previous, rule_id)) {
                    return error.DuplicatePolicyRuleId;
                }
            }
        }
    }
}

pub fn printSummary(writer: *Io.Writer, ledger: Ledger) !void {
    var linked_entries: usize = 0;
    for (ledger.entries) |entry| {
        if (entry.policy_rule_ids.len != 0) linked_entries += 1;
    }
    try writer.print(
        "Evidence ledger is valid: {s}\n" ++
            "Entries: {d} ({d} linked to at least one policy rule)\n",
        .{ ledger.ledger_id, ledger.entries.len, linked_entries },
    );
}

fn isWebUrl(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "https://") or
        std.mem.startsWith(u8, value, "http://");
}

fn validLedger() Ledger {
    return .{
        .schema_version = 1,
        .ledger_id = "test-ledger",
        .entries = &.{
            .{
                .evidence_id = "E-TAPER-001",
                .citation = .{
                    .title = "Example review",
                    .authors = "Example et al.",
                    .year = 2023,
                    .url = "https://example.com/review",
                },
                .population = "Trained endurance athletes",
                .training_status = "Trained",
                .intervention = "Reduced pre-race training volume",
                .comparison = "Normal training",
                .outcomes = &.{"Endurance performance"},
                .limitations = &.{"Interventions varied between studies"},
                .planning_implication = "Retain a bounded taper policy.",
                .confidence = .moderate,
                .policy_rule_ids = &.{"TAPER-01"},
            },
        },
    };
}

test "validates a traceable evidence ledger" {
    try validate(validLedger());
}

test "rejects duplicate evidence and policy rule identifiers" {
    const entry = validLedger().entries[0];
    const duplicate_entries = [_]Entry{ entry, entry };
    var ledger = validLedger();
    ledger.entries = &duplicate_entries;
    try std.testing.expectError(error.DuplicateEvidenceId, validate(ledger));

    const duplicate_rules = [_][]const u8{ "TAPER-01", "TAPER-01" };
    var duplicate_rule_entry = entry;
    duplicate_rule_entry.policy_rule_ids = &duplicate_rules;
    const entries = [_]Entry{duplicate_rule_entry};
    ledger.entries = &entries;
    try std.testing.expectError(error.DuplicatePolicyRuleId, validate(ledger));
}
