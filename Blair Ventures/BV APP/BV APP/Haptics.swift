// Haptics.swift
// Aski IQ — Centralised haptic feedback helpers.
//
// WHY THIS EXISTS
// Audit §29: "Zero haptic feedback (UIImpactFeedbackGenerator) — 1 day to wire
// throughout." This is that file. Single import, single API, semantic names.
//
// USAGE
//   Haptics.tap()                  // light interaction confirmation
//   Haptics.success()              // saved, approved, sent
//   Haptics.warning()              // soft validation issue
//   Haptics.error()                // permission denied, sync failure
//   Haptics.selectionChanged()     // picker / segmented control / tab
//
// Calls are no-ops in tests and on devices that don't support haptics.

#if canImport(UIKit)
import Foundation
import UIKit

enum Haptics {

    /// Light tap — confirmation of a button press. Cheap, use freely.
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Medium tap — for slightly heavier actions like committing a multi-step
    /// flow (saving a quote, completing an estimate).
    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Heavy tap — destructive actions (delete confirmation accepted) or
    /// significant state changes (project marked complete).
    static func heavy() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    /// Success notification feedback — task completed positively.
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Warning notification feedback — soft caution.
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// Error notification feedback — operation failed.
    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// Selection changed — for pickers, segmented controls, switching tabs.
    static func selectionChanged() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
#endif
