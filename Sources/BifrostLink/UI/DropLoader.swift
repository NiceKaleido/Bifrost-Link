import Foundation

enum DropLoader {
    static func fileURLs(_ providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            guard let item = try? await provider.loadItem(forTypeIdentifier: "public.file-url") else { continue }
            if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                urls.append(url)
            } else if let url = item as? URL {
                urls.append(url)
            } else if let url = item as? NSURL {
                urls.append(url as URL)
            } else if let text = item as? String, let url = URL(string: text) {
                urls.append(url)
            }
        }
        return urls
    }
}
