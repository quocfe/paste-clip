# ClipStack

A native, local-only clipboard manager for macOS 13+. SwiftUI + AppKit, SQLite/GRDB, FTS5 search, and a keyboard-first history panel.

ClipStack opens as a full-width shelf at the bottom of the active screen, with horizontal cards showing text and image previews. It records new clipboard changes and automatically imports newly saved macOS screenshots while running.

History has one fixed budget of **20 clips total**, across text, images, links, files, and pinned items. A new unique clip evicts the least recently copied clip and removes its saved image. Re-copying an existing clip moves it to the front. Existing histories are trimmed to 20 on first launch of this version.

## Build and run on a Mac

Install full Xcode 16.4 or newer, select it as the active developer directory, and accept its license. The package requires a Swift 6 toolchain and uses Swift 5 language mode for the app. Build tools need macOS supported by that Xcode; the resulting application targets macOS 13+.

For a local build for this Mac, without XcodeGen:

```bash
bash scripts/build-local.sh
open build/ClipStack.app
```

For a universal Apple Silicon + Intel build:

```bash
brew install xcodegen
bash scripts/build.sh
open build/DerivedData/Build/Products/Release/ClipStack.app
```

The script generates the application icon and Xcode project, runs Swift tests, and builds an ad-hoc signed universal app for Apple Silicon and Intel. This local development signature is not a Developer ID signature or notarization. For development in Xcode:

```bash
swift scripts/make-icon.swift
xcodegen generate
open ClipStack.xcodeproj
```

Select the ClipStack scheme and My Mac. Use the `.app` bundle for login registration and Accessibility testing; `swift run` is only useful for debugging. Quit any earlier instance before launching another build.

## Included behavior

- Recording starts on launch. Clipboard changes are checked every 250 ms; the existing clipboard is not imported on startup or when resuming.
- New macOS screenshot files are imported automatically. The default Desktop and configured screenshot folder are checked every 750 ms; Spotlight also detects screenshots saved elsewhere in the home folder. Only files marked by macOS as screenshots are imported. Folder access may need to be allowed in Privacy & Security → Files and Folders. Screenshots taken while paused or before launch are not backfilled. The original files and system clipboard are left untouched.
- Text, HTTP(S) links, plain text with HTML/RTF representations, PNG/TIFF images, and multiple Finder file URLs are captured. Images are normalized to PNG on disk. Original files are referenced, never copied or deleted.
- SHA-256 deduplication includes content type and rich representations. Re-copying retains the clip ID and pin, refreshes recency, and increments the copies/uses count.
- FTS5 searches text, source app name, URL, and file URLs using safe token-prefix AND queries. Results load in pages. Punctuation-only queries return no results.
- The bottom shelf has horizontally scrolling preview cards, All, Pinned, Images, Links, and Files filters, source app icons, relative times, pin/delete actions, a context menu, and drag-out support. It opens on launch, on app reopen, or with the global shortcut. Escape and switching to another app dismiss it.
- Global ⌘⇧V opens the panel; ⌘⌥V is available as an alternative. A registration conflict is shown as an error.
- Enter restores the selected item, activates the previous app, waits for focus and released modifiers, then sends Cmd+V. Without Accessibility permission, the item is copied and the panel explains the manual fallback.
- Preferences include launch at login, pause, excluded applications, optional secret heuristics, and clear history with an explicit option to include pins. The total history limit is fixed at 20; pinning helps filtering but does not exempt a clip from eviction.
- Menu bar controls open history, pause/resume, clear unpinned history, open settings, toggle login startup, and quit. No Dock icon is used.
- The UI follows the system light/dark appearance. No sample clipboard content is inserted.

| Shortcut | Action |
| --- | --- |
| ⌘⇧V (or ⌘⌥V) | Open/close history |
| ← / → (or ↑ / ↓) | Select a clip; left/right edit text when search is focused |
| Enter | Paste, or copy if permission is unavailable |
| ⌘Enter | Copy without leaving the panel |
| ⌘P | Pin/unpin |
| ⌘D | Delete selected clip |
| ⌘F | Focus search |
| ⌘, | Settings |
| Escape | Close history |

## Data and privacy

```text
~/Library/Application Support/ClipStack/
  clips.db
  assets/
    <sha256>.png
```

The app contains no networking or analytics code. SQLite stores text, rich representations, metadata, and relative asset names. Its parent directory is restricted to the current user. Content is not encrypted by ClipStack; it remains accessible to software with access to that user's files. Deletion is not a forensic erasure guarantee for filesystem snapshots or backups.

Transient, concealed, autogenerated, and ClipStack-restored pasteboards are always skipped. Common password managers are excluded by bundle ID before reading content. Users can add installed apps to that list.

The optional secret heuristic detects several private-key headers, common API-token prefixes, JWTs, credential assignments, and 4–8 digit numbers. It cannot identify all secrets, inspect image contents, or guarantee that a copied password will be excluded. It can produce false positives. Pause recording or exclude the source app for sensitive workflows.

Eviction uses last-copy time (`updatedAt`), preserving recent recopies. All types and pins share the 20-item cap, enforced inside each save transaction and when opening an existing database. There is no age-based expiry. Cleanup also runs every minute; unreferenced images are removed only from ClipStack's asset directory. Clearing history does not clear the current system clipboard.

Payloads over 20 MiB and images over 40 million pixels are skipped. Card previews display at most 3,000 characters; copying restores full saved text. HTML is stored but never rendered as web content or fetched, and HTML-only data without inspectable text is skipped while secret filtering is enabled. A drag of a multi-file clip exports the first file; Enter/Copy restores all file URLs.

