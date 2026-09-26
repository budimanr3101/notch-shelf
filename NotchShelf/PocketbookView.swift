import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Motion / geometry

enum PocketbookV3Motion {
    static let shoulderDuration: TimeInterval = 0.12
    static let bridgeDelay: TimeInterval = 0.08
    static let bridgeDuration: TimeInterval = 0.20
    static let contentDelay: TimeInterval = 0.16
    static let contentDuration: TimeInterval = 0.12
    static let closeContentDuration: TimeInterval = 0.10
    static let closeBridgeDelay: TimeInterval = 0.04
    static let closeBridgeDuration: TimeInterval = 0.18
    static let closeShoulderDelay: TimeInterval = 0.12
    static let closeDuration: TimeInterval = 0.26
    static let reducedDuration: TimeInterval = 0.12

    static func reveal(_ duration: TimeInterval) -> Animation {
        return .timingCurve(0.23, 1, 0.32, 1, duration: duration)
    }
}

struct PocketbookV3Metrics {
    let wingWidth: CGFloat
    let homeDepth: CGFloat
    let detailDepth: CGFloat
    let maxDepth: CGFloat
    let contentWidth: CGFloat
    let windowSize: CGSize

    init(geometry: NotchGeometry, screen: NSScreen) {
        let availableHalfWidth = max(100, (screen.frame.width - geometry.hardwareWidth - 48) / 2)
        wingWidth = min(126, availableHalfWidth - NotchGeometry.topRadius)
        homeDepth = 228
        detailDepth = 286
        maxDepth = 294
        contentWidth = geometry.hardwareWidth + 2 * wingWidth
        windowSize = CGSize(
            width: geometry.hardwareWidth + 2 * (wingWidth + NotchGeometry.topRadius) + 32,
            height: geometry.hardwareHeight + maxDepth + 4
        )
    }
}

@MainActor
final class PocketbookV3Panel: NSPanel {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return false }

    init(
        frame: NSRect,
        model: PocketbookV3Model,
        geometry: NotchGeometry,
        metrics: PocketbookV3Metrics,
        onClose: @escaping () -> Void,
        onSettings: @escaping () -> Void
    ) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        // File Shelf is +3 and magnetic Drop Zone is +6. Pocketbook stays below
        // both so developer utility surfaces never block one another.
        level = .mainMenu + 2
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false

        let hosting = NSHostingView(
            rootView: PocketbookV3View(
                model: model,
                geometry: geometry,
                metrics: metrics,
                onClose: onClose,
                onSettings: onSettings
            )
        )
        hosting.safeAreaRegions = []
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }
}

struct PocketbookV3View: View {
    @ObservedObject var model: PocketbookV3Model
    let geometry: NotchGeometry
    let metrics: PocketbookV3Metrics
    let onClose: () -> Void
    let onSettings: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @Namespace private var bookSelection
    @Namespace private var categorySelection
    @State private var shoulderExpansion: CGFloat = 0
    @State private var bridgeExpansion: CGFloat = 0
    @State private var contentVisible = false
    @State private var pendingMotion: [DispatchWorkItem] = []
    @State private var pendingFocus: DispatchWorkItem?

    private var activeDepth: CGFloat {
        return model.selectedID == nil ? metrics.homeDepth : metrics.detailDepth
    }

