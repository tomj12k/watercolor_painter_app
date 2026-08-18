import AppKit
import Combine
import SwiftUI
import WatercolorCore
import WatercolorEngine

struct WatercolorStudioApp: App {
    @NSApplicationDelegateAdaptor(WatercolorStudioApplicationDelegate.self)
    private var applicationDelegate

    init() {
        // Install the launch observer before AppKit enters its event loop.
        // This avoids relying on SwiftUI's document-scene delegate timing.
        _ = NewCanvasWindowPresenter.shared
    }

    var body: some Scene {
        // A viewing document scene does not ask AppKit to manufacture an
        // untitled document during launch. The explicit New Canvas window is
        // the only startup surface; drafts live in memory until saved.
        DocumentGroup(viewing: PaintingDocument.self) { configuration in
            StudioDocumentView(document: configuration.$document)
        }
        .defaultSize(width: 1_220, height: 790)
        .commands {
            StudioAppCommands()
        }

        Window("Watercolor Studio Help", id: StudioHelp.windowIdentifier) {
            StudioHelpView()
        }
        .defaultSize(width: 540, height: 640)

        // This is the launch surface, rather than a document scene. The
        // DocumentGroup remains available for opened/created paintings, but
        // AppKit never needs to manufacture an untitled document just to show
        // the first screen.
    }
}

@MainActor
private final class NewCanvasWindowPresenter {
    static let shared = NewCanvasWindowPresenter()
    private var window: NSWindow?

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.show()
            }
        }
    }

    func show() {
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            return
        }
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "New Watercolor"
        newWindow.contentViewController = NSHostingController(
            rootView: NewCanvasLaunchView(coordinator: NewDocumentLaunchCoordinator.shared)
        )
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }


    func close() {
        window?.close()
        window = nil
    }

    func showCanvas(_ project: PaintingProject) {
        show()
        window?.title = "Untitled"
        window?.contentViewController = NSHostingController(
            rootView: DraftCanvasView(project: project)
        )
        window?.setContentSize(NSSize(width: 1_220, height: 790))
        window?.center()
    }
}

@MainActor
private struct DraftCanvasView: View {
    @State private var document: PaintingDocument
    @StateObject private var saveStore = DraftPaintingStore()
    @State private var saveFailure: StudioFailure?

    init(project: PaintingProject) {
        _document = State(initialValue: PaintingDocument(project: project))
    }

    var body: some View {
        StudioDocumentView(document: $document)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: saveDraft) {
                        Label("Save Painting", systemImage: "square.and.arrow.down")
                    }
                    .help(
                        saveStore.destinationURL == nil
                            ? "Choose where to save this draft"
                            : "Save this draft"
                    )
                    .accessibilityLabel("Save painting")
                }
            }
            .alert(item: $saveFailure) { failure in
                Alert(
                    title: Text("Could not save painting"),
                    message: Text("\(failure.message)\n\n\(failure.recoverySuggestion)"),
                    dismissButton: .default(Text("OK"))
                )
            }
    }

    private func saveDraft() {
        if let destination = saveStore.destinationURL {
            save(project: document.project, to: destination)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.watercolorPainting]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Untitled.watercolor"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                save(project: document.project, to: destination)
            }
        }
    }

    private func save(project: PaintingProject, to destination: URL) {
        do {
            try saveStore.save(project, to: destination)
        } catch {
            saveFailure = StudioFailure(message: "Watercolor Studio could not save this painting. Try another location.")
        }
    }
}

@MainActor
final class DraftPaintingStore: ObservableObject {
    @Published private(set) var destinationURL: URL?

    func save(_ project: PaintingProject, to destination: URL) throws {
        let data = try PaintingDocumentCodec.encode(project)
        try data.write(to: destination, options: .atomic)
        destinationURL = destination
    }
}

@MainActor
final class NewDocumentLaunchCoordinator: ObservableObject {
    typealias CanvasLoadAction = @MainActor (PaintingProject) -> Bool

    private let canvasLoadAction: CanvasLoadAction
    @Published private(set) var failure: StudioFailure?

    static let shared = NewDocumentLaunchCoordinator()

    init(canvasLoadAction: @escaping CanvasLoadAction = { project in
        NewCanvasWindowPresenter.shared.showCanvas(project)
        return true
    }) {
        self.canvasLoadAction = canvasLoadAction
    }