## Architecture

```text
Sources/ClipStackCore/
  ClipboardItem.swift        Types, records, content hashing
  ClipboardParser.swift      NSPasteboard parser + polling watcher
  ClipboardWriter.swift      Type-preserving clipboard restoration
  PrivacyFilter.swift        Pasteboard markers + secret heuristics
  ClipboardRepository.swift  GRDB migration, FTS triggers, CRUD, 20-clip eviction
  ScreenshotWatcher.swift    New macOS screenshot detection and image import
  StorageService.swift       Private local directories + image assets

Sources/ClipStack/
  ClipStackApp.swift         App lifecycle, NSPanel, NSStatusItem, keyboard events
  AppState.swift             Capture/search orchestration and selection
  HistoryView.swift          Welcome, history, rows, preview
  SettingsView.swift         Privacy/history settings + SMAppService
  SettingsStore.swift        Persisted preferences
  HotkeyManager.swift        Carbon global hotkey registration
  PasteService.swift         Accessibility and target-app restoration
```

The repository is actor-isolated, so database operations and asset cleanup serialize away from the UI actor. AppKit clipboard access stays on the main actor. Search requests are debounced and stale responses cannot replace a newer query. Source attribution uses the frontmost application at capture time; macOS does not provide reliable clipboard owner identity here.

## Verification

```bash
swift test
python3 scripts/validate_sql.py
```

The Swift suite covers persistence, deduplication/pins, FTS triggers, the shared 20-clip cap, migration of larger histories, timestamp ties, image cleanup, path validation, pagination, private markers, rich clipboard restoration, files, PNG capture, screenshot detection/retries, pause/resume, and secret filtering. It uses temporary databases and uniquely named pasteboards instead of the user's general clipboard.

The UI rendering test renders the production text/image cards in light and dark appearances using synthetic fixtures. It checks dimensions and image pixels without starting the application or accessing the global clipboard. Set `CLIPSTACK_PREVIEW_OUTPUT` to a directory when running `swift test --filter CardRenderingTests` to export the PNG previews.

The portable validator executes the **actual migration and cleanup SQL extracted from the Swift repository**. Its four tests pass on the Windows development host, including a 50,000-row FTS query. That SQL timing is not a measurement of native UI latency.

GitHub Actions on `macos-15` runs the Swift suite, creates a universal `.app`, verifies both architectures, and uploads an ad-hoc signed development build artifact. Download `ClipStack-development` from a successful workflow run; it contains `ClipStack-development.zip` with the application bundle.

Before release, perform these macOS checks:

1. Launch the bundled app; verify the bottom shelf, menu bar, horizontal scrolling, keyboard selection, and light/dark UI.
2. Copy from Safari/Terminal, rich text from an editor, an image, and several Finder files. Restart and verify persistence.
3. Recopy a pinned item; verify one row, preserved pin, updated source/recency.
4. Open history from TextEdit with the shortcut; search and paste. Test without Accessibility, then grant permission and repeat. Switch focus unexpectedly and verify no paste is sent to an unrelated app.
5. Test arrows, Enter, ⌘Enter, ⌘P, ⌘D, Escape, alternate shortcut, and shortcut conflict feedback.
6. Pause and copy; resume and verify no backfill. Test excluded applications and marked private data using non-secret samples.
7. Capture a mix of 21 text/image clips; verify only the newest 20 remain, including eviction of old pins and their saved image assets. Take a macOS screenshot without copying it and verify automatic import. Check pause/resume and clear with/without pins.
8. Register launch at login from an installed `.app`, log out/in, and verify startup.
9. Test missing original files, large payloads, multiple displays/Spaces, and signed/notarized installation on a clean Mac.

## Signed release and Homebrew

The release workflow runs for `vMAJOR.MINOR.PATCH` tags. Configure the GitHub `release` environment and these secrets first:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_BASE64` | Base64-encoded Developer ID Application `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | Password protecting that certificate |
| `APPLE_SIGNING_IDENTITY` | Full Developer ID Application signing identity |
| `APPLE_TEAM_ID` | Apple Developer team ID |
| `APPLE_ID` | Apple ID used for notarization |
| `APPLE_APP_PASSWORD` | App-specific password for notarytool |

After the macOS checks pass, push a version tag to invoke the workflow. It creates a temporary signing keychain, tests, archives both architectures with Hardened Runtime, verifies signing, submits with `notarytool`, staples/validates the ticket, assesses with Gatekeeper, and publishes `ClipStack-<version>.zip`, `SHA256SUMS`, and `clipstack.rb` to GitHub Releases. Certificates are removed from the runner at exit. No signing secrets belong in the repository.

The generated cask has the real archive SHA-256 and repository URL. To generate it manually from a completed signed archive:

```bash
python3 scripts/make_cask.py --version 0.1.0 \
  --repository quocfe/paste-clip \
  --archive build/ClipStack-0.1.0.zip \
  --output build/clipstack.rb
```

Publish that file as `Casks/clipstack.rb` in `quocfe/homebrew-tap`. Only after the release and tap exist will installation work:

```bash
brew tap quocfe/tap
brew install --cask clipstack
```

The tap is deliberately generated from an actual artifact; this repo does not ship an installable cask with a placeholder checksum. Publishing/updating the tap remains a separate action.

## API references

The clipboard watcher follows Apple's [NSPasteboard change-count contract](https://developer.apple.com/documentation/appkit/nspasteboard/changecount). Login registration uses [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice/register()). Persistence uses [GRDB](https://github.com/groue/GRDB.swift), pinned to 7.8.0. The selected CI toolchain is listed in the [macOS 15 runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md).
