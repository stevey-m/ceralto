# Folio

**A quiet place for everything worth keeping.**

Native Mac writing. An offline iPad reader. Readable Markdown. MIT licensed.
Folio aims for Apple Notes' simplicity, Joplin's notebook management and
Obsidian's ownership and extensibility, without turning your notebook into
a dashboard.

This is an independent community project, not affiliated with those products.
Contributions are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md) and the
[extension API](EXTENSIONS.md).

![Native composition view with synthetic sample notes](docs/mac-compose.png)

## What is actually ready

**0.10.0 is a development release, not a finished replacement for your library.**
The Mac app is packaged as a DMG. The native iPhone/iPad reader builds as a
device application but still requires your Apple signing and a real-device
check before installation. Its interface is read-only by design.

The cloud-folder exchange is **experimental**. Its merge, conflict,
deletion and offline-resource behaviour is covered by local filesystem tests;
Dropbox, OneDrive, Google Drive and cross-device iCloud delivery have not
been validated against live accounts or physical devices.
Keep an independent backup and start with a small test notebook.

## Install on Mac

Download the Apple Silicon DMG from [GitHub Releases](https://github.com/stevey-m/folio/releases).
Open `Folio-0.10.0-arm64.dmg`, drag **Folio** to **Applications**, eject the
image and launch. If building locally, the DMG is in `dist/`.
Quit the old Folio before replacing it. Existing libraries
load without manual conversion. Export a complete backup before upgrading;
older releases cannot read the new native-composition format marker.

Requires macOS 14+. This DMG targets Apple Silicon; Intel requires a separate
build. Development bundles are ad-hoc signed, not Apple-notarized. For a build
you trust, macOS may require **System Settings > Privacy & Security > Open Anyway**.

## A notebook, not a control panel

Shortcuts below are defaults. Customize application commands in
**Settings > Keyboard Shortcuts**; contextual editing shortcuts stay fixed.

- **Start with today.** Open **Today's Note** from the sidebar, Navigate menu,
  command palette or Command-Shift-D. Folio reuses today's dated note without
  replacing your words. Choose a notebook path and starter template in
  **Settings > Editor > Daily notes**.
- **Choose a useful starting page.** The searchable template chooser combines
  built-in Daily page, Meeting notes and Project brief templates with installed
  community packs. Preview the actual Markdown before creating a note in your
  current notebook. Open it from the sidebar or Command-Shift-T.
- **See what needs doing.** **Tasks** (Command-Shift-J) gathers Markdown
  checkboxes from active notes. Filter open/completed/all, search task text and
  note/notebook names, mark a task complete, or open its original note. No
  duplicate task database is created.
- **Use your own keys.** Remap or unassign 18 application commands in Settings.
  Menus, toolbar hints and command-palette labels follow the saved assignments.
  Duplicate bindings and reserved standard commands are rejected.
- **Choose your tools.** Settings separates **Built-in Features** from
  **Community Extensions**. Switch Daily notes, Template chooser and Task
  overview on or off without changing notes. Enable individual Folio template
  packs, or disable all community packs. Register extracted Joplin or Obsidian
  folders to inspect their names, versions and declared host requirements.
  **Inspection is not execution:** those plugins cannot run in this release.
  There is no JavaScript compatibility runtime, catalogue, package/URL installer,
  update service, or import of Obsidian's bundled core plugins.
- **Save a search, not another copy.** Smart folders collect matching notes
  automatically without moving or copying the originals. Choose **Save Search**
  above the note list, **New Smart Folder** in the sidebar, or use the File menu
  or command palette. Name the folder, edit its rules and see the matching count
  before saving. Right-click a smart folder to edit or delete it; deleting it
  never deletes notes. Tags, pins, text, notebook moves and Trash changes update
  membership immediately. Refine a smart folder with the note-list search.
- **Keep a few thoughts open.** Ordinary note selection reuses the current
  document tab. Right-click a note and choose **Open in New Tab** to keep both;
  new notes also open their own tab. Already-open notes select their existing
  tab instead of creating duplicates. Close a tab with its cross or
  Command-Option-W; closing never deletes a note. Open Compose and source tabs
  retain their native editor, selection, scroll position and independent undo
  history while switching between them. Tabs, the active note and navigation
  history restore on relaunch; cursor, scroll and undo state are session-only.
- **Read beside your writing.** Right-click a note and choose **Show as
  Reference**, or use the Navigate menu. A resizable, read-only preview stays
  beside the main document while you open and edit other notes. Its images
  use the same in-document viewer. This is a reference reader, not a second
  independent editing pane.
- **Find the action, not the menu.** Command-Shift-P opens the searchable command
  palette. Use arrow keys and Return, or click an action. Unavailable commands
  show why they cannot run. Command-K remains the note finder. Use
  Command-[ and Command-] or the toolbar arrows to go Back and Forward through
  up to 100 document visits, including links and finder results. Navigating
  after going Back starts a new history branch.
- **Compose directly into the page.** New Mac notes use a native AppKit editor
  for headings, bold, italic, bullets, quotes, code, links and inline images.
  The saved body is ordinary Markdown, not RTF, base64 or an opaque editor model.
  Native undo/redo and spelling are available. Formatting shortcuts include
  Command-B and Command-I.
- **Keep advanced source intact.** Imported Markdown and HTML remain in their
  original source format with Write, Split and Preview modes. The bounded
  formatted editor is not a full Markdown round-trip editor. For tables,
  nested lists and other advanced structures, choose **Note actions > Use
  Markdown Source Editor** or **File > New Markdown Source Note**. Switching
  changes only the editing mode, not the body. Unsupported structures are
  rejected by the formatted editor rather than silently flattened.
- **Capture without organising.** Quick Capture is a separate floating window,
  available from the menu bar, toolbar or Command-Shift-Space while Folio is
  active. Save to Inbox with Command-Return. Unsubmitted drafts remain locally
  when the window closes; failed saves keep the draft. This is not a global
  keyboard hook.
- **Jump to a thought.** Command-K opens an all-library finder with
  keyboard selection, matching passages and a note preview. Search includes
  titles, text, tags and notebook names. The note-list search stays scoped to
  the current collection. Search works offline; OCR, attachment-text indexing
  and semantic/AI search are not implemented.
- **Use notebooks that behave like notebooks.** Nested paths form collapsible
  trees. Main folders stay on the left; their expandable subtopics and notes
  appear in the middle; selecting a note displays it on the right. Notes saved
  directly in a main folder remain visible above its subtopics. Search reveals
  matching notes inside subtopics. On Mac, use a folder's context menu to add a
  subtopic or create a note in it. Tags, pins, moving notes, Trash and restore are included. Navigation
  widths are saved and do not grow when selecting long names. Drag dividers,
  hide either pane or toggle focused writing to return the space to the page.
- **Connect ideas with plain text.** Write `[[Note title]]`, `[[Notebook/Note
  title]]` or `[[Note title|display label]]`. Preview links open notes on both
  Mac and iPad. **Note actions > Linked Mentions** shows backlinks on Mac.
  Duplicate titles need a qualified notebook path. Code examples are not
  treated as links. Renames do not automatically rewrite existing links.
- **Let pictures fill the page.** Images fill the available document width in
  Preview and Compose, even when the text uses a narrower reading column.
  Original files and aspect ratios are preserved. Click an image to open it
  in the main document area, not a popup or another application. Pinch on the
  trackpad to zoom, scroll to pan, and choose **Fit to window** to reset.
  **Back to note** (or Escape on Mac) returns without rebuilding the note view.
  The iPad reader uses the same in-document navigation with pinch and drag.
  Smaller preview sizes remain available in Settings.
  Add files with the paperclip, drag files into Compose,
  or paste files copied in Finder. Text paste is intentionally plain text;
  clipboard-only image paste and rich-text paste are not yet supported.
- **Make it yours, quietly.** System, Light, Dark and Dracula appearances, five
  accent colours (Gold, Blue, Purple, Green and Rose), font family, text
  size, image display size and full-width reading are in Settings. Tags are
  tucked behind the tag button rather than always exposing an editing field.
  New installations follow the system appearance with a native system font
  and Gold accent. Existing appearance and font choices are preserved.
  The iPad reader's sidebar also offers appearance and accent choices.

Notes save atomically to the local library. Save failures are visible; changes
stay in memory and Folio warns before quitting. History retains up to 20
title/body/format checkpoints, at most once per five minutes of editing.
Restoring also preserves the current version.

## Dropbox, OneDrive, Google Drive and cloud folders

On Mac, choose **Settings > Cloud Folders > Connect Cloud Folder** and select
a dedicated folder managed by your provider's installed desktop app.
Sign in using that app, not Folio, and mark the entire folder as downloaded or
available offline. Select the same folder on another Mac only after the
provider has delivered the initial snapshot. Use **Sync Now** manually after
editing, then check the provider's status before refreshing the other Mac.
Existing iCloud folder bookmarks and the snapshot format are unchanged.

Folio keeps its working library local and exchanges immutable, checksummed
snapshots with original attachments. Connection rejects folders overlapping
Folio's local storage. Status reports **local exchange**, never verified
upload or delivery. Offline placeholders, partially delivered snapshots and
provider failures may require keeping the folder downloaded and retrying.
This generic folder path is experimental, not a certified integration with
any provider. No OAuth, direct cloud API, background scheduling, automatic
provider detection or cross-provider copying is implemented.

**Export Dated Complete Backup** lets you choose a separate local/cloud
location. Each manual backup creates a unique dated directory containing
notes, history and original attachments. Restore with **Import Folio Backup**;
import adds copies without replacing current notes. Sync snapshots are not a
substitute for independent backups: cloud deletion can propagate to backups
in the same account. There is no automatic pruning or scheduled backup.
Settings, unsaved drafts, smart folders and plugin registrations are not part
of these library backups. Use Time Machine for the entire local app folder.

Keep an independent copy. Files in cloud folders are readable; Folio does not
provide end-to-end encryption. The existing iPad iCloud reader remains
experimental; Dropbox/OneDrive/Google Drive access through iPad Files is not
validated and is not enabled by connecting a Mac folder.

## Daily notes, templates and tasks

Daily notes use your Mac's local Gregorian date and the exact `YYYY-MM-DD` title
in the configured notebook path (default **Journal**). Repeated opening selects
the same note and tab; it does not reapply the template or overwrite edits.
Duplicate notebook records sharing that path are searched together. If multiple
active notes already have today's title there, the most recently edited is
opened. A dated note in Trash must be restored explicitly, not silently
resurrected or duplicated. Renaming a dated note allows a new note with the
original daily title to be created; changing/renaming the notebook path likewise
changes where Folio looks. It is not a permanent calendar-ID system.

The configured template supplies the Markdown body and tags; the daily title
stays the date, and `daily` is added to its tags. Built-in templates work offline
without installation. A missing community template or invalid notebook path
shows an error before creating anything. Ordinary template creation still uses
the current real notebook and respects Pinned/tag collection defaults; smart
folders do not apply implicit rules to new notes.

Daily and template notes use the **Markdown source editor**, preserving task
syntax and advanced structures. Their text, tags and tasks are ordinary library
notes, so they participate in existing exports, history and manual folder
exchange. Daily-note preferences, shortcut bindings and installed template
packs are local settings and are not exported or synced.

The Tasks window recognizes list checkboxes such as `- [ ] Read the chapter`,
`- [x] Finished`, nested bullets, numbered lists and quoted lists. CommonMark
structure excludes fenced/indented code and HTML blocks; HTML-format notes and
Trash are not indexed. Task titles show their first source line. Opening a task
opens its note; the displayed line number helps locate it in source, rather than
claiming a cursor jump. Toggling validates the current source location and
changes only that checkbox marker, preserving other content and line endings.
Stale/moved tasks must be refreshed before editing. Save failures remain visible;
unsaved changes are retained in memory under the existing library safeguards.
This is not a reminders/calendar service: due dates, notifications, recurring
tasks and task editing on iPad are not implemented.

In **Keyboard Shortcuts**, choose a key and optional Shift/Option/Control
modifiers; Command is always included. Choose **Unassigned** to remove a binding,
then **Save Shortcuts** to apply all changes. The supported keys are letters,
digits, Space and the punctuation offered by the picker. Standard editing,
window-management and selected system combinations remain reserved. Global
hotkeys and arbitrary key recording are not implemented, and shortcuts owned by
other applications or external system customizations cannot be detected.
Malformed/newer saved configurations remain untouched, with an explicit warning
and default bindings active. **Reset to Defaults** asks before replacing saved
assignments.

## Search rules and smart folders

The collection search, Command-K finder and iPad reader use the same search
rules. Plain words still match titles, note text, tags and notebook names,
ignoring case and accents. All words and filters must match (AND).

| Search | Matches |
| --- | --- |
| `"release plan"` | An adjacent phrase, rather than separate words |
| `-draft` or `-"old plan"` | Notes without that word or phrase |
| `tag:review -tag:archive` | An exact tag, excluding another exact tag |
| `notebook:"Work/Ideas"` | That notebook path and all its subtopics, not `Work/Ideas-old` |
| `title:"Release plan"` | A phrase within the note title only |
| `is:pinned` or `is:unpinned` | Pin status |
| `updated-after:2026-01-01` | Updated at or after midnight UTC on that date (inclusive) |
| `updated-before:2027-01-01` | Updated before midnight UTC on that date (exclusive) |

Prefix any filter with `-` to exclude it. Combine filters, phrases and words:
`notebook:Work tag:review is:pinned -draft`. Use double quotes around values
containing spaces; inside quotes, `\"` and `\\` represent a literal quote or
backslash. Unknown prefixes (including `https:`) remain literal text.
Malformed recognized filters, impossible dates and unclosed quotes show an
explicit error instead of silently searching everything. **Search Help** in
the list and finder summarises the syntax. Searches are limited to 4,096
characters and 128 terms. OR, wildcards, regular expressions, OCR and
attachment-content search are not implemented.

Saving a collection search includes the selected notebook path, tag, Pinned
filter or existing smart-folder rules as well as the current search text.
The sheet shows the complete rules for review. Smart folders and the finder
exclude Trash; the Trash collection can still be searched directly.
Notebook rules follow names/paths, not IDs: edit the rule if you rename a
notebook. Saved rules do not automatically rewrite themselves.

Smart folders are **local to this Mac**, in `smart-folders.json`, outside the
note library schema. They restore on relaunch but are not synced to iPad or
other Macs, nor included in complete backups, open-folder exports or local
daily library recovery copies. Preserve this file separately, or include the
entire Folio folder in Time Machine. A corrupt or newer smart-folder file is
left untouched; the library still opens, and **Reload Smart Folders** lets
you retry after repairing or preserving/removing the file while Folio is quit.

Selecting a matching open tab keeps the smart folder and refinement. Opening
a note outside its results reveals that note's real notebook. New notes and
template notes are created in the selected note's real notebook (or the first
notebook if nothing is selected), then shown in All Notes; saved rules are
never applied to new notes as implicit tags or pins.

