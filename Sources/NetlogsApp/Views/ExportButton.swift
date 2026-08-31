import SwiftUI
import UniformTypeIdentifiers
import NetlogsCore

/// Toolbar "Export" — a menu of format × scope, then a save panel via
/// `.fileExporter`. Builds the export off-main from the session's SQLite
/// history (plan §10).
struct ExportButton: View {
    let store: SessionStore
    let sessionID: UUID?

    @State private var doc: DataDocument?
    @State private var filename = "netlogs"
    @State private var showExporter = false
    @State private var working = false

    var body: some View {
        Menu {
            Section("Full session") {
                ForEach(ExportFormat.allCases, id: \.self) { fmt in
                    Button("\(fmt.menuLabel)…") { build(fmt, failuresOnly: false) }
                }
            }
            Section("Failures only") {
                ForEach(ExportFormat.allCases, id: \.self) { fmt in
                    Button("\(fmt.menuLabel)…") { build(fmt, failuresOnly: true) }
                }
            }
        } label: {
            Label("Export", systemImage: working ? "hourglass" : "square.and.arrow.up")
        }
        .disabled(sessionID == nil || working)
        .fileExporter(
            isPresented: $showExporter,
            document: doc,
            contentType: doc?.type ?? .plainText,
            defaultFilename: filename
        ) { _ in doc = nil }
    }

    private func build(_ format: ExportFormat, failuresOnly: Bool) {
        guard let sessionID else { return }
        working = true
        Task {
            defer { working = false }
            do {
                let export = try await DetailLoader.export(store: store, sessionID: sessionID)
                let data = try SessionExporter.data(export, as: format, failuresOnly: failuresOnly)
                filename = SessionExporter.filename(export, format: format, failuresOnly: failuresOnly)
                doc = DataDocument(data: data, type: format.utType)
                showExporter = true
            } catch {
                doc = nil
            }
        }
    }
}

struct DataDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText, .commaSeparatedText, .json]

    var data: Data
    var type: UTType

    init(data: Data, type: UTType) {
        self.data = data
        self.type = type
    }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        type = .plainText
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private extension ExportFormat {
    var menuLabel: String {
        switch self {
        case .csv: return "CSV (ping log)"
        case .json: return "JSON (everything)"
        case .text: return "Text report"
        }
    }
    var utType: UTType {
        switch self {
        case .csv: return .commaSeparatedText
        case .json: return .json
        case .text: return .plainText
        }
    }
}
