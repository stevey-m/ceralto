# Folio extensions: small powers, quiet interface

Folio's first extension API is **data-only template packs**. It is not an
Obsidian or Joplin `.jpl` plugin compatibility layer, a JavaScript runtime, or a marketplace.
No extension code executes. Packs cannot access your library, filesystem,
network, credentials or other installed extensions.

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
The pack ID `dev.folio.builtin` is reserved for Folio's built-in templates.
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
