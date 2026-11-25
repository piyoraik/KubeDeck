import SwiftUI

struct SettingsView: View {
    var body: some View {
        // 変えるものと「いまどうなっているか」を同じタブに積まない（診断で設定が埋もれる）。
        TabView {
            GeneralSettings()
                .tabItem { Label("一般", systemImage: "gearshape") }
            ViewSettings()
                .tabItem { Label("表示", systemImage: "macwindow") }
            PlacementSettings()
                .tabItem { Label("配置", systemImage: "rectangle.3.group") }
            LogSettings()
                .tabItem { Label("ログ", systemImage: "text.alignleft") }
            MetricsSettings()
                .tabItem { Label("メトリクス", systemImage: "chart.line.uptrend.xyaxis") }
            ContextSettings()
                .tabItem { Label("コンテキスト", systemImage: "flag") }
            ConnectionSettings()
                .tabItem { Label("接続", systemImage: "network") }
            DiagnosticsSettings()
                .tabItem { Label("診断", systemImage: "stethoscope") }
        }
        // 高さを決めておかないと、下の項目が畳まれて見えない。
        .frame(width: 560, height: 640)
    }
}

// MARK: - 一般

private struct GeneralSettings: View {
    @State private var preferences = Preferences.shared
    @State private var confirmsReset = false

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section {
                Picker("言語", selection: $preferences.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("""
                        macOS のシステム設定（一般 › 言語と地域 › アプリケーション）\
                        からも変えられます。訳が無い言語では日本語で出ます。
                        """)
                        .foregroundStyle(.secondary)
                    // **効いていないように見せない。** 起動時に解決された言語は
                    // 作り直せないので、切り替えても画面はそのまま。断りが無いと
                    // 設定が壊れていると読める。
                    if preferences.languageChangeNeedsRestart {
                        Label(
                            "次に KubeDeck を起動したときに変わります",
                            systemImage: "arrow.clockwise")
                            .foregroundStyle(Palette.textColor(for: .warning))
                    }
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("起動") {
                Picker("開く画面", selection: $preferences.startupScreen) {
                    ForEach(StartupScreen.allCases) { screen in
                        Text(screen.title).tag(screen)
                    }
                }
            }

            ListRefreshSection()

            UpdateSections()

            Section {
                Button("すべて既定値に戻す", role: .destructive) { confirmsReset = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "すべての設定を既定値に戻しますか？",
            isPresented: $confirmsReset
        ) {
            Button("戻す", role: .destructive) { preferences.resetAll() }
            Button("やめる", role: .cancel) {}
        } message: {
            // **残るものを正確に書く。** 以前は `contextProfiles` も消して
            // いたのに「コンテキストは残ります」と書いており、読み取り専用の
            // 指定が黙って外れていた。いまは消さないので、そう書ける。
            // **戻るものも名指しする。** 言語は見た目の既定値なので戻すが、
            // 反映は次の起動からなので、そう書かないと「戻したのに英語のまま」
            // に見える。
            Text("""
                接続先のコンテキストや Namespace の選択は残ります。\
                コンテキストごとの色・別名・読み取り専用の指定も残ります\
                （消すときは「コンテキスト」タブから）。\
                言語は「システムに従う」に戻り、次の起動から反映されます。
                """)
        }
    }
}

// MARK: - 表示

private struct ViewSettings: View {
    @State private var preferences = Preferences.shared

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section {
                Toggle("種別ごとの件数を出す", isOn: $preferences.showsSidebarCounts)
                Toggle("件数が 0 の種別を隠す", isOn: $preferences.hidesEmptyKinds)
                Toggle("カスタムリソース（CRD）を出す", isOn: $preferences.showsCustomResources)
                // **CRD は別のトグルで畳む。** 上の「件数が 0 の種別を隠す」に
                // 相乗りさせていたが、あちらは既定 off なので**既定のままでは
                // CRD が 1 つも畳まれなかった**（実測で 188 種別のうち 117 が
                // 空振りする状態がそのまま残っていた）。規模が違うので既定も
                // 分ける —— CRD はそのクラスタで使われていないものが大半。
                Toggle("使われていない CRD を隠す", isOn: $preferences.hidesUnusedCustomResources)
            } header: {
                Text("サイドバー")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    // **どちらがどちらに効くかを書く。** 書かないと、片方を
                    // 入れたのに CRD が畳まれない（あるいは組み込みまで消えた）
                    // 理由が読めない。
                    if preferences.showsCustomResources {
                        Text("""
                            「件数が 0 の種別を隠す」は組み込みの種別に効きます。\
                            CRD は「使われていない CRD を隠す」が持ちます。
                            """)
                            .foregroundStyle(.secondary)
                    }
                    // **経路で見え方が変わることを黙らない。** CRD の件数は常駐
                    // proxy 経由でしか数えない（kubectl では種別ごとに 1 プロセス
                    // 起こすことになり、実測で 188 種別に 58 秒かかる）。断りが
                    // 無いと「隠す設定が CRD にだけ効かない」「組み込みには
                    // 件数が出るのに CRD には出ない」としか見えず、**原因を探す
                    // 先がこの画面のどこにも無い。**
                    //
                    // **proxy が立てられなかった場合はここで言わない** —— それは
                    // 「接続」タブの読み取りの経路が持っている。設定で切った人と、
                    // 切ったつもりが無いのに落ちている人では、見に行く先が違う。
                    if preferences.showsCustomResources, !preferences.usesAPIProxy {
                        Label(
                            """
                            読み取りの経路が kubectl のあいだ、CRD の件数は数えません\
                            （種別ごとに 1 プロセス起こすことになるため）。CRD には\
                            件数が出ず、使われていないものも畳まれません。
                            """,
                            systemImage: "info.circle")
                            .foregroundStyle(Palette.textColor(for: .warning))
                    }
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                ForEach(ResourceCategory.allCases) { category in
                    DisclosureGroup(category.title) {
                        ForEach(ResourceKind.kinds(in: category)) { kind in
                            Toggle(isOn: Binding(
                                get: { preferences.isVisible(kind) },
                                set: { preferences.setVisible(kind, $0) })
                            ) {
                                Label(kind.displayName, systemImage: kind.symbol)
                            }
                        }
                    }
                }
            } header: {
                Text("出す種別")
            } footer: {
                HStack {
                    Text("外した種別はサイドバーに出ません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("すべて出す") { preferences.hiddenKinds = [] }
                        .controlSize(.small)
                        .disabled(preferences.hiddenKinds.isEmpty)
                }
            }

            Section {
                Picker("行の詰め方", selection: $preferences.rowDensity) {
                    ForEach(RowDensity.allCases) { density in
                        Text(density.title).tag(density)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("一覧")
            } footer: {
                Text("行の高さと文字の大きさが変わります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("置き場所", selection: $preferences.inspectorPlacement) {
                    ForEach(InspectorPlacement.allCases) { placement in
                        Text(placement.title).tag(placement)
                    }
                }
                .pickerStyle(.segmented)
                Toggle(
                    "畳んでいるとき、行を選んだら出す",
                    isOn: $preferences.opensInspectorOnSelection)
            } header: {
                Text("詳細パネル")
            } footer: {
                Text("選んだ行の詳細・設定・イベント・YAML を出す欄です。列の多い一覧を見るときは下、縦に長い一覧を見るときは右のほうが読めます。下に置いたときはログと同じ帯に横並びで入り（上下に積むとどちらも数行しか残らないため）、仕切りを掴めば高さと幅を変えられます。出す／畳むはツールバーの「詳細」で、置き場所もその ▾ から選べます。行を選んだときに出るのは畳んでいるときだけで、勝手に畳むことはありません（列を広く見たいときは切ってください）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 配置

private struct PlacementSettings: View {
    @State private var preferences = Preferences.shared

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section {
                Picker("タイルの大きさ", selection: $preferences.placementTileSize) {
                    ForEach(PlacementTileSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                Picker("ノードの並び", selection: $preferences.placementNodeOrder) {
                    ForEach(PlacementNodeOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                Picker("棒が表すもの", selection: $preferences.placementMetric) {
                    ForEach(PlacementMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("ワークロードでまとめる", isOn: $preferences.placementGroupsByWorkload)
                Toggle("Pod が 0 のノードを隠す", isOn: $preferences.placementHidesEmptyNodes)
            } header: {
                Text("配置")
            } footer: {
                Text("見方（ノード別／ワークロード別／たどる）は配置の画面で切り替えます。ここにあるのは、いちど決めたら変えない類のものだけです。棒が表すものは、CPU で詰まる環境とメモリで詰まる環境があるので選べます（Pod のタイルは 1 本しか出せないため、「CPU とメモリ」のときは詰まっているほうを出します）。ワークロードでまとめると、同じ Deployment のレプリカが 1 行にまとまります。Pod が少ないクラスタでは、まとめないほうが縦に縮みます。「小」は名前を出さず、しるしだけを並べます（名前と状態と使用量は、タイルを指すと出ます）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - ログ

private struct LogSettings: View {
    @State private var preferences = Preferences.shared

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section {
                Toggle(
                    "ログを開いているとき、Pod を選んだら切り替える",
                    isOn: $preferences.followsSelectionForLogs)
            } footer: {
                Text("ログは「ログを見る」を押したときだけ開きます。行を選んだだけでは開きません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("追いかける・末尾へ送る", isOn: $preferences.logFollowsByDefault)
                Toggle("長い行を折り返す", isOn: $preferences.logWrapsByDefault)
                Toggle("時刻を出す", isOn: $preferences.logShowsTimestamps)
                Toggle("出どころを色で分ける", isOn: $preferences.logColorsSources)
            } header: {
                Text("開いたときの既定")
            } footer: {
                Text("ログの画面では「追いかける」（kubectl logs --follow で新しい行を受け取り続ける）と「末尾へ送る」（新しい行が来たら末尾までスクロールする）を別々に切れます。遡って読むときに切るのは後者で、切っても取得は続くので行は消えません。\n\n時刻は現地時刻の列に出します（原文の UTC はツールチップとコピーに残ります）。色が付くのは出どころ（pod/コンテナ）の列だけで、行頭の帯と下地は深刻度のままです。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("遡って読む行数", selection: $preferences.logTailLines) {
                    ForEach([100, 500, 1_000, 5_000], id: \.self) { count in
                        Text("\(count) 行").tag(count)
                    }
                }
                Picker("画面に残す上限", selection: $preferences.logBufferLines) {
                    ForEach([1_000, 5_000, 20_000, 100_000], id: \.self) { count in
                        Text("\(count) 行").tag(count)
                    }
                }
            } header: {
                Text("行数")
            } footer: {
                Text("上限を超えたぶんは古いほうから捨てます。大きくすると、長く追従したときに使うメモリが増えます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - メトリクス

private struct MetricsSettings: View {
    @Environment(ClusterStore.self) private var store
    @State private var preferences = Preferences.shared

    @State private var isSearching = false
    @State private var manualNamespace = ""
    @State private var manualService = ""
    @State private var manualPort = "9090"
    @State private var manualResult: String?
    @State private var isChecking = false

    var body: some View {
        @Bindable var store = store
        @Bindable var preferences = preferences

        Form {
            Section {
                Picker("取得元", selection: $store.metricsPreference) {
                    ForEach(MetricsSourcePreference.allCases) { preference in
                        Text(preference.title).tag(preference)
                    }
                }
                .pickerStyle(.segmented)

                Text(store.metricsPreference.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // 選んだ先が使えないときに黙って別の値を出さない。
                if let problem = store.metricsSourceProblem {
                    Label(problem, systemImage: StatusLevel.warning.symbol)
                        .font(.caption)
                        .foregroundStyle(Palette.textColor(for: .warning))
                        .fixedSize(horizontal: false, vertical: true)
                }

                LabeledContent("いま使っている先") {
                    Text(store.activeMetricsSource.isAvailable
                        ? store.activeMetricsSource.label : String(localized: "なし"))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("現在値の取得元")
            }

            Section {
                Picker("範囲", selection: $preferences.historyWindowMinutes) {
                    // 書式は 1 か所（`Preferences.windowLabel`）。概要のカードと
                    // 詳細パネルの見出しも同じものを読む。
                    ForEach([15, 30, 60, 180], id: \.self) { minutes in
                        Text(Preferences.windowLabel(minutes: minutes)).tag(minutes)
                    }
                }
                Picker("取り直す間隔", selection: $preferences.historyRefreshSeconds) {
                    ForEach([30, 60, 180, 300], id: \.self) { seconds in
                        Text(seconds < 60 ? "\(seconds) 秒" : "\(seconds / 60) 分").tag(seconds)
                    }
                }
            } header: {
                Text("推移（Prometheus）")
            } footer: {
                Text("範囲クエリは 1 回につき kubectl を 1 本起こすので、一覧の更新とは別の間隔にしてあります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("注意", selection: $preferences.usageWarningPercent) {
                    ForEach([60, 70, 80, 90], id: \.self) { Text("\($0)%").tag($0) }
                }
                Picker("異常", selection: $preferences.usageCriticalPercent) {
                    ForEach([80, 90, 95, 99], id: \.self) { Text("\($0)%").tag($0) }
                }
            } header: {
                Text("使用率のしきい値")
            } footer: {
                Text("ノードの CPU / メモリ列と、使用量の棒の色が変わる境目です。「異常」は「注意」より下にできません（下にできると、注意の色が一度も出ないまま異常に飛ぶため）。片方を動かすと、必要なときだけもう片方も動きます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("metrics-server") {
                    availability(store.metricsServerAvailable)
                }
                LabeledContent("Prometheus") {
                    if let endpoint = store.prometheus {
                        Text(endpoint.display).foregroundStyle(.secondary)
                    } else {
                        availability(false)
                    }
                }
                Button {
                    isSearching = true
                    Task {
                        await store.rediscoverMetricsSources()
                        isSearching = false
                    }
                } label: {
                    if isSearching {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("探しています…")
                        }
                    } else {
                        Text("もう一度探す")
                    }
                }
                .disabled(isSearching || store.currentContext.isEmpty)
            } header: {
                Text("このクラスタで使えるもの")
            }

            Section {
                TextField("Namespace", text: $manualNamespace)
                TextField("Service", text: $manualService)
                TextField("ポート", text: $manualPort)
                HStack {
                    Button("確認して使う") { checkManualEndpoint() }
                        .disabled(isChecking || manualNamespace.isEmpty || manualService.isEmpty)
                    if isChecking { ProgressView().controlSize(.small) }
                    if let manualResult {
                        Text(manualResult).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Prometheus を手で指定する")
            } footer: {
                Text("自動で見つからないときに使います。API サーバのプロキシ経由で繋ぐので、ポートは Service のポート番号です（port-forward は不要）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard let endpoint = store.prometheus, manualNamespace.isEmpty else { return }
            manualNamespace = endpoint.namespace
            manualService = endpoint.service
            manualPort = "\(endpoint.port)"
        }
    }

    private func checkManualEndpoint() {
        guard let port = Int(manualPort) else {
            manualResult = String(localized: "ポート番号が数値ではありません。")
            return
        }
        let endpoint = PrometheusEndpoint(
            namespace: manualNamespace.trimmingCharacters(in: .whitespaces),
            service: manualService.trimmingCharacters(in: .whitespaces),
            port: port)

        isChecking = true
        manualResult = nil
        Task {
            let ok = await store.useManualPrometheus(endpoint)
            isChecking = false
            // 応答しない場所を「設定した」と言わない。
            manualResult = ok
                ? String(localized: "つながりました。")
                : String(localized: "応答がありません。")
        }
    }

    @ViewBuilder
    private func availability(_ available: Bool?) -> some View {
        switch available {
        case true:
            Label("使える", systemImage: StatusLevel.good.symbol)
                .foregroundStyle(Palette.textColor(for: .good))
        case false:
            Label("見つからない", systemImage: StatusLevel.neutral.symbol)
                .foregroundStyle(.secondary)
        case nil:
            Text("確認中").foregroundStyle(.secondary)
        }
    }
}

// MARK: - 接続

/// コンテキストごとの札。
///
/// **どのクラスタを触っているのかを、名前の文字列だけに頼らせない。** 削除も
/// drain も書き戻しもできる道具になったので、prod と dev の見分けが
/// ツールバーの小さな文字だけ、という状態は事故の入口そのもの。
private struct ContextSettings: View {
    @Environment(ClusterStore.self) private var store
    @State private var preferences = Preferences.shared
    @State private var confirmsClear = false

    var body: some View {
        Form {
            Section {
                Text("""
                    色を付けたコンテキストは、窓の上に帯が出ます。\
                    読み取り専用にすると、変更する操作をいっさい出しません\
                    （見るだけのクラスタを取り違えても壊せません）。
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.contexts.isEmpty {
                // **「ありません」と言わない。** まだ引けていないだけかもしれない。
                Section {
                    Text("コンテキストの一覧を読み込めていません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(store.contexts, id: \.self) { context in
                Section {
                    row(for: context)
                } header: {
                    HStack(spacing: 6) {
                        Text(context)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if context == store.currentContext {
                            Text("接続中")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // **消す口はここにしか置かない。** 「すべて既定値に戻す」に
            // 混ぜていたので、一般タブのボタンで読み取り専用が黙って外れていた。
            Section {
                Button("コンテキストの札をすべて消す", role: .destructive) {
                    confirmsClear = true
                }
                .disabled(preferences.contextProfiles.isEmpty)
            } footer: {
                Text("色・別名・読み取り専用の指定をまとめて消します。他の設定は「一般」タブの「すべて既定値に戻す」で戻せますが、そちらではこの札は消えません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "コンテキストの札をすべて消しますか？",
            isPresented: $confirmsClear
        ) {
            Button("消す", role: .destructive) { preferences.clearContextProfiles() }
            Button("やめる", role: .cancel) {}
        } message: {
            // **何が外れるのかを名指しする。** 読み取り専用はこのアプリで
            // 唯一「壊せなくする」仕組みなので、消える前に言う。
            Text("読み取り専用の指定も外れます。以後、それらのクラスタでも削除や drain が押せるようになります。")
        }
    }

    private func row(for context: String) -> some View {
        let profile = preferences.profile(for: context)
        return Group {
            Picker("色", selection: binding(context, \.tint)) {
                ForEach(ContextTint.allCases) { tint in
                    if let color = Palette.color(for: tint) {
                        Label {
                            Text(tint.title)
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(color)
                        }
                        .tag(tint)
                    } else {
                        Text(tint.title).tag(tint)
                    }
                }
            }
            TextField(
                "別名", text: binding(context, \.alias),
                prompt: Text("空ならコンテキスト名"))
            Toggle("読み取り専用", isOn: binding(context, \.isReadOnly))
            if profile.isReadOnly {
                Text("この設定はこのアプリの中だけの話です。クラスタ側の権限は変わりません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// **値型の入れ子を直接触らない。** 中身だけ書き換えても辞書の `didSet` は
    /// 走らず、保存し損ねる。読むのは写し、書くのは `setProfile` を通す。
    private func binding<Value>(
        _ context: String, _ keyPath: WritableKeyPath<ContextProfile, Value>
    ) -> Binding<Value> {
        Binding(
            get: { preferences.profile(for: context)[keyPath: keyPath] },
            set: { newValue in
                var profile = preferences.profile(for: context)
                profile[keyPath: keyPath] = newValue
                preferences.setProfile(profile, for: context)
            })
    }
}

private struct ConnectionSettings: View {
    @Environment(ClusterStore.self) private var store
    @State private var preferences = Preferences.shared
    @State private var resolvedPath: String?
    @State private var transport: Kubectl.ReadTransport?
    @State private var proxyDiagnostics: ClusterProxy.Diagnostics?

    /// いま何経由で読んでいるか。**「立てられなかった」を黙らせない。**
    private var transportLabel: String {
        switch transport {
        case .apiProxy:
            return String(localized: "kubectl proxy 経由（HTTP）")
        case .kubectl(let reason):
            guard let reason, !reason.isEmpty else {
                // **「切ってある」と「まだ立てていない」を混ぜない。**
                return preferences.usesAPIProxy
                    ? String(localized: "kubectl を毎回起こす（まだ立てていません）")
                    : String(localized: "kubectl を毎回起こす（設定で切ってあります）")
            }
            return String(localized: """
                kubectl を毎回起こす（常駐を立てられませんでした）
                \(reason)
                """)
        case nil:
            return String(localized: "確認中")
        }
    }

    private var transportIsProxy: Bool { transport == .apiProxy }

    private func refreshTransport() async {
        transport = await Kubectl.shared.readTransport(for: store.currentContext)
        proxyDiagnostics = await Kubectl.shared.proxyDiagnostics(for: store.currentContext)
    }

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section {
                Toggle("kubectl proxy を常駐させて HTTP で読む", isOn: $preferences.usesAPIProxy)
                LabeledContent("いまの読み取り") {
                    // **「使えないから黙って別の先」をしない。**
                    Text(transportLabel)
                        .foregroundStyle(transportIsProxy ? .secondary : Color(Palette.color(for: .warning)))
                        .multilineTextAlignment(.trailing)
                }
                if let proxy = proxyDiagnostics {
                    LabeledContent("待ち受け") {
                        // **prefix は出さない。** あれは資格情報と同じ扱い。
                        Text(proxy.address)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    LabeledContent("プロセス") {
                        // **pid を数値として補間しない。** SwiftUI は桁区切りを
                        // 付けるので `pid 14,403` になる（そのまま `kill` に
                        // 貼れない値を出す）。文字列にしてから渡す。
                        Text("pid \(String(proxy.pid)) · \(proxy.startedAt.formatted(date: .omitted, time: .standard)) から")
                            .foregroundStyle(.secondary)
                    }
                    if !proxy.recentOutput.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(proxy.recentOutput.suffix(6).enumerated()), id: \.offset) {
                                Text($0.element)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                Button("立て直す") {
                    Task {
                        // **畳むだけにしない。** 畳んだ直後に状態を読むと
                        // 「kubectl を毎回起こす」に見えるが、実際は次の取得で
                        // 立ち上がる。押した結果として立て直った姿を出したいので、
                        // ここで 1 回引いてから読み直す。
                        await Kubectl.shared.releaseTransports(keeping: "")
                        _ = try? await Kubectl.shared.serverVersion(
                            context: store.currentContext)
                        await refreshTransport()
                    }
                }
                .disabled(!preferences.usesAPIProxy || store.currentContext.isEmpty)
            } header: {
                Text("読み取りの経路")
            } footer: {
                Text("認証の委ね先は変わりません。入れても切っても、資格情報を扱うのは kubectl（の中の client-go）のままで、exec 認証プラグインもトークンの更新もそちらが行います。変わるのは「取得のたびに 1 プロセス起こす」か「1 本を常駐させて HTTP で読む」かだけです。書き込み・drain・rollout・exec・ログは、どちらでも kubectl を起こします。常駐は 127.0.0.1 だけで待ち受け、URL の秘密の前置きを知らない相手には 404 を返します。立てられなかったときは kubectl 経由に落ちますが、その理由をここに出します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("待ち上限", selection: $preferences.requestTimeoutSeconds) {
                    ForEach([5, 10, 20, 60], id: \.self) { Text("\($0) 秒").tag($0) }
                }
            } header: {
                Text("kubectl の待ち時間")
            } footer: {
                Text("到達できないクラスタを選んだときに、この時間で諦めます。遅い回線越しのクラスタでは長めにしてください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("空なら自動で探す", text: $preferences.kubectlPathOverride)
                LabeledContent("いま使っている kubectl") {
                    Text(resolvedPath ?? "確認中")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
            } header: {
                Text("kubectl の場所")
            } footer: {
                Text("Homebrew・krew・gcloud SDK の場所は自動で探します。指定した場所が実行できないときは、自動探索に戻ります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: preferences.kubectlPathOverride) {
            resolvedPath = await Kubectl.shared.resolvedExecutablePath()
            ?? String(localized: "見つかりません")
            await refreshTransport()
        }
        .task(id: preferences.usesAPIProxy) { await refreshTransport() }
    }
}

/// 一覧の自動更新。取得の振る舞いなので「一般」に置く（「アップデート」と取り違えさせない）。
private struct ListRefreshSection: View {
    @Environment(ClusterStore.self) private var store

    var body: some View {
        @Bindable var store = store

        Section {
            Toggle("自動更新", isOn: $store.autoRefresh)
            Picker("間隔", selection: $store.refreshInterval) {
                ForEach([5.0, 10.0, 30.0, 60.0], id: \.self) { seconds in
                    Text("\(Int(seconds)) 秒").tag(seconds)
                }
            }
            .disabled(!store.autoRefresh)
        } header: {
            Text("一覧の更新")
        } footer: {
            // 切っていても画面が止まりきらない理由を書く。書かないと、操作のあとの取り直しが自動更新に見える。
            Text("""
                切っていても、削除したものが消えるまでと、再起動などの入れ替わりが\
                終わるまでは取り直します（最長 \(Int(FollowUp.limit / 60)) 分）。
                """)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 診断

private struct DiagnosticsSettings: View {
    @State private var resolvedPath: String?
    @State private var searchPath: String?
    @State private var variables: [String: String] = [:]
    @State private var cacheDirectory: String?
    @State private var lastDiscoveryReset: Date?

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("下の内容を貼って共有できます。鍵やトークンに見える値は伏せてあります。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("まとめてコピー") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                    }
                    .disabled(searchPath == nil)
                }
            }

            Section {
                Text(cacheDirectory ?? String(localized: "確認中"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.head)
                LabeledContent("最後に捨てた時刻") {
                    // **「まだ捨てていない」と「捨てた」を混ぜない。**
                    Text(lastDiscoveryReset.map {
                        $0.formatted(date: .omitted, time: .standard)
                    } ?? String(localized: "まだありません"))
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("API の一覧（discovery）の置き場所")
            } footer: {
                Text("kubectl が覚えている API の一覧です。ターミナルの kubectl（~/.kube/cache）とは別に持っているので、片方が壊れてももう片方は巻き込みません。実在する種別に「the server doesn't have a resource type」と言われたときは、ここを捨てて 1 度だけ引き直します（1 分に 1 回まで）。これが何度も起きるときは、API サーバやゲートウェイが欠けた一覧を返しています。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text(searchPath ?? String(localized: "確認中"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(6)
            } header: {
                Text("子プロセスに渡している PATH")
            } footer: {
                Text("kubeconfig の exec 認証プラグイン（GKE の gke-gcloud-auth-plugin、EKS の aws）は、ここから探されます。ログインシェルの PATH を写しているので、シェルの設定ファイルで足した場所も入ります。プラグインが見つからないと言われたら、その置き場所がここにあるか確かめてください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if variables.isEmpty {
                    Text("確認中").foregroundStyle(.secondary)
                } else {
                    // **入れ子のスクロールにしない。** Form の中に ScrollView を
                    // 置くと高さが潰れて 1 行も見えないことがある。Form 自体が
                    // スクロールするので、素直に並べれば足りる。
                    ForEach(variables.keys.sorted(), id: \.self) { name in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(name)
                            Spacer(minLength: 12)
                            Text(variables[name] ?? "")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    }
                }
            } header: {
                Text("子プロセスに渡している環境")
            } footer: {
                Text("ログインシェルの環境をそのまま渡しています。「ターミナルでは通るのに動かない」ときは、まずここに必要な変数が届いているかを見てください。TLS を覗くプロキシの下なら REQUESTS_CA_BUNDLE や SSL_CERT_FILE、gcloud なら CLOUDSDK_ で始まるものです。鍵やトークンに見える値は伏せています（場所を指す値は残します）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: Preferences.shared.kubectlPathOverride) {
            resolvedPath = await Kubectl.shared.resolvedExecutablePath()
            searchPath = await Kubectl.shared.resolvedSearchPath()
            ?? String(localized: "確認できません")
            variables = await Kubectl.shared.resolvedVariables()
            let cache = await Kubectl.shared.resolvedCacheDirectory()
            cacheDirectory = cache.path
            lastDiscoveryReset = cache.lastReset
        }
    }

    /// 貼る先は issue やチャットなので、見出しは訳さず `env` の形に揃える。値は画面と同じく伏せ字済み。
    private var report: String {
        var lines = [
            "# KubeDeck \(UpdateController.shared.currentVersion)",
            "# kubectl: \(resolvedPath ?? "-")",
            "# discovery cache: \(cacheDirectory ?? "-")",
            "PATH=\(searchPath ?? "")",
        ]
        lines += variables.keys.sorted().map { "\($0)=\(variables[$0] ?? "")" }
        return lines.joined(separator: "\n")
    }
}

// MARK: - アップデート

/// 「一般」の中に並べる。タブ名に「更新」を使うと、一覧の自動更新と取り違える。
private struct UpdateSections: View {
    @State private var preferences = Preferences.shared
    @State private var updater = UpdateController.shared

    var body: some View {
        @Bindable var preferences = preferences

        Group {
            Section {
                LabeledContent("いまの版") {
                    Text(updater.currentVersion)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("最後の確認") {
                    // 「まだ確認していない」「最新だった」「更新がある」
                    // 「確認できなかった」を混ぜない。
                    switch updater.lastOutcome {
                    case .never:
                        Text("まだ確認していません").foregroundStyle(.secondary)
                    case .upToDate:
                        Label("最新です", systemImage: StatusLevel.good.symbol)
                            .foregroundStyle(Palette.textColor(for: .good))
                    case .updateAvailable(_, let version):
                        Label("\(version) が出ています", systemImage: "arrow.down.circle")
                            .foregroundStyle(Palette.textColor(for: .warning))
                    case .failed(_, let reason):
                        Label(reason, systemImage: StatusLevel.warning.symbol)
                            .foregroundStyle(Palette.textColor(for: .warning))
                            .lineLimit(2)
                    }
                }
                if let date = updater.lastOutcome.date {
                    LabeledContent("確認した時刻") {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                }
                Button("いまアップデートを確認") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            } header: {
                Text("アップデート")
            }

            Section {
                Toggle("新しい版が出ていないか自動で確認する", isOn: $preferences.checksForUpdates)
                Picker("確認する間隔", selection: $preferences.updateCheckIntervalHours) {
                    Text("1 日").tag(24)
                    Text("1 週間").tag(168)
                }
                .disabled(!preferences.checksForUpdates)
                Toggle("見つけたら先にダウンロードしておく",
                       isOn: $preferences.downloadsUpdatesAutomatically)
                    .disabled(!preferences.checksForUpdates)
            } footer: {
                Text("確認では GitHub の Releases に置いた更新情報を読むだけで、クラスタの情報や利用状況は送りません。入れ替えるかどうかは必ず尋ねます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Link("リリース一覧を開く", destination: UpdateController.releasesURL)
            } footer: {
                Text("配布は ad-hoc 署名で、Apple の公証は通していません。手で入れ替えるときは、初回だけ隔離属性を外す必要があります（README に手順があります）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
