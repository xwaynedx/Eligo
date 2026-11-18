import SwiftUI

/// The first-run Welcome Guide: a six-step, lightly interactive
/// walkthrough — language, welcome, how routing works, rules & scope, real
/// activation, done. All navigation and auto-advance decisions live in
/// `WelcomeGuideModel`; this view only renders the model and feeds it
/// activation status.
struct WelcomeGuideView: View, AppLocalizing {
    @ObservedObject var appLanguageStore: AppLanguageStore
    @ObservedObject var browserRepository: BrowserRepository
    @ObservedObject var defaultBrowserController: DefaultBrowserController
    @State private var model: WelcomeGuideModel
    @State private var transitionEdge: Edge = .trailing

    let onClose: () -> Void
    let onOpenSettings: () -> Void
    let onAddFirstRule: () -> Void

    init(
        appLanguageStore: AppLanguageStore,
        browserRepository: BrowserRepository,
        defaultBrowserController: DefaultBrowserController,
        onClose: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onAddFirstRule: @escaping () -> Void
    ) {
        self.appLanguageStore = appLanguageStore
        self.browserRepository = browserRepository
        self.defaultBrowserController = defaultBrowserController
        self.onClose = onClose
        self.onOpenSettings = onOpenSettings
        self.onAddFirstRule = onAddFirstRule
        let hasUsableBrowsers = !browserRepository.browsers.isEmpty && !browserRepository.enabledBrowsers.isEmpty
        _model = State(initialValue: WelcomeGuideModel(
            activationComplete: defaultBrowserController.state.isDefaultBrowser && hasUsableBrowsers
        ))
    }

    private var hasUsableBrowsers: Bool {
        !browserRepository.browsers.isEmpty && !browserRepository.enabledBrowsers.isEmpty
    }

    var activationComplete: Bool {
        defaultBrowserController.state.isDefaultBrowser && hasUsableBrowsers
    }

