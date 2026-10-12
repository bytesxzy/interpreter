# Gold changes after seeing engine output (dev split only)

Every edit to a dev gold item that was made *after* observing the engine's behaviour is logged here, with the reason.
The held-out test split must have an empty log.

| case | change | reason |
|---|---|---|
| D011 | `from=Acme Robotics:company` -> `:organization` | The name cue "Robotics" establishes *organization*; the CEO relation's signature (`company`) only suggests a narrower type. The engine reports what is established (name cue) and records the signature inference separately; asserting `company` as known was my error. |
| D127 | `ctx=none` -> `ctx=comparison_set` | "Which one is older?" names no items; it depends on the comparison set established by the previous sentence. My original gold treated the sentence in isolation, which was wrong. Discourse keys (`dep`, `ref`, `unres`) were added to D125-D127 when the discourse layer was built. |
