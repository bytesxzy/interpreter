# Gold changes after seeing engine output (dev split only)

Every edit to a dev gold item that was made *after* observing the engine's behaviour is logged here, with the reason.
The held-out test split must have an empty log.

| case | change | reason |
|---|---|---|
| D011 | `from=Acme Robotics:company` -> `:organization` | The name cue "Robotics" establishes *organization*; the CEO relation's signature (`company`) only suggests a narrower type. The engine reports what is established (name cue) and records the signature inference separately; asserting `company` as known was my error. |
| D127 | `ctx=none` -> `ctx=comparison_set` | "Which one is older?" names no items; it depends on the comparison set established by the previous sentence. My original gold treated the sentence in isolation, which was wrong. Discourse keys (`dep`, `ref`, `unres`) were added to D125-D127 when the discourse layer was built. |
| D093 | removed `neg=none` (kept `pol=negative`) | Round-2 independent authors (blind2 C116, "Which companies do not hire interns?") record a negated predicate over a typed wh-noun as a negative constraint (`type:company+hires:intern`). The format document defines `neg=none` as "the request contains no negation"; "Which claims are NOT supported by ..." does contain one, so `neg=none` was my error. The engine now emits the exclusion (claims minus those supported); the item is left unasserted rather than rewritten to the new value. |
| V066 (val) | removed `neg=none` | Same reason as D093 - this is the only edit ever made to a validation gold item; it is logged here so the calibration cross-fit can be re-run on the corrected labels. |

