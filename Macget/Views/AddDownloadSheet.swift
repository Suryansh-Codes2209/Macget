import SwiftUI

struct AddDownloadSheet: View {
    @Bindable var vm: AddDownloadViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Download")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("URL").font(.callout).foregroundStyle(.secondary)
                HStack {
                    TextField("https://example.com/file.zip", text: $vm.urlString)
                        .textFieldStyle(.roundedBorder)
                    Button("From Clipboard") { vm.prefillFromClipboard() }
                        .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Save to").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text(vm.destinationFolder.path)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(.quaternary)
                        .cornerRadius(4)
                    Button("Choose…") { vm.chooseFolder() }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Checksum (optional)").font(.callout).foregroundStyle(.secondary)
                TextField("sha256=… / md5=… / hex digest", text: $vm.checksumText)
                    .textFieldStyle(.roundedBorder)
                if !vm.checksumIsAcceptable {
                    Text("Not a valid SHA-256 or MD5 digest.")
                        .font(.caption).foregroundStyle(.red)
                }
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Threads: \(vm.threadCount)")
                        .font(.callout).foregroundStyle(.secondary)
                    Stepper(value: $vm.threadCount, in: 1...Download.maxThreadCount) {
                        EmptyView()
                    }
                    .labelsHidden()
                }
                Toggle("Start immediately", isOn: $vm.startImmediately)
                Spacer()
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    Task {
                        let added = await vm.submit()
                        if added {
                            vm.reset()
                            isPresented = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!vm.isValid || !vm.checksumIsAcceptable)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { vm.prefillFromClipboard() }
    }
}
