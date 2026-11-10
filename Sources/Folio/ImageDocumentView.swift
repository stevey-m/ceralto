import AppKit
import SwiftUI

struct ImageDocumentView: View {
    let url: URL
    let onBack: () -> Void
    @ViewState private var fitRequest = 0
    @ViewState private var image: NSImage?
    @ViewState private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) { Label("Back to note", systemImage: "chevron.left") }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text(url.lastPathComponent).lineLimit(1).foregroundStyle(.secondary)
                Spacer()
                Button("Fit to window") { fitRequest += 1 }
            }
            .buttonStyle(.borderless)
            .padding(16)
            Divider()
            if let image {
                ImageDocumentCanvas(image: image, fitRequest: fitRequest)
                    .accessibilityLabel("Original image. Pinch to zoom and scroll to pan.")
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Cannot open image", systemImage: "photo.badge.exclamationmark",
                                       description: Text("The file is missing or is not a supported image."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: url) {
            image = NSImage(contentsOf: url)
            loading = false
        }
    }
}

struct ImageDocumentCanvas: NSViewRepresentable {
    let image: NSImage
    let fitRequest: Int

    func makeNSView(context: Context) -> ImageDocumentScrollView {
        let view = ImageDocumentScrollView()
        view.show(image)
        view.fitRequest = fitRequest
        return view
    }

    func updateNSView(_ view: ImageDocumentScrollView, context: Context) {
        if view.picture.image !== image { view.show(image) }
        if view.fitRequest != fitRequest {
            view.fitRequest = fitRequest
            view.fitToWindow()
        }
    }
}

final class ImageDocumentScrollView: NSScrollView {
    let picture = NSImageView()
    var fitRequest = 0
    private var fitting = true
    private var settingFit = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = CenteredImageClipView()
        documentView = picture
        picture.imageScaling = .scaleAxesIndependently
        picture.setAccessibilityLabel("Original image")
        allowsMagnification = true
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        backgroundColor = .textBackgroundColor
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    func show(_ image: NSImage) {
        picture.image = image
        // Use pixels, not JPEG DPI metadata, for the full-resolution canvas.
        let representation = image.representations.max { $0.pixelsWide < $1.pixelsWide }
        picture.setFrameSize(NSSize(width: max(1, representation?.pixelsWide ?? Int(image.size.width)),
                                    height: max(1, representation?.pixelsHigh ?? Int(image.size.height))))
        fitToWindow()
    }

    override var magnification: CGFloat {
        didSet { if !settingFit { fitting = false } }
    }

    override func layout() {
        super.layout()
        if fitting { fitToWindow() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if fitting { fitToWindow() }
    }

    func fitToWindow() {
        guard !settingFit, picture.frame.width > 0, picture.frame.height > 0,
              contentSize.width > 0, contentSize.height > 0 else { return }
        let scale = min(contentSize.width / picture.frame.width, contentSize.height / picture.frame.height)
        settingFit = true
        defer { settingFit = false }
        minMagnification = min(0.05, scale)
        maxMagnification = max(8, scale)
        setMagnification(scale, centeredAt: NSPoint(x: picture.frame.midX, y: picture.frame.midY))
        fitting = true
    }
}

private final class CenteredImageClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return result }
        if result.width > documentView.frame.width {
            result.origin.x = (documentView.frame.width - result.width) / 2
        }
        if result.height > documentView.frame.height {
            result.origin.y = (documentView.frame.height - result.height) / 2
        }
        return result
    }
}
