import SwiftUI
import AppKit
import BlazebunnyCore

/// The panel on the right. Sections adapt to the image's source:
/// Prompt and Midjourney/Generation for generated images, Camera for photos, File always.
struct InspectorView: View {
    let model: LibraryModel

    var body: some View {
        if let d = model.detail {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    PreviewImage(model: model, detail: d)
                    if model.selection.count > 1 {
                        Text("\(model.selection.count) selected — copy puts one prompt per line")
                            .dsText(.meta).foregroundStyle(.secondary)
                    }
                    if let m = d.metadata {
                        header(m)
                        if let text = m.promptText { promptSection(m, text) }
                        if let p = m.prompt, !p.parameters.isEmpty { midjourneySection(p) }
                        if let g = m.generator { generationSection(g) }
                        if let c = m.camera, m.source == .camera { cameraSection(c) }
                    } else if d.metadataFailed {
                        Label("Could not read this file.", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    } else {
                        Label("Reading metadata…", systemImage: "hourglass").foregroundStyle(.secondary)
                    }
                    fileSection(d)
                    actions
                }
                .padding(DS.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if model.library != nil {
            LibrarySummaryView(model: model)
        } else {
            ContentUnavailableView("No Selection", systemImage: "photo.on.rectangle",
                                   description: Text("Select an image to see its details."))
        }
    }

    func header(_ m: ItemMetadata) -> some View {
        HStack(spacing: DS.Space.s) {
            Label(m.source.title, systemImage: m.source.symbol)
                .dsText(.metaStrong)
                .padding(.horizontal, DS.Space.s)
                .frame(height: DS.Size.badge)
                .background(sourceTint(m.source).opacity(DS.Tint.fill), in: Capsule())
                .foregroundStyle(sourceTint(m.source))
                .onTapGesture { model.addFilter(.source, m.source.rawValue) }
                .help("Show only \(m.source.title) images")
            Spacer()
            if m.promptText != nil || m.camera != nil {
                Text("Click a value to filter").dsText(.meta).foregroundStyle(.secondary)
            }
        }
    }

    func sourceTint(_ s: ItemSource) -> Color {
        switch s {
        case .midjourney: return DS.Tint.midjourney
        case .stableDiffusion: return DS.Tint.stableDiffusion
        case .camera: return DS.Tint.camera
        default: return .secondary
        }
    }

    func promptSection(_ m: ItemMetadata, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text)
                .dsText(.reading)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { model.copy(.prompt) } label: {
                    Text(model.copiedKind == .prompt ? "Copied" : "Copy Prompt")
                }
                .buttonStyle(.borderedProminent)
                if m.prompt != nil {
                    Button(model.copiedKind == .text ? "Copied" : "Copy Text") { model.copy(.text) }
                    Button(model.copiedKind == .parameters ? "Copied" : "Copy Parameters") { model.copy(.parameters) }
                }
            }
            if let neg = m.generator?.negativePrompt, !neg.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    SectionTitle("Negative prompt")
                    Text(neg).dsText(.label).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    func midjourneySection(_ p: MidjourneyPrompt) -> some View {
        InfoTable(title: "Midjourney") {
            ForEach(Array(p.parameters.enumerated()), id: \.offset) { _, param in
                InfoRow(label: paramLabel(param.name)) {
                    switch param.name {
                    case "ar", "aspect":
                        FilterLink(param.value) { model.addFilter(.shape, "r:" + param.value) }
                    case "v", "version":
                        FilterLink(param.value) { model.addFilter(.version, param.value) }
                    case "niji":
                        FilterLink("niji " + param.value) { model.addFilter(.version, param.value.isEmpty ? "niji" : "niji " + param.value) }
                    default:
                        FilterLink(param.value.isEmpty ? param.name : param.value) { model.addFilter(.param, paramFacetKey(param)) }
                        if param.name == "sref" || param.name == "cref" || param.name == "profile" || param.name == "p" {
                            Button { copyString(param.value) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless).help("Copy")
                        }
                    }
                }
            }
            if let job = p.jobID {
                InfoRow(label: "Job ID") { Text(job).dsText(.label, .number).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
            }
        }
    }

    func paramLabel(_ name: String) -> String {
        ["ar": "Aspect", "aspect": "Aspect", "v": "Version", "version": "Version", "niji": "Niji", "raw": "Style", "style": "Style",
         "stylize": "Stylize", "s": "Stylize", "chaos": "Chaos", "c": "Chaos", "sref": "Style ref", "cref": "Character ref",
         "sw": "Style weight", "cw": "Char. weight", "weird": "Weird", "w": "Weird", "q": "Quality", "quality": "Quality",
         "profile": "Profile", "p": "Profile", "no": "Exclude", "seed": "Seed", "tile": "Tile", "hd": "HD", "exp": "Exp",
         "preview": "Preview", "personalize": "Personalize"][name] ?? name.capitalized
    }

    func generationSection(_ g: GeneratorInfo) -> some View {
        InfoTable(title: "Generation") {
            if let t = g.tool { InfoRow(label: "Tool") { Text(t) } }
            if let m = g.model { InfoRow(label: "Model") { Text(m).lineLimit(1).truncationMode(.middle) } }
            if let s = g.steps { InfoRow(label: "Steps") { Text("\(s)").dsText(.label, .number) } }
            if let c = g.cfg { InfoRow(label: "CFG") { Text(CameraInfo.trim(c)).dsText(.label, .number) } }
            if let s = g.sampler { InfoRow(label: "Sampler") { Text(s) } }
            if let s = g.seed { InfoRow(label: "Seed") { Text(s).dsText(.label, .number).textSelection(.enabled) } }
        }
    }

    func cameraSection(_ c: CameraInfo) -> some View {
        InfoTable(title: "Camera") {
            if let cam = c.camera { InfoRow(label: "Camera") { FilterLink(cam, mono: false) { model.addFilter(.camera, cam) } } }
            if let l = c.lens { InfoRow(label: "Lens") { Text(l).lineLimit(1) } }
            if let e = c.exposureSummary { InfoRow(label: "Exposure") { Text(e).dsText(.label, .number) } }
        }
    }

    func fileSection(_ d: ItemDetail) -> some View {
        let m = d.metadata
        return InfoTable(title: "File") {
            if let date = m?.createdAt {
                InfoRow(label: "Created") {
                    Text(date.formatted(date: .abbreviated, time: .shortened)).dsText(.label, .number)
                    Text(sourceNote(m!.createdSource)).dsText(.meta).foregroundStyle(.secondary)
                }
            }
            if let a = m?.author, !a.isEmpty { InfoRow(label: "Author") { Text(a) } }
            if let w = m?.width, let h = m?.height {
                InfoRow(label: "Dimensions") {
                    Text("\(w) × \(h)").dsText(.label, .number)
                    if let ar = m?.aspect { FilterLink(ar) { model.addFilter(.shape, "r:" + ar) } }
                }
            }
            InfoRow(label: "Type") {
                FilterLink(d.kind.title, mono: false) { model.addFilter(.type, d.kind.rawValue) }
                Text(ByteCountFormatter.string(fromByteCount: d.size, countStyle: .file)).foregroundStyle(.secondary)
            }
            InfoRow(label: "Name") {
                Text((d.relPath as NSString).lastPathComponent).dsText(.label, .number).textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Show in Finder") { model.revealInFinder() }
                Button("Open") { model.openOriginal() }
            }
            .disabled(!model.isOnline)
            if !model.isOnline {
                Label("Disk not connected — the original is not reachable.", systemImage: "externaldrive.badge.xmark")
                    .dsText(.meta).foregroundStyle(DS.Tint.warning)
            }
        }
    }

    func sourceNote(_ s: CreatedSource) -> String {
        switch s {
        case .pngText: return "embedded"
        case .exif: return "EXIF"
        case .xmp: return "XMP"
        case .file: return "file date"
        }
    }

    func copyString(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).dsText(.caption).foregroundStyle(.secondary)
    }
}

/// A titled two-column table with hairline separators, 28 pt rows.
struct InfoTable<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title)
            VStack(spacing: 0) { content }
        }
    }
}

