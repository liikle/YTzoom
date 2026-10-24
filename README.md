# YTzoom

An open-source YouTube enhancement for iOS.

## Features

| Area | Included |
|---|---|
| Downloads | Video, audio, Shorts and whole-playlist downloads; save to the library, Photos or the share sheet; sorting; backup and restore |
| Queue | Play next or play last without Premium, with reorder, swipe to remove, shuffle, loop and clear |
| Playback | Background playback, PiP, loop, speed controls, default speed, gestures, tap to seek and an HLS playback mode |
| SponsorBlock | Category controls, progress markers, skip modes and configurable alerts |
| Interface | OLED mode, overlay controls, navigation cleanup and native share sheets |
| Liquid Glass | Glass tab bar, top bar buttons, menus, sheets, player buttons and YTzoom popups on iOS 26, with shrink on scroll and a selected tab color |
| Tabs | Hide, reorder and add YouTube destinations |
| Library | Downloaded video, Shorts and audio players with resume support |
| Settings | Searchable settings, 15 languages and a native YouTube settings section |
| AI titles | A Gemini-powered button next to the Shorts title box that suggests titles from the video and the text you added |
| Moshly camera | Live datamosh between Shorts clips, a ghost of the last clip, 0.5× lens, stabilization and 60 fps |
| Region testing | Tell YouTube you are in another country (US, UK, Japan and more) to test region-locked features |

## Compatibility

- **iOS:** 15.0 and newer (tweak packages); the prebuilt IPAs follow their YouTube base
- **Architecture:** arm64
- **YTzoom:** 1.1.2

YouTube 21.41.5 requires iOS 17, so two IPAs are published:

| IPA | YouTube base | iOS |
| --- | --- | --- |
| `YTzoom_1.1.2_YouTube_iOS16_21.33.6.ipa` | 21.33.6 | 16.0 and newer |
| `YTzoom_1.1.2_YouTube_21.41.5.ipa` | 21.41.5 | 17.0 and newer |

Pick the 21.41.5 build unless you are on iOS 16. Either one installs with TrollStore or a developer-certificate sideloader.

## Install

**Jailbroken.** Add the repository in Sileo, Zebra or Cydia:

```
https://liikle.github.io/ytzoom/
```

