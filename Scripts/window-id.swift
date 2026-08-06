#!/usr/bin/env swift
// KubeDeck の窓の id を出す。無ければ何も出さない。
//
// **`osascript` を使わない。** ウインドウを数えるだけで補助アクセスの許可が
// 要り、断られると理由の分かりにくい失敗になる。`CGWindowList` は許可なしで
// 読める。
import CoreGraphics
import Foundation

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
    as? [[String: Any]] ?? []
for window in windows {
    guard (window[kCGWindowOwnerName as String] as? String) == "KubeDeck",
          let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
          // ツールチップや小さな補助窓を拾わない。
          (bounds["Height"] ?? 0) > 200,
          let number = window[kCGWindowNumber as String] as? Int
    else { continue }
    print(number)
    exit(0)
}
