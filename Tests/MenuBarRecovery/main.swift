import AppKit

func check(_ condition: Bool, _ label: String) {
    precondition(condition, label)
    print("PASS: \(label)")
}

let normal = NSRect(x: 0, y: 0, width: 1440, height: 875)
let normalFrame = MenuBarRecoveryPlacement.frame(in: normal)!
check(normalFrame == NSRect(x: 1304, y: 833, width: 124, height: 32), "pill uses upper-right margins")
check(normal.contains(normalFrame), "pill remains within the usable band")
let negative = NSRect(x: -1920, y: -200, width: 1920, height: 1080)
let negativeFrame = MenuBarRecoveryPlacement.frame(in: negative)!
check(negativeFrame.maxX == -12 && negativeFrame.maxY == 870 && negative.contains(negativeFrame),
      "negative display origins preserve margins and containment")
let above = NSRect(x: 500, y: 1200, width: 800, height: 600)
check(above.contains(MenuBarRecoveryPlacement.frame(in: above)!), "vertically stacked displays are supported")
let smallest = NSRect(x: -10, y: 20, width: 136, height: 42)
check(smallest.contains(MenuBarRecoveryPlacement.frame(in: smallest)!), "smallest usable band fits without overlap")
check(MenuBarRecoveryPlacement.frame(in: NSRect(x: 0, y: 0, width: 135, height: 100)) == nil,
      "insufficient width rejects presentation")
check(MenuBarRecoveryPlacement.frame(in: NSRect(x: 0, y: 0, width: 200, height: 41)) == nil,
      "insufficient height rejects presentation")
check(MenuBarRecoveryPlacement.frame(in: .zero) == nil, "empty usable band rejects presentation")
check(MenuBarRecoveryPlacement.frame(in: NSRect(x: 0, y: 0, width: -200, height: 100)) == nil,
      "negative size rejects presentation")
check(MenuBarRecoveryPlacement.frame(in: NSRect(x: CGFloat.nan, y: 0, width: 200, height: 100)) == nil,
      "nonfinite origin rejects presentation")
check(MenuBarRecoveryPlacement.frame(in: NSRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)) == nil,
      "nonfinite size rejects presentation")
let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
let autoHidden = MenuBarRecoveryPlacement.usableBand(visibleFrame: screen, screenFrame: screen, topInset: 25)!
check(autoHidden.maxY == 875, "auto-hidden menu bar still reserves its band")
let notched = MenuBarRecoveryPlacement.usableBand(visibleFrame: screen, screenFrame: screen, topInset: 38)!
check(MenuBarRecoveryPlacement.frame(in: notched)!.maxY == 852, "notch safe area stays above the pill")
check(MenuBarRecoveryPlacement.usableBand(visibleFrame: normal, screenFrame: screen, topInset: 25) == normal,
      "existing visible-frame menu bar exclusion is preserved")
check(MenuBarRecoveryPlacement.usableBand(visibleFrame: normal, screenFrame: screen, topInset: .nan) == nil,
      "nonfinite top inset rejects placement")
check(MenuBarRecoveryPlacement.usableBand(visibleFrame: normal, screenFrame: screen, topInset: 1000) == nil,
      "unusable screen band rejects placement")

MainActor.assumeIsolated {
    let controller = MenuBarRecoveryController()
    check(!controller.isPresented, "initialization presents no recovery panel")
    controller.hide()
    check(!controller.isPresented, "hiding before presentation is harmless")
}
print("All 18 recovery placement and unpresented-state checks passed")
