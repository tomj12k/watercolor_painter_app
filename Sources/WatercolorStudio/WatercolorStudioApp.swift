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

struct InitialDocumentFlowCoordinator {
    private enum State {
        case existingDocument
        case configuring
        case awaitingConfigurationDismissal
        case saveAsRequested
    }

    private var state: State

    init(needsInitialConfiguration: Bool) {
        state = needsInitialConfiguration ? .configuring : .existingDocument
    }

    var presentsConfiguration: Bool {
        state == .configuring
    }

    mutating func configurationSucceeded() {
        guard state == .configuring else { return }
        state = .awaitingConfigurationDismissal
    }

    mutating func configurationFailed() {
        // A failed allocation leaves the in-app configuration in place.
    }

    mutating func configurationSheetDidDismiss(requestSaveAs: () -> Void) {
        guard state == .awaitingConfigurationDismissal else { return }
        state = .saveAsRequested
        requestSaveAs()
    }
}

@MainActor
struct NativeDocumentSaveAsRequester {
    typealias SendAction = (_ selector: Selector, _ target: Any?, _ sender: Any?) -> Bool

    private let sendAction: SendAction

    init(sendAction: @escaping SendAction = { selector, target, sender in
        NSApplication.shared.sendAction(selector, to: target, from: sender)
    }) {
        self.sendAction = sendAction
    }

    @discardableResult
    func request() -> Bool {
        sendAction(#selector(NSDocument.saveAs(_:)), nil, nil)
    }
}

struct StudioDocumentView: View {
    @Binding private var document: PaintingDocument
    @StateObject private var host: StudioDocumentHost
    @State private var initialDocumentFlow: InitialDocumentFlowCoordinator
    private let requestInitialSaveAs: @MainActor () -> Void

    init(
        document: Binding<PaintingDocument>,
        requestInitialSaveAs: @escaping @MainActor () -> Void = {
            NativeDocumentSaveAsRequester().request()
        }
    ) {
        _document = document
        _host = StateObject(wrappedValue: StudioDocumentHost(document: document))
        _initialDocumentFlow = State(
            initialValue: InitialDocumentFlowCoordinator(
                needsInitialConfiguration: document.wrappedValue.needsInitialConfiguration
            )
        )
        self.requestInitialSaveAs = requestInitialSaveAs
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
        .alert(item: failureBinding) { failure in
            Alert(
                title: Text("Studio issue"),
                message: Text(failure.message),
                dismissButton: .default(Text("Dismiss")) { host.dismissFailure() }
            )
        }
        .sheet(isPresented: configurationPresentation, onDismiss: {
            initialDocumentFlow.configurationSheetDidDismiss {
                requestInitialSaveAs()
            }
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
            get: { host.failure },
            set: { value in
                if value == nil { host.dismissFailure() }
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
