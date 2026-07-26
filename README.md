# MSGViewer

Lightweight native macOS viewer for Microsoft Outlook `.msg` files.

- Opens messages from Finder or drag and drop
- Displays sender, recipients, date, and HTML/RTF/plain-text bodies
- Saves, opens, and Quick Looks attachments
- Opens embedded messages in place
- Processes everything locally with no network access or external dependencies

## Install

```sh
brew install --cask araidz/tap/msgviewer
```

Requires macOS 14 or newer on Apple silicon.

## Build

```sh
swift test
Scripts/bundle.sh
```

The signed application is written to `dist/MSGViewer.app`.

The parser implementation was informed by the MIT-licensed [molotochok/msg-viewer](https://github.com/molotochok/msg-viewer) project.