## Local opening-day recovery

On Mac, Folio also saves the first validated on-disk library from each UTC day
when opening an existing library, retaining the last seven opening days in
`Recovery/`. Reopening on the same day does not overwrite that day's copy.
Recovery-copy failures stop the library opening for editing and show an error;
unsupported future formats and corrupt libraries are not overwritten.
These copies include note text, metadata and note history, **not attachment
files or unsaved capture drafts**. They are local and unencrypted, can contain
previously deleted notes, and are not a replacement for complete backups.
There is no library-schema migration in this release.

Use **Settings > Files & Backups > Show Local Recovery Copies** to find them.
To recover: quit Folio, preserve the current `library.json` separately, copy
the chosen JSON file into the library folder as `library.json`, then reopen.
Original attachment folders must still exist. Do not replace the live library
while Folio is running.

## Your Mac library on iPad

The first iPad experience is deliberately **viewing only**: notebooks, tags,
search, readable pages and tap-to-open original images in the document area. There are no
half-finished editing controls.

1. On Mac, create a dedicated folder in **iCloud Drive**. In Folio choose
   **File > Connect Cloud Folder**, then **Sync Now**.
2. Let iCloud upload it. In Files on iPad, make the folder available offline
   using **Keep Downloaded** where available.
3. In the iPad reader, choose **Connect iCloud Drive Folder** and select that
   same folder. It downloads and verifies a local copy.
