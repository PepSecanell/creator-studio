# Studio Recorder

A small macOS app that records your takes. It is the recording half of the creator studio:
the Studio app decides what to film, this app films it and saves a clean take folder
that the editing agents can pick up.

It records:

* your screen, your microphone and your Mac's system audio
* a camera bubble with a shaped mask, painted in at the end by a custom compositor
* an iPhone screen over a USB cable
* camera only takes ("Just me")
* vertical Shorts (9:16) with a face framing guide
* clicks, the pointer path and zoom marks, so the edit can add smooth zooms and click highlights

It also has a teleprompter that follows your voice, a 3, 2, 1 countdown, global hotkeys and
support for a Bluetooth clicker.

## Build

You need macOS 15, Xcode and XcodeGen (`brew install xcodegen`).

```
./build.sh
```

The script generates the Xcode project, builds a Release app into `apps/recorder/build`
and prints the path of the `.app`. It never installs anything into `/Applications`.
The app is signed ad hoc, so no Apple developer account is needed. Open it from the
printed path.

To run the unit tests (no camera, no screen, no GPU):

```
xcodegen generate && xcodebuild -project StudioRecorder.xcodeproj -scheme RecorderTests test
```

The bundle id prefix lives in one place, `project.yml`.

## First start

Run `./studio setup` in the repo first. It writes `~/.config/creator-studio/config.json`,
which tells the recorder where your workspace is. Without it the app shows a short
"Run ./studio setup first" message and nothing else.

Two environment variables override the config: `CREATOR_STUDIO_CONFIG` (the path of the
config file) and `CREATOR_STUDIO_WORKSPACE` (the workspace folder).

The window title and the accent colour come from your brand. The recorder reads
`workspace/.brand/brand.resolved.json` (fields `name` and `palette.accent`), and falls back to
`brand/brand.json` in the repo. With no brand it is called Studio Recorder.

## Permissions

macOS asks once for each of these. If you tap Don't Allow, switch it on later in
System Settings, Privacy and Security.

| Permission | Used for |
|---|---|
| Camera | The camera bubble, Just me and Shorts |
| Microphone | Your voice in every take |
| Screen Recording | Screen takes only. Camera only takes do not need it. |
| Speech Recognition | The teleprompter that follows your voice |
| Input Monitoring | Only if you set up a Bluetooth clicker |

After you grant Screen Recording, quit and open the app again.
Rebuilding the app can reset these grants, because the ad hoc signature changes.

## Recording

Pick a mode at the top of the window:

* **Screen**: your display, microphone and system audio. Optional camera bubble and iPhone
  screen. Clicks and the pointer path are saved as data, so zoom and highlights can be
  changed in the edit.
* **Just me**: camera and microphone only. The whole camera frame is saved, untouched.
* **Short**: a vertical 9:16 take. The full camera frame is saved, plus a ready cut.

Press Record. After the countdown the take starts.

### Hotkeys

| Keys | Action |
|---|---|
| ⌘R | Start or stop recording |
| ⌘P | Pause or resume |
| ⌃⌥Z | Zoom in here (Screen mode) |
| ⌃⌥X | Zoom back out |
| ⌃⌥← and ⌃⌥→ | Move the teleprompter to the previous or next box |

### Bluetooth clicker

Pair a selfie clicker or presenter button in System Settings, then press Learn my button
in the app.

* One press starts a take.
* While recording, one press stops it. The last second or so, your hand reaching for the
  button, is cut off the end.
* Two quick presses throw the take away, like the trash button.
* Holding the button for about half a second moves the teleprompter to the next box.

You hear a Pop after a stop and a Basso after a discard.

## Where takes are saved

Everything goes under `workspace/takes/`. The recorder never writes anywhere else, even if
a handoff file asks it to.

```
workspace/takes/shorts/<date>-<id>-take-<n>/
workspace/takes/long/<video>/take-<n>/
```

Every take folder follows the `take/v1` contract:

| File | What it is |
|---|---|
| `take.mov` | The camera. For a Short, the full frame that the 9:16 crop is cut from. |
| `screen.mov` | The screen, with the microphone and system audio. Screen takes only. |
| `mic.wav` | The microphone on its own, 48 kHz mono. |
| `clicks.json` | Click log. Screen takes only. |
| `take.json` | Id, kind, take number, duration, frame rate, file names and the Short crop. |

A few extra files can appear: `short.mov` (the finished 9:16 cut), `composite.mov` (the screen
with bubble, phone, cursor and zoom painted in), `iphone.mov`, `cursor.json`, `zoom.json` and
`layout.json`. `take.json` lists the ones that exist.

Free recording, with no request from the Studio app, still works. Shorts go to
`takes/shorts/<date>-free-take-<n>` and long takes to `takes/long/untitled-<date>/take-<n>`.
Pick an existing video folder in the Save to menu to keep adding takes to it.

## How it hands off with the Studio app

The Studio app writes a request into `workspace/handoff/`:

* `next_take.json` for a Short
* `next_recording.json` for a long video

Both use the `handoff/v1` format. The recorder checks the folder every two seconds. It
ignores a request older than six hours, and a request it has already used (same `id` and
`created`). When a new one arrives it sets the mode, loads the script or talking points into
the teleprompter and writes the next take into the `out_dir` the request names. A banner shows
what you are recording, and Not this one lets go of it. If the folder already holds a take,
the take number counts up.

The app's `Info.plist` carries `CSHandoff = 1`, so the Studio app can check that the recorder
it finds understands these files.

## Notes

* Only the first audio track of `take.mov` and `screen.mov` is the microphone. In a screen
  take the system audio is a second track.
* Takes that finish in the background (painting the overlays into `composite.mov`) show a
  progress line. You can record the next take while they run.
* Logs are written to `~/Library/Logs/Studio Recorder.log`.
* Set a preferred microphone by name with
  `defaults write io.github.creatorstudio.recorder preferredMicName "<name>"`.
