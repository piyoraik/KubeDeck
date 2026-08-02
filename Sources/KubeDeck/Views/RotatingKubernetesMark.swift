import AppKit
import SwiftUI

/// 舵輪を Core Animation で回す。
///
/// **SwiftUI の `rotationEffect` で回さない。** 舵輪は 180 を超えるセグメントの
/// 塗りで、`TimelineView` から角度を与えて回すと毎フレーム塗り直しになる。
/// Release ビルドの実測で、待機中に CPU を 25% 使った。`drawingGroup()` を挟んでも
/// TimelineView が中身を作り直す以上ラスタライズは繰り返されるので、38% に悪化した。
///
/// ロゴを 1 枚のビットマップとして `CALayer` に載せ、回転はレンダーサーバに任せる。
/// アプリのプロセスは何もしないので CPU は 0% に落ちる。
struct RotatingKubernetesMark: NSViewRepresentable {
    var activity: ClusterActivity
    var side: CGFloat

    func makeNSView(context: Context) -> RotatingLogoView {
        RotatingLogoView(side: side, activity: activity)
    }

    func updateNSView(_ view: RotatingLogoView, context: Context) {
        view.update(side: side, activity: activity)
    }
}

final class RotatingLogoView: NSView {
    private static let rotationKey = "kubedeck.rotation"

    private let logoLayer = CALayer()
    private var side: CGFloat
    private var activity: ClusterActivity

    init(side: CGFloat, activity: ClusterActivity) {
        self.side = side
        self.activity = activity
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))

        wantsLayer = true
        // Y を下向きに揃える。ビットマップは SVG 由来で上下が下向きに描かれており、
        // かつこの向きなら回転角の正が右回りになる。
        logoLayer.isGeometryFlipped = true
        logoLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.addSublayer(logoLayer)

        redrawContents()
        applyAnimation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Storyboard からは使わない")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    override func layout() {
        super.layout()
        // 位置の更新にアニメーションを付けない。付くと回転と喧嘩して揺れる。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        logoLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        logoLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        redrawContents()
    }

    func update(side: CGFloat, activity: ClusterActivity) {
        if side != self.side {
            self.side = side
            invalidateIntrinsicContentSize()
            redrawContents()
            needsLayout = true
        }
        if activity != self.activity {
            self.activity = activity
            applyAnimation()
        }
    }

    private func redrawContents() {
        let scale = window?.backingScaleFactor ?? 2
        logoLayer.contentsScale = scale
        logoLayer.contents = KubernetesLogo.image(side: side, scale: scale)
    }

    private func applyAnimation() {
        // 速さが変わっても見た目の角度が飛ばないよう、いまの角度を引き継ぐ。
        let currentAngle = (logoLayer.presentation() ?? logoLayer)
            .value(forKeyPath: "transform.rotation.z") as? Double ?? 0
        logoLayer.removeAnimation(forKey: Self.rotationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        logoLayer.setValue(currentAngle, forKeyPath: "transform.rotation.z")
        CATransaction.commit()

        guard activity.degreesPerSecond > 0 else { return }

        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = currentAngle
        // レイヤの回転は角度が正で左回り。右回りにしたいので負を与える。
        // （`isGeometryFlipped` は contents の向きを直すだけで、回転の向きは変えない。
        // 連続フレームを撮って頂点の角度を測り、実測で確かめてある。）
        animation.byValue = -2 * Double.pi
        animation.duration = 360 / activity.degreesPerSecond
        animation.repeatCount = .greatestFiniteMagnitude
        animation.isRemovedOnCompletion = false
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        logoLayer.add(animation, forKey: Self.rotationKey)
    }
}
