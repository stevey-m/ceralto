import AppKit
import NotesCore
import PDFKit
import WebKit

@MainActor
final class NotePrinter: NSObject {
    let title: String
    let html: String
    private(set) var webView: WKWebView?
    private var coordinator: DocumentWebView.Coordinator?
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var checkingResources = false
    private var isReady = false
    private var printContinuation: CheckedContinuation<Bool, Never>?
    private var operation: NSPrintOperation?
    private let resources: ImportedResources?

    init(note: Note) throws {
        title = note.displayTitle
        html = try PrintDocument.html(note: note)
        if let source = note.importedSourceURL, let root = note.importedRootURL {
            resources = ImportedResources(source: source, root: root)
        } else {
            resources = nil
        }
    }

    func prepare() async throws {
        guard webView == nil else {
            throw NoteWorkflowError("This print job has already been prepared.")
        }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let parent = DocumentWebView(html: html, resources: resources, onImage: { _ in },
                                        onError: { [weak self] message in
                self?.finish(.failure(NoteWorkflowError(message)))
            }, onLoaded: { [weak self] view in self?.checkResources(in: view) })
            let coordinator = DocumentWebView.Coordinator(parent: parent)
            self.coordinator = coordinator
            let view = DocumentWebView.makeWebView(coordinator: coordinator)
            view.frame = NSRect(x: 0, y: 0, width: 720, height: 900)
            webView = view
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(20)) }
                catch { return }
                self?.finish(.failure(NoteWorkflowError("The note did not finish loading for printing. Check its attachments and try again.")))
            }
            view.loadHTMLString(html, baseURL: URL(string: "about:blank"))
        }
    }

    private func checkResources(in view: WKWebView) {
        guard continuation != nil, !checkingResources else { return }
        checkingResources = true
        Task { [weak self] in
            do {
                let result = try await view.callAsyncJavaScript("""
                await document.fonts.ready;
                await Promise.all(Array.from(document.images).map(image => image.decode().catch(() => {})));
                return document.querySelectorAll('.folio-image-placeholder').length +
                  Array.from(document.images).filter(image => !image.complete || image.naturalWidth === 0).length;
                """, arguments: [:], in: nil, contentWorld: .defaultClient)
                guard let missing = result as? Int, missing == 0 else {
                    throw NoteWorkflowError("One or more note images could not be loaded. Restore the missing attachments before printing or exporting a PDF.")
                }
                self?.finish(.success(()))
            } catch { self?.finish(.failure(error)) }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        if case .success = result { isReady = true }
        continuation.resume(with: result)
    }

    func makeOperation() throws -> NSPrintOperation {
        guard let info = NSPrintInfo.shared.copy() as? NSPrintInfo else {
            throw NoteWorkflowError("The system print settings could not be copied.")
        }
        return try makeOperation(using: info)
    }

    private func makeOperation(using info: NSPrintInfo) throws -> NSPrintOperation {
        guard let webView, isReady else {
            throw NoteWorkflowError("The note is not ready to print.")
        }
        info.topMargin = 36
        info.bottomMargin = 36
        info.leftMargin = 36
        info.rightMargin = 36
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let operation = webView.printOperation(with: info)
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        return operation
    }

    func pdfData(in window: NSWindow) async throws -> Data {
        // Export the entire note, not a previous print job's selected page range or copies.
        let operation = try makeOperation(using: NSPrintInfo(dictionary: [:]))
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ceralto-PDF-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.printInfo.jobDisposition = .save
        operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        guard await run(operation, in: window) else {
            throw NoteWorkflowError("The PDF could not be generated.")
        }
        let data = try Data(contentsOf: output)
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw NoteWorkflowError("The PDF renderer did not produce a readable document.")
        }
        return data
    }

    func run(_ operation: NSPrintOperation, in window: NSWindow) async -> Bool {
        await withCheckedContinuation { continuation in
            self.operation = operation
            printContinuation = continuation
            operation.runModal(for: window, delegate: self,
                               didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
    }

    @objc nonisolated private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool,
                                                       contextInfo: UnsafeMutableRawPointer?) {
        Task { @MainActor in
            let continuation = printContinuation
            printContinuation = nil
            self.operation = nil
            continuation?.resume(returning: success)
        }
    }

    func close() {
        finish(.failure(NoteWorkflowError("Print preparation was cancelled.")))
        timeout?.cancel()
        timeout = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "folioImage", contentWorld: .defaultClient)
        webView = nil
        coordinator = nil
        isReady = false
    }
}
