import Cocoa

let bundle = Bundle(path: CommandLine.arguments[1])!
var checks = 0
func check(_ test: @autoclosure () -> Bool, _ message: String) {
    precondition(test(), message)
    checks += 1
}
for icon in BrandIcon.allCases {
    let image = BrandAssets.template(named: icon.rawValue, subdirectory: "BrandIcons", pointSize: 32, bundle: bundle)
    check(image != nil, "Missing icon: \(icon.rawValue)")
    check(image!.isTemplate, "Toolbar icon must use template rendering")
    check(Set(image!.representations.map { $0.pixelsWide }) == [32, 64], "Missing toolbar retina representation")
    check(image!.size == NSSize(width: 32, height: 32), "Toolbar logical size mismatch")
}
for name in ["menubar_icon", "menubar_icon_drop"] {
    let image = BrandAssets.template(named: name, pointSize: 18, bundle: bundle)
    check(image != nil && image!.isTemplate, "Menu bar template missing")
    check(Set(image!.representations.map { $0.pixelsWide }) == [18, 36], "Missing menu bar retina representation")
    check(image!.size == NSSize(width: 18, height: 18), "Menu bar logical size mismatch")
}
for name in RefinedAssets.names {
    let image = BrandAssets.template(named: name, subdirectory: "RefinedIcons", pointSize: 12, bundle: bundle)
    check(image != nil, "Missing Refined icon: \(name)")
    check(image!.isTemplate, "Refined icon must use template rendering")
    check(image!.representations.allSatisfy { $0.pixelsWide >= 24 && $0.pixelsHigh >= 24 }, "Refined icon resolution is insufficient")
}
let iconURL = bundle.url(forResource: "AppIcon", withExtension: "icns")!
check(NSImage(contentsOf: iconURL) != nil, "Application icon cannot be decoded")
print("All \(checks) bundled icon checks passed")