4. After making changes on Mac, choose **Sync Now**. On iPad, **Refresh from
   Mac** fetches them; the reader also refreshes on returning to the foreground.

Reading, search and images continue to work after disconnecting. A failed
refresh leaves the prior local cache intact and shows an explicit status.
Disconnecting a folder does not delete your local notes.

The working `library.json` is **never** shared. The folder contains immutable,
checksummed snapshots, version vectors and original resources. Concurrent
Mac edits are retained as deterministic conflict copies tagged `sync-conflict`.
Permanent deletions have tombstones so a stale device does not resurrect them.
The read-only iPad pulls snapshots without publishing changes.

This is snapshot exchange, **not continuous background sync**. iCloud may
deliver files at different times; incomplete or damaged snapshots fail
verification and need a later retry. Initialise the folder on one Mac and let
it download before connecting another device.

Snapshots currently contain full copies and are retained indefinitely. They
can use significant cloud/local space. Automatic compaction and garbage
collection are not implemented. Previously synced/deleted notes can remain in
old snapshots. This is not end-to-end encryption; protect the iCloud folder
and only share it with trusted people.

### Install on your iPad using Xcode

No paid Apple Developer membership is required for a personal Xcode install.

1. Open `FolioMobile.xcodeproj` in Xcode.
2. In **Xcode > Settings > Accounts**, sign in with your Apple ID.
3. Select the **FolioMobile** target, **Signing & Capabilities**, enable
   automatic signing and select your **Personal Team**.
