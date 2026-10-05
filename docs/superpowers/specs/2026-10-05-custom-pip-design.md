# Custom Picture in Picture

## Intent

Replace the visible macOS Picture in Picture window with a Vane-owned floating
window. The user wants the controls shown in their screenshot, unrestricted window
placement, and Back to Tab to fade the window out in place before revealing the
source tab. Preserve playback on sites that currently support Vane PiP.

The user approved this direction on 2026-10-05 and asked whether existing site
compatibility will be preserved. The working build must be shown to the user and explicitly approved before merging.

## User experience

- Drag the video background to any position on any connected display. Do not snap
  to corners. Keep the window above ordinary application windows and available
  alongside full-screen applications. Reopening remembers the custom position and size,
  recovering onto a connected display when necessary.
- Entry moves the original live video from its actual inline rectangle to the
  saved placement in a single 280 ms motion. Both axes and size share progress,
  without bounce. Preserve raw source geometry separately from the natural-aspect,
  minimum-sized destination. Reduce Motion retains an in-place appearance. Dragging
  takes over immediately; an early exit must not save an intermediate flight frame.
- Resize with a stable video aspect ratio. Preserve a usable minimum size and
  adapt the control labels to compact sizes rather than overlapping them.
- Show rounded glass controls on hover: Back to Tab at the upper left, the source
  hostname in the header, and Minimize and Close at the upper right.
- Show play/pause between backward and forward 15-second controls at the center,
  with a seek bar along the bottom. Hide or disable seeking when the video has no
  seekable range. Keep controls visible during pointer interaction and keyboard
  focus; fade them away when idle. Supply accessibility names for each control.
- Back to Tab fades only the window's opacity, retaining its exact position and
  size during the fade. Then return the video inline, reveal its source Space and
  tab, restore the source browser window if minimized, and activate Vane. Playback
  continues. There must be no visible native fly-back animation.
- Minimize returns playback to the existing sidebar player and keeps it playing.
  Close pauses the selected video and dismisses PiP without navigating the user.
- Preserve existing manual PiP, automatic PiP, and sidebar restore behavior.

## Existing implementation

`PictureInPicture.swift` requests WebKit presentation changes in the frame holding
the selected video. `Engine.swift` observes those changes and updates the tab and
media state. `PiPMinimizeControls.swift` discovers a native `PIPPanel` containing
`WebVideoViewContainer` and places a second panel above the remote system controls.
`MediaPlayer.swift` retains the selected media source across PiP minimization and
routes media commands to its frame.

WebKit uses a remote video layer and the private PIP framework for its macOS PiP
presentation. Its exit path supplies a replacement window and rectangle to the
system controller, which animates the return. An ordinary Vane panel can own drag
and fade behavior, but reliable live video hosting in that panel must be verified.

Reference inspected: WebKit's
[VideoPresentationInterfaceMac.mm](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/mac/VideoPresentationInterfaceMac.mm).

## Approach and feasibility gate

Prefer hosting the existing live WebKit video presentation view in a Vane-owned
AppKit panel while preserving the source element, frame, decoder, cookies, and
media session. Avoid a second player loaded from the video's URL: that would
change authentication and break blob URLs, Media Source players, and potentially
protected playback. Moving the entire page into the panel would preserve its
session but alter page layout and leave no live page in the original tab.

The first implementation step is a focused hosting experiment. Verify that the
existing presentation view can render live, resize, and return inline in a custom
panel while the native window stays invisible throughout entry and exit. Merely
overlaying a native PiP window does not satisfy this design.

Private WebKit presentation details are not a supported arbitrary-hosting API.
Do not claim this approach works until a live test proves it. If it cannot pass
the hosting experiment, report the limitation and revisit the design before
replacing the current implementation.

## Ownership and lifecycle

Give each custom presentation one owner associated with its tab, source frame,
web view, and original presentation host. Keep ownership separate from the view
that draws controls. The owner handles attachment, detachment, state observation,
and cancellation. The panel handles layout, dragging, resizing, and accessibility.

Route commands to the captured PiP video, never to a newly selected largest video
or unrelated playing advertisement. Extend the isolated PiP bridge for playback
position and seek commands as necessary; pass bounded numbers as JavaScript
arguments. Reflect actual playback state rather than optimistic button state.

Restore the video host before teardown when required by WebKit. Release the panel,
tasks, and observations when the tab closes, navigates, crashes, replaces its web
view, or exits PiP from page controls. Prevent delayed callbacks from attaching a
window to a stale tab or frame. Preserve existing automatic-PiP ownership and
minimize suppression rules.

## Compatibility contract

All currently working sites remaining playable is the release target, not an
already verified guarantee. Test ordinary video, Media Source/blob playback,
cross-origin embedded video, and protected playback that already works in the
baseline build. Each case must preserve the original session and advance live
video frames and time; hearing audio alone is insufficient evidence.

If the custom host cannot attach safely, leave the existing native PiP working
and clean up all partial custom state. A native fallback preserves playback but
does not provide custom placement or controls on that case. Report any such
exceptions explicitly rather than calling them full custom-PiP support.

## Validation and delivery

Add meaningful regressions for arbitrary placement, aspect-preserving resize,
source-specific play/pause and seeking, and Back to Tab preserving geometry
during its fade. Extend the existing WebKit media tests for automatic entry and
exit, return without pause, minimize and restore, close with pause, late ad frames,
source-frame removal, navigation, and cleanup. Observe live frame changes as well
as playback-time progress during the hosting experiment.

Manually verify compact and large layouts, hover and keyboard controls, multiple
displays, full-screen spaces, source-window minimization, and the supported-site
matrix. Record which protected site and account were tested; do not infer all DRM
compatibility from a plain-video fixture.

Run the relevant README build and checks. Carry the change through a PR,
independent review of the latest diff, fixes, passing required CI and approvals,
and, after the user has inspected and explicitly approved the working build,
squash-merge under the repository workflow. Track and quit every task-owned
test application after merge or abandonment.

The user-approved fade-only checkpoint is `a1865392a931d401d9a33741c5140992eda685a1`,
saved on `codex/custom-pip-fade-checkpoint` before the requested movement experiment.
