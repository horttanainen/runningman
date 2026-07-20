# Half-marathon policy version 1

Status: implemented for Increment 2 review

This document explains what `half-marathon-v1` does, which parts are linked to
research, and which parts are transparent product assumptions. The policy file
is the executable source of truth:
[`policies/half-marathon-v1.json`](../policies/half-marathon-v1.json).

## Assessment model

The planner selects one primary performance using this order:

1. Distance specificity: half marathon, then 10K, then 5K.
2. Maximal before hard effort.
3. Race before time trial before training.
4. More recent result.

Easy and moderate efforts are not converted into race predictions. Results more
than 180 days before the plan start are not used.

Current half-marathon equivalence uses:

```text
equivalent time =
  recorded time × (21.0975 km ÷ recorded distance) ^ 1.07
```

The 1.07 exponent is linked to `E-PRED-001`. It remains an estimate: equivalent
preparation, terrain, conditions, and race execution cannot be inferred from a
single result.

The initial uncertainty is:

| Source distance | Policy uncertainty |
|---|---:|
| Half marathon | ±2% |
| 10K | ±4% |
| 5K | ±6% |

Hard rather than maximal effort, a training result, age beyond 56 days, and
conflicting eligible performances widen the estimate. These percentages are
product assumptions, not statistical confidence intervals from the cited
study.

## Race-date outcome range

The slow end is the current equivalence plus its uncertainty. The fast end also
allows bounded improvement over the available complete weeks:

```text
assumed improvement = min(0.3% × complete weeks, 6%)
```

The improvement assumption is halved when the baseline is below 20 km per week,
the longest recent run is below 10 km, or the reported interruption exceeds
seven days.

These are deliberately inspectable product assumptions. They prevent the
planner from treating every week until race day as guaranteed improvement.
Increment 3 may generate the strongest policy-valid program toward the fast end,
but the range is not a promised result.

## Target behavior

When no target is supplied:

- performance intent rounds the current equivalence up to the next five
  minutes;
- comfortable-finish intent rounds the slow end of the range up to the next
  five minutes; and
- missing eligible performance evidence produces a completion goal rather than
  an invented time.

When a target is supplied:

- `supported` means it is no faster than the fast end of the supported range;
- `aspirational` means it is up to 5% faster than that boundary, or lacks
  performance evidence; and
- `infeasible` means it exceeds that aspirational margin.

The training anchor uses a supported requested time or the planner's
recommendation. It never uses an aspirational or infeasible time.

## Policy-rule ledger

| Rule | Purpose | Evidence | Explicit assumption |
|---|---|---|---|
| `SCOPE-01` | Half marathon, 56–168 days, 3–6 core days | None | Approved Phase 1 scope |
| `PER-01` | Foundation → build/recovery → race-specific → taper → race | `E-TID-001`, `E-BLOCK-001` | Transparent traditional phases are preferred for version 1 |
| `BASE-01` | Race-equivalence estimate with uncertainty | `E-PRED-001` | Distance-specific uncertainty bands |
| `TARGET-01` | Recommendation and feasibility classification | `E-PRED-001` | Improvement, rounding, readiness, and aspiration parameters |
| `VOL-01` | Build-volume and peak boundaries | `E-INJURY-001` | A 10% construction cap smooths plans; it is not a proven injury threshold |
| `REC-01` | Reduced-volume recovery weeks | `E-IND-001` | Timing and reduction ranges are defaults |
| `INT-01` | 75–90% low intensity; at most two quality sessions | `E-TID-001` | Exact operational range and session cap |
| `LONG-01` | Long-run increase, weekly share, and peak | `E-INJURY-001` | 2 km, 40%, and 21 km construction boundaries |
| `TAPER-01` | 7–21 days; 41–60% volume reduction; retain rhythm/intensity | `E-TAPER-001` | Generator selects duration by plan length |
| `SCHED-01` | Separate demanding sessions | None | At least one easy/rest day |
| `OPTIONAL-01` | Keep recovery run removable | None | At most 12% of weekly distance |
| `MISSED-01` | Do not stack missed work | None | Preserve remaining structure and spacing |
| `RECIPE-01` | Phase-appropriate workout recipe set | `E-TID-001` | Exact prescriptions wait for Increment 3 |

The reviewed evidence is stored in
[`evidence/half-marathon-v1.json`](../evidence/half-marathon-v1.json). Policy
validation requires reciprocal links: a policy rule must cite the evidence, and
the evidence entry must list the policy rule.

## Evidence boundaries

The injury review found conflicting associations between injuries and distance,
duration, frequency, intensity, and recent changes. It did not justify a
universal 10% progression rule. Version 1 therefore treats its progression
limits as deterministic plan-construction assumptions.

The taper review covered different endurance sports, distances, and protocols.
Version 1 stays inside its reported duration and volume-reduction ranges but
does not claim one uniquely optimal half-marathon taper.

The individualized-training study combined nocturnal heart-rate variability,
perceived recovery, and running-performance status. It does not justify changing
the schedule automatically from one Oura score. Automatic response estimation
remains outside Phase 1.