4. Choose a unique bundle identifier such as `your.reverse.domain.folio`.
5. Connect and trust your iPad, enable Developer Mode if prompted, select it
   as the run destination and press **Run**.

Free provisioning expires and may require rebuilding/reinstalling. The DMG
does not install on iPad. An unsigned `.app` is not an installable iPad release.
No Apple credentials or signing team are stored in this repository.

For a reproducible **unsigned build**, not an installation:

```bash
bash scripts/build-ipad.sh
```

An iOS runtime must be installed separately to run Simulator. A successful
device build is not a substitute for testing the reader and iCloud transfer
on your iPad.

## Import your existing notes

**Joplin:** export **MD - Markdown + Front Matter**, then choose **File >
Import Joplin Folder**. Titles, tags, dates and notebook paths are preserved.
The export and its original resources are copied into Folio; the source export
can then be removed. Other YAML fields remain in the copied originals.
JEX, RAW exports and unexported `:/resource-id` links are not supported.

**Markdown/HTML:** import individual UTF-8 files or a whole export folder.
Directly linked images and files are copied. Links outside an individual
file's folder require importing the containing folder instead. Folder imports
retain shared resources and nested notebook paths. Invalid metadata, unreadable
resources and symbolic links fail before committing partial notes.

CommonMark/GFM preview includes tables, fenced code, lists, task markers,
quotes, links and sanitized HTML. HTML source is retained, but its original
stylesheets and active content are not reproduced. Remote images, scripts,
forms and embeds are blocked. Local images are restricted to the note's
resource root. Relative links to other documents open their saved originals,
not editable Folio notes.

