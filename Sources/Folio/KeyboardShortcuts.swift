import Foundation
import SwiftUI

enum ShortcutAction: String, CaseIterable, Identifiable {
    case newNote, newNotebook, capture, find, palette, save, back, forward, closeTab
    case toggleFolders, toggleNotes, importFiles, exportNote, sync, today, templates, tasks, addAttachments

    var id: String { rawValue }
    var title: String {
        switch self {
        case .capture: "Quick Capture"
        case .palette: "Command Palette"
        case .addAttachments: "Add Images or Attachments"
        default: command?.title ?? rawValue
        }
    }

    var command: FolioCommand? {
        switch self {
        case .newNote: .newNote
        case .newNotebook: .newNotebook
        case .find: .find
        case .save: .save
        case .back: .back
        case .forward: .forward
        case .closeTab: .closeTab
        case .toggleFolders: .toggleFolders
        case .toggleNotes: .toggleNotes
        case .importFiles: .importFiles
        case .exportNote: .exportNote
        case .sync: .sync
        case .today: .today
        case .templates: .templates
        case .tasks: .tasks
        case .capture, .palette, .addAttachments: nil
        }
    }

    var defaultBinding: ShortcutBinding {
        switch self {
        case .newNote: ShortcutBinding(key: "n")
        case .newNotebook: ShortcutBinding(key: "n", modifiers: 1)
        case .capture: ShortcutBinding(key: " ", modifiers: 1)
        case .find: ShortcutBinding(key: "k")
        case .palette: ShortcutBinding(key: "p", modifiers: 1)
        case .save: ShortcutBinding(key: "s")
        case .back: ShortcutBinding(key: "[")
        case .forward: ShortcutBinding(key: "]")
        case .closeTab: ShortcutBinding(key: "w", modifiers: 2)
        case .toggleFolders: ShortcutBinding(key: "s", modifiers: 2)
        case .toggleNotes: ShortcutBinding(key: "l", modifiers: 2)
        case .importFiles: ShortcutBinding(key: "i", modifiers: 1)
        case .exportNote: ShortcutBinding(key: "e", modifiers: 1)
        case .sync: ShortcutBinding(key: "r", modifiers: 1)
        case .today: ShortcutBinding(key: "d", modifiers: 1)
        case .templates: ShortcutBinding(key: "t", modifiers: 1)
        case .tasks: ShortcutBinding(key: "j", modifiers: 1)
        case .addAttachments: ShortcutBinding(key: "a", modifiers: 1)
        }
    }
}

struct ShortcutBinding: Codable, Equatable, Hashable {
    var key: String
    /// Command is always present; bits add Shift, Option and Control.
    var modifiers: Int = 0

    var label: String {
        guard !key.isEmpty else { return "Unassigned" }
        return Self.modifierLabels[modifiers] + (key == " " ? "Space" : key.uppercased())
    }

    var keyboardShortcut: KeyboardShortcut? {
        guard let key = key.first else { return nil }
        var flags: EventModifiers = .command
        if modifiers & 1 != 0 { flags.insert(.shift) }
        if modifiers & 2 != 0 { flags.insert(.option) }
        if modifiers & 4 != 0 { flags.insert(.control) }
        return KeyboardShortcut(KeyEquivalent(key), modifiers: flags)
    }

    static let modifierLabels = ["⌘", "⇧⌘", "⌥⌘", "⌥⇧⌘", "⌃⌘", "⌃⇧⌘", "⌃⌥⌘", "⌃⌥⇧⌘"]
    static let keys = [""] + Array("abcdefghijklmnopqrstuvwxyz0123456789[]/.,;-= ").map(String.init)
}

