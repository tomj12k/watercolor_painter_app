import AppKit
import Combine
import SwiftUI
import WatercolorCore

@main
struct WatercolorStudioApp: App {
    @NSApplicationDelegateAdaptor(WatercolorStudioApplicationDelegate.self)
    private var applicationDelegate

    var body: some Scene {
        DocumentGroup(newDocument: PaintingDocument()) { configuration in
            StudioDocumentView(document: configuration.$document)
        }
        .defaultSize(width: 1_220, height: 790)
        .commands {
            StudioAppCommands()
        }
    }
}

@MainActor
final class WatercolorStudioApplicationDelegate: NSObject, NSApplicationDelegate {
    typealias SendAction = (_ selector: Selector, _ target: Any?, _ sender: Any?) -> Bool
    typealias Schedule = (_ action: @escaping @MainActor () -> Void) -> Void
    typealias HasOpenDocumentOrWindow = @MainActor () -> Bool

    private enum UntitledRequestState {
        case notRequested
        case requesting
        case requested
    }

    private let sendAction: SendAction
    private let schedule: Schedule
    private let hasOpenDocumentOrWindow: HasOpenDocumentOrWindow
    private var untitledRequestState = UntitledRequestState.notRequested

    override convenience init() {
        self.init(
            sendAction: { selector, target, sender in
                NSApplication.shared.sendAction(selector, to: target, from: sender)
            },
            schedule: { action in DispatchQueue.main.async { action() } },
            hasOpenDocumentOrWindow: Self.liveHasOpenDocumentOrWindow
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
            WatercolorStudioApplicationDelegate.liveHasOpenDocumentOrWindow
    ) {
        self.sendAction = sendAction
        self.schedule = schedule
        self.hasOpenDocumentOrWindow = hasOpenDocumentOrWindow
        super.init()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        requestUntitledDocument()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        schedule { [weak self] in
            guard let self else { return }
            let hasOpenDocumentOrWindow = self.hasOpenDocumentOrWindow()
            guard !hasOpenDocumentOrWindow else { return }
            _ = self.requestUntitledDocument()
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
    private let keyWindow: WindowProvider
    private let mainWindow: WindowProvider
    private let documentForWindow: DocumentForWindow
    private let focusWindow: FocusWindow
    private let sendAction: SendAction

    init(
        owningWindow: @escaping WindowProvider,
        keyWindow: @escaping WindowProvider = { NSApplication.shared.keyWindow },
        mainWindow: @escaping WindowProvider = { NSApplication.shared.mainWindow },
        documentForWindow: @escaping DocumentForWindow = {
            NSDocumentController.shared.document(for: $0)
        },
        focusWindow: @escaping FocusWindow = { $0.makeKey() },
        sendAction: @escaping SendAction = { selector, target, sender in
            NSApplication.shared.sendAction(selector, to: target, from: sender)
        }
    ) {
        self.owningWindow = owningWindow
        self.keyWindow = keyWindow
        self.mainWindow = mainWindow
        self.documentForWindow = documentForWindow
        self.focusWindow = focusWindow
        self.sendAction = sendAction
    }

    @discardableResult
    func request() -> Bool {
        var visitedWindows = Set<ObjectIdentifier>()
        let candidates = [owningWindow(), keyWindow(), mainWindow()]
        for case let window? in candidates {
            guard !(window is NSPanel), visitedWindows.insert(ObjectIdentifier(window)).inserted,
                  let document = documentForWindow(window)
            else { continue }
            focusWindow(window)
            return sendAction(#selector(NSDocument.saveAs(_:)), document, nil)
        }
        return false
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
    }

    var body: some View {
        Group {
            if let model = host.model {
                StudioView(model: model)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 26))
                    Text("Watercolor Studio could not open this painting")
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                    Text("The renderer is unavailable.")
                        .foregroundStyle(StudioPalette.graphite)
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
                    message: Text(failure.message),
                    dismissButton: .default(Text("Dismiss")) { host.dismissFailure() }
                )
            }
        }
        .sheet(isPresented: configurationPresentation, onDismiss: {
            initialDocumentFlow.configurationSheetDidDismiss()
        }) {
            NewCanvasConfigurationView(
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
            get: { initialDocumentFlow.initialSaveFailure ?? host.failure },
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

    let model: StudioModel?
    @Published private(set) var failure: StudioFailure?
    private var failureSubscription: AnyCancellable?
    private let document: Binding<PaintingDocument>

    init(
        document: Binding<PaintingDocument>,
        modelFactory: ModelFactory = { project, onDocumentUpdate in
            try StudioModel(project: project, onDocumentUpdate: onDocumentUpdate)
        }
    ) {
        self.document = document
        failureSubscription = nil
        do {
            let createdModel = try modelFactory(
                document.wrappedValue.project,
                { project in
                    guard document.wrappedValue.project != project else { return }
                    document.wrappedValue.project = project
                }
            )
            model = createdModel
            failure = nil
            failureSubscription = createdModel.$error.sink { [weak self] failure in
                self?.failure = failure
            }
        } catch {
            model = nil
            failure = StudioFailure(message: error.localizedDescription)
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
            guard let model, model.replaceProjectFromDocument(project) else {
                if failure == nil {
                    failure = StudioFailure(message: "The new canvas could not be allocated.")
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
            failure = StudioFailure(message: error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func useDefaultCanvas() -> Bool {
        guard model != nil else { return false }
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
}