struct InfoRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: Value
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Text(label).foregroundStyle(.secondary).frame(width: DS.Size.inspectorLabel, alignment: .leading)
            HStack(spacing: DS.Space.iconGap) { value }
            Spacer(minLength: 0)
        }
        .dsText(.label)
        .frame(minHeight: DS.Size.control)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.Palette.rowRule).frame(height: 1) }
    }
}

/// A value that adds itself as a filter when clicked.
struct FilterLink: View {
    let text: String
    let mono: Bool
    let action: () -> Void
    @State private var hover = false

    init(_ text: String, mono: Bool = true, action: @escaping () -> Void) {
        self.text = text
        self.mono = mono
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(text)
                .dsText(.label, mono ? .number : .text)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(hover ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(hover ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .padding(.leading, -6)
        .onHover { hover = $0 }
        .help("Filter by \(text)")
    }
}

/// The thumbnail at once, upgraded to a larger image from the original when
/// the disk is connected. Tall images are capped so the details stay visible.
struct PreviewImage: View {
    let model: LibraryModel
    let detail: ItemDetail
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: 300)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: detail.id) { await load() }
    }

    var aspect: CGFloat {
        guard let w = detail.metadata?.width, let h = detail.metadata?.height, w > 0, h > 0 else { return 1 }
        return CGFloat(w) / CGFloat(h)
    }

    func load() async {
        let id = detail.id
        image = model.thumbnails.cached(id)
        if image == nil {
            image = await withCheckedContinuation { cont in model.thumbnails.load(id) { cont.resume(returning: $0) } }
        }
        guard model.isOnline, !detail.kind.isVideo, let url = model.originalURL(detail.relPath) else { return }
        try? await Task.sleep(for: .milliseconds(250))  // skip while arrowing quickly through the grid
        if Task.isCancelled { return }
        let big: CGImage? = await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1200,
            ] as CFDictionary)
        }.value
        if !Task.isCancelled, let big { image = NSImage(cgImage: big, size: NSSize(width: big.width, height: big.height)) }
    }
}
