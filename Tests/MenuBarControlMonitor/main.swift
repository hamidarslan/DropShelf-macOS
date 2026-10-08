import Foundation

private var failures = 0

private func check(_ actual: MenuBarControlReachability, _ expected: MenuBarControlReachability,
                   _ message: String) {
    if actual != expected {
        failures += 1
        fputs("FAIL: \(message): expected \(expected), got \(actual)\n", stderr)
    }
}

let valid = MenuBarControlClassificationEvidence(
    authorized: true, tree: .complete(arrowCount: 1, dividerCount: 1), geometry: .valid,
    applicationHit: .ownControl, systemHit: .ownControl)
check(MenuBarControlClassifier.classify(valid, mode: .collapsed), .reachable,
      "matching application and system hits prove reachability")

let unknownSystemControl = MenuBarControlClassificationEvidence(
    authorized: true, tree: .complete(arrowCount: 1, dividerCount: 1), geometry: .valid,
    applicationHit: .ownControl, systemHit: .otherControl)
check(MenuBarControlClassifier.classify(unknownSystemControl, mode: .collapsed), .indeterminate,
      "an unidentified same-host system hit is not proven obstruction or loss")

let systemDivider = MenuBarControlClassificationEvidence(
    authorized: true, tree: .complete(arrowCount: 1, dividerCount: 1), geometry: .valid,
    applicationHit: .ownControl, systemHit: .differentHostControl)
check(MenuBarControlClassifier.classify(systemDivider, mode: .collapsed), .unreachable,
      "the exact divider at the arrow point proves displacement despite an application arrow hit")

let unsupportedApplicationProbe = MenuBarControlClassificationEvidence(
    authorized: true, tree: .complete(arrowCount: 1, dividerCount: 1), geometry: .valid,
    applicationHit: .unavailable, systemHit: .ownControl)
check(MenuBarControlClassifier.classify(unsupportedApplicationProbe, mode: .collapsed), .reachable,
      "a successful system hit proves reachability when application hit-testing is unavailable")

let applicationHelpTag = MenuBarControlClassificationEvidence(
    authorized: true, tree: .complete(arrowCount: 1, dividerCount: 1), geometry: .valid,
    applicationHit: .overlay, systemHit: .otherControl)
check(MenuBarControlClassifier.classify(applicationHelpTag, mode: .collapsed), .temporarilyObscured,
      "a help tag or menu in the host layer is a temporary obstruction")

let foreignWindow = MenuBarControlClassificationEvidence(
    authorized: true, tree: .complete(arrowCount: 1, dividerCount: 1), geometry: .valid,
    applicationHit: .unavailable, systemHit: .foreignOverlay)
check(MenuBarControlClassifier.classify(foreignWindow, mode: .collapsed), .temporarilyObscured,
      "a foreign process above a valid arrow is an obstruction")

let partial = MenuBarControlClassificationEvidence(
    authorized: true, tree: .partial, geometry: .unavailable,
    applicationHit: .unavailable, systemHit: .unavailable)
check(MenuBarControlClassifier.classify(partial, mode: .collapsed), .indeterminate,
      "a partial Accessibility tree cannot prove absence")

let missing = MenuBarControlClassificationEvidence(
    authorized: true, tree: .complete(arrowCount: 0, dividerCount: 0), geometry: .unavailable,
    applicationHit: .unavailable, systemHit: .unavailable)
check(MenuBarControlClassifier.classify(missing, mode: .collapsed), .indeterminate,
      "a successful empty tree remains insufficient to prove physical arrow loss")

let displaced = MenuBarControlClassificationEvidence(
    authorized: true, tree: .complete(arrowCount: 1, dividerCount: 1), geometry: .outsideMenuBar,
    applicationHit: .unavailable, systemHit: .unavailable)
check(MenuBarControlClassifier.classify(displaced, mode: .collapsed), .unreachable,
      "an arrow outside the menu bar is unreachable")

