import SwiftUI

/// Settings tab for managing OPDS book catalogs: toggle the built-ins, add your
/// own feed (a Calibre server, a library, any OPDS URL), remove the ones you added.
///
/// Owns its own state rather than living on `AppSettings` — catalogs are a list
/// with their own file (`catalogs.json`) and don't need to ride along in every
/// settings write.
struct CatalogSettingsView: View {
    @State private var catalogs: [CatalogSource] = CatalogStore.load()
    @State private var newName = ""
    @State private var newURL = ""
    @State private var addError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                Section("Catalogs") {
                    ForEach($catalogs) { $catalog in
                        HStack(spacing: 8) {
                            Toggle("", isOn: $catalog.isEnabled)
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(catalog.name)
                                    .lineLimit(1)
                                // Explicit Color on both branches: a ternary mixing
                                // `.secondary` (HierarchicalShapeStyle) with a Color
                                // blows up type inference here.
                                Text(catalog.note ?? catalog.feedURL.absoluteString)
                                    .font(.caption)
                                    .foregroundStyle(catalog.note == nil ? Color.secondary : Theme.Palette.paused)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            if !catalog.isBuiltIn {
                                Button {
                                    remove(catalog)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove this catalog")
                            }
                        }
                    }
                }
            }
            .onChange(of: catalogs) { _, updated in CatalogStore.save(updated) }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Add a catalog")
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    TextField("Name (optional)", text: $newName)
                        .frame(width: 130)
                    TextField("https://example.org/opds", text: $newURL)
                        .onSubmit(addCatalog)
                    Button("Add", action: addCatalog)
                        .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .textFieldStyle(.roundedBorder)

                if let addError {
                    Text(addError)
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.error)
                } else {
                    Text("Any OPDS feed works — including your own Calibre server's.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
    }

    private func addCatalog() {
        do {
            let source = try CatalogStore.makeCustomSource(
                name: newName,
                urlString: newURL,
                existing: catalogs
            )
            catalogs.append(source)
            newName = ""
            newURL = ""
            addError = nil
        } catch {
            addError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func remove(_ catalog: CatalogSource) {
        catalogs.removeAll { $0.id == catalog.id }
    }
}