    @discardableResult
    func create(_ configuration: NewCanvasConfiguration) -> Bool {
        do {
            let project = try configuration.makeProject()
            guard canvasLoadAction(project) else {
                failure = StudioFailure(message: "Watercolor Studio could not load this canvas. Try again.")
                return false
            }
            failure = nil
            return true
        } catch {
            failure = StudioFailure(error: error, project: nil)
            return false
        }
    }

    @discardableResult
    func useDefault() -> Bool {
        create(NewCanvasConfiguration(preset: .landscape))
    }

}

@MainActor
private struct NewCanvasLaunchView: View {
    @ObservedObject var coordinator: NewDocumentLaunchCoordinator

    var body: some View {
        NewCanvasConfigurationView(
            failure: coordinator.failure,
            copyDetails: { _ in },
            dismissFailure: {},
            create: {
                _ = coordinator.create($0)
            },
            useDefault: {
                _ = coordinator.useDefault()
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudioPalette.carbon)
    }
}

@main
enum WatercolorStudioMain {
    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--qualify-customer-input") {
            do {
                try await ReleasePerformanceQualification.run()
            } catch {
                FileHandle.standardError.write(
                    Data("Watercolor qualification failed: \(error)\n".utf8)
                )
                Foundation.exit(EXIT_FAILURE)
            }
            return
        }
        // The launch experience is intentionally non-document-first. Ignore
        // AppKit's persisted window restoration so a prior force-quit cannot
        // block the explicit New Canvas launch window.
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        WatercolorStudioApp.main()
    }
}

@MainActor
final class WatercolorStudioApplicationDelegate: NSObject, NSApplicationDelegate {
    typealias SendAction = (_ selector: Selector, _ target: Any?, _ sender: Any?) -> Bool
    typealias Schedule = (_ action: @escaping @MainActor () -> Void) -> Void
    typealias HasOpenDocumentOrWindow = @MainActor () -> Bool
    typealias PresentNewCanvas = @MainActor () -> Void

    private enum UntitledRequestState {
        case notRequested
        case requesting
        case requested
    }

    private let sendAction: SendAction
    private let schedule: Schedule
    private let hasOpenDocumentOrWindow: HasOpenDocumentOrWindow
    private let presentNewCanvas: PresentNewCanvas
    private var untitledRequestState = UntitledRequestState.notRequested

    override convenience init() {
        self.init(
            sendAction: { selector, target, sender in
                NSApplication.shared.sendAction(selector, to: target, from: sender)
            },
            schedule: { action in DispatchQueue.main.async { action() } },
            hasOpenDocumentOrWindow: Self.liveHasOpenDocumentOrWindow,
            presentNewCanvas: { NewCanvasWindowPresenter.shared.show() }
        )
    }

    init(
        sendAction: @escaping SendAction,
        schedule: @escaping Schedule = { action in
            DispatchQueue.main.async {
                action()
            }
        },
        hasOpenDocumentOrWindow: @escaping HasOpenDocumentOrWindow =
            WatercolorStudioApplicationDelegate.liveHasOpenDocumentOrWindow,
        presentNewCanvas: @escaping PresentNewCanvas = { NewCanvasWindowPresenter.shared.show() }
    ) {
        self.sendAction = sendAction
        self.schedule = schedule
        self.hasOpenDocumentOrWindow = hasOpenDocumentOrWindow
        self.presentNewCanvas = presentNewCanvas
        super.init()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    // This studio intentionally owns its document launch flow. Restoring a
    // stale SwiftUI document window after a force-quit can leave AppKit at a
    // recovery alert before DocumentGroup creates the in-app canvas setup.
    func applicationShouldRestoreState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreSecureState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The SwiftUI app initializer owns the first-run surface.
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Intentionally do not manufacture a document or window here.
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        schedule { [weak self] in
            self?.closeStartupOpenPanels()
            self?.presentNewCanvas()
        }
    }

    private func closeStartupOpenPanels() {
        for window in NSApplication.shared.windows where window is NSOpenPanel || window.title == "Open" {
            window.close()
        }
    }

    private static func liveHasOpenDocumentOrWindow() -> Bool {
        !NSDocumentController.shared.documents.isEmpty
            || NSApplication.shared.windows.contains { window in
                window.isVisible && !(window is NSPanel)
            }
    }

    private func requestUntitledDocument() -> Bool {
        guard untitledRequestState == .notRequested else { return true }
        untitledRequestState = .requesting
        let opened = sendAction(
            #selector(NSDocumentController.newDocument(_:)),
            NSDocumentController.shared,
            nil
        )
        untitledRequestState = opened ? .requested : .notRequested
        return opened
    }
}

