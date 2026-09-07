const targeted_adjustment = @import("src/targeted_adjustment.zig");

// Keep the package root above src so planner tests can embed schema and policy
// fixtures. Explicitly reference the module so Zig's lazy analysis includes it.
test {
    _ = targeted_adjustment;
}
