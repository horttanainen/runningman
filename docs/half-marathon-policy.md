# Half-marathon policy

Status: implemented

This document explains what the `half-marathon` policy does, which parts are linked to
research, and which parts are transparent product assumptions. The policy file
is the executable source of truth:
[`policies/half-marathon.json`](../policies/half-marathon.json).

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

For a trail goal, the flat-running equivalence is displayed only as baseline
context. The planner does not turn it into a predicted trail finish time or a
kilometre pace. Gradient, surface, technicality, altitude, and descending skill
make that precision unsupported, so the target becomes effort-based completion
and all trail prescriptions use RPE and breathing cues.

## Policy-rule ledger

| Rule | Purpose | Evidence | Explicit assumption |
|---|---|---|---|
| `SCOPE-01` | Half marathon, 55–168 days, 3–6 distance-based or 2–6 duration-based core days | None | Approved product scope; 55 days admits a Monday start before a Saturday race |
| `PER-01` | Foundation → build/recovery → race-specific → taper → race | `E-TID-001`, `E-BLOCK-001` | Transparent traditional phases are preferred for version 2 |
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
| `RECIPE-01` | Phase-appropriate recipes and explicit quality-work progression | `E-TID-001` | Exact work increments, repetition formats, and recoveries are deterministic construction choices |
| `TRAIL-01` | Course-aware vertical progression, trail specificity, effort pacing, and controlled descending | `E-TRAIL-PERF-001`, `E-DOWNHILL-001`, `E-TRAIL-INJURY-001` | Exact ascent caps, fractions, and session counts are conservative construction choices |

The reviewed evidence is stored in
[`evidence/half-marathon.json`](../evidence/half-marathon.json). Policy
validation requires reciprocal links: a policy rule must cite the evidence, and
the evidence entry must list the policy rule.

## Quality-work progression

Policy version 2 makes the progression of the weekly quality session explicit.
Every quality workout records:

- its stage and phase week;
- the work distance and previous quality-work distance;
- repetition distance and count where applicable;
- recovery duration; and
- the load method: establish, progress, recovery reduction, race-specific
  progression, taper reduction, or race-week sharpening.

Foundation intervals retain 1 km repetitions and two-minute recoveries. Work
progresses by adding a whole repetition, subject to the weekly-distance and
session caps. Build and race-specific stages progress continuous work without
regressing at a stage transition. Recovery, taper, and race-week stages must
reduce or hold quality work relative to the preceding quality session. The
independent plan validator recomputes these relationships and rejects edited
proposals whose structured segments and progression record disagree.

In a low-volume taper week, the minimum warm-up and cooldown may reduce from
1 km to 500 m each so the retained quality dose fits inside the weekly quality
cap. Both segments remain explicit and must be non-zero.

These exact increments and formats are transparent product assumptions. The
cited intensity-distribution evidence supports controlled quality within a
mostly low-intensity program, but does not identify one universally optimal
repetition sequence.

## Trail-specific progression

A profile with `goal.course.surface.value` set to `trail` must supply race
ascent and technicality. Race descent may remain unknown. When recent average
weekly ascent and longest-run ascent are present, they provide the vertical
baseline. Otherwise, the same trail modifier uses an explicit conservative
course-relative construction regardless of running frequency or load basis.
The trail policy currently supports races with no more
than 1,500 m of ascent. The generator then adds:

- weekly and long-run ascent targets with structured provenance;
- no more than 15% ascent growth from the immediately preceding non-taper week;
- an ascent peak bounded by both the baseline and race-course demand;
- reduced vertical load in recovery and taper weeks;
- uphill repetitions or sustained uphill effort in quality sessions;
- at least one trail-specific core session each week; and
- controlled descending, with hard descending removed during the final 14 days.

The race week contains the course's complete vertical demand, so it is excluded
from the training-week ascent-growth check. Core trail sessions are allocated
explicit terrain and vertical targets, while optional recovery remains freely
removable and carries no required ascent.

The runner profile selects distance- or duration-based training load explicitly.
That selection is independent of running frequency and trail surface. Duration
load allocates one explicit time-based quality session, one long run or hike,
and easy sessions on remaining available days. The same phase, recovery, taper,
spacing, provenance, and validation rules apply at every supported frequency.
Unknown ascent history starts from 30% of race
ascent, is capped at 80% before race week, and uses the normal 15% weekly growth
limit. These percentages and duration increments are conservative product
assumptions, not claims of a uniquely optimal training dose. Other exercise is
outside the generated plan and receives no running-distance or ascent credit.

The trail-running performance review identifies physiological, neuromuscular,
biomechanical, and course characteristics relevant to performance
([de Waal et al.](https://pubmed.ncbi.nlm.nih.gov/33508776/)). The downhill
review describes the muscle-damage and neuromuscular demands of prolonged
downhill running and the protective repeated-bout effect
([Bontemps et al.](https://pubmed.ncbi.nlm.nih.gov/33037592/)). The clinical
review supports terrain-specific preparation and highlights common lower-limb
injury considerations
([Vincent et al.](https://pmc.ncbi.nlm.nih.gov/articles/PMC8811510/)). These
sources support specificity, progressive exposure, and caution around downhill
load; they do not validate a universal 15% ascent rule or the exact fractions
encoded here. Those numbers remain visible product assumptions.

## Evidence boundaries

The injury review found conflicting associations between injuries and distance,
duration, frequency, intensity, and recent changes. It did not justify a
universal 10% progression rule. Version 2 therefore treats its progression
limits as deterministic plan-construction assumptions.

The taper review covered different endurance sports, distances, and protocols.
Version 2 stays inside its reported duration and volume-reduction ranges but
does not claim one uniquely optimal half-marathon taper.

The individualized-training study combined nocturnal heart-rate variability,
perceived recovery, and running-performance status. It does not justify
changing the schedule automatically from one Oura score. The versioned local
review classifier therefore requires persistent low wearable scores, labels
its thresholds as product assumptions, and only requests human review; it
never changes the schedule.