@MainActor
final class InitialDocumentFlowCoordinator: ObservableObject {
    typealias Schedule = (_ action: @escaping @MainActor () -> Void) -> Void
    typealias RequestSaveAs = @MainActor () -> Bool

    private enum State {
        case existingDocument
        case configuring
        case awaitingConfigurationDismissal
        case pendingInitialSave
        case completed
    }

    @Published private var state: State
    @Published private(set) var initialSaveFailure: StudioFailure?
    private let schedule: Schedule
    private let requestSaveAs: RequestSaveAs
    private var saveRequestIsScheduled = false

    init(
        needsInitialConfiguration: Bool,
        schedule: @escaping Schedule,
        requestSaveAs: @escaping RequestSaveAs
    ) {
        state = needsInitialConfiguration ? .configuring : .existingDocument
        initialSaveFailure = nil
        self.schedule = schedule
        self.requestSaveAs = requestSaveAs
    }

    var presentsConfiguration: Bool {
        state == .configuring
    }

    var hasPendingInitialSave: Bool {
        state == .pendingInitialSave
    }

    func requestInitialSaveAsAfterAppearance() {
        guard state == .existingDocument else { return }
        state = .pendingInitialSave
        schedulePendingSaveRequest()
    }

    func configurationSucceeded() {
        guard state == .configuring else { return }
        state = .awaitingConfigurationDismissal
    }

    func configurationFailed() {
        // A failed allocation leaves the in-app configuration in place.
    }

    func configurationSheetDidDismiss() {
        guard state == .awaitingConfigurationDismissal else { return }
        state = .pendingInitialSave
        schedulePendingSaveRequest()
    }

    func retryInitialSaveAs() {
        guard state == .pendingInitialSave else { return }
        initialSaveFailure = nil
        schedulePendingSaveRequest()
    }

    func dismissInitialSaveFailure() {
        initialSaveFailure = nil
    }

    private func schedulePendingSaveRequest() {
        guard state == .pendingInitialSave, !saveRequestIsScheduled else { return }
        saveRequestIsScheduled = true
        schedule { [weak self] in
            self?.performPendingSaveRequest()
        }
    }

    private func performPendingSaveRequest() {
        guard state == .pendingInitialSave else {
            saveRequestIsScheduled = false
            return
        }
        let requested = requestSaveAs()
        saveRequestIsScheduled = false
        if requested {
            state = .completed
            initialSaveFailure = nil
        } else {
            initialSaveFailure = StudioFailure(
                message: "Watercolor Studio could not open Save As for this painting. Try again, or choose File > Save As."
            )
        }
    }
}

@MainActor
struct NativeDocumentSaveAsRequester {
    typealias SendAction = (_ selector: Selector, _ target: Any?, _ sender: Any?) -> Bool
    typealias WindowProvider = @MainActor () -> NSWindow?
    typealias DocumentForWindow = @MainActor (NSWindow) -> NSDocument?
    typealias FocusWindow = @MainActor (NSWindow) -> Void

    private let owningWindow: WindowProvider
    private let documentForWindow: DocumentForWindow
    private let focusWindow: FocusWindow
    private let sendAction: SendAction

    init(
        owningWindow: @escaping WindowProvider,
        documentForWindow: @escaping DocumentForWindow = {
            NSDocumentController.shared.document(for: $0)
        },
        focusWindow: @escaping FocusWindow = { $0.makeKey() },
        sendAction: @escaping SendAction = { selector, target, sender in
            NSApplication.shared.sendAction(selector, to: target, from: sender)
        }
    ) {
        self.owningWindow = owningWindow
        self.documentForWindow = documentForWindow
        self.focusWindow = focusWindow
        self.sendAction = sendAction
    }

    @discardableResult
    func request() -> Bool {
        guard let window = owningWindow(), !(window is NSPanel),
              let document = documentForWindow(window)
        else { return false }
        focusWindow(window)
        return sendAction(#selector(NSDocument.saveAs(_:)), document, nil)
    }
}

@MainActor
final class StudioDocumentWindowLocator: ObservableObject {
    private weak var owner: StudioDocumentWindowProbe?
    private(set) weak var window: NSWindow?

    fileprivate func receive(window: NSWindow?, from owner: StudioDocumentWindowProbe) {
        if let window {
            self.owner = owner
            self.window = window
        } else if self.owner === owner {
            self.owner = nil
            self.window = nil
        }
    }
}

@MainActor
final class StudioDocumentWindowProbe: NSView {
    private weak var locator: StudioDocumentWindowLocator?

