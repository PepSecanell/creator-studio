---
name: package
description: Write the titles, captions, hashtags, pinned comments, descriptions and chapters for a finished video in the brand's voice, then build the day's posting kit. Use for "package this", "write the captions", "make today's kit", or after an edit reaches ready_for_review.
---

# Package and kit

Nothing here posts anything. The output is files a person posts by hand.

## Per video

`./studio package <edit>` drafts POSTING.md (Shorts) or DESCRIPTION.md (long) from the brand voice.
Then read it and fix by hand what reads like a machine wrote it:

- Write the way the creator talks (`brand.voice.tone`). Short sentences. Plain words.
- No em dashes or en dashes. No words from `brand.voice.banned`. None of: unlock, game changer,
  dive in, seamless, elevate, in today's world.
- Titles: name the real thing or the result. A search phrase or a specific number beats a clever line.
- Shorts title for YouTube: the phrase someone would type to find this.
- Caption: the first line works alone, as the hook again in different words.
- Pinned comment: a question people can answer in three words.
- Hashtags: 3 to 5, specific beats popular.
- Long videos: description opens with the promise, then chapters with times from the real cut,
  then `brand.voice.cta` and `brand.voice.link`.

## The kit

`./studio kit [date]` collects everything approved for that day into `workspace/kits/<date>/`:
per platform video files, the cover, and `kit.json` with every caption ready to copy. Post times
follow `brand.schedule`.