    var body: some View {
        VStack(spacing: 0) {
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(model.step)
                .transition(.asymmetric(
                    insertion: .move(edge: transitionEdge).combined(with: .opacity),
                    removal: .move(edge: transitionEdge == .trailing ? .leading : .trailing).combined(with: .opacity)
                ))

            Divider()

            navigationBar
        }
        .frame(width: 640, height: 420)
        .onAppear {
            syncActivation(activationComplete)
        }
        .onChange(of: activationComplete) { _, newValue in
            syncActivation(newValue)
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch model.step {
        case .language:
            LanguageStepView(appLanguageStore: appLanguageStore)
        case .welcome:
            WelcomeStepView(appLanguageStore: appLanguageStore)
        case .howItWorks:
            HowItWorksStepView(appLanguageStore: appLanguageStore)
        case .rulesAndScope:
            RulesAndScopeStepView(appLanguageStore: appLanguageStore)
        case .activation:
            activationStep
        case .complete:
            CompleteStepView(
                activationComplete: model.activationComplete,
                onOpenSettings: onOpenSettings,
                onAddFirstRule: onAddFirstRule,
                appLanguageStore: appLanguageStore
            )
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 12) {
            Button(t("Skip")) { onClose() }

            Spacer()

            StepIndicatorView(current: model.step)

            Spacer()

            if model.canGoBack {
                Button(t("Back"), action: goBack)
            }

            if model.step == .activation, !model.activationComplete {
                // The step's own "Set Up Later" continues; a bare Next here
                // would compete with the real activation action.
            } else if model.canGoForward {
                Button(t("Next"), action: goForward)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(t("Start Using Eligo")) { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var browserDetail: String {
        if browserRepository.availability == .configurationUnreadable {
            return BrowserPreferencesError.unreadableConfiguration.message(using: appLanguageStore)
        }
        if browserRepository.browsers.isEmpty {
            return t("No browsers detected")
        }
        return appLanguageStore.format(
            "%@ detected, %@ available",
            String(browserRepository.browsers.count),
            String(browserRepository.enabledBrowsers.count)
        )
    }

    private func goForward() {
        transitionEdge = .trailing
        withAnimation(.easeInOut(duration: 0.25)) { model.goForward() }
    }

    private func goBack() {
        transitionEdge = .leading
        withAnimation(.easeInOut(duration: 0.25)) { model.goBack() }
    }

    private func syncActivation(_ isComplete: Bool) {
        guard model.noteActivationComplete(isComplete) else { return }
        // Pause on the success state before advancing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard model.step == .activation else { return }
            transitionEdge = .trailing
            withAnimation(.easeInOut(duration: 0.3)) { model.goForward() }
        }
    }

    var activationStep: ActivationStepView {
        ActivationStepView(
            presentation: model.activationPresentation,
            defaultBrowserState: defaultBrowserController.state,
            hasUsableBrowsers: hasUsableBrowsers,
            browserDetail: browserDetail,
            browserConfigurationUnreadable: browserRepository.availability == .configurationUnreadable,
            onOpenSettings: onOpenSettings,
            onSetAsDefaultBrowser: defaultBrowserController.requestDefaultBrowser,
            onContinue: { goForward() },
            appLanguageStore: appLanguageStore
        )
    }

}

private struct StepIndicatorView: View {
    let current: WelcomeGuideModel.Step

    var body: some View {
        HStack(spacing: 6) {
            ForEach(WelcomeGuideModel.Step.allCases, id: \.rawValue) { step in
                Circle()
                    .fill(step == current ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 6, height: 6)
            }
        }
    }
}

/// The language step renders before any language is chosen, so its prompt is
/// deliberately bilingual hardcoded text; the options use each language's own
/// name. Picking one immediately re-renders every later step.
private struct LanguageStepView: View {
    @ObservedObject var appLanguageStore: AppLanguageStore

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "globe")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)

            Text("Choose your language / 选择语言")
                .font(.title2)
                .fontWeight(.bold)

            Picker("", selection: Binding(
                get: { appLanguageStore.language },
                set: { appLanguageStore.select($0) }
            )) {
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Concept introduction only — no controls. Configuration stays in
/// Settings; the complete page's deep link is the narrative follow-through.
private struct RulesAndScopeStepView: View, AppLocalizing {
    @ObservedObject var appLanguageStore: AppLanguageStore

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            Text(t("Rules and Routing Scope"))
                .font(.title2)
                .fontWeight(.bold)

            HStack(alignment: .top, spacing: 14) {
                rulesCard
                scopeCard
            }
            .frame(maxWidth: 560)

            Text(t("You can configure both anytime in Settings."))
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("Rules"))
                .font(.headline)

            HStack(spacing: 8) {
                Text("example.com")
                    .font(.system(.callout, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "globe")
                    .foregroundStyle(Color.accentColor)
            }

            Text(t("Pin a domain to a browser so matching links open there directly. Without rules, every link shows the chooser."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private var scopeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("Routing Scope"))
                .font(.headline)

            Text(t("All domains"))
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())

            Text(t("Decide which links Eligo manages. The default covers every domain."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct WelcomeStepView: View, AppLocalizing {
    @ObservedObject var appLanguageStore: AppLanguageStore

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(nsImage: EligoIcon.appIcon(size: 84))
                .resizable()
                .frame(width: 84, height: 84)
                .accessibilityLabel(t("Eligo app icon"))

            Text(t("Welcome to Eligo"))
                .font(.largeTitle)
                .fontWeight(.bold)

            Text(t("Links you click open through Eligo: automatically via domain rules, or by choosing a browser each time."))
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct HowItWorksStepView: View, AppLocalizing {
    enum RoutingMode: String, CaseIterable {
        case automatic
        case chooser
    }

    @ObservedObject var appLanguageStore: AppLanguageStore
    @State private var mode: RoutingMode = .automatic
    @State private var pulseProgress: CGFloat = 0

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)

            Text(t("How Eligo Routes Your Links"))
                .font(.title2)
                .fontWeight(.bold)

            Picker("", selection: $mode) {
                Text(t("Route Automatically")).tag(RoutingMode.automatic)
                Text(t("Choose Each Time")).tag(RoutingMode.chooser)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)

            FlowDiagramView(
                mode: mode,
                pulseProgress: pulseProgress,
                appLanguageStore: appLanguageStore
            )

            Text(caption)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
                .animation(.easeInOut(duration: 0.2), value: mode)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .onAppear { firePulse() }
        .onChange(of: mode) { _, _ in firePulse() }
    }

    private var caption: String {
        switch mode {
        case .automatic:
            t("Matching links open directly in the destination your rules choose.")
        case .chooser:
            t("Every link waits for you to pick a browser.")
        }
    }

    private func firePulse() {
        pulseProgress = 0
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 1.2)) {
                pulseProgress = 1
            }
        }
    }
}

/// A single link pulse travels the routing diagram each time the user picks a mode.
private struct FlowDiagramView: View {
    let mode: HowItWorksStepView.RoutingMode
    let pulseProgress: CGFloat
    @ObservedObject var appLanguageStore: AppLanguageStore

    private let canvasSize = CGSize(width: 560, height: 190)
    private let edgeGap: CGFloat = 6

    /// A diagram node: anchor point plus the visual radius that edges must
    /// respect when trimming.
    private struct Node {
        let point: CGPoint
        let radius: CGFloat
    }

    private let link = Node(point: CGPoint(x: 56, y: 85), radius: 22)
    private let picker = Node(point: CGPoint(x: 224, y: 85), radius: 28)
    private let chooser = Node(point: CGPoint(x: 364, y: 85), radius: 22)
    private let singleBrowser = Node(point: CGPoint(x: 508, y: 85), radius: 22)
    private let browserA = Node(point: CGPoint(x: 508, y: 40), radius: 22)
    private let browserB = Node(point: CGPoint(x: 508, y: 130), radius: 22)

    /// One connection between two nodes. Curves evaluate true cubic geometry
    /// so the pulse rides the visible line instead of cutting the corner.
    private enum Segment {
        case line(CGPoint, CGPoint)
        case curve(CGPoint, CGPoint, CGPoint, CGPoint)

        func point(at t: CGFloat) -> CGPoint {
            switch self {
            case let .line(a, b):
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            case let .curve(a, c1, c2, b):
                let mt = 1 - t
                return CGPoint(
                    x: mt * mt * mt * a.x + 3 * mt * mt * t * c1.x + 3 * mt * t * t * c2.x + t * t * t * b.x,
                    y: mt * mt * mt * a.y + 3 * mt * mt * t * c1.y + 3 * mt * t * t * c2.y + t * t * t * b.y
                )
            }
        }

        var path: Path {
            Path { path in
                switch self {
                case let .line(a, b):
                    path.move(to: a)
                    path.addLine(to: b)
                case let .curve(a, c1, c2, b):
                    path.move(to: a)
                    path.addCurve(to: b, control1: c1, control2: c2)
                }
            }
        }
    }

    /// Straight edges are all horizontal, so trimming the x extent lands the
    /// line exactly on each node's edge — lines never run under the icons.
    private func edgeLine(from a: Node, to b: Node) -> Segment {
        .line(
            CGPoint(x: a.point.x + a.radius + edgeGap, y: a.point.y),
            CGPoint(x: b.point.x - b.radius - edgeGap, y: b.point.y)
        )
    }

    /// Horizontal tangents at both ends keep the chooser fork smooth.
    private func forkCurve(from a: Node, to b: Node) -> Segment {
        let start = CGPoint(x: a.point.x + a.radius + edgeGap, y: a.point.y)
        let end = CGPoint(x: b.point.x - b.radius - edgeGap, y: b.point.y)
        let bend: CGFloat = 56
        return .curve(start, CGPoint(x: start.x + bend, y: start.y), CGPoint(x: end.x - bend, y: end.y), end)
    }

    /// Every visible edge, in flow order.
    private var edges: [Segment] {
        var result: [Segment] = [edgeLine(from: link, to: picker)]
        switch mode {
        case .automatic:
            result.append(edgeLine(from: picker, to: singleBrowser))
        case .chooser:
            result.append(edgeLine(from: picker, to: chooser))
            result.append(forkCurve(from: chooser, to: browserA))
            result.append(forkCurve(from: chooser, to: browserB))
        }
        return result
    }

    /// The route the pulse rides: the visible edges, minus the lower fork in
    /// chooser mode — the pulse always takes the upper branch.
    private var pulseRoute: [Segment] {
        switch mode {
        case .automatic: edges
        case .chooser: Array(edges.dropLast())
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            connections

            node(systemIcon: "link", label: t("Link"), tint: .secondary)
                .position(link.point)
            appHubNode()
                .position(picker.point)

            if mode == .chooser {
                node(systemIcon: "list.bullet", label: t("Chooser"), tint: .accentColor, halo: true)
                    .position(chooser.point)
                node(systemIcon: "globe", label: t("Browser"), tint: .accentColor, halo: true)
                    .position(browserA.point)
                node(systemIcon: "globe", label: t("Browser"), tint: .accentColor, halo: true)
                    .position(browserB.point)
            } else {
                node(systemIcon: "globe", label: t("Browser"), tint: .accentColor, halo: true)
                    .position(singleBrowser.point)
            }

            pulse
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .animation(.easeInOut(duration: 0.25), value: mode)
    }

    @ViewBuilder private var connections: some View {
        ForEach(Array(edges.indices), id: \.self) { index in
            edges[index].path
                .stroke(
                    LinearGradient(
                        colors: [Color.secondary.opacity(0.35), Color.accentColor.opacity(0.45)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
        }
    }

    /// A comet: bright head plus a short fading trail sampled just behind it
    /// along the route in a single pass.
    @ViewBuilder private var pulse: some View {
        ForEach(trailDots, id: \.offset) { dot in
            Circle()
                .fill(Color.accentColor)
                .frame(width: dot.size, height: dot.size)
                .opacity(pulseOpacity * dot.opacity)
                .position(pulsePoint(at: pulseProgress - dot.offset))
        }

        Circle()
            .fill(Color.accentColor)
            .frame(width: 10, height: 10)
            .shadow(color: .accentColor.opacity(0.5), radius: 4)
            .opacity(pulseOpacity)
            .position(pulsePoint(at: pulseProgress))
    }

    /// One ghost image of the pulse head, sampled this far behind it.
    private struct TrailDot {
        let offset: CGFloat
        let size: CGFloat
        let opacity: Double
    }

    private let trailDots: [TrailDot] = [
        TrailDot(offset: 0.045, size: 7, opacity: 0.5),
        TrailDot(offset: 0.09, size: 5, opacity: 0.28),
        TrailDot(offset: 0.135, size: 3.5, opacity: 0.14),
    ]

    private func pulsePoint(at progress: CGFloat) -> CGPoint {
        let route = pulseRoute
        let scaled = min(max(progress, 0), 1) * CGFloat(route.count)
        let index = min(Int(scaled), route.count - 1)
        let local = min(scaled - CGFloat(index), 1)
        return route[index].point(at: local)
    }

    private var pulseOpacity: Double {
        let fadeIn = min(1, pulseProgress * 8)
        let fadeOut = 1 - max(0, (pulseProgress - 0.9) / 0.1)
        return fadeIn * fadeOut
    }

    private func t(_ english: String) -> String {
        appLanguageStore.text(english)
    }

    /// Nodes anchor by icon center: the label rides in an overlay so it can't
    /// shift the icon off the connection points. Nodes are solid chips —
    /// translucent circles read as placeholders — and accent nodes get a soft
    /// halo to layer them between the neutral link and the hub.
    private func node(systemIcon: String, label: String, tint: Color, halo: Bool = false) -> some View {
        ZStack {
            Circle()
                .fill(Color(nsColor: .controlBackgroundColor))
                .frame(width: 44, height: 44)
                .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
            Circle()
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                .frame(width: 44, height: 44)
            Image(systemName: systemIcon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
        }
        .background {
            if halo {
                Circle()
                    .fill(tint.opacity(0.14))
                    .frame(width: 58, height: 58)
                    .blur(radius: 5)
            }
        }
        .overlay(alignment: .bottom) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
                .offset(y: 20)
        }
    }

    /// The hub: larger than the satellite nodes so the flow visibly passes
    /// through Eligo rather than past a bead on a string.
    private func appHubNode() -> some View {
        Image(nsImage: EligoIcon.appIcon(size: 56))
            .resizable()
            .frame(width: 56, height: 56)
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            .overlay(alignment: .bottom) {
                Text("Eligo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(y: 20)
            }
    }

}

struct ActivationStepView: View, AppLocalizing {
    let presentation: WelcomeGuideModel.ActivationPresentation
    let defaultBrowserState: DefaultBrowserState
    let hasUsableBrowsers: Bool
    let browserDetail: String
    let browserConfigurationUnreadable: Bool
    let onOpenSettings: () -> Void
    let onSetAsDefaultBrowser: () -> Void
    let onContinue: () -> Void
    @ObservedObject var appLanguageStore: AppLanguageStore

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text(t("Make Eligo the Default Browser"))
                    .font(.title2)
                    .fontWeight(.bold)

                VStack(alignment: .leading, spacing: 10) {
                    statusRow(
                        isComplete: defaultBrowserState.isDefaultBrowser,
                        text: defaultBrowserState.statusText(using: appLanguageStore)
                    )
                    statusRow(isComplete: hasUsableBrowsers, text: browserDetail)
                }
                .padding(12)
                .frame(maxWidth: 500, alignment: .leading)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))

                if let message = defaultBrowserState.feedbackText(using: appLanguageStore) {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 500)
                }

                switch presentation {
                case .pending:
                    if browserConfigurationUnreadable || defaultBrowserState.isDefaultBrowser {
                        Button(t("Open Settings"), action: onOpenSettings)
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(defaultBrowserState.actionTitle(using: appLanguageStore), action: onSetAsDefaultBrowser)
                            .buttonStyle(.borderedProminent)
                            .disabled(!defaultBrowserState.canRequest)
                    }
                    if browserConfigurationUnreadable {
                        Text(t("Open Settings and confirm Reset to repair browser settings."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Button(t("Open System Settings"), action: LaunchServicesBrowserManager.openDefaultBrowserSettings)
                    Button(t("Set Up Later"), action: onContinue)
                case .succeeded:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                    Text(t("Eligo is the default browser for HTTP and HTTPS."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
    }

    private func statusRow(isComplete: Bool, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isComplete ? .green : .secondary)
                .font(.system(size: 13, weight: .semibold))
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CompleteStepView: View, AppLocalizing {
    let activationComplete: Bool
    let onOpenSettings: () -> Void
    let onAddFirstRule: () -> Void
    @ObservedObject var appLanguageStore: AppLanguageStore

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: activationComplete ? "checkmark.seal.fill" : "menubar.rectangle")
                .font(.system(size: 56))
                .foregroundStyle(activationComplete ? .green : .secondary)

            Text(activationComplete ? t("You're All Set") : t("Ready When You Are"))
                .font(.largeTitle)
                .fontWeight(.bold)

            Text(activationComplete
                 ? t("Links you click will now open through Eligo.")
                 : t("You can finish setup anytime from the menu bar: choose Help Set Default Browser, or open Settings."))
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)

            // The follow-through for "introduce, don't configure": one
            // clear next action. Activated users land on the Rules tab to
            // create their first rule; others get plain Settings to finish
            // activation.
            Button(activationComplete ? t("Add Your First Rule") : t("Open Settings")) {
                activationComplete ? onAddFirstRule() : onOpenSettings()
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