    private var activeSurface: PocketbookV3Wings {
        return PocketbookV3Wings(
            geometry: geometry,
            expansion: shoulderExpansion,
            extraDepth: bridgeExpansion * activeDepth,
            wingWidth: metrics.wingWidth,
            maximumDepth: metrics.maxDepth
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            activeSurface
                .fill(Color.black)
                .overlay {
                    PocketbookV3OuterEdge(
                        geometry: geometry,
                        expansion: shoulderExpansion,
                        extraDepth: bridgeExpansion * activeDepth,
                        wingWidth: metrics.wingWidth,
                        maximumDepth: metrics.maxDepth
                    )
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.75)
                }
                .shadow(
                    color: Color.black.opacity(0.34 * Double(bridgeExpansion)),
                    radius: 14,
                    y: 5
                )

            content
                .frame(width: metrics.windowSize.width, height: metrics.windowSize.height, alignment: .top)
                .mask(activeSurface)
                .opacity(contentVisible ? 1 : 0)
                .offset(y: reduceMotion || contentVisible ? 0 : -5)
                .allowsHitTesting(model.presented && contentVisible)
                .accessibilityHidden(!model.presented || !contentVisible)
        }
        .frame(width: metrics.windowSize.width, height: metrics.windowSize.height, alignment: .top)
        .clipped()
        .opacity(reduceMotion && !model.presented ? 0 : 1)
        .animation(
            reduceMotion ? .easeOut(duration: PocketbookV3Motion.reducedDuration) : nil,
            value: model.presented
        )
        .animation(
            reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.90),
            value: activeDepth
        )
        .onChange(of: model.presented) { visible in
            animatePresentation(visible)
        }
        .onChange(of: model.selectedID) { selectedID in
            searchFocused = false
            if selectedID == nil { focusSearchWhenReady() }
            else { pendingFocus?.cancel() }
        }
        .onChange(of: contentVisible) { visible in
            if visible { focusSearchWhenReady() }
            else {
                pendingFocus?.cancel()
                searchFocused = false
            }
        }
        .onDisappear {
            cancelMotion()
            pendingFocus?.cancel()
        }
    }

    private var content: some View {
        VStack(spacing: 7) {
            if model.selectedID == nil {
                homeHeader
                if model.currentBook == nil {
                    emptyState
                } else {
                    bookTabs
                    searchBar
                    categoryTabs
                    results
                }
            } else if let entry = model.selected {
                detail(entry)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, geometry.hardwareHeight + 8)
        .padding(.bottom, 10)
        .frame(
            width: metrics.contentWidth,
            height: geometry.hardwareHeight + activeDepth,
            alignment: .top
        )
    }

    private var homeHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 0) {
                Text("Pocketbook")
                    .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.96))
                Text(model.currentBook?.title ?? "No books enabled")
                    .font(.system(size: 9.3, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.42))
            }

            Spacer()

            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.54))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.055)))
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.58))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
        }
        .frame(height: 26)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 12)
            Image(systemName: "books.vertical")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.white.opacity(0.24))
            Text("Pocketbook is empty")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.80))
            Text("Enable Kubernetes, AWS, Bash, kubectl, or your own JSON books in Settings.")
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(.white.opacity(0.38))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button("Open Settings", action: onSettings)
                .buttonStyle(.bordered)
                .controlSize(.small)
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bookTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 3) {
                ForEach(model.books) { book in
                    Button {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.27, dampingFraction: 0.88)) {
                            model.switchBook(to: book.id)
                        }
                    } label: {
                        ZStack {
                            if model.bookID == book.id {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.white.opacity(0.10))
                                    .matchedGeometryEffect(id: "PocketbookBook", in: bookSelection)
                            }

                            HStack(spacing: 5) {
                                Image(systemName: book.icon)
                                    .font(.system(size: 8.5, weight: .semibold))
                                Text(book.title)
                                    .font(.system(size: 9.4, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(
                                model.bookID == book.id
                                    ? Color.white.opacity(0.94)
                                    : Color.white.opacity(0.38)
                            )
                            .padding(.horizontal, 9)
                        }
                        .frame(height: 24)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
        }
        .scrollIndicators(.never)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.022))
        )
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.38))

            TextField(model.currentBook?.searchPlaceholder ?? "Search…", text: $model.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))

            if !model.query.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { model.query = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.30))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 31)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(searchFocused ? 0.085 : 0.055))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(searchFocused ? 0.16 : 0.055), lineWidth: 0.7)
        }
    }

    private var categoryTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(model.categories, id: \.self) { category in
                    Button {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.27, dampingFraction: 0.88)) {
                            model.category = category
                            model.selectedID = nil
                        }
                    } label: {
                        ZStack {
                            if model.category == category {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.white.opacity(0.10))
                                    .matchedGeometryEffect(id: "PocketbookCategory", in: categorySelection)
                            }
                            Text(category)
                                .font(.system(size: 9.2, weight: .semibold, design: .rounded))
                                .foregroundStyle(
                                    model.category == category
                                        ? Color.white.opacity(0.92)
                                        : Color.white.opacity(0.39)
                                )
                                .padding(.horizontal, 9)
                        }
                        .frame(height: 22)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
        }
        .scrollIndicators(.never)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.020))
        )
    }

    private var results: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if model.results.isEmpty {
                    Text("No reference found")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.38))
                        .frame(maxWidth: .infinity, minHeight: 76)
                } else {
                    ForEach(model.results) { entry in
                        resultRow(entry)
                    }
                }
            }
        }
        .scrollIndicators(.never)
        .frame(maxHeight: .infinity)
    }

    private func resultRow(_ entry: PocketbookV3Entry) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.90)) {
                model.selectedID = entry.id
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: entryIcon(entry))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(entryColor(entry))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1.5) {
                    Text(entry.title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.91))
                        .lineLimit(1)
                    Text(entry.subtitle)
                        .font(.system(size: 8.9, design: .rounded))
                        .foregroundStyle(.white.opacity(0.38))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
                Text(entry.category)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.26))
                Image(systemName: "chevron.right")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.20))
            }
            .padding(.horizontal, 6)
            .frame(height: 34)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5)
            }
        }
        .buttonStyle(.plain)
    }

    private func detail(_ entry: PocketbookV3Entry) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.88)) {
                        model.selectedID = nil
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 25, height: 25)
                        .background(Circle().fill(Color.white.opacity(0.065)))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))
                    Text(entry.subtitle)
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.white.opacity(0.39))
                        .lineLimit(1)
                }
                Spacer()
                Text(entry.category)
                    .font(.system(size: 8.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(entryColor(entry))
            }

            referenceBody(entry)

            HStack {
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.90)) {
                        model.copy(entry)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: model.copiedID == entry.id ? "checkmark" : "doc.on.doc")
                        Text(model.copiedID == entry.id ? "Copied" : "Copy")
                    }
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(
                        model.copiedID == entry.id
                            ? Color.green.opacity(0.95)
                            : Color.white.opacity(0.82)
                    )
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                model.copiedID == entry.id
                                    ? Color.green.opacity(0.11)
                                    : Color.white.opacity(0.055)
                            )
                    )
                }
                .buttonStyle(.plain)
                Spacer()
                Text("⌘C")
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.22))
            }
        }
        .frame(maxHeight: .infinity)
        .transition(.opacity.combined(with: .offset(x: reduceMotion ? 0 : 6)))
    }

    private func referenceBody(_ entry: PocketbookV3Entry) -> some View {
        ScrollView([.vertical, .horizontal]) {
            if entry.code {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(
                        Array(entry.content.split(separator: "\n", omittingEmptySubsequences: false).enumerated()),
                        id: \.offset
                    ) { index, line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.17))
                                .frame(width: 20, alignment: .trailing)
                            Text(String(line))
                                .font(.system(size: 10.1, design: .monospaced))
                                .foregroundStyle(codeColor(for: String(line)))
                                .textSelection(.enabled)
                        }
                        .frame(minHeight: 17)
                    }
                }
                .padding(10)
            } else {
                Text(entry.content)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(.white.opacity(0.80))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(11)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 0.65)
        }
    }

    private func entryIcon(_ entry: PocketbookV3Entry) -> String {
        switch entry.type {
        case .code: return "terminal.fill"
        case .checklist: return "checklist"
        case .link: return "link"
        case .text: return "doc.text.fill"
        }
    }

    private func entryColor(_ entry: PocketbookV3Entry) -> Color {
        if entry.category.localizedCaseInsensitiveContains("AWS")
            || model.bookID == PocketbookBuiltinID.aws {
            return Color.orange.opacity(0.84)
        }
        if model.bookID == PocketbookBuiltinID.kubectl {
            return Color.blue.opacity(0.88)
        }
        if model.bookID == PocketbookBuiltinID.bash {
            return Color.green.opacity(0.82)
        }
        return Color.accentColor.opacity(0.88)
    }

    private func codeColor(for line: String) -> Color {
        let value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { return Color.white.opacity(0.34) }
        if value.hasPrefix("kubectl ")
            || value.hasPrefix("aws ")
            || value.hasPrefix("curl ")
            || value.hasPrefix("find ")
            || value.hasPrefix("grep ") {
            return Color.green.opacity(0.86)
        }
        if value.contains("apiVersion:") || value.contains("kind:") {
            return Color.accentColor.opacity(0.90)
        }
        return Color.white.opacity(0.80)
    }

    private func cancelMotion() {
        pendingMotion.forEach { $0.cancel() }
        pendingMotion.removeAll()
    }

    private func focusSearchWhenReady() {
        pendingFocus?.cancel()
        let focus = DispatchWorkItem {
            guard model.presented, contentVisible,
                  model.selectedID == nil, model.currentBook != nil else { return }
            searchFocused = true
        }
        pendingFocus = focus
        DispatchQueue.main.async(execute: focus)
    }

    private func scheduleMotion(after delay: TimeInterval, opening: Bool, action: @escaping () -> Void) {
        let work = DispatchWorkItem {
            guard model.presented == opening else { return }
            action()
        }
        pendingMotion.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func animatePresentation(_ opening: Bool) {
        cancelMotion()
        if !opening {
            pendingFocus?.cancel()
            searchFocused = false
        }

        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                shoulderExpansion = 1
                bridgeExpansion = 1
            }
            withAnimation(.easeOut(duration: PocketbookV3Motion.reducedDuration)) {
                contentVisible = opening
            }
            return
        }

        if opening {
            withAnimation(PocketbookV3Motion.reveal(PocketbookV3Motion.shoulderDuration)) {
                shoulderExpansion = 1
            }
            scheduleMotion(after: PocketbookV3Motion.bridgeDelay, opening: true) {
                withAnimation(PocketbookV3Motion.reveal(PocketbookV3Motion.bridgeDuration)) {
                    bridgeExpansion = 1
                }
            }
            scheduleMotion(after: PocketbookV3Motion.contentDelay, opening: true) {
                withAnimation(PocketbookV3Motion.reveal(PocketbookV3Motion.contentDuration)) {
                    contentVisible = true
                }
            }
        } else {
            withAnimation(PocketbookV3Motion.reveal(PocketbookV3Motion.closeContentDuration)) {
                contentVisible = false
            }
            scheduleMotion(after: PocketbookV3Motion.closeBridgeDelay, opening: false) {
                withAnimation(PocketbookV3Motion.reveal(PocketbookV3Motion.closeBridgeDuration)) {
                    bridgeExpansion = 0
                }
            }
            scheduleMotion(after: PocketbookV3Motion.closeShoulderDelay, opening: false) {
                withAnimation(PocketbookV3Motion.reveal(PocketbookV3Motion.shoulderDuration)) {
                    shoulderExpansion = 0
                }
            }
        }
    }
}
