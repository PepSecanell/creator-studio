---
name: motion
description: Make, change or review a motion graphics component in motion/ (HyperFrames, brand tokened). Use for "new animation", "add a comp", "this graphic looks cheap", or when the creative director needs a component the catalogue does not have.
---

# Motion components

Every component lives in `motion/comps/<name>/` and reads only the `--cs-*` tokens, so it changes
look when the brand changes. Read `motion/README.md` for the folder contract and the render command.

## The craft floor

- One idea per component. If it needs a paragraph to explain, it is two components.
- At most 3 labels, at most 6 words each.
- Reveals use masks, wipes along an edge, or a line drawing on. Avoid plain fades.
- Motion has a reason: things arrive in reading order, the key value lands last and holds.
- Respect the zones. `split` keeps the face side clear, `full` respects the platform UI safe zones.
- Light ground by default. Contrast passes in all three looks.

## Workflow

1. Copy the closest existing component, rename it, change one thing at a time.
2. Write `vars.example.json` and the vars schema.
3. `node motion/render.mjs --comp <name> --vars motion/comps/<name>/vars.example.json --out /tmp/x.webm --zone split --size 1080x1920 --duration 4`
4. Run `motion/lint` and `motion/preview <look>`, open the PNGs and look at them honestly.
5. Check it in all three looks before you call it done.
