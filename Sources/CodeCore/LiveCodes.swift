import Foundation

public func loadLiveCodes() -> (Data, URL) {
    guard let indexURL = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "build"), let webViewBaseURL = URL(string: "code://code/") else {
        fatalError("Couldn't load LiveCodes index.")
    }
    let data = try! Data.init(contentsOf: indexURL)
    return (data, webViewBaseURL)
}
