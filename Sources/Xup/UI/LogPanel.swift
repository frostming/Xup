import SwiftUI

/// §2.6 日志面板。
struct LogPanel: View {
    @EnvironmentObject private var center: UpdateCenter
    @EnvironmentObject private var ui: UIState

    @State private var follow = true
    @State private var atBottom = true

    private var lines: [LogLine] { ui.logErrorsOnly ? center.log.filter(\.isError) : center.log }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            body_
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("日志", systemImage: "terminal").font(.caption).foregroundStyle(.secondary)
            Text("\(lines.count) 行").font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Toggle(isOn: $ui.logErrorsOnly) {
                Image(systemName: "exclamationmark.triangle")
            }
            .toggleStyle(.button).buttonStyle(.borderless).controlSize(.small)
            .help("仅显示错误")
            Button { center.clearLog() } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).controlSize(.small)
                .help("清空")
            Button {
                XupActions.copy(center.log.map { "\(XupFormat.time.string(from: $0.time)) [\($0.source)] \($0.text)" }.joined(separator: "\n"))
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).controlSize(.small)
                .help("复制全部")
            Button { ui.showLog = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).controlSize(.small)
                .help("关闭日志面板")
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.bar)
    }

    private var body_: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        LogRow(line: line).id(line.id)
                    }
                }
                .padding(.vertical, 4)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: LogScrollKey.self,
                                               value: geo.frame(in: .named("logScroll")).maxY)
                    }
                )
            }
            .coordinateSpace(name: "logScroll")
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    Color.clear.preference(key: LogViewportKey.self, value: geo.size.height)
                }
            }
            .onPreferenceChange(LogScrollKey.self) { maxY in
                viewportMaxY = maxY
                updateFollow()
            }
            .onPreferenceChange(LogViewportKey.self) { h in
                viewportHeight = h
                updateFollow()
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(alignment: .bottomTrailing) {
                if !follow {
                    Button {
                        follow = true
                        if let last = lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    } label: {
                        Label("跳到底部", systemImage: "arrow.down.to.line.compact").font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(8)
                }
            }
            .onChange(of: center.log.count) { _, _ in
                if follow, let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: ui.logErrorsOnly) { _, _ in
                if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: ui.logScrollTarget) { _, target in
                guard let target else { return }
                follow = false
                withAnimation { proxy.scrollTo(target, anchor: .center) }
                ui.logScrollTarget = nil
            }
            .onAppear {
                if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    @State private var viewportMaxY: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    /// 根据内容底部与可视区底部的距离判断是否在底部；用户上滚后停止跟随。
    private func updateFollow() {
        guard viewportHeight > 0 else { return }
        let nowAtBottom = viewportMaxY - viewportHeight < 24
        if nowAtBottom != atBottom {
            atBottom = nowAtBottom
            if nowAtBottom { follow = true } else if viewportMaxY > viewportHeight + 24 { follow = false }
        }
    }
}

private struct LogScrollKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct LogViewportKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct LogRow: View {
    let line: LogLine

    private var isCommand: Bool { line.text.hasPrefix("$ ") }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(XupFormat.time.string(from: line.time))
                .foregroundStyle(line.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
            Text("[\(line.source)]")
                .frame(width: 72, alignment: .trailing)
                .lineLimit(1)
                .foregroundStyle(line.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            Text(line.text)
                .fontWeight(isCommand ? .bold : .regular)
                .foregroundStyle(line.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
    }
}
