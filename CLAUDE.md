# Working in this repo

This is a creator studio: a desktop app for ideas and cards, a recorder, and a video pipeline that
Claude Code agents drive. The person using it records. You edit.

## Read first

- `docs/CONTRACTS.md` is the source of truth for every file the parts exchange. Follow it exactly.
- `brand/brand.json` is the channel. Everything the viewer sees (look, colours, fonts, voice, call
  to action) comes from it. Never hardcode a name, colour, font or tone anywhere else.
- `workspace/` holds the user's data. It is not in git. Never delete takes.

## Agents and skills

| Job | Use |
|---|---|
| Edit a Short | skill `edit-short` |
| Edit a long video | skill `edit-long` |
| Captions, titles, posting kit | skill `package` |
| New or better motion graphic | skill `motion` |
| Design vision and beat plan | agent `creative-director` (Opus) |
| Mechanical build steps | agent `editor` (Sonnet) |
| Last look at the finished cut | agent `qa` (Sonnet) |

Creative calls run on Opus. Everything mechanical runs on Sonnet. A stronger model on a mechanical
step buys nothing.

## Rules

- Run `./studio` commands instead of writing one off video scripts. If a command is missing,
  add it to `cstudio/` properly.
- No em dashes or en dashes in anything a viewer reads.
- Never post to any platform. The posting kit is files for a person.
- Never put a graphic over the face.
- When something fails, read the whole error, fix the cause, and write down any quirk you learned in
  the relevant README so the next run does not hit it.
