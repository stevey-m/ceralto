# Contributing to Deltos

Deltos aims for Apple Notes' ease of use, Joplin's notebook management, and
Obsidian's readable, portable documents. It is an independent open-source
project, not affiliated with any of those products.

## Development

Use macOS 14 or newer and a Swift 6 toolchain. From the standalone repository:

```bash
bash scripts/test.sh
bash scripts/build-app.sh
open dist/Deltos.app
```

In the original parent repository, first `cd MacNotes`. Swift Package Manager
fetches the pinned dependencies on the first build. Build an installer with
`bash scripts/build-dmg.sh`.

The iOS project is a read-only offline companion. See the README for its signing
and runtime limitations; an unsigned build is not a device test.

## Changes that belong here

Keep the native interface calm, readable and keyboard accessible. Prefer work
on reliable writing, capture, organisation, search, faithful imports and
ownership over feature proliferation.

Keep imported source intact. Display resizing must never overwrite original
attachments. New storage fields must decode existing libraries. Never silently
discard unsaved edits or mask a failed import/export with a success message.
Do not introduce a runtime account or network requirement for core note-taking.

Add focused tests for changed behaviour, including real native-editor or
WebKit tests when a model-only test cannot demonstrate the result. Run
`bash scripts/test.sh` before submitting a pull request. The runner executes tests
serially because the native window tests share `NSApplication` and AppKit
appearance state; each test still uses synthetic notes and isolated preferences.

Data-only template extensions are the first supported extension surface.
See [EXTENSIONS.md](EXTENSIONS.md) and `Examples/Extensions/meeting-notes`.
Executable plugins need an approved isolation and permissions design first.

Use synthetic fixtures, not your personal library, screenshots containing
personal notes, signing credentials or cloud tokens. A development app uses
the normal Deltos library unless you run it in an isolated macOS account.
Make a complete backup before testing a development release.

## Licensing

Contributions are made under the MIT license in `LICENSE`. Keep third-party
license notices with redistributed dependencies. Icons, product names and
assets must be original or appropriately licensed.
