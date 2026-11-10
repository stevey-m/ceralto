# Deltos extensions: small powers, quiet interface

Deltos's first extension API is **data-only template packs**. It is not an
Obsidian or Joplin `.jpl` plugin compatibility layer, a JavaScript runtime, or a marketplace.
No extension code executes. Packs cannot access your library, filesystem,
network, credentials or other installed extensions.

## Extension manager (0.9)

**Settings > Built-in Features** switches Daily notes, Template chooser and
Task overview on or off. Disabled tools disappear from the Workspace sidebar
and their menu commands/shortcuts cannot run. Disabling the chooser does not
disable templates used by daily notes. Disabling Task overview leaves every
Markdown checkbox intact and editable in its note. Notes, tool preferences
and shortcuts are retained.

**Settings > Community Extensions** lists installed Deltos template packs with
enable switches and an explicit **Disable All Community Template Packs**
action. Disabled packs disappear from the chooser and template menus, but their
files and previously created notes are untouched. A daily template from a
disabled pack is unavailable for new dates; existing dated notes still open.
To uninstall a data-only pack, move its folder out of Extensions and reload.
Malformed reloads retain the last successfully loaded packs and show an error.

**Inspect Joplin or Obsidian Folder** accepts an extracted local folder with
`manifest.json`. It reads only bounded manifest metadata: ecosystem, name, ID,
version and declared minimum host version. It registers a reference to the
original folder, not an installed copy. Recheck rereads its current manifest;
missing or malformed manifests remain registered with a visible error.
**Forget Registration** never deletes original files. Symbolic-link folders
and manifests, ambiguous ecosystems and unsupported Joplin manifest versions
are rejected.

These registrations are **inspection only, not compatible or runnable plugins**.
No JavaScript, CSS, executable code, plugin network requests or host APIs are
loaded. There are no fake enable or update switches for these registrations.
Joplin `.jpl` archives, repository URLs, downloads, updates, marketplace browsing
and executable Joplin/Obsidian compatibility remain unimplemented. Obsidian core
plugins ship inside Obsidian and are not independently importable packages.
Manifests are not evidence that the underlying code works or is safe.

Manager preferences and folder registrations are Mac-local, versioned data in
Deltos's preferences, not in the note library, complete backups, sync snapshots
or opening-day recovery copies. Invalid/future manager data is preserved:
community packs become inactive, manager changes are blocked, and Settings
provides retry or an explicitly confirmed reset. Reset forgets registrations
and re-enables tools/packs; it does not change note or plugin files.

## Install the example

In the Mac app choose **File > New from Template > Open Extensions Folder**.
Copy `Examples/Extensions/meeting-notes` from the source repository into that
folder. Choose **Reload Extensions**. The Meeting Notes menu now creates
meeting notes or daily pages in your current notebook.

The **Templates** sidebar button, **File > New from Template > Choose a
Template**, and the command palette open a searchable chooser. Built-in daily,
meeting and project starters appear alongside installed packs, with a Markdown
source preview. All template-created notes use the source editor. In
**Settings > Editor > Daily notes**, a pack template can supply the body and
tags for Today's Note; its title remains the local `YYYY-MM-DD` date.

The default location is:

```text
~/Library/Application Support/Folio/Extensions/
  meeting-notes/
    extension.json
```

Extensions are local to the Mac and are not installed on the read-only iPad
companion. Notes created from templates sync and export like any other note.

## API version 1

Each pack has one UTF-8 `extension.json`:

```json
{
  "id": "org.example.my-pack",
  "name": "My Templates",
  "apiVersion": 1,
  "templates": [
    {
      "id": "daily",
      "name": "Daily Page",
      "title": "{{date}}",
      "body": "# Today\n\n- [ ] One important thing\n",
      "tags": ["journal"]
    }
  ]
}
```

Pack IDs must be unique. Template IDs must be unique within a pack. IDs use
lowercase ASCII letters, numbers, dots and hyphens, at most 100 characters.
The pack ID `dev.folio.builtin` is reserved for Deltos's built-in templates.
Names must not be empty. `tags` is optional. Unknown API versions, duplicate
IDs, malformed JSON and symbolic links are rejected with a visible error.
Failed reloads leave the previously loaded packs available.

`title` and `body` substitute `{{date}}` (local `yyyy-MM-dd`) and `{{time}}`
(local short time) when a note is created. There is no expression evaluation.
Bodies are ordinary Markdown; template notes use the source editor so advanced
Markdown is not passed through the deliberately bounded formatted editor.

## Contribute a pack

Keep the pack in a GitHub repository with its own license and a README showing
the result. Contributors can copy the example and send a pull request improving
the API, its validation or its documentation. Include synthetic examples and
tests; do not include personal notes or credentials.

Future executable extensions need an explicit permission model, process
isolation, version negotiation and a disable/recovery path before shipping.
Keeping the notebook simple and offline-capable is an API requirement, not a
reason to allow unrestricted code inside the application.