    init(locator: StudioDocumentWindowLocator) {
        self.locator = locator
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        locator?.receive(window: window, from: self)
    }
}

private struct StudioDocumentWindowReader: NSViewRepresentable {
    let locator: StudioDocumentWindowLocator

    func makeNSView(context: Context) -> StudioDocumentWindowProbe {
        StudioDocumentWindowProbe(locator: locator)
    }

    func updateNSView(_ nsView: StudioDocumentWindowProbe, context: Context) {}
}

struct StudioDocumentView: View {
    @Binding private var document: PaintingDocument
    @StateObject private var host: StudioDocumentHost
    @StateObject private var initialDocumentFlow: InitialDocumentFlowCoordinator
    @StateObject private var documentWindowLocator: StudioDocumentWindowLocator
    @StateObject private var mcpController: MCPDrawingController
    init(
        document: Binding<PaintingDocument>,
        scheduleInitialSaveAs: @escaping InitialDocumentFlowCoordinator.Schedule = { action in
            DispatchQueue.main.async { action() }
        },
        requestInitialSaveAs: @escaping @MainActor (NSWindow?) -> Bool = { owningWindow in
            NativeDocumentSaveAsRequester(owningWindow: { owningWindow }).request()
        }
    ) {
        let windowLocator = StudioDocumentWindowLocator()
        _document = document
        _host = StateObject(wrappedValue: StudioDocumentHost(document: document))
        _documentWindowLocator = StateObject(wrappedValue: windowLocator)
        _initialDocumentFlow = StateObject(
            wrappedValue: InitialDocumentFlowCoordinator(
                needsInitialConfiguration: document.wrappedValue.needsInitialConfiguration,
                schedule: scheduleInitialSaveAs,
                requestSaveAs: { requestInitialSaveAs(windowLocator.window) }
            )
        )
        _mcpController = StateObject(wrappedValue: MCPDrawingController())
    }

    var body: some View {
        Group {
            if let model = host.model {
                StudioView(model: model, mcpController: mcpController)
                    .onAppear {
                        mcpController.attach(model: model)
                    }
                    .onDisappear { mcpController.setEnabled(false) }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 26))
                    Text("Watercolor Studio could not open this painting")
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                    Text(host.failure?.message ?? "The renderer is unavailable.")
                        .foregroundStyle(StudioPalette.graphite)
                    if let failure = host.failure {
                        Text(failure.recoverySuggestion)
                            .foregroundStyle(StudioPalette.graphite)
                        HStack {
                            Button("Try Again") {
                                _ = host.retryRendererInitialization()
                            }
                            .keyboardShortcut(.defaultAction)
                            Button("Copy Details") {
                                host.copyDetails(for: failure)
                            }
                        }
                    }
                }
                .foregroundStyle(StudioPalette.fiber)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(StudioPalette.carbon)
                .frame(minWidth: 1_050, minHeight: 680)
            }
        }
        .onChange(of: document.project) { _, project in
            host.receiveDocumentProject(project)
        }
        .background(StudioDocumentWindowReader(locator: documentWindowLocator))
        .alert(item: failureBinding) { failure in
            if initialDocumentFlow.initialSaveFailure?.id == failure.id {
                Alert(
                    title: Text("Choose a save location"),
                    message: Text(failure.message),
                    primaryButton: .default(Text("Try Again")) {
                        initialDocumentFlow.retryInitialSaveAs()
                    },
                    secondaryButton: .cancel(Text("Not Now")) {
                        initialDocumentFlow.dismissInitialSaveFailure()
                    }
                )
            } else {
                Alert(
                    title: Text("Studio issue"),
                    message: Text("\(failure.message)\n\n\(failure.recoverySuggestion)"),
                    primaryButton: .default(Text("Copy Details")) {
                        host.copyDetails(for: failure)
                        host.dismissFailure()
                    },
                    secondaryButton: .cancel(Text("Dismiss")) {
                        host.dismissFailure()
                    }
                )
            }
        }
        .sheet(isPresented: configurationPresentation, onDismiss: {
            initialDocumentFlow.configurationSheetDidDismiss()
        }) {
            NewCanvasConfigurationView(
                failure: host.failure,
                copyDetails: { failure in host.copyDetails(for: failure) },
                dismissFailure: { host.dismissFailure() },
                create: { configuration in
                    if host.configureNewDocument(configuration) {
                        initialDocumentFlow.configurationSucceeded()
                    } else {
                        initialDocumentFlow.configurationFailed()
                    }
                },
                useDefault: {
                    if host.useDefaultCanvas() {
                        initialDocumentFlow.configurationSucceeded()
                    } else {
                        initialDocumentFlow.configurationFailed()
                    }
                }
            )
        }
    }

    private var configurationPresentation: Binding<Bool> {
        Binding(
            get: { initialDocumentFlow.presentsConfiguration },
            set: { _ in }
        )
    }

    private var failureBinding: Binding<StudioFailure?> {
        Binding(
            get: {
                if let initialSaveFailure = initialDocumentFlow.initialSaveFailure {
                    return initialSaveFailure
                }
                if initialDocumentFlow.presentsConfiguration, host.model != nil {
                    return nil
                }
                if host.model == nil {
                    return nil
                }
                return host.failure
            },
            set: { value in
                if value == nil {
                    if initialDocumentFlow.initialSaveFailure != nil {
                        initialDocumentFlow.dismissInitialSaveFailure()
                    } else {
                        host.dismissFailure()
                    }
                }
            }
        )
    }
}

