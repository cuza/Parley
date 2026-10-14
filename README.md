# Parley

A native macOS client for Google Chat, written in Swift with SwiftUI and AppKit.

Parley is an unofficial, independent project. It is not affiliated with or endorsed by Google. It uses the same private web API as Google Chat's web app, signed in with your own session. It stops working if Google changes that API. Use it with your own account.

An LLM wrote most of the code. It was tested it in daily use but didn't design or review it line by line. Expect rough edges, and read the code before relying on it.

![Home in Parley, with recent conversations and followed threads](Screenshots/home.png)

| A conversation | Threads in a side pane, in dark mode |
|---|---|
| ![A conversation in Parley](Screenshots/conversation.png) | ![A thread open beside the conversation, in dark mode](Screenshots/thread-dark.png) |
| **The conversation info panel** | **An app's card, with Reply and Resolve in the card** |
| ![The info panel with members and notification settings](Screenshots/info.png) | ![A documents app's comment card in its app DM](Screenshots/apps.png) |

## Why a Mac app

- **Notifications.** Native banners with a Reply field. Focus applies to them.
- **Dock.** An unread badge, and a Dock menu to open unread conversations or mark them all read.
- **Keyboard.** ⌘K opens any conversation, ⌘1 to ⌘9 the first nine, and ⌘F searches the open one.
- **Windows.** Any conversation or thread can open in its own window, and conversation windows join as tabs.
- **Shortcuts and Spotlight.** Shortcuts actions open, send and search, and Spotlight finds your conversations.
- **Sharing.** Parley is in the Share menu and in Services, for text, links and files.
- **Files.** Quick Look, and drag files in and out.
- **Handoff.** Continue the open conversation on your iPhone or iPad.
- **Links.** Google Chat links open in Parley when a link router such as [Velja](https://sindresorhus.com/velja) / [finicky](https://github.com/johnste/finicky) / [Choosy](https://choosy.app/) sends them there.

## Features

- **Sidebar.** Your Google Chat sections, pins, mutes and unread state, in sync with the web.
- **Timeline.** Bubbles or a plain list, with reactions, read receipts, previews and swipe to reply.
- **Threads.** A side pane, plus a list of a conversation's threads. Follow and read state sync.
- **Search.** Old results open among their neighbours, as on the web.
- **Composer.** Mentions, emoji, GIFs, slash commands, voice messages and full formatting.
- **Spaces.** Create spaces, accept invitations, and manage members, roles and settings.
- **Apps.** Chat app cards with working forms, buttons and polls.
- **More.** Meet links, translations, custom emoji, Ask Gemini, and block and report.

## Install

Download the latest DMG from [Releases](https://github.com/cuza/Parley/releases/latest) and drag Parley to Applications. Parley updates itself after that.

## Requirements

- macOS 15 or later
- Xcode 27 with Swift 6
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the Xcode project from `project.yml`
- A Google account with Google Chat

## Building

1. Clone the repository.
2. In `project.yml`, set `DEVELOPMENT_TEAM` to your own Apple Developer team ID. It is the only place the team appears.
3. Generate the project and open it:
   ```sh
   xcodegen generate
   open Parley.xcodeproj
   ```
4. Build and run the `Parley` scheme.

Swift Package Manager resolves the dependencies, [SwiftProtobuf](https://github.com/apple/swift-protobuf) and [Sparkle](https://github.com/sparkle-project/Sparkle).

### Signing in

On first launch Parley shows a welcome screen. Sign in with Google opens a Google sign-in window inside Parley, with its own website data, separate from your browsers. Once Google has signed you in to Google Chat, Parley checks the session, keeps it in your Keychain and closes the window. Passkeys don't work in that window, so choose Try another way at that step.

Parley keeps your session only in the macOS Keychain. Signing out from Settings ▸ Account also clears the sign-in window's data.

### GIF search

Add your own GIPHY API key in Settings. Parley keeps it in the Keychain.

## Tests

```sh
xcodebuild test -project Parley.xcodeproj -scheme Parley -only-testing:ParleyTests -destination 'platform=macOS'
```

Unit tests use Swift Testing and run against a fake backend with stubbed network requests, so they never reach Google. UI tests (`ParleyUITests`) launch the app with the fake backend through launch arguments such as `-uiTestingLongHistory`, `-uiTestingManyConversations` and `-uiTestingFormattedThread`.

## Project layout

| Path | Contents |
|---|---|
| `Parley/App` | App entry point, scenes and Sparkle updates |
| `Parley/Domain` | Models and the `ChatBackend` protocol |
| `Parley/Dynamite` | The Google Chat API client, with requests, the realtime channel, mapping and sign-in |
| `Parley/Store` | `ChatStore`, notifications, sign-in flow, launch cache, diagnostics |
| `Parley/UI` | SwiftUI views and the AppKit timeline |
| `Parley/Intents` | App Intents for Shortcuts, Spotlight and Siri |
| `ParleyShare` | The Share menu extension |
| `Parley/Preview` | `FakeBackend`, used by previews and tests |
| `Proto` | The protobuf schema; regenerate the Swift code with `protoc --proto_path=Proto --swift_out=Parley/Dynamite/Proto Proto/dynamite.proto` |
| `ParleyTests`, `ParleyUITests` | Unit and UI tests |

## Acknowledgments

- [SwiftProtobuf](https://github.com/apple/swift-protobuf) (Apache License 2.0), the protobuf runtime and code generator.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (MIT License), which generates the Xcode project.
- [Sparkle](https://github.com/sparkle-project/Sparkle) (MIT License), which updates the app.
- [purple-googlechat](https://github.com/EionRobb/purple-googlechat) (GPL-3.0) and [mautrix-googlechat](https://github.com/mautrix/googlechat) (AGPL-3.0), open-source Google Chat clients consulted as references for request and message formats.
- [Telegram for macOS](https://github.com/overtake/TelegramSwift), which inspired the timeline's design and swipe to reply.
- GIF search is [Powered by GIPHY](https://developers.giphy.com).

## License

Parley uses the MIT License. See [LICENSE](LICENSE).
