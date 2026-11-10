import NotesCore
import SwiftUI

struct TemplateChooser: View {
    @EnvironmentObject private var store: NotesStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var query = ""
    @ViewState private var selectedID: String?

    private var choices: [TemplateChoice] {
        store.templateChoices.filter { choice in
            query.split(whereSeparator: \.isWhitespace).allSatisfy {
                (choice.template.name + " " + choice.packName).localizedStandardContains(String($0))
            }
        }
    }

    private var selected: TemplateChoice? {
        choices.first { $0.id == selectedID } ?? choices.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose a Template").font(.title2.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20).fixedSize(horizontal: false, vertical: true)
            TextField("Search templates and packs", text: $query).textFieldStyle(.roundedBorder)
                .onSubmit(create)
                .padding(.horizontal, 20).padding(.bottom, 16)
            Divider()
            HStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(choices) { choice in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(choice.template.name).fontWeight(.medium)
                            Text(choice.packName).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 6).tag(choice.id)
                    }
                }
                .frame(width: 235)
                .overlay { if choices.isEmpty { ContentUnavailableView.search(text: query) } }
                Divider()
                ScrollView {
                    if let selected {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(selected.template.render(selected.template.title)).font(.title2.bold())
                            Text("Markdown source preview").font(.caption).foregroundStyle(.secondary)
                            Text(selected.template.render(selected.template.body))
                                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(22)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                }
                HStack {
                    Text("Creates a Markdown note in \(store.library.notebooks.first { $0.id == store.currentNotebookID }?.name ?? "your notebook").")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Create Note", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil || !store.isLoaded || store.isReadOnly)
                }
            }.padding(16)
        }
        .frame(width: 760, height: 540)
        .background(.background).folioAppearance()
        .onAppear { selectedID = choices.first?.id }
        .onChange(of: query) { _, _ in selectedID = choices.first?.id }
    }

    private func create() {
        if let selected, store.createFromTemplate(selected.template) { dismiss() }
    }
}

struct TaskOverview: View {
    @EnvironmentObject private var store: NotesStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var tasks: [NoteTask] = []
    @ViewState private var failure: String?
    @ViewState private var filter = "Open"
    @ViewState private var query = ""

    private var visible: [NoteTask] {
        let notes = Dictionary(uniqueKeysWithValues: store.library.notes.map { ($0.id, $0) })
        let names = Dictionary(uniqueKeysWithValues: store.library.notebooks.map { ($0.id, $0.name) })
        return tasks.filter { task in
            guard filter == "All" || task.isComplete == (filter == "Completed") else { return false }
            let note = notes[task.noteID]
            let text = [task.title, note?.displayTitle ?? "", note.flatMap { names[$0.notebookID] } ?? ""].joined(separator: "\n")
            return query.split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedStandardContains(String($0)) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tasks").font(.title2.weight(.semibold))
                    Text("Markdown checkboxes across active notes. Changes update the original note.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Search tasks, notes and notebooks", text: $query).textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                Picker("Show tasks", selection: $filter) {
                    Text("Open").tag("Open")
                    Text("Completed").tag("Completed")
                    Text("All").tag("All")
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }.padding(.horizontal, 20).padding(.bottom, 16).fixedSize(horizontal: false, vertical: true)
            Divider()
            List(visible) { task in
                HStack(alignment: .top, spacing: 12) {
                    Button { store.setTask(task, complete: !task.isComplete) } label: {
                        Image(systemName: task.isComplete ? "checkmark.square.fill" : "square")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Mark \(task.title.isEmpty ? "task" : task.title) \(task.isComplete ? "incomplete" : "complete")")
                    .disabled(failure != nil || !store.isLoaded || store.isReadOnly)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(task.title.isEmpty ? "Untitled task" : task.title)
                            .strikethrough(task.isComplete).textSelection(.enabled)
                        if let note = store.library.notes.first(where: { $0.id == task.noteID }) {
                            Button {
                                store.openNote(note.id)
                                dismiss()
                            } label: {
                                Text("\(store.library.notebooks.first { $0.id == note.notebookID }?.name ?? "Notebook") / \(note.displayTitle) · Line \(task.lineNumber)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.buttonStyle(.plain)
                        }
                    }
                    Spacer()
                }.padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if visible.isEmpty && failure == nil {
                    ContentUnavailableView("No \(filter == "Completed" ? "completed " : "")matching tasks",
                        systemImage: "checklist",
                        description: Text("Add - [ ] followed by task text to a Markdown source note. Code examples, HTML and Trash are not task sources."))
                }
            }
            Divider()
            HStack {
                if let error = failure ?? store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else {
                    Text("\(tasks.filter { !$0.isComplete }.count) open · \(tasks.filter(\.isComplete).count) completed")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh", action: refresh)
            }.font(.caption).padding(16).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 820, height: 560)
        .background(.background).folioAppearance()
        .onAppear(perform: refresh)
        .onChange(of: store.library) { _, _ in refresh() }
    }

    private func refresh() {
        do {
            tasks = try NoteTasks.find(in: store.library)
            failure = nil
        } catch { failure = "Could not refresh tasks: \(error.localizedDescription)" }
    }
}