Rootless and roothide packages are both published. The repository page also has an
[Add to Sileo](https://liikle.github.io/ytzoom/) button.

**Sideloaded.** Download the IPA for your iOS version from the [latest release](https://github.com/liikle/ytzoom/releases/latest) and install it with TrollStore, AltStore, SideStore or LiveContainer.

## Build

Fork the repository, enable Actions, open the **IPA** workflow and provide a direct link to a decrypted YouTube IPA you are legally allowed to use. The completed workflow provides the injected IPA as an artifact. The **Deb** workflow builds the tweak package.

To build both IPAs in one run, fill in the second URL field as well: the workflow takes an iOS 16 base (21.33.6) and an optional iOS 17+ base (21.41.5), and uploads them as separate artifacts. Leaving the second field empty builds a single IPA.

## Settings

Open the YTzoom tab and tap the gear, or open YouTube Settings and choose YTzoom.
Both pages carry the same options, and the YouTube Settings section has a search bar.

## AI Titles

1. Get a Gemini API key at [aistudio.google.com](https://aistudio.google.com/apikey).
2. Open YTzoom settings → **AI & Region**, turn on **AI Title Button** and paste the key into **Gemini API Key**.
3. When you upload a Short, tap the ✨ button next to the title box. Pick one of the 5 suggested titles (1–4 words, sometimes
   ending in an emoji), or tap **Regenerate** for 5 new ones.

Gemini receives a few frames from your video (or a screenshot of the upload screen if no video
frames can be read), the text you typed in the Shorts editor and your draft title. The key stays on
the device and is left out of YTzoom backups. If the button doesn't show up on the upload screen,
set **Show Button On** to **Any Text Box**, then hold the button to copy the screen's class names and
open an issue with them.

## Moshly Camera

The Shorts camera keeps YouTube's screen, music picker and upload flow, with Moshly's datamosh engine
underneath. Record a clip; its last frame stays on screen as a ghost so you can line up the next shot.
Record the next clip and it smears out of the last one, live in the preview and in the recorded video.
Deleting the last clip in YouTube brings back the ghost of the clip before it.

Buttons on the left of the camera:

- **Datamosh** (wand): on or off. Hold it to forget the last clip and start fresh.
- **Lens**: 1× or 0.5× ultra-wide.
- **Stabilization**: off by default, because it changes how the mosh moves.
- **60/30**: frame rate. 60 fps is the default and falls back to 30 on lenses that can't do it.

It is real H.264 datamoshing, matching Moshly's Classic effect: a live VideoToolbox encoder and decoder
(`Tweak/Features/Mosh/MoshCodec.*`) run against each other, dropping keyframes, withholding each clip's
first frame and resubmitting P-frames so the motion compounds. **Mosh Strength** (1 clean to 5) sets how
many times. Because it is a codec round-trip inside YouTube's capture path, it is heavier than a filter —
report anything that stutters or drops frames on your device.

## Hold All Comments

On the upload page, a button below the download button sets Comments to **Hold all** in one tap. YouTube
sends that menu's text from its servers, so if your YouTube isn't in English, set **Hold All Option Text**
under YTzoom settings → Shorts → Upload to the option's name in your language.

## Region Testing

**AI & Region → Pretend to Be In** changes the country, and optionally the language, time zone and
locale, that YouTube is told on every request. Restart YouTube after changing it. YouTube can still
see your real location from your IP address and account, so features gated on the server usually
also need a VPN in that country. Use a test account.

## Screenshots

<p align="center">
  <img src="screenshots/framed/settings.png" width="220" alt="YTzoom settings">
  <img src="screenshots/framed/video-download-menu.png" width="220" alt="Video download menu">
  <img src="screenshots/framed/audio-player.png" width="220" alt="Audio player">
</p>

<p align="center">
  <sub>Settings · Downloads · Audio Player</sub>
</p>

<p align="center">
  <img src="screenshots/framed/glass-menu.png" width="220" alt="Liquid Glass menu">
  <img src="screenshots/framed/glass-quality-sheet.png" width="220" alt="Liquid Glass quality sheet">
  <img src="screenshots/framed/glass-download.png" width="220" alt="Liquid Glass download progress">
</p>

<p align="center">
  <sub>Liquid Glass · Menus · Sheets · Tab Bar</sub>
</p>

<details>
  <summary>More screenshots</summary>
  <br>
  <p align="center">
    <img src="screenshots/framed/shorts-download-menu.png" width="190" alt="Shorts download menu">
    <img src="screenshots/framed/tab-editor.png" width="190" alt="Tab editor">
    <img src="screenshots/framed/download-progress.png" width="190" alt="Download progress">
  </p>
  <p align="center">
    <img src="screenshots/framed/download-library.png" width="190" alt="Download library">
    <img src="screenshots/framed/video-player.png" width="190" alt="Downloaded video player">
    <img src="screenshots/framed/player-settings.png" width="190" alt="Player settings">
  </p>
  <p align="center">
    <img src="screenshots/framed/sponsorblock-settings.png" width="190" alt="SponsorBlock settings">
    <img src="screenshots/framed/audio-queue.png" width="190" alt="Audio queue">
  </p>
  <p align="center">
    <img src="screenshots/framed/glass-settings.png" width="190" alt="Liquid Glass settings">
    <img src="screenshots/framed/glass-share-sheet.png" width="190" alt="Liquid Glass share sheet">
    <img src="screenshots/framed/glass-home.png" width="190" alt="Liquid Glass tab bar">
  </p>
</details>

## Privacy

YTzoom has no activation service, analytics, telemetry or updater.

## Notes

The playback fix that shipped after 0.8.0 was taken from another project without credit and has been removed. The current Playback Fix is adapted from Mark02's YTPlaybackFix under the MIT license and is credited in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). If you find anything else that isn't credited, open an issue and it will be credited or removed.

## Contributing

Contributions are welcome — issues and pull requests both help.

For bug reports, include your device, iOS version and YouTube version.

For pull requests, keep each one focused on a single change and match the
surrounding style. Two things worth knowing:

- Hooks are installed by name through the helpers in `Tweak/Runtime/Hooking.h`,
  not a hooking framework, so a missing class or selector fails quietly instead
  of crashing on older YouTube versions.
- New user-facing strings go through `YTzoomLocalized` and belong in
  `Resources/YTzoom.bundle/en.lproj/Localizable.strings`. Translations for the
  other 14 languages can follow separately.

Build instructions are above.

## Donate

If YTzoom is useful to you, you can support it on [Ko-fi](https://ko-fi.com/itzzace) or with crypto:

- **BTC:** `bc1q6ahl2mghgq34r3w26yhwevsza0vl8436gugxke`
- **LTC:** `LYQ2ivZ52d2zAsm896MwWEkPEi15WwprS4`

## License

YTzoom source is available under the [MIT License](LICENSE). See [Third-Party Notices](THIRD_PARTY_NOTICES.md) for components and services with separate terms.
