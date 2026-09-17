import SwiftUI
import StockBarCore

struct PanelView: View {
    @ObservedObject var store: AppStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var panelSize = CGSize(width: 480, height: 600)
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(Color.accentColor.opacity(0.12)).frame(width: 38, height: 38)
                    Image(systemName: "chart.xyaxis.line").font(.system(size: 19, weight: .semibold)).foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("StockBar").font(.system(size: 18, weight: .semibold))
                    Text("A 股 · 场内 ETF").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.selectedPage = store.selectedPage == 0 ? 1 : 0 } label: { Image(systemName: store.selectedPage == 0 ? "gearshape" : "list.bullet") }
                    .buttonStyle(.borderless).help(store.selectedPage == 0 ? "打开设置" : "返回自选").accessibilityLabel("切换设置")
                if store.refreshing { ProgressView().controlSize(.small).frame(width: 20) }
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("刷新行情（至少间隔5秒）").disabled(store.refreshing).accessibilityLabel("刷新行情")
            }.padding(20)
            Picker("页面", selection: $store.selectedPage) { Text("自选行情").tag(0); Text("设置").tag(1) }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.bottom, 16)
            if store.selectedPage == 0 { watchlist } else { settings }
            Divider()
            HStack {
                Circle().fill(store.refreshing ? Color.accentColor : (store.fetchErrors.isEmpty ? Color.green : Color.orange)).frame(width: 6, height: 6)
                Text(store.sleeping || store.paused ? "自动刷新已暂停" : store.refreshing ? "更新中" : store.lastAttempt.map { "最近请求 \(store.time($0))" } ?? "等待行情")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 14) {
                    footerButton(
                        systemImage: store.paused ? "play.fill" : "pause.fill",
                        help: store.paused ? "继续自动刷新" : "暂停自动刷新"
                    ) { store.paused.toggle() }
                    footerButton(systemImage: "cup.and.saucer.fill", help: "Buy a coffee") {
                        store.supportVisible = true
                    }
                    footerButton(systemImage: "power", help: "退出 StockBar") {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }.padding(.horizontal, 20).padding(.vertical, 13)
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .modifier(PanelMaterial(enabled: store.preferences.glassEnabled))
        .tint(Color(red: 0.18, green: 0.39, blue: 0.75))
        .overlay {
            if store.supportVisible {
                ZStack {
                    Color.black.opacity(0.25).onTapGesture { store.supportVisible = false }
                    VStack(spacing: 12) {
                        HStack {
                            Text("buy a coffe").font(.headline)
                            Spacer()
                            Button { store.supportVisible = false } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("关闭二维码")
                        }
                        if let url = Bundle.main.url(forResource: "SupportQR", withExtension: "jpg"), let image = NSImage(contentsOf: url) {
                            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                                .frame(maxHeight: panelSize.height - 150)
                                .accessibilityLabel("微信收款二维码，请使用微信扫码")
                        } else {
                            Text("二维码暂不可用").foregroundStyle(.secondary)
                        }
                        Text("微信扫一扫，感谢支持").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(18).frame(width: min(340, panelSize.width - 48))
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .shadow(radius: 12)
                }.clipShape(RoundedRectangle(cornerRadius: 22))
            }
        }
    }
    private var watchlist: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("添加 A 股 / ETF · 名称、拼音或代码", text: $store.searchText)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .onChange(of: store.searchText) { _ in store.search() }
                if store.searching { ProgressView().controlSize(.mini) }
                if !store.searchText.isEmpty { Button { store.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).accessibilityLabel("清除搜索") }
            }.padding(11).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 20)
            if !store.searchText.isEmpty {
                searchResults
            } else {
                HStack {
                    Text("我的自选  \(store.preferences.instruments.count)")
                    Spacer()
                    Text("★ 固定 · 拖动排序 · ··· 管理")
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.top, 17).padding(.bottom, 7)
                if store.preferences.instruments.isEmpty {
                    VStack(spacing: 12) { Image(systemName: "plus.circle").font(.largeTitle).foregroundStyle(.tertiary); Text("搜索并添加第一个自选").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(store.preferences.instruments) { instrument in
                            QuoteRow(store: store, instrument: instrument)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                        }.onMove { source, destination in store.move(source, to: destination) }
                    }.listStyle(.plain).scrollContentBackground(.hidden)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                if let message = store.storageError { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if !store.fetchErrors.isEmpty {
                    Text(store.fetchErrors.keys.sorted().map { "\(store.sourceName($0))：\(store.fetchErrors[$0]!)" }.joined(separator: "；"))
                        .foregroundStyle(.orange).lineLimit(2).help(store.fetchErrors.values.joined(separator: "；"))
                }
                Text(MarketClock.isLikelySession(Date()) ? "交易时段估计 · \(store.preferences.interval)秒刷新 · 时间为北京时间" : "休市时段估计 · 5分钟刷新 · 时间为北京时间")
                    .foregroundStyle(.secondary)
                Text("时段按工作日估计，未接入节假日日历；报价时间以来源为准。")
                    .foregroundStyle(.secondary)
            }.font(.system(size: 10)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 12)
        }
    }
    private var searchResults: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let message = store.searchMessage { Text(message).font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 20) }
                ForEach(store.searchResults) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) { Text(item.name).font(.system(size: 13, weight: .medium)); Text(item.id.uppercased()).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                        Spacer()
                        let added = store.preferences.instruments.contains(where: { $0.id == item.id })
                        Button(added ? "已添加" : "添加") { store.add(item) }.disabled(added || store.preferences.instruments.count >= 50).controlSize(.small)
                    }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                }
                if store.preferences.instruments.count >= 50 { Text("最多支持50个自选，请先移除部分标的。").font(.caption).foregroundStyle(.orange) }
            }.padding(20)
        }.frame(maxHeight: .infinity)
    }
    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("行情来源", subtitle: "自动选择会在来源不可用时切换")
                    Picker("首选来源", selection: $store.preferences.preferredSource) {
                        Text("自动选择").tag("auto")
                        ForEach(store.registry.descriptors) { source in Text(source.name).tag(source.id) }
                    }.onChange(of: store.preferences.preferredSource) { _ in store.preferenceChanged(sourceChanged: true) }
                    Toggle("失败时切换到其他来源", isOn: Binding(get: { store.effectiveFallback }, set: { store.preferences.allowFallback = $0; store.preferenceChanged(sourceChanged: true) }))
                        .disabled(store.preferences.preferredSource == "auto")
                    ForEach(store.registry.descriptors) { source in
                        let health = store.health[source.id]
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(health?.cooldownUntil.map { $0 > Date() } == true ? Color.orange : health?.lastError != nil ? Color.orange : health?.lastSuccess != nil ? Color.green : Color.gray.opacity(0.5)).frame(width: 6, height: 6).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.name).font(.system(size: 12, weight: .medium))
                                Text(health?.lastError ?? (health?.lastSuccess.map { "上次成功 \(store.time($0))" } ?? source.detail)).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("菜单栏显示", subtitle: "仅图标节省空间，行情文字支持固定或轮播")
                    Picker("显示样式", selection: $store.preferences.menuStyle) {
                        Text("仅图标").tag(MenuBarStyle.icon)
                        Text("行情文字").tag(MenuBarStyle.quotes)
                    }.pickerStyle(.segmented).onChange(of: store.preferences.menuStyle) { _ in store.preferenceChanged() }
                    HStack {
                        if store.preferences.menuStyle == .icon {
                            Image(systemName: "chart.xyaxis.line").font(.system(size: 17))
                        } else {
                            Text(store.menuTitle).font(.system(size: CGFloat(store.preferences.menuFontSize), weight: .medium, design: .monospaced)).lineLimit(1)
                        }
                        Spacer(); Text("菜单栏预览").font(.caption2).foregroundStyle(.secondary)
                    }
                        .padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    if store.preferences.menuStyle == .icon {
                        Text("只占一个图标的位置。点击图标查看自选；切回行情文字会恢复之前的显示与轮播配置。")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                    Picker("固定标的", selection: $store.preferences.pinnedID) {
                        if store.preferences.instruments.isEmpty { Text("暂无自选").tag("") }
                        ForEach(store.preferences.instruments) { Text($0.name).tag($0.id) }
                    }.disabled(store.preferences.rotate).onChange(of: store.preferences.pinnedID) { _ in store.preferenceChanged(); store.refresh() }
                    Picker("标的名称", selection: $store.preferences.menuLabel) { Text("简称").tag("name"); Text("代码").tag("code"); Text("不显示").tag("none") }
                        .onChange(of: store.preferences.menuLabel) { _ in store.preferenceChanged() }
                    Picker("显示内容", selection: $store.preferences.menuContent) { Text("涨跌幅").tag("change"); Text("价格").tag("price"); Text("价格 + 涨跌幅").tag("both") }
                        .onChange(of: store.preferences.menuContent) { _ in store.preferenceChanged() }
                    Picker("最大宽度", selection: $store.preferences.menuWidth) { Text("紧凑 · 120 pt").tag(120); Text("标准 · 180 pt").tag(180); Text("宽松 · 240 pt").tag(240) }
                        .onChange(of: store.preferences.menuWidth) { _ in store.preferenceChanged() }
                    Picker("字号", selection: $store.preferences.menuFontSize) { Text("小 · 11").tag(11); Text("标准 · 12").tag(12); Text("大 · 13").tag(13) }
                        .onChange(of: store.preferences.menuFontSize) { _ in store.preferenceChanged() }
                    Toggle("轮播自选", isOn: $store.preferences.rotate).onChange(of: store.preferences.rotate) { _ in store.preferenceChanged() }
                    if store.preferences.rotate {
                        Picker("轮播间隔", selection: $store.preferences.rotationSeconds) { ForEach([5, 8, 15, 30], id: \.self) { Text("\($0)秒").tag($0) } }
                            .onChange(of: store.preferences.rotationSeconds) { _ in store.preferenceChanged() }
                    }
                    }
                    Toggle("单色显示", isOn: $store.preferences.monochrome).onChange(of: store.preferences.monochrome) { _ in store.preferenceChanged() }
                    Toggle("红涨绿跌", isOn: $store.preferences.redIsUp).onChange(of: store.preferences.redIsUp) { _ in store.preferenceChanged() }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("面板外观", subtitle: "弹窗高度会自动适应屏幕可用空间")
                    Toggle("毛玻璃效果", isOn: $store.preferences.glassEnabled).onChange(of: store.preferences.glassEnabled) { _ in store.preferenceChanged() }
                    Text(glassDescription).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("紧凑面板", isOn: $store.preferences.compact).onChange(of: store.preferences.compact) { _ in store.preferenceChanged() }
                    Toggle("显示每行数据来源", isOn: $store.preferences.showSource).onChange(of: store.preferences.showSource) { _ in store.preferenceChanged() }
                    Button("恢复默认外观") { store.restoreAppearance() }.controlSize(.small)
                    Text("仅恢复显示设置，保留自选和行情来源。").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("刷新与启动", subtitle: "休市降频、睡眠暂停、失败退避")
                    Picker("交易时段刷新", selection: $store.preferences.interval) { ForEach([10, 15, 30, 60], id: \.self) { Text("\($0)秒").tag($0) } }.onChange(of: store.preferences.interval) { _ in store.preferenceChanged() }
                    Toggle("登录时启动", isOn: Binding(get: { store.loginEnabled }, set: { store.toggleLogin($0) }))
                    if let message = store.loginMessage { Text(message).font(.caption).foregroundStyle(.orange) }
                    Text("配置和自选仅存于本机。首版支持 A 股和场内 ETF；网络故障时保留最后报价并标记旧值。").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.font(.system(size: 12)).padding(.horizontal, 20).padding(.bottom, 20)
        }
    }
    private var glassDescription: String {
        if reduceTransparency || contrast == .increased { return "系统已启用减少透明度或增强对比度，当前使用清晰背景。" }
        if !store.preferences.glassEnabled { return "已关闭透明效果，使用纯色背景。" }
        if #available(macOS 26.0, *) { return "使用 macOS Liquid Glass，随系统自动适配浅色与深色。" }
        return "使用系统毛玻璃背景；macOS 26 及以上自动使用 Liquid Glass。"
    }
    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 13, weight: .semibold)); Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary) }
    }
    private func footerButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct QuoteRow: View {
    @ObservedObject var store: AppStore
    let instrument: Instrument
    var body: some View {
        let quote = store.quotes[instrument.id]
        let name = quote?.name ?? instrument.name
        HStack(spacing: 9) {
            Button { store.pin(instrument.id) } label: {
                Image(systemName: store.preferences.pinnedID == instrument.id && !store.preferences.rotate ? "star.fill" : "star")
                    .font(.system(size: 11)).foregroundStyle(store.preferences.pinnedID == instrument.id ? Color.accentColor : .secondary)
            }.buttonStyle(.plain).frame(width: 16).help("在菜单栏固定显示").accessibilityLabel("固定\(instrument.name)")
            VStack(spacing: store.preferences.compact ? 5 : 8) {
                HStack(spacing: 8) {
                    Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading).help(name)
                    Text(quote.map { store.price($0, instrument: instrument) } ?? "—")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.85)
                        .frame(width: 76, alignment: .trailing)
                    Text(quote.map { store.percent($0) } ?? "—")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.85)
                        .foregroundStyle(quote.map { store.color($0) } ?? .secondary).frame(width: 70, alignment: .trailing)
                }
                HStack(spacing: 5) {
                    Text(instrument.id.uppercased()).fontDesign(.monospaced)
                    Spacer(minLength: 4)
                    if let quote {
                        if store.isOld(quote) { Text("旧值").foregroundStyle(.orange) }
                        if store.preferences.showSource { Text(store.sourceName(quote.sourceID)) }
                        Text(store.time(quote.quoteTime))
                    } else { Text(store.refreshing ? "读取中" : "暂无行情") }
                }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Menu {
                Button("固定到菜单栏") { store.pin(instrument.id) }
                Divider()
                Button("上移") { store.moveOne(instrument.id, offset: -1) }.disabled(store.preferences.instruments.first?.id == instrument.id)
                Button("下移") { store.moveOne(instrument.id, offset: 1) }.disabled(store.preferences.instruments.last?.id == instrument.id)
                Divider()
                Button("移除自选", role: .destructive) { store.remove(instrument.id) }
            } label: { Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(.secondary) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18)
                .accessibilityLabel("管理\(instrument.name)")
        }
        .accessibilityElement(children: .contain)
        .padding(.horizontal, 10).padding(.vertical, store.preferences.compact ? 9 : 13)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
        .contextMenu { Button("固定到菜单栏") { store.pin(instrument.id) }; Button("移除自选", role: .destructive) { store.remove(instrument.id) } }
    }
}