Evernote ENEX, web clipping and OCR are not implemented.

## Open formats and backups

**File > Export Open Markdown Folder** creates ordinary Markdown/HTML files,
notebook folders, metadata and original linked attachments. Markdown has YAML
front matter; HTML has a metadata sidecar. Notes have separate resource trees
so relative links keep working, which can duplicate shared attachments.
This is a portable snapshot you can open with other tools, not a live Obsidian
vault backend.

**File > Export Complete Backup** includes the full library, history and copied
original resource trees. **Import Folio Backup** adds records without replacing
existing notes. Backups use portable relative paths and can be moved between
devices. Device-local sync state and folder permissions are not exported.

The Mac working library is:

```text
~/Library/Application Support/Folio/
  library.json
  Imports/
  Attachments/
  SyncAssets/
  Extensions/
  Recovery/
  workspace.json
  smart-folders.json
  sync-folder.bookmark
```

Keep it in Time Machine or export backups. Do not put the live `library.json`
in a shared folder or run separate app processes against it. Individual-note
export writes only the source body; use an open-folder export or complete
backup for original attachments.

There is no Folio account, subscription, analytics service or runtime server.
Your chosen provider's desktop app handles file delivery. Local notes, drafts
and snapshots are not encrypted by Folio. Use device protection/FileVault.
History and retained attachments are not substitutes for independent backups.

