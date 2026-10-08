import Foundation

func check(_ condition: Bool, _ label: String) {
    precondition(condition, label)
    print("PASS: \(label)")
}

var policy = MenuBarGuardPolicy()

check(policy.observe(.reachable, at: 0) == .keepHidden,
      "verified recovery keeps the hidden layout")
check(policy.observe(.indeterminate, at: 1) == .keepHidden,
      "one transport timeout does not reveal icons")
check(policy.observe(.reachable, at: 2) == .keepHidden,
      "healthy recovery clears a transient timeout")
check(policy.observe(.unreachable, at: 3) == .keepHidden,
      "one loss after recovery does not restore icons for control loss")
check(policy.observe(.reachable, at: 4) == .keepHidden,
      "healthy sampling resets the loss streak")

policy.reset()
check(policy.observe(.indeterminate, at: 10) == .keepHidden,
      "continuous unknown state starts with a grace period")
check(policy.observe(.indeterminate, at: 17.999) == .keepHidden,
      "unknown state remains hidden before eight seconds")
check(policy.observe(.indeterminate, at: 18) == .revealPreservingSetup,
      "eight seconds of continuous unknown state reveals without discarding setup")

policy.reset()
check(policy.observe(.reachable, at: 20) == .keepHidden,
      "popup fixture begins from a verified hidden state")
check(policy.observe(.obscured, at: 80) == .keepHidden &&
      policy.observe(.obscured, at: 620) == .keepHidden,
      "known popup occlusion can continue without being treated as arrow loss")
check(policy.observe(.unreachable, at: 621) == .keepHidden,
      "occlusion clears prior failures before a new loss sample")

policy.reset()
check(policy.observe(.unreachable, at: 700) == .keepHidden,
      "first confirmed loss waits for a second sample")
check(policy.observe(.unreachable, at: 701) == .revealForControlLoss,
      "two consecutive confirmed losses restore icons for confirmed control loss")

policy.reset()
check(policy.observe(.unreachable, at: 800) == .keepHidden,
      "first loss is recorded before an explicit recovery reset")
policy.reset()
check(policy.observe(.unreachable, at: 801) == .keepHidden,
      "new hide or reveal resets the previous loss")
check(policy.observe(.unreachable, at: 802) == .revealForControlLoss,
      "a fresh pair of confirmed losses still restores icons for control loss")

policy.reset()
check(policy.observe(.unreachable, at: 900) == .keepHidden,
      "mixed transport sequence begins with one confirmed loss")
check(policy.observe(.indeterminate, at: 901) == .keepHidden,
      "indeterminate transport breaks the confirmed-loss streak")
check(policy.observe(.unreachable, at: 902) == .keepHidden,
      "loss after indeterminate transport starts a new streak")
check(policy.observe(.indeterminate, at: 903) == .keepHidden &&
      policy.observe(.indeterminate, at: 907) == .keepHidden,
      "repeated short unknown samples are not counted as real losses")
check(policy.observe(.reachable, at: 908) == .keepHidden,
      "healthy recovery clears both unknown and loss state")

policy.reset()
check(policy.observe(.indeterminate, at: 950) == .keepHidden &&
      policy.observe(.unreachable, at: 952) == .keepHidden &&
      policy.observe(.indeterminate, at: 954) == .keepHidden &&
      policy.observe(.unreachable, at: 956) == .keepHidden &&
      policy.observe(.indeterminate, at: 957.9) == .keepHidden,
      "alternating transport and loss samples share one unverified grace period")
check(policy.observe(.unreachable, at: 958) == .revealPreservingSetup,
      "eight mixed unverified seconds reveal without invalidating confirmed setup")
check(policy.observe(.reachable, at: 959) == .keepHidden &&
      policy.observe(.indeterminate, at: 960) == .keepHidden &&
      policy.observe(.unreachable, at: 967.9) == .keepHidden,
      "healthy recovery resets the mixed unverified time budget")

policy.reset()
check(policy.observe(.unreachable, at: 1_000) == .keepHidden,
      "permission fixture begins with one confirmed loss")
check(policy.observe(.unauthorized, at: 1_001) == .revealPreservingSetup,
      "permission loss reveals immediately without invalidating setup")
check(policy.observe(.unreachable, at: 1_002) == .keepHidden,
      "permission loss clears the prior confirmed-loss streak")

policy.reset()
check(policy.observe(.indeterminate, at: 2_000) == .keepHidden,
      "clock fixture starts an unknown grace period")
check(policy.observe(.indeterminate, at: 1_999) == .revealPreservingSetup,
      "backward monotonic time fails safely without invalidating setup")
check(policy.observe(.indeterminate, at: .nan) == .revealPreservingSetup,
      "invalid monotonic time fails safely without invalidating setup")

print("PASS: menu bar guard policy regression suite")
