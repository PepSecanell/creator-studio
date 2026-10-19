---
name: edit-short
description: Edit one vertical Short from a recorded take into final.mp4, cover.jpg and POSTING.md, in the channel's own look. Use for "edit this short", "edit take <id>", "edit pending shorts", or when a take folder under workspace/takes/shorts/ has no finished edit.
---

# Edit a Short

The creator only records. You do the rest, in this order, and the look comes from the brand file,
never from you.

## Inputs

- Take folder: `workspace/takes/shorts/<date>-<card_id>-take-<n>/` (one or more takes of the same card)
- Card: the matching entry in `workspace/shorts/week-NN/cards.json` (find it by `card_id`)
- Brand: `workspace/.brand/brand.resolved.json` (run `./studio brand build` if it is missing)

The edit folder is `workspace/edits/shorts/<card_id>/`. Intermediate files go in `work/`.

## Steps

1. **Status.** Write `status.json` with state `editing`.
2. **Words and cut.** `./studio words <take>` then `./studio cut <take>`. With several takes of the
   same card, cut each and pick the best hook take: the one where the first line is clean, about the
   viewer and lands inside 2 seconds. Scriptless takes are normal: the transcript is the script and
   the card only gives the intent. Keep deliberate pauses only if `brand.editing.keep_pauses` is true.
3. **Facts.** If the card has `facts`, check each one is what was actually said. If something said
   on camera is wrong, set `needs_you` with the timestamp. Never fix a fact by editing words.
4. **Design.** Call the `creative-director` agent with the edit folder, the card and the cut. It
   writes `creative.json` and runs `./studio check creative`.
5. **Build.** Call the `editor` agent, or run the steps yourself:
   `./studio spec from-creative <edit>`, `./studio render motion <edit>`, `./studio build short <edit>`,
   `./studio cover <edit>`, `./studio package <edit>`, `./studio check edit <edit>`.
6. **QA.** Call the `qa` agent. It opens real frames and sets the final state.
7. **Report.** One paragraph: where the video is, its length, the hook line, what QA said.

## What good looks like

- Under `brand.editing.max_short_seconds`, usually 20 to 45 s.
- Frame 1 is the topic moving. The hook is readable by 1.5 s. No intro, no logo first.
- Captions on every spoken line, one emphasis word each, never across the face.
- One thing to read at a time. A motion graphic only where it makes the line clearer.
- The end line from the card, then the brand's call to action on the end card.
- POSTING.md has a title, caption, hashtags and a pinned comment per platform, in the brand voice,
  no em or en dashes.

## When things fail

- Transcription empty: check the take has audio (`ffprobe`), then `./studio doctor`.
- A comp fails to render: drop that beat, note it in `status.json`, keep going.
- Anything you cannot fix mechanically: state `needs_you` with a clear note. Never ship a broken beat.
