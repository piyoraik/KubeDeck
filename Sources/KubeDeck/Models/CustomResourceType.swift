import Foundation

/// CRD で定義された種別。
struct CustomResourceType: Sendable, Hashable, Codable, Identifiable {
    /// CRD が宣言する表示列。`kubectl get` が出しているのと同じもの。
    struct PrinterColumn: Sendable, Hashable, Codable {
        var name: String
        var jsonPath: String
        /// 0 は既定で表示、1 以上は `-o wide` 相当。
        var priority: Int
    }

    var group: String
    var version: String
    /// `Application` のような単数形。表示に使う。
    var kind: String
    /// `applications` のような複数形。kubectl に渡す。
    var plural: String
    var namespaced: Bool
    var printerColumns: [PrinterColumn] = []

    var id: String { resourceName }

    /// kubectl に渡す名前。
    ///
    /// **group を必ず付ける。** 別のグループが同じ複数形を持つことがあり
    /// （`certificates` など）、短い名前だと別の種別を引いてしまう。
    var resourceName: String {
        group.isEmpty ? plural : "\(plural).\(group)"
    }

    var displayName: String { kind }

    /// CRD の JSON 1 件からつくる。served なバージョンが無ければ nil。
    init?(crd: K8sObject) {
        guard let spec = crd.spec,
              let group = spec["group"]?.stringValue,
              let plural = spec.path("names.plural")?.stringValue,
              let kind = spec.path("names.kind")?.stringValue
        else { return nil }

        let versions = spec["versions"]?.arrayValue ?? []
        // storage に指されているものを優先する。無ければ served な最初のもの。
        let chosen = versions.first { $0["storage"]?.boolValue == true }
            ?? versions.first { $0["served"]?.boolValue == true }
        guard let chosen, let version = chosen["name"]?.stringValue else { return nil }

        self.group = group
        self.version = version
        self.kind = kind
        self.plural = plural
        self.namespaced = spec["scope"]?.stringValue == "Namespaced"
        self.printerColumns = (chosen["additionalPrinterColumns"]?.arrayValue ?? [])
            .compactMap { column in
                guard let name = column["name"]?.stringValue,
                      let path = column["jsonPath"]?.stringValue
                else { return nil }
                return PrinterColumn(
                    name: name, jsonPath: path, priority: column["priority"]?.intValue ?? 0)
            }
    }
}

/// 一覧の対象。組み込みの種別か、CRD で定義された種別。
enum ResourceTarget: Hashable, Sendable {
    case builtIn(ResourceKind)
    case custom(CustomResourceType)

    var displayName: String {
        switch self {
        case .builtIn(let kind): return kind.displayName
        case .custom(let type): return type.displayName
        }
    }

    var resourceName: String {
        switch self {
        case .builtIn(let kind): return kind.resourceName
        case .custom(let type): return type.resourceName
        }
    }

    var isNamespaced: Bool {
        switch self {
        case .builtIn(let kind): return kind.isNamespaced
        case .custom(let type): return type.namespaced
        }
    }

    var symbol: String {
        switch self {
        case .builtIn(let kind): return kind.symbol
        case .custom: return "puzzlepiece.extension"
        }
    }

    /// 組み込みのときだけ種別を返す。種別ごとの特別扱い（スケール、ログなど）の判定に使う。
    var builtIn: ResourceKind? {
        if case .builtIn(let kind) = self { return kind }
        return nil
    }

    var customType: CustomResourceType? {
        if case .custom(let type) = self { return type }
        return nil
    }
}

// MARK: - JSONPath

extension JSONValue {
    /// `additionalPrinterColumns` の JSONPath を解釈する。
    ///
    /// 対応するのは `.a.b` と `.a[0].b` まで。
    /// **`[?(@.type=="Ready")]` のような絞り込みは扱わない。** 扱うには
    /// JSONPath の式評価が要り、表示列 1 つのために持ち込む重さではない。
    /// 解釈できないパスは nil を返し、セルは空欄になる。
    func jsonPath(_ path: String) -> JSONValue? {
        var current: JSONValue? = self
        let trimmed = path.hasPrefix(".") ? String(path.dropFirst()) : path
        guard !trimmed.isEmpty else { return self }

        for rawComponent in trimmed.split(separator: ".") {
            var component = String(rawComponent)
            var indices: [Int] = []

            // 末尾の [n] を切り出す。複数連続も許す。
            while component.hasSuffix("]"), let open = component.lastIndex(of: "[") {
                let inside = component[component.index(after: open)..<component.index(before: component.endIndex)]
                guard let index = Int(inside) else { return nil }
                indices.insert(index, at: 0)
                component = String(component[component.startIndex..<open])
            }

            if !component.isEmpty {
                current = current?[component]
            }
            for index in indices {
                current = current?[index]
            }
            if current == nil { return nil }
        }
        return current
    }
}
