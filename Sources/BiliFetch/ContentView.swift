import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: DownloadViewModel
    @ObservedObject var updater: MacAppUpdater
    @State private var showAdvanced = false
    @State private var showBilibiliLogin = false
    @State private var showUpdate = false
    @State private var checkedUpdatesOnLaunch = false
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true
    @AppStorage("updateManifestURL") private var updateManifestURL = ""

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.055, green: 0.065, blue: 0.11), Color(red: 0.13, green: 0.07, blue: 0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    header
                    linkCard
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 12)
                .background(.black.opacity(0.12))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(.white.opacity(0.08))
                        .frame(height: 1)
                }
                .zIndex(1)

                ScrollView {
                    VStack(spacing: 12) {
                        if model.isAnalyzing || model.hasCurrentCollectionPreview {
                            collectionPreviewCard
                        }
                        legalNote
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 12)
                    .padding(.bottom, 14)
                }
            }
        }
        .preferredColorScheme(.dark)
        .popover(isPresented: $showAdvanced, arrowEdge: .top) {
            advancedSettingsPanel
        }
        .sheet(isPresented: $showBilibiliLogin) {
            BilibiliLoginSheet(model: model)
        }
        .sheet(isPresented: $showUpdate) {
            updateSheet
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshBackend()
            model.refreshBilibiliLoginStatus()
        }
        .onChange(of: updater.phase) { phase in
            if phase == .available { showUpdate = true }
        }
        .onAppear {
            if updateManifestURL.isEmpty { updateManifestURL = updater.bundledManifestURL }
            guard !checkedUpdatesOnLaunch else { return }
            checkedUpdatesOnLaunch = true
            if autoCheckUpdates, !updateManifestURL.isEmpty {
                updater.check(manifestURL: updateManifestURL, silent: true)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 54, height: 54)
                .shadow(color: .purple.opacity(0.32), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text("BiliFetch")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text("粘贴后先解析分集，再勾选下载")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                backendBadge
                HStack(spacing: 7) {
                    Button(action: checkForUpdates) {
                        Label(
                            updater.phase == .available ? "发现更新" : "检查更新",
                            systemImage: updater.phase == .available ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath"
                        )
                        .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        showAdvanced.toggle()
                    } label: {
                        Label("高级设置", systemImage: "slider.horizontal.3")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var backendBadge: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(model.backend.hasFullQualitySupport ? Color.green : (model.backend.canDownload ? Color.orange : Color.red))
                .frame(width: 8, height: 8)
            Text(model.backend.hasFullQualitySupport ? "组件就绪" : "需要准备")
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(.white.opacity(0.07), in: Capsule())
        .help(model.backendSummary)
    }

    private var linkCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Label("视频或合集链接", systemImage: "link")
                        .font(.headline)
                    Spacer()
                    Label(
                        model.resolvedScopeSummary,
                        systemImage: URLClassifier.validatedURL(from: model.link) == nil
                            ? "info.circle"
                            : "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        URLClassifier.validatedURL(from: model.link) == nil
                            ? Color.secondary
                            : Color.green
                    )
                    .lineLimit(1)
                }

                HStack(spacing: 10) {
                    TextField("https://www.bilibili.com/video/BV...", text: $model.link)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .padding(.horizontal, 13)
                        .frame(height: 44)
                        .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .disabled(model.isBusy)
                        .onSubmit {
                            if model.canAnalyzeCollection && !model.hasCurrentCollectionPreview {
                                model.analyzeCollection()
                            } else if model.canStart {
                                model.start()
                            }
                        }
                        .onChange(of: model.link) { _ in model.linkDidChange() }
                        .onChange(of: model.scope) { _ in model.scopeDidChange() }

                    Button(action: model.pasteLink) {
                        Label("粘贴", systemImage: "doc.on.clipboard")
                            .frame(height: 42)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)
                }

                HStack(spacing: 10) {
                    destinationButton
                    compactActionButton
                }

                if model.state != .idle {
                    statusLine
                }
            }
        }
    }

    private var collectionPreviewCard: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(
                            model.collectionTitle.isEmpty ? "正在获取合集" : model.collectionTitle,
                            systemImage: model.collectionItems.count == 1 ? "play.rectangle.fill" : "rectangle.stack.fill"
                        )
                        .font(.headline)
                        if !model.collectionItems.isEmpty {
                            Text("共 \(model.collectionItems.count) 项 · 已选 \(model.selectedItemCount) 项")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !model.collectionItems.isEmpty && !model.isBusy {
                        Button(model.selectedItemCount == model.collectionItems.count ? "取消全选" : "全选") {
                            model.selectAllCollectionItems(model.selectedItemCount != model.collectionItems.count)
                        }
                        .buttonStyle(.bordered)
                        Button("重新获取", action: model.analyzeCollection)
                            .buttonStyle(.bordered)
                    }
                }

                if model.isAnalyzing {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(model.statusText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                } else {
                    Label(
                        "解析完成。默认已全选，请取消不需要的分集，再点击下载。",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 175, maximum: 240), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(model.collectionItems) { item in
                            CollectionItemCard(
                                item: item,
                                isDisabled: model.isBusy,
                                onSelectionChange: { selected in
                                    model.setCollectionItemSelected(item.id, selected: selected)
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    private var advancedSettingsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("高级设置", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Button("完成") { showAdvanced = false }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            Divider()

            optionRow(title: "下载范围", subtitle: "合集会先显示标题、缩略图和复选框") {
                Picker("", selection: $model.scope) {
                    ForEach(DownloadScope.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 160)
            }

            optionRow(
                title: "画质",
                subtitle: model.isBilibiliLoggedIn ? "使用账号可用画质" : "使用游客可用画质"
            ) {
                Picker("", selection: $model.quality) {
                    ForEach(VideoQuality.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 190)
            }

            optionRow(
                title: "下载引擎",
                subtitle: model.backend.hasAccelerationSupport ? "aria2 多连接加速" : "当前仅可使用标准模式"
            ) {
                Picker("", selection: $model.engine) {
                    ForEach(DownloadEngine.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 190)
            }

            optionRow(
                title: "同时下载",
                subtitle: "并行下载不同分集，最多 5 个"
            ) {
                Picker("", selection: $model.downloadConcurrency) {
                    ForEach(1...5, id: \.self) { count in
                        Text("\(count) 个视频").tag(count)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .disabled(model.isBusy)
            }

            optionRow(title: "B站账号", subtitle: model.bilibiliLoginStatus) {
                Button(action: openBilibiliLogin) {
                    Label(
                        model.isBilibiliLoggedIn ? "管理登录" : "扫码登录",
                        systemImage: model.isBilibiliLoggedIn
                            ? "person.crop.circle.badge.checkmark"
                            : "qrcode"
                    )
                }
                .buttonStyle(.bordered)
                .tint(model.isBilibiliLoggedIn ? .green : .pink)
            }

            optionRow(title: "浏览器 Cookie", subtitle: "仅作为登录备用方式") {
                Picker("", selection: $model.cookies) {
                    ForEach(BrowserCookies.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 190)
            }

            Toggle(isOn: $model.includeSubtitles) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("同时下载字幕/弹幕")
                    Text("仅在页面提供时生效")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Toggle(isOn: $autoCheckUpdates) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动检查软件更新")
                    Text("当前版本 v\(updater.currentVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            optionRow(title: "更新清单", subtitle: "固定 HTTPS 地址，供 macOS/Windows 共用") {
                TextField("https://…/update.json", text: $updateManifestURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 275)
            }

            HStack {
                Spacer()
                Button("立即检查", action: checkForUpdates)
                    .buttonStyle(.bordered)
                    .disabled(updateManifestURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 520)
    }

    private func checkForUpdates() {
        if updateManifestURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showAdvanced = true
            return
        }
        showAdvanced = false
        showUpdate = true
        updater.check(manifestURL: updateManifestURL)
    }

    private var updateSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("BiliFetch 软件更新", systemImage: "arrow.down.app.fill")
                    .font(.title3.bold())
                Spacer()
                Button("关闭") {
                    showUpdate = false
                    updater.dismiss()
                }
                .buttonStyle(.bordered)
                .disabled(updater.phase == .downloading)
            }

            if let release = updater.release {
                Text("v\(updater.currentVersion) → v\(release.version)")
                    .font(.headline)
                ScrollView {
                    Text(release.notes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 180)
                .padding(12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }

            if updater.phase == .downloading {
                ProgressView(value: updater.progress)
            } else if updater.phase == .checking {
                ProgressView()
                    .controlSize(.small)
            }

            Text(updater.statusText.isEmpty ? "正在准备更新信息…" : updater.statusText)
                .font(.callout)
                .foregroundStyle(updater.phase == .failed ? Color.orange : Color.secondary)

            HStack {
                Spacer()
                if updater.phase == .available {
                    Button("下载更新", action: updater.download)
                        .buttonStyle(.borderedProminent)
                        .tint(.pink)
                } else if updater.phase == .ready {
                    Button("退出并升级", action: updater.install)
                        .buttonStyle(.borderedProminent)
                        .tint(.pink)
                        .disabled(model.isBusy)
                        .help(model.isBusy ? "请先结束当前下载任务" : "退出、替换应用并自动重新打开")
                } else if updater.phase == .failed || updater.phase == .current {
                    Button("重新检查") {
                        updater.check(manifestURL: updateManifestURL)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(22)
        .frame(width: 500, height: 330)
    }

    private func openBilibiliLogin() {
        showAdvanced = false
        DispatchQueue.main.async {
            showBilibiliLogin = true
        }
    }

    @ViewBuilder
    private func optionRow<Control: View>(title: String, subtitle: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            control()
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            Text(model.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var statusIcon: String {
        if model.isPaused { return "pause.circle.fill" }
        switch model.state {
        case .success: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle.fill"
        case .analyzing: return "sparkles"
        case .downloading: return "arrow.down.circle.fill"
        case .idle: return "info.circle"
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .success: return .green
        case .failed: return .orange
        case .cancelled: return .secondary
        default: return .cyan
        }
    }

    private var destinationButton: some View {
        Button(action: model.chooseDestination) {
            HStack(spacing: 9) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.blue)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text("保存位置")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(model.destination.path)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 5)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(.white.opacity(0.07), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
        .help("更改保存位置")
    }

    @ViewBuilder
    private var compactActionButton: some View {
        if !model.backend.canDownload {
            Button(action: model.prepareTools) {
                compactActionLabel("准备组件", systemImage: "wrench.and.screwdriver.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
        } else if model.backend.ffmpeg == nil || model.backend.ffprobe == nil {
            Button(action: model.prepareTools) {
                compactActionLabel("补全媒体组件", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
        } else if model.isDownloading {
            HStack(spacing: 8) {
                Button(action: model.togglePause) {
                    compactActionLabel(
                        model.isPaused ? "继续" : "暂停",
                        systemImage: model.isPaused ? "play.circle.fill" : "pause.circle.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isPaused ? .green : .orange)

                Button(action: model.cancel) {
                    Label("取消", systemImage: "xmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .frame(minHeight: 40)
                }
                .buttonStyle(.bordered)
            }
        } else if model.isAnalyzing {
            Button(action: model.cancel) {
                compactActionLabel("取消解析", systemImage: "xmark.circle.fill")
            }
            .buttonStyle(.bordered)
        } else if model.requiresReanalysisAfterPermanentFailure {
            Button(action: model.analyzeCollection) {
                compactActionLabel("重新解析链接", systemImage: "arrow.clockwise.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        } else if model.canAnalyzeCollection && !model.hasCurrentCollectionPreview {
            Button(action: model.analyzeCollection) {
                compactActionLabel("解析链接", systemImage: "sparkle.magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(!model.canAnalyzeCollection)
        } else if model.state == .success {
            Button(action: model.revealDownload) {
                compactActionLabel("在 Finder 中显示", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .tint(.pink)
        } else {
            Button(action: model.start) {
                compactActionLabel(primaryActionTitle, systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.pink)
            .disabled(!model.canStart)
        }
    }

    private var primaryActionTitle: String {
        guard model.wantsCollection else { return "开始下载" }
        if model.completedItemCount > 0 {
            return "下载剩余 \(model.remainingSelectedItemCount) 项"
        }
        return "下载 \(model.remainingSelectedItemCount) 项"
    }

    private func compactActionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .frame(minWidth: 150, minHeight: 40)
    }

    private var legalNote: some View {
        Text("请仅下载你有权保存的内容。本工具不绕过付费、DRM 或平台访问控制。")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.09), lineWidth: 1)
            }
    }
}

private struct CollectionItemCard: View {
    let item: CollectionItem
    let isDisabled: Bool
    let onSelectionChange: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinPhase = false
    @State private var pulsePhase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            thumbnail
                .frame(maxWidth: .infinity)
                .frame(height: 104)
                .clipped()
                .background(.black.opacity(0.28))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(alignment: .top, spacing: 8) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { item.isSelected },
                        set: onSelectionChange
                    )
                )
                .labelsHidden()
                .toggleStyle(.checkbox)
                .tint(.green)
                .disabled(isDisabled)
                .help(item.isSelected ? "取消选择此视频" : "选择此视频")

                Text("\(item.index). \(item.title)")
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 6) {
                if let duration = item.durationText {
                    Text(duration)
                }
                Spacer()
                statusLabel
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if item.status != .pending {
                VStack(spacing: 5) {
                    HStack(spacing: 8) {
                        Text(item.progress, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .foregroundStyle(item.status == .failed ? Color.orange : Color.primary)
                        if !item.speedText.isEmpty {
                            Text(item.speedText)
                                .foregroundStyle(.cyan)
                                .lineLimit(1)
                        } else if isActivelyDownloading {
                            Text(item.progress > 0 ? "正在接收数据…" : "正在连接媒体服务器…")
                                .foregroundStyle(.cyan)
                                .lineLimit(1)
                                .opacity(reduceMotion ? 0.85 : (pulsePhase ? 1 : 0.48))
                                .animation(
                                    reduceMotion
                                        ? nil
                                        : .easeInOut(duration: 0.75).repeatForever(autoreverses: true),
                                    value: pulsePhase
                                )
                        }
                        if item.attempt > 1 && item.status != .completed {
                            Spacer()
                            Text("重试 \(min(item.attempt - 1, 3))/3")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption2.weight(.medium))

                    animatedProgressBar
                }
            }
        }
        .padding(9)
        .background(
            item.isSelected ? Color.purple.opacity(0.16) : Color.black.opacity(0.16),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(cardBorderColor, lineWidth: isActivelyDownloading ? 1.5 : 1)
        }
        .shadow(
            color: isActivelyDownloading ? Color.cyan.opacity(pulsePhase ? 0.24 : 0.06) : .clear,
            radius: isActivelyDownloading ? 9 : 0
        )
        .opacity(item.isSelected ? 1 : 0.62)
        .onAppear { updateActivityAnimation(isActive: isActivelyDownloading) }
        .onChange(of: item.status) { status in
            updateActivityAnimation(isActive: status == .downloading)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = item.thumbnailURL {
            BilibiliThumbnailView(url: url, placeholder: AnyView(placeholder))
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [.purple.opacity(0.55), .blue.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "play.rectangle.fill")
                .font(.title)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch item.status {
        case .pending:
            EmptyView()
        case .downloading:
            HStack(spacing: 5) {
                Image(systemName: item.attempt > 1 ? "arrow.clockwise.circle.fill" : "arrow.down.circle")
                    .rotationEffect(.degrees(reduceMotion ? 0 : (spinPhase ? 360 : 0)))
                    .animation(
                        reduceMotion
                            ? nil
                            : .linear(duration: 1.05).repeatForever(autoreverses: false),
                        value: spinPhase
                    )
                Text(item.attempt > 1 ? "重试下载中" : "下载中")
            }
            .foregroundStyle(item.attempt > 1 ? .orange : .cyan)
        case .paused:
            Label("已暂停", systemImage: "pause.circle.fill")
                .foregroundStyle(.orange)
        case .retrying:
            Label("正在重试", systemImage: "arrow.clockwise.circle.fill")
                .foregroundStyle(.orange)
        case .completed:
            Label("已完成", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Label("失败", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var animatedProgressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.10))

                Capsule()
                    .fill(progressTint)
                    .frame(width: max(0, geometry.size.width * min(max(item.progress, 0), 1)))

                if isActivelyDownloading && !reduceMotion {
                    let sweepWidth = max(34, geometry.size.width * 0.28)
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.16), .cyan.opacity(0.95), .white.opacity(0.16), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: sweepWidth)
                    .offset(x: spinPhase ? geometry.size.width : -sweepWidth)
                    .animation(
                        .linear(duration: 1.35).repeatForever(autoreverses: false),
                        value: spinPhase
                    )
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
    }

    private var isActivelyDownloading: Bool {
        item.status == .downloading
    }

    private var cardBorderColor: Color {
        if isActivelyDownloading {
            return .cyan.opacity(pulsePhase ? 0.90 : 0.38)
        }
        return item.isSelected ? .purple.opacity(0.65) : .white.opacity(0.07)
    }

    private func updateActivityAnimation(isActive: Bool) {
        guard !reduceMotion else {
            spinPhase = false
            pulsePhase = false
            return
        }
        spinPhase = false
        pulsePhase = false
        guard isActive else { return }
        DispatchQueue.main.async {
            spinPhase = true
            pulsePhase = true
        }
    }

    private var progressTint: Color {
        switch item.status {
        case .failed: return .orange
        case .paused, .retrying: return .yellow
        case .completed: return .green
        default: return .pink
        }
    }
}

private struct BilibiliThumbnailView: View {
    let url: URL
    let placeholder: AnyView
    @StateObject private var loader = BilibiliThumbnailLoader()

    var body: some View {
        ZStack {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
                if loader.isLoading { ProgressView().controlSize(.small) }
            }
        }
        .onAppear { loader.load(url) }
        .onChange(of: url) { loader.load($0) }
    }
}
