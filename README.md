# Flare ✦

Your own Raycast-style launcher for macOS: native Swift, Raycast look and feel, no account, no limits.

| | |
|---|---|
| **⌘ Space** | Launcher: search apps and files in `~/Downloads`, convert currencies |
| **⌥ ⌘ V** | Clipboard history: **unlimited** entries, **unlimited** size, any content type |

## Features (v1)

**Launcher (⌘ Space)**
- Fuzzy search across all installed apps (`saf` → Safari, `vsc` → Visual Studio Code, localized names too) with frecency ranking, so the things you open most float to the top.
- Recursive search of `~/Downloads` (kept live with FSEvents).
- `↩` opens the app or file · `⌘ ↩` reveals it in Finder with the file selected · `⌘ K` shows all actions (Copy Path, Copy File, Move to Trash, …) · `⌘ ⇧ C` copies the path.
- Currency conversion right in the search bar: `100 usd to eur`, `€50 in czk`, `20 gbp`, `1,5k chf`, `usd to jpy`. `↩` copies the number, `⌘ ↩` copies it with the currency code. Rates come from open.er-api.com (160+ currencies, no API key), are cached on disk and refreshed every 12 hours, so conversion also works offline.

**Clipboard history (⌥ ⌘ V)**
- Every copy is stored forever: no count limit, no size limit, no expiry. Text, rich text, images, files, links, colors and any custom type. Every pasteboard representation is kept, so pasting back is lossless.
- Raycast layout: list on the left, a preview plus metadata on the right (source app, characters and words, image dimensions, how many times it was copied, when).
- Substring search over the full text (SQLite FTS5 trigram index), a type filter (`⌘ P`), pinning (`⇧ ⌘ P`) and delete (`⌃ X`).
- `↩` pastes straight into the app you were using · `⌘ ↩` copies only.
- Copying the same thing again moves it to the top instead of creating a duplicate.
- Items that password managers mark as concealed or transient are never recorded.

**Experience**
- A non-activating floating panel with vibrancy, like Raycast and Spotlight: it never steals focus from your app.
- Raycast's behaviour of keeping your query for 90 seconds, then starting fresh.
- First-launch onboarding: every permission step updates live and moves on by itself once you grant it. You never need to relaunch.
- An Apple-style Settings window (`⌘ ,`) where you can record new hotkeys, change your home currency, see history stats and turn on launch at login.

## Install

Requirements: macOS 13 or later, and Xcode 16 or later (or the matching Command Line Tools).

```bash
git clone <this repo> flare && cd flare
scripts/build-app.sh --install     # builds, copies to /Applications, launches
```

The onboarding then walks you through:
1. **⌘ Space**: Spotlight owns this shortcut by default. Click **Disable Spotlight Shortcut** and Flare unticks it for you (or open Keyboard Shortcuts → Spotlight yourself). You can also pick ⌥ Space instead.
2. **Accessibility**: needed only so Flare can press ⌘V for you when you paste from history.
3. **Downloads**: macOS asks once whether Flare may read your Downloads folder.
4. **Launch at login**.

You can also download a prebuilt `Flare.zip` from the latest CI run (Actions → CI → Artifacts). Because it is ad-hoc signed and downloaded from the internet, clear the quarantine flag first: `xattr -dr com.apple.quarantine Flare.app`.

### Rebuilding and Accessibility

Ad-hoc signed builds get a new code signature on every rebuild, so macOS may stop trusting the new build for Accessibility. If pasting stops working after a rebuild, remove Flare from System Settings → Privacy & Security → Accessibility and add it back. To avoid this, sign with a stable identity: `FLARE_SIGN_IDENTITY="Apple Development: you@example.com" scripts/build-app.sh --install`.

## Where your data lives

`~/Library/Application Support/Flare/`
- `Clipboard/clipboard.sqlite`: history metadata, small payloads and the search index
- `Clipboard/blobs/`: payloads larger than 256 KB, content-addressed (identical data is stored once)
- `rates.json`: cached exchange rates · `usage.json`: launch counts used for ranking

Nothing leaves your Mac except the exchange-rate request.

## Development

```bash
swift build          # debug build
swift test           # FlareCore unit tests (matcher, currency parser, clipboard store)
swift run Flare      # run without bundling (some permissions need the .app bundle)
```

```
Sources/FlareCore/   platform logic, unit-tested: FuzzyMatcher, SearchEngine, CurrencyQueryParser,
                     CurrencyRates, ClipboardStore (SQLite + FTS5 + blobs), ClipAnalyzer, UsageStore
Sources/Flare/       the macOS app: panel, launcher, clipboard UI, onboarding, settings
Resources/           Info.plist, AppIcon.icns (regenerate with scripts/make-icon.py)
```

## Not in v1

Importing your existing Raycast clipboard history (Raycast keeps it in an encrypted SQLCipher database whose key is stored in the Keychain, so it could be a separate importer later), a calculator, extensions, folders other than Downloads, and notarized DMG distribution.
