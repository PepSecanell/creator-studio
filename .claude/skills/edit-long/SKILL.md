---
name: edit-long
description: Edit one long horizontal video (talking head, screen recording with a camera bubble, or both) into final.mp4, chapters, a thumbnail base and DESCRIPTION.md in the channel's look. Use for "edit the long video", "edit <slug>", or a take folder under workspace/takes/long/ with no finished edit.
---

# Edit a long video

## Inputs

- Take folder: `workspace/takes/long/<slug>/take-<n>/` with `take.mov` (camera), optional
  `screen.mov`, `mic.wav`, `clicks.json`, and `take.json`.
- Plan: `workspace/long/<slug>/video.json` (title, map or script, thumbnail ideas, description draft).
- Brand: `workspace/.brand/brand.resolved.json`.

The edit folder is `workspace/edits/long/<slug>/`.

## Steps

1. `status.json` state `editing`.
2. `./studio words <take>` and `./studio cut <take>`. For scripted takes the cut aligns to the script
   so deliberate repeats are kept. For map takes the transcript is the script.
3. **Promise check.** The title's promise must be said in the first 30 seconds (about 75 words).
   If it is not, note it for the creator. Do not reorder the video to fake it.
4. **Design.** Call `creative-director`. For long videos it also plans the "where we are" element
   (progress, chapter strip, a list that ticks off) and the chapter turns. Screen beats use the real
   screen, zoomed with `callout` where the click log shows the action.
5. **Build.** `./studio spec from-creative <edit>`, `./studio render motion <edit>`,
   `./studio build long <edit>`, `./studio cover <edit>` (thumbnail base frame plus the 3 thumbnail
   ideas from the plan), `./studio package <edit>` (title options, description, chapters),
   `./studio check edit <edit>`.
6. **QA.** Call `qa`, then report.

## What good looks like

- The open shows the result or the thing itself, not a greeting.
- The camera bubble never hides the part of the screen being talked about.
- Chapter times in DESCRIPTION.md match the real cut.
- Thumbnails: 3 structurally different ideas (a number, a face with a line, a before and after),
  never 3 versions of the same idea.