let ambiguous = MenuBarControlClassificationEvidence(
    authorized: true, tree: .complete(arrowCount: 2, dividerCount: 1), geometry: .valid,
    applicationHit: .ownControl, systemHit: .ownControl)
check(MenuBarControlClassifier.classify(ambiguous, mode: .collapsed), .indeterminate,
      "duplicate arrow identifiers are not proof of reachability")

let denied = MenuBarControlClassificationEvidence(
    authorized: false, tree: .partial, geometry: .unavailable,
    applicationHit: .unavailable, systemHit: .unavailable)
check(MenuBarControlClassifier.classify(denied, mode: .collapsed), .unauthorized,
      "revoked Accessibility permission is distinct from query failure")

let wrongApplicationHit = MenuBarControlClassificationEvidence(
    authorized: true, tree: .complete(arrowCount: 1, dividerCount: 1), geometry: .valid,
    applicationHit: .differentHostControl, systemHit: .otherControl)
check(MenuBarControlClassifier.classify(wrongApplicationHit, mode: .collapsed), .unreachable,
      "MenuBarAgent resolving another control proves the arrow is covered within its own layer")

let unknownApplicationHit = MenuBarControlClassificationEvidence(
    authorized: true, tree: .complete(arrowCount: 1, dividerCount: 1), geometry: .valid,
    applicationHit: .otherControl, systemHit: .otherControl)
check(MenuBarControlClassifier.classify(unknownApplicationHit, mode: .collapsed), .indeterminate,
      "an unidentified host element is not proof that the arrow was displaced")

let missingExpandedDivider = MenuBarControlClassificationEvidence(
    authorized: true, tree: .complete(arrowCount: 1, dividerCount: 0), geometry: .valid,
    applicationHit: .ownControl, systemHit: .ownControl)
check(MenuBarControlClassifier.classify(missingExpandedDivider, mode: .expanded), .indeterminate,
      "a missing expanded divider denies placement without proving lasting physical loss")

let invalidGeometry = MenuBarControlClassificationEvidence(
    authorized: true, tree: .complete(arrowCount: 1, dividerCount: 1), geometry: .invalid,
    applicationHit: .unavailable, systemHit: .unavailable)
check(MenuBarControlClassifier.classify(invalidGeometry, mode: .collapsed), .indeterminate,
      "zero or malformed AX geometry cannot erase a saved confirmation")

let invalidOrder = MenuBarControlClassificationEvidence(
    authorized: true, tree: .complete(arrowCount: 1, dividerCount: 1), geometry: .invalidOrder,
    applicationHit: .unavailable, systemHit: .unavailable)
check(MenuBarControlClassifier.classify(invalidOrder, mode: .expanded), .unreachable,
      "verified invalid placement remains unreachable")

func placementPermitsHide(_ evidence: MenuBarControlClassificationEvidence) -> Bool {
    let reachability = MenuBarControlClassifier.classify(evidence, mode: .expanded)
    let result = MenuBarControlInspectionResult(requestID: 1, arrowFrame: .zero, dividerFrame: .zero,
        menuBarFrame: .zero, reachability: reachability, reason: .verified,
        diagnostic: MenuBarControlInspectionDiagnostic(stage: .systemHitTest, axError: nil,
            elapsedMilliseconds: 1, hitProcessID: nil, overlay: nil))
    return result.placementVerified
}
if !placementPermitsHide(foreignWindow) || !placementPermitsHide(applicationHelpTag) {
    failures += 1
    fputs("FAIL: a verified arrow placement can hide while an unrelated overlay is present\n", stderr)
}
for evidence in [partial, missing, displaced, ambiguous, denied, systemDivider, unknownSystemControl,
                 missingExpandedDivider, invalidGeometry, invalidOrder] {
    if placementPermitsHide(evidence) {
        failures += 1
        fputs("FAIL: uncertain or displaced controls must not permit hiding\n", stderr)
    }
}

if failures > 0 { exit(1) }
print("MenuBarControlMonitor classification tests passed")
