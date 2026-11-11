import AppKit
import ImageIO
import NotesCore
import QuickLook
import SwiftUI

struct AttachmentBrowser: View {
    @EnvironmentObject private var store: NotesStore
    @Environment(\.dismiss) private var dismiss
    let notes: [Note]
    let scopeTitle: String
    @ViewState private var attachments: [NoteAttachment] = []
    @ViewState private var issues: [String] = []
    @ViewState private var loading = true
    @ViewState private var kind: NoteAttachment.Kind?
    @ViewState private var previewURL: URL?
    @ViewState private var actionError: String?
    @ThemeColors private var palette

    private var filtered: [NoteAttachment] {
        attachments.filter { kind == nil || $0.kind == kind }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Attachments").font(.title2.bold())
                    Text("\(scopeTitle) - \(attachments.count) files").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("Attachment type", selection: $kind) {
                Text("All Files").tag(Optional<NoteAttachment.Kind>.none)
                ForEach(NoteAttachment.Kind.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }
            .pickerStyle(.segmented)
            if let actionError { Label(actionError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if !issues.isEmpty {
                DisclosureGroup("Some notes could not be indexed (\(issues.count))") {
                    ScrollView {
                        VStack(alignment: .leading) {
                            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in Text(issue).font(.caption) }
                        }
                    }.frame(maxHeight: 100)
                }
            }
            attachmentGrid
            Text("Files linked from notes in this view, including subfolders and search filters. Remote links are not downloaded.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 620, idealWidth: 800, minHeight: 420, idealHeight: 600)
        .folioAppearance()
        .quickLookPreview($previewURL)
        .task(id: notes) { await load() }
    }

    private var attachmentGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 14)], spacing: 14) {
                ForEach(filtered) { attachment in
                    VStack(alignment: .leading, spacing: 8) {
                        AttachmentThumbnail(attachment: attachment).frame(maxWidth: .infinity).frame(height: 110)
                        Text(attachment.name).font(.headline).lineLimit(2).help(attachment.name)
                        Text(attachment.noteTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        HStack {
                            Button("Preview") { perform(attachment) { previewURL = $0 } }
                            Spacer()
                            Button("Open Note") { store.openNote(attachment.noteID); dismiss() }
                                .buttonStyle(.borderless).fixedSize()
                        }.font(.caption).controlSize(.small)
                        Button("Show in Finder") {
                            perform(attachment) { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
                        }.font(.caption).buttonStyle(.borderless)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette?.sidebarColor ?? Color(nsColor: .controlBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 10))
                }
            }.padding(2)
        }
        .overlay {
            if loading { ProgressView("Finding attachments...") }
            else if filtered.isEmpty {
                ContentUnavailableView("No attachments in this view", systemImage: "paperclip",
                                       description: Text("Choose another file type, notebook or search."))
            }
        }
    }

    private func perform(_ attachment: NoteAttachment, action: (URL) -> Void) {
        do { let url = try attachment.resolvedURL(); actionError = nil; action(url) }
        catch { actionError = "\(attachment.name): \(error.localizedDescription)" }
    }

    private func load() async {
        loading = true
        let notes = notes
        let work = Task.detached(priority: .userInitiated) {
            var files: [NoteAttachment] = []
            var issues: [String] = []
            for note in notes {
                try Task.checkCancellation()
                do { files += try Attachments.references(in: note) }
                catch { issues.append("\(note.displayTitle): \(error.localizedDescription)") }
            }
            return (files, issues)
        }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await work.value },
                                                              onCancel: { work.cancel() })
            guard !Task.isCancelled else { return }
            attachments = result.0
            issues = result.1
            loading = false
        } catch is CancellationError {
            return
        } catch {
            actionError = "Could not list attachments: \(error.localizedDescription)"
            loading = false
        }
    }
}

struct NoteGalleryPreview: View {
    let note: Note
    @ViewState private var image: NoteAttachment?
    @ViewState private var previewError: String?

    var body: some View {
        Group {
            if let image { AttachmentThumbnail(attachment: image) }
            else if let previewError {
                Label("Preview unavailable", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).help(previewError)
            } else {
                Image(systemName: "doc.text").font(.system(size: 36)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .task(id: note) {
            previewError = nil
            let note = note
            do {
                try await Task.sleep(for: .milliseconds(150))
                let result = try await Task.detached(priority: .utility) {
                    try Attachments.references(in: note).first { $0.kind == .image }
                }.value
                guard !Task.isCancelled else { return }
                image = result
            } catch {
                guard !Task.isCancelled else { return }
                previewError = error.localizedDescription
            }
        }
    }
}

struct AttachmentThumbnail: View {
    let attachment: NoteAttachment
    @ViewState private var image: NSImage?
    @ViewState private var previewError: String?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else if let previewError {
                Label("Preview unavailable", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).help(previewError)
            } else {
                Image(systemName: attachment.kind == .image ? "photo" : attachment.kind == .pdf ? "doc.richtext" : "doc")
                    .font(.system(size: 36)).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(attachment.name)
        .task(id: attachment) {
            image = nil
            previewError = nil
            let attachment = attachment
            do {
                let data = try await Task.detached(priority: .utility) { try Self.thumbnail(attachment) }.value
                guard !Task.isCancelled else { return }
                if let data {
                    guard let decoded = NSImage(data: data) else { throw NoteWorkflowError("Could not display the thumbnail.") }
                    image = decoded
                }
            } catch {
                guard !Task.isCancelled else { return }
                previewError = error.localizedDescription
            }
        }
    }

    nonisolated static func thumbnail(_ attachment: NoteAttachment) throws -> Data? {
        let url = try attachment.resolvedURL()
        guard attachment.kind == .image else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NoteWorkflowError("Could not read the image thumbnail. The original file has not been changed.")
        }
        return data
    }
}
