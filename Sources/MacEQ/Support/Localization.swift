import Foundation

/// SwiftPM's generated `Bundle.module` looks for the resource bundle next to
/// `Bundle.main.bundleURL` (i.e. at the .app's root, sibling to `Contents/`).
/// `codesign --verify` rejects that as "unsealed contents present in the
/// bundle root" for a real .app — everything has to live under `Contents/`.
/// `scripts/bundle.sh` puts the resource bundle in the standard
/// `Contents/Resources/` location instead, so lookup here checks there
/// first and only falls back to `Bundle.module` for `swift build`/`swift
/// test`, where `Bundle.main` isn't a real .app bundle at all.
private let resourceBundle: Bundle = {
    let inAppBundle = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Resources/MacEQ_maceq.bundle")
    return Bundle(url: inAppBundle) ?? Bundle.module
}()

/// Looks up `key` in Resources/*.lproj/Localizable.strings via the classic
/// NSBundle table API, which resolves reliably from a resource bundle.
/// `String(localized:)` was tried first and silently returned the raw key:
/// without an .xcassets/String Catalog build step (Xcode-only, this project
/// stays Xcode-project-free per Gate A), `swift build` copies .xcstrings as
/// an inert file instead of compiling it. `.lproj` +
/// `Bundle.localizedString(forKey:)` is the older mechanism, but it is the
/// one that actually works from a bare `swift build`.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = resourceBundle.localizedString(forKey: key, value: nil, table: "Localizable")
    return args.isEmpty ? format : String(format: format, arguments: args)
}