@MainActor
final class StudioDocumentHost: ObservableObject {
    typealias ModelFactory = (
        _ project: PaintingProject,
        _ onDocumentUpdate: @escaping (PaintingProject) -> Void
    ) throws -> StudioModel
    typealias DiagnosticWriter = (String) -> Void

    @Published private(set) var model: StudioModel?
    @Published private(set) var failure: StudioFailure?
    private var failureSubscription: AnyCancellable?
    private let document: Binding<PaintingDocument>
    private let modelFactory: ModelFactory
    private let diagnosticWriter: DiagnosticWriter

    init(
        document: Binding<PaintingDocument>,
        modelFactory: @escaping ModelFactory = { project, onDocumentUpdate in
            try StudioModel(project: project, onDocumentUpdate: onDocumentUpdate)
        },
        diagnosticWriter: @escaping DiagnosticWriter = { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    ) {
        self.document = document
        self.modelFactory = modelFactory
        self.diagnosticWriter = diagnosticWriter
        model = nil
        failure = nil
        failureSubscription = nil
        _ = initializeRenderer()
    }

    var canRetryRendererInitialization: Bool {
        model == nil
    }

    @discardableResult
    func retryRendererInitialization() -> Bool {
        guard model == nil else { return false }
        return initializeRenderer()
    }

    @discardableResult
    private func initializeRenderer(project requestedProject: PaintingProject? = nil) -> Bool {
        let initializationProject = requestedProject ?? document.wrappedValue.project
        do {
            let createdModel = try modelFactory(
                initializationProject,
                { [weak self] project in
                    guard let self,
                          self.document.wrappedValue.project != project
                    else { return }
                    self.document.wrappedValue.project = project
                }
            )
            model = createdModel
            failure = nil
            failureSubscription = createdModel.$error.sink { [weak self] failure in
                self?.failure = failure
            }
            return true
        } catch {
            model = nil
            failureSubscription = nil
            failure = StudioFailure.rendererInitialization(
                error: error,
                project: initializationProject
            )
            return false
        }
    }

    func receiveDocumentProject(_ project: PaintingProject) {
        guard model?.project != project else { return }
        model?.replaceProjectFromDocument(project)
    }

    @discardableResult
    func configureNewDocument(_ configuration: NewCanvasConfiguration) -> Bool {
        do {
            let project = try configuration.makeProject()
            let isReady: Bool
            if let model {
                isReady = model.replaceProjectFromDocument(project)
            } else {
                isReady = initializeRenderer(project: project)
            }
            guard isReady else {
                if failure == nil {
                    failure = StudioFailure(
                        error: RendererError.allocation("new canvas"),
                        project: document.wrappedValue.project
                    )
                }
                return false
            }
            var configuredDocument = document.wrappedValue
            configuredDocument.project = project
            configuredDocument.needsInitialConfiguration = false
            document.wrappedValue = configuredDocument
            failure = nil
            return true
        } catch {
            failure = StudioFailure(error: error, project: document.wrappedValue.project)
            return false
        }
    }

    @discardableResult
    func useDefaultCanvas() -> Bool {
        guard model != nil || initializeRenderer() else { return false }
        var configuredDocument = document.wrappedValue
        configuredDocument.needsInitialConfiguration = false
        document.wrappedValue = configuredDocument
        failure = nil
        return true
    }

    func dismissFailure() {
        model?.dismissError()
        failure = nil
    }

    func copyDetails(for failure: StudioFailure) {
        diagnosticWriter(failure.diagnostic.customerText)
    }
}
