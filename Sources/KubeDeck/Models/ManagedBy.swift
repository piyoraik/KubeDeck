import Foundation

/// このオブジェクトを外から管理している道具。
///
/// **手で変えても戻ることを、押す前に言う。** GitOps や Helm の下にある
/// オブジェクトを画面から書き換えても、次の同期で元に戻る。断りが無いと
/// 「書き戻しが効かなかった」としか見えず、原因をアプリの側に探しに行くことに
/// なる。HPA 管理下のワークロードでレプリカ数を変えるときと同じ扱い。
///
/// **止めない。** 一時的に手で当てて確かめるのは正当な操作。禁じるのではなく、
/// 戻ることを先に言う。
enum ManagedBy: String, Sendable {
    case argoCD = "Argo CD"
    case helm = "Helm"
    case flux = "Flux"

    /// **名前で決め打ちしない。** 見るのは各ツールが自分で付ける目印だけ。
    /// `app.kubernetes.io/managed-by` は誰でも書ける汎用のラベルなので、
    /// Helm の判定にだけ使い、値が `Helm` のときに限る。
    static func detect(_ object: K8sObject) -> ManagedBy? {
        let labels = object.labels
        let annotations = object.annotations

        // Argo CD は既定でラベル、`installationID` 併用時などは注釈で追跡する。
        if labels["argocd.argoproj.io/instance"] != nil
            || annotations["argocd.argoproj.io/tracking-id"] != nil {
            return .argoCD
        }
        if labels["app.kubernetes.io/managed-by"] == "Helm"
            || annotations["meta.helm.sh/release-name"] != nil {
            return .helm
        }
        // Flux は Kustomization / HelmRelease のどちらから来ても
        // `<種類>.toolkit.fluxcd.io/name` を付ける。
        if labels.keys.contains(where: { $0.hasSuffix(".toolkit.fluxcd.io/name") }) {
            return .flux
        }
        return nil
    }

    /// 書き戻す前に出す断り。**何が起きるかを書く**（「管理されています」だけだと
    /// それで困るのかどうかが分からない）。
    var warning: String {
        String(localized: """
            \(rawValue) が管理しています。ここで書き戻しても、次の同期で元に戻ります。
            """)
    }
}
