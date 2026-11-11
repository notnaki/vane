# Subscription streaming: observed compatibility

Live checks on **2026-11-11** verified Netflix 4K SDR, Netflix 4K Dolby Vision,
and Spotify music playback in the installed Vane app. These are scoped playback
observations, not a certification of every title, account, device, or macOS version.

## Tested environment

- Installed app: **Vane 0.1.1-nightly.20261111.1**, bundle version **641**,
  `io.github.notnaki.vane`, at `/Applications/Vane.app`.
- Developer ID signature, Hardened Runtime, and stapled notarization ticket were
  present. No rebuilt app or disposable test copy supplied these live results.
- Executable SHA-256:
  `4ae9cccd68c976bb511272b8977c3b8b54e2b3952f9e32796aaf8b347661cbc6`.
  The bundle did not expose a source commit identifier; the current documentation
  checkout is not evidence of the installed app's exact source revision.
- **macOS 27.0.1 (26A434)**, Apple M1 Max, built-in Liquid Retina XDR display;
  physical panel resolution **3024 × 1964**, desktop scaling **1512 × 982**.
  A 3840 × 2160 stream is decoded and scaled to this display; it does not turn the
  physical panel into a native 4K display.
- System WebKit, Safari-style user agent. Netflix's player reported
  `Version/27.0.1 Safari/605.1.15`. No user-agent switch or DRM bypass was used.
- Existing signed-in accounts in the user's normal Vane profile. Netflix's
  account page showed **Premium**, and its active profile used **Auto** data
  usage. Account identifiers, credentials, session identifiers, and raw account
  screenshots are deliberately excluded from this report.
- Native Vane UI and its Web Inspector were used. Playback statistics describe
  the actual installed app, not a separate preview browser or a public DRM demo.

## Results and limits

| Service / flow | Result | Verified level | Evidence and boundary |
| --- | --- | --- | --- |
| Netflix, *Power*, season 1 episode 1 (`80091071`) | **Pass** | **1920 × 1080 SDR**, HEVC, FairPlay | Player reported video bitrate 1,852 kbps, 23.976 fps, normal buffering, and zero dropped/corrupted frames at the sampled point. The title page showed HD in this session. This observation alone did not establish a Vane-wide 1080p ceiling. |
| Netflix, *Dark*, season 1 episode 1 (`80114790`) | **Pass** | **3840 × 2160 SDR**, HEVC, FairPlay | Actual playing resolution rose from 1080p to 2160p. A later sample reported 13,609 kbps video and zero dropped/corrupted frames after 1,788 frames. The initial HD title badge did not predict the eventual 4K stream. |
| Netflix, *Our Planet II*, episode 1, “World on the Move” (`81236554`) | **Pass** | **3840 × 2160 Dolby Vision**, FairPlay | Playing time advanced from 16.464 s to 47.545 s; the later sample reported 4K, `dyhe.05.01` video, `CE4_DoVi_DO_v1,MCCLEAREN_DV,NOP,identPOI` tags, 3,205 kbps video, 23.976 fps, 1,010 frames, and zero dropped/corrupted frames. The buffering bitrate was 17,680 kbps; that is distinct from the bitrate currently playing. |
| Netflix audio in these samples | **Pass** | **2-channel HE-AAC, 128 kbps** | Player reported `audio/mp4;codecs=mp4a.40.5`, channels 2.0. The nature title also reported `SpeakerSpatialAudio`. This does not verify discrete surround sound or Dolby Atmos output. |
| Spotify Web Player, signed-in browsing and Spotify Connect | **Pass** | Library/settings load; existing remote playback is represented | The initial player correctly displayed an iPhone as the playback destination with advancing track progress. Remote progress alone was not counted as local browser audio. |
| Spotify Web Player, local music playback | **Pass, quality unmeasured** | Local playback, pause/resume; **Automatic** streaming quality | After choosing **This web browser**, the remote-device banner disappeared, local volume controls became available, track progress advanced, and `navigator.mediaSession.playbackState` reported `playing`. Pause changed the main control to Play; resume changed it back to Pause. The user also confirmed playback. The quality menu exposed only Automatic in the observed session. Actual codec, bitrate, sample rate, bit depth, and lossless delivery were not measured. |
| Disney+ subscription playback | **Blocked / unverified** | Sign-in page loads | `disneyplus.com` redirected to `/identity/login/enter-email` in the tested profile. No authenticated video was available for this pass. Resolution, HDR, audio format, DRM licensing, and playback controls cannot be scored as passes from the login page. |

Netflix reported `com.apple.fps.3_0` as the active key system and usable keys for
the selected representations. The HDR pass is supported by the **playing Dolby
Vision codec and tags**, not just the separate `HDR support: true
(media-capabilities)` line. Physical display luminance, color accuracy, HDR10
fallback, external-display HDCP, and Dolby Atmos were not independently measured.

These were short checks, not full episodes, long listening sessions, or a network
recovery test. Minimum macOS 26, Intel Macs, other displays, other subscription
tiers, fresh login/MFA, relaunch persistence, offline downloads, casting, and every
service feature remain outside this evidence.

## Observations that should not be mistaken for playback limits

- **Adaptive ramp-up:** Netflix initially played 1080p while buffering a higher
  representation, then actually played 4K. A title badge, a usable 2160p key, a
  buffering bitrate, or an HDR capability flag alone is insufficient evidence of
  the currently decoded stream.
- **Duplicate playback:** Opening a second Netflix player while the first was
  paused produced **S7020**, with Netflix asking for other player tabs to close.
  Testing one player in the original tab allowed playback. No product fix was
  established by this observation.
- **Autofill console noise:** Repeated cross-origin `SecurityError` messages were
  traced through Web Inspector's source link to Vane's password-autofill script.
  They also appeared on Spotify. They are a separate observed issue; these checks
  did not establish that they cause a quality downgrade. Netflix still played
  4K SDR and Dolby Vision with the installed app's scripts present.
- **Source maps:** Netflix's `playercore.js.map` request returned 403 in Web
  Inspector. A failed developer source-map request is not itself evidence that a
  media segment or license request failed.
- **Spotify media lookup:** A read-only `document.querySelectorAll('audio,video')`
  query returned an empty list even after the local playback UI was active. This
  query does not cover detached elements or other execution contexts and was not
  used to declare playback broken or to infer its codec/DRM system.
- **Zoom:** Choosing View → Actual Size did not visibly shrink Netflix's controls.
  This pass did not identify the cause of the large-control appearance, and page
  UI size was not used to infer stream resolution.

## Repeating the checks

1. Record the installed Vane version, executable hash, macOS version, display,
   account tier, and existing quality setting. Keep personal account/session data
   out of published evidence.
2. Use one Netflix player tab. Play the selected content and open Netflix's
   diagnostics with **Control–Option–Shift–D**. Allow adaptive quality to settle;
   record **Playing bitrate** and its resolution, video codec/tags, key system,
   advancing time, frames, and dropped/corrupted frames. Record buffering values
   separately. Pause when finished.
3. For Spotify, first check the Connect destination. If it is another device,
   explicitly select **This web browser** before scoring local playback. Confirm
   local controls, advancing progress, and pause/resume. Read Settings → Audio
   quality; do not turn Automatic into an assumed measured kbps rate. DOM media
   queries and Media Session metadata alone do not establish the audio format.
4. For Disney+, use an authenticated subscribed profile, start protected content,
   and measure the actual decoded video and audio before replacing the unverified
   row. Catalog labels and supported-device documentation are not a live playback
   pass.

The older public-demo and native-fixture results remain in
[Real-site compatibility evidence](REAL-SITE-COMPATIBILITY.md).