enum ShortcutConfiguration {
    static var defaults: [String: ShortcutBinding] {
        Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0.rawValue, $0.defaultBinding) })
    }

    private struct Document: Codable {
        var version = 1
        let bindings: [String: ShortcutBinding]
    }

    static func decode(_ data: Data?) throws -> [String: ShortcutBinding] {
        guard let data else { return defaults }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1 else { throw ShortcutError("The saved shortcut version is not supported.") }
        let bindings = defaults.merging(document.bindings) { _, saved in saved }
        try validate(bindings)
        return bindings
    }

    static func encode(_ bindings: [String: ShortcutBinding]) throws -> Data {
        try validate(bindings)
        return try JSONEncoder().encode(Document(bindings: bindings))
    }

    static func validate(_ bindings: [String: ShortcutBinding]) throws {
        guard Set(bindings.keys) == Set(defaults.keys) else { throw ShortcutError("The shortcut configuration contains missing or unknown actions.") }
        let reserved = Set(["a", "b", "c", "f", "h", "i", "m", "p", "q", "u", "v", "w", "x", "z", ","].map {
            ShortcutBinding(key: $0)
        } + [ShortcutBinding(key: "z", modifiers: 1), ShortcutBinding(key: "h", modifiers: 2),
             ShortcutBinding(key: "m", modifiers: 2), ShortcutBinding(key: "f", modifiers: 4),
             ShortcutBinding(key: " "), ShortcutBinding(key: " ", modifiers: 4),
             ShortcutBinding(key: "q", modifiers: 1), ShortcutBinding(key: "q", modifiers: 4),
             ShortcutBinding(key: "/", modifiers: 1)] +
            ["3", "4", "5"].map { ShortcutBinding(key: $0, modifiers: 1) })
        var used: [ShortcutBinding: ShortcutAction] = [:]
        for action in ShortcutAction.allCases {
            guard let binding = bindings[action.rawValue],
                  ShortcutBinding.keys.contains(binding.key), (0...7).contains(binding.modifiers) else {
                throw ShortcutError("Choose a supported key and modifiers for \(action.title).")
            }
            guard !binding.key.isEmpty else { continue }
            guard !reserved.contains(binding) else {
                throw ShortcutError("\(binding.label) is reserved for standard editing, window or system commands.")
            }
            if let other = used[binding] {
                throw ShortcutError("\(binding.label) is already assigned to \(other.title). Choose a different shortcut for \(action.title).")
            }
            used[binding] = action
        }
    }
}

struct ShortcutError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct ShortcutSettings: View {
    @EnvironmentObject private var store: NotesStore
    @ViewState private var draft: [String: ShortcutBinding]
    @ViewState private var failure: String?
    @ViewState private var confirmingReset = false

    init(bindings: [String: ShortcutBinding]) { _draft = ViewState(initialValue: bindings) }

    var body: some View {
        Section("Customize application shortcuts") {
            Text("Command is always included. Choose Unassigned to remove a shortcut. Changes apply after Save Shortcuts, including menus, toolbars and the command palette.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(ShortcutAction.allCases) { action in
                HStack {
                    Text(action.title).frame(maxWidth: .infinity, alignment: .leading)
                    Picker("Modifiers for \(action.title)", selection: binding(action, \.modifiers)) {
                        ForEach(0..<8, id: \.self) { Text(ShortcutBinding.modifierLabels[$0]).tag($0) }
                    }.labelsHidden().frame(width: 100)
                    Picker("Key for \(action.title)", selection: binding(action, \.key)) {
                        ForEach(ShortcutBinding.keys, id: \.self) { key in
                            Text(key.isEmpty ? "Unassigned" : key == " " ? "Space" : key.uppercased()).tag(key)
                        }
                    }.labelsHidden().frame(width: 120)
                }
            }
            if let failure { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if !store.shortcutsAvailable {
                Text("Saved shortcuts could not load; defaults are active. Reset to Defaults explicitly replaces the unreadable configuration.")
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("Reset to Defaults") { confirmingReset = true }
                Spacer()
                Button("Save Shortcuts") {
                    do { try store.saveShortcuts(draft); failure = nil }
                    catch { failure = error.localizedDescription }
                }
                .disabled(!store.shortcutsAvailable || draft == store.shortcutBindings)
            }
            Text("Only Deltos application commands are configurable here. Standard editing, window and system shortcuts remain reserved. These are local preferences, not global hotkeys.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Reset all application shortcuts?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset to Defaults") {
                store.resetShortcuts()
                draft = store.shortcutBindings
                failure = nil
            }
        } message: { Text("This replaces your saved shortcut assignments on this Mac.") }
    }

    private func binding<Value>(_ action: ShortcutAction, _ path: WritableKeyPath<ShortcutBinding, Value>) -> Binding<Value> {
        Binding(get: { (draft[action.rawValue] ?? action.defaultBinding)[keyPath: path] }, set: { value in
            var shortcut = draft[action.rawValue] ?? action.defaultBinding
            shortcut[keyPath: path] = value
            draft[action.rawValue] = shortcut
            failure = nil
        })
    }
}
