import SwiftUI
import SwiftUIDownloads

public struct DownloadButton: View {
    @ObservedObject var downloadable: Downloadable
    @Binding var downloadModels: [String]

    public init(downloadable: Downloadable, downloadModels: Binding<[String]>) {
        self.downloadable = downloadable
        _downloadModels = downloadModels
    }
    
    public var body: some View {
        Group {
            if #available(macOS 14, iOS 16, *) {
                Button(action: {
                    downloadModels = Array(Set(downloadModels).union(Set([downloadable.id])))
                }) {
                    Text("Download")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            } else {
                Button(action: {
                    downloadModels = Array(Set(downloadModels).union(Set([downloadable.id])))
                }) {
                    Text("Download")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .font(.callout)
#if os(iOS)
        .textCase(.uppercase)
#endif
    }
}
