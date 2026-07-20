---
name: code-style
description: Apply this skill whenever writing new code or refactoring existing code in Runningman. Keep Zig modules data-oriented, functions explicit, ownership clear, and abstractions proportionate to this terminating CLI and append-only training model.
---

# Code Style and Architecture

Runningman is a Zig CLI organized into domain modules such as profiles,
schedules, activities, storage, reports, and plan validation. It is not an
entity component system.

## Keep behavior in domain modules

Place related data types and file-level functions in one focused module. Add a
new module when it represents a distinct domain responsibility; do not create
generic managers, registries, or utility layers without a concrete need.

Structs hold data. Functions implement parsing, validation, transformation, and
rendering at file scope.

## Pass the representation the operation needs

Use values, slices, IDs, or pointers according to ownership and mutation needs:

- pass small immutable data by value;
- pass slices for ordered collections;
- pass pointers when operating on shared or mutable state;
- use stable IDs where persisted records need identity; and
- do not introduce IDs merely to avoid a clear direct parameter.

The append-only model requires stable schedule, workout, activity, and check-in
IDs. It does not require an ID-based API for every function.

## Prefer explicit data flow

Keep parsing, validation, mutation, and output visibly separate when practical.
Pure calculations should not perform file I/O. Commands may orchestrate these
operations, but domain rules belong in their domain modules rather than
`main.zig`.

Use plain structs and functions before introducing callbacks, function-pointer
dispatch, builders, factories, or generic frameworks.

## Use collections according to access

Use maps when records are repeatedly looked up by stable key. Use slices or
array lists when order matters or the operation naturally processes every
element. Do not add a map to a small ordered format merely to avoid one bounded
validation scan.

## Preserve auditability

Do not silently overwrite stored training facts or schedule revisions.
Corrections and changed plans must preserve provenance and the record that was
previously in effect.

Keep measured, user-entered, derived, and defaulted values distinguishable.
Missing information must remain missing instead of being replaced with false
precision.

## Functions are flat

Do not define functions inside struct bodies. Keep behavior at module scope and
use descriptive parameter names rather than `self`.

```zig
pub const Assessment = struct {
    confidence: Confidence,
    recommended_time_seconds: ?u32,
};

pub fn assess(profile: RunnerProfile, policy: Policy) !Assessment {
    // ...
}
```

## Imports stay at the top

Put all `@import` declarations at the top of the file and name them after the
module they represent.

## Match existing interfaces

Follow the repository's established error-union, allocator, `std.Io`, JSON, and
test patterns. Prefer extending an existing format compatibly over creating a
parallel representation of the same domain concept.
