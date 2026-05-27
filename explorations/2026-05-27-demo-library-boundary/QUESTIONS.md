# Questions driving this exploration

Motivation: `ContentView` in both demos feels overloaded — video switching,
detector switching, filter changes, session/task lifecycle. Should that logic
live in the Iris library so consumers don't re-implement it? Prompted also by an
upcoming feature: **optional external player controls**.

- When we **switch a video**, what happens, in what order, and who owns each step (demo vs library)?
- When we **switch a detector**, same question.
- When we **change a detector filter/threshold setting**, same — and how does the cache survive vs. invalidate?
- How is the **detection cache** maintained across all three?
- For **player controls**: when a button is pressed, how does the intent propagate through the system, what reacts, and what is the source of truth ("how do we know we got it right")?
- What would an **optional external player controls** API need — is there already a seam?
- Net: where is the demo/library boundary currently drawn, and where *should* it be?