## Settings that stay out of your way

Open **Folio > Settings** (Command-comma). Search settings by name or purpose,
then select a matching category:

- **General:** version, manual release downloads, documentation, contributor
  guide, note-list preview lines and date visibility.
- **Appearance:** System/Light/Dark/Dracula, accent colour, font, text size,
  preview width, image size, pane visibility and reading-layout reset.
- **Editor:** default format for new notes, daily-note notebook/template, and local macOS spelling in Compose.
  Existing notes and imports keep their format; automatic correction stays off.
- **Files & Backups:** actual library location, imports, portable exports,
  complete backups and recovery guidance.
- **Cloud Folders:** provider-neutral folder connection, manual snapshot
  exchange, dated complete backups, local-only status and offline iPad guidance.
- **Extensions:** installed template packs, chooser, folder access, reload and API docs.
- **Keyboard Shortcuts:** editable application assignments and fixed contextual
  editing references. Default Sync is Command-Shift-R; Command-Option-S toggles
  the folder pane.

Settings are local to the device and are not included in library exports.
Release checking is manual. Scheduled backups, automatic trash expiry, OCR,
encryption and executable plugins are not implemented.
The iPad reader retains its lightweight appearance menu; the full Settings
window is Mac-only.

## Build and contribute

In the original parent repository, first `cd MacNotes`. In the standalone
source archive or repository, start at its root:

```bash
bash scripts/test.sh
bash scripts/build-app.sh
open dist/Folio.app
bash scripts/build-dmg.sh
bash scripts/build-ipad.sh
bash scripts/package-source.sh
```

Requires Swift 6, macOS 14+ and Xcode for the iOS build. Dependencies are pinned
in `Package.resolved`. Initial development builds fetch them. Tests cover
storage, imports, sanitization, real WebKit images, native formatting/undo,
pane measurements, capture, search, open export, extensions and sync merges.
The presentation test generates `dist/Folio-compose-preview.png` from
synthetic notes, never the user's library.

`Sources/NotesCore` holds portable models, rendering, imports, extension
validation and folder exchange. `Sources/Folio` is the native Mac interface
and shared store. `Mobile` is the native iPad/iPhone reader. WebKit is an
embedded document preview, not a web-app shell.

The standalone source archive includes MIT licensing, contributor guidance,
an example extension and macOS CI. The nested `.github/workflows` becomes
active when Folio is published at its own repository root; it does not
replace the original parent repository's workflows.

## License

[MIT](LICENSE). Third-party dependencies retain their respective licenses;
the packaged Mac app includes their notices.
