import AppKit
import Foundation
import Testing
@testable import WatercolorStudio

@Suite @MainActor struct InitialDocumentFlowTests {
    @Test func coldLaunchRequestsAnUntitledDocumentInsteadOfAnOpenPanel() {
        let delegate = WatercolorStudioApplicationDelegate()

        #expect(delegate.applicationShouldOpenUntitledFile(.shared))
    }

    @Test func launchDoesNotRestoreStaleWindowsAfterAForceQuit() {
        let delegate = WatercolorStudioApplicationDelegate()
        #expect(!delegate.applicationShouldRestoreState(.shared))
        #expect(!delegate.applicationShouldRestoreSecureState(.shared))
    }

    @Test func coldLaunchOpensTheUntitledDocumentThroughTheStandardNewDocumentAction() {
        var receivedSelector: Selector?
        var receivedTarget: Any?
        let delegate = WatercolorStudioApplicationDelegate { selector, target, _ in
            receivedSelector = selector
            receivedTarget = target
            return true
        }

        #expect(delegate.applicationOpenUntitledFile(.shared))
        #expect(receivedSelector.map(NSStringFromSelector) == "newDocument:")
        #expect(receivedTarget is NSDocumentController)
    }

    @Test func defaultLaunchFallsBackToOpeningOneUntitledDocumentAfterStartup() {
        var receivedSelectors: [String] = []
        let delegate = WatercolorStudioApplicationDelegate(
            sendAction: { selector, _, _ in
                receivedSelectors.append(NSStringFromSelector(selector))
                return true
            },
            schedule: { action in action() }
        )
        let notification = Notification(
            name: NSApplication.didFinishLaunchingNotification,
            object: NSApplication.shared,
            userInfo: [NSApplication.launchIsDefaultUserInfoKey: true]
        )

        delegate.applicationDidFinishLaunching(notification)
        _ = delegate.applicationOpenUntitledFile(.shared)

        #expect(receivedSelectors == ["newDocument:"])
    }

    @Test func launchForAnExistingFileDoesNotCreateAnUntitledDocument() {
        var requestCount = 0
        let delegate = WatercolorStudioApplicationDelegate(
            sendAction: { _, _, _ in
                requestCount += 1
                return true
            },
            schedule: { action in action() },
            hasOpenDocumentOrWindow: { true }
        )
        let notification = Notification(
            name: NSApplication.didFinishLaunchingNotification,
            object: NSApplication.shared,
            userInfo: [NSApplication.launchIsDefaultUserInfoKey: false]
        )

        delegate.applicationDidFinishLaunching(notification)

        #expect(requestCount == 0)
    }

    @Test func nondefaultLaunchWithoutAFileStillOpensOneUntitledDocument() {
        var receivedSelectors: [String] = []
        let delegate = WatercolorStudioApplicationDelegate(
            sendAction: { selector, _, _ in
                receivedSelectors.append(NSStringFromSelector(selector))
                return true
            },
            schedule: { action in action() },
            hasOpenDocumentOrWindow: { false }
        )
        let notification = Notification(
            name: NSApplication.didFinishLaunchingNotification,
            object: NSApplication.shared,
            userInfo: [NSApplication.launchIsDefaultUserInfoKey: false]
        )

        delegate.applicationDidFinishLaunching(notification)
        _ = delegate.applicationOpenUntitledFile(.shared)

        #expect(receivedSelectors == ["newDocument:"])
    }

    @Test func successfulCreateRequestsSaveAsOnceAfterTheConfigurationSheetDismisses() {
        var scheduledActions: [@MainActor () -> Void] = []
        var saveAsRequestCount = 0
        let flow = InitialDocumentFlowCoordinator(
            needsInitialConfiguration: true,
            schedule: { scheduledActions.append($0) },
            requestSaveAs: {
                saveAsRequestCount += 1
                return true
            }
        )

        #expect(flow.presentsConfiguration)
        flow.configurationSucceeded()

        #expect(!flow.presentsConfiguration)
        #expect(saveAsRequestCount == 0)

        flow.configurationSheetDidDismiss()

        #expect(scheduledActions.count == 1)
        #expect(saveAsRequestCount == 0)
        scheduledActions.removeFirst()()

        flow.configurationSheetDidDismiss()

        #expect(saveAsRequestCount == 1)
        #expect(!flow.hasPendingInitialSave)
    }

    @Test func successfulUseDefaultRequestsSaveAsOnceAfterTheConfigurationSheetDismisses() {
        var scheduledActions: [@MainActor () -> Void] = []
        var saveAsRequestCount = 0
        let flow = InitialDocumentFlowCoordinator(
            needsInitialConfiguration: true,
            schedule: { scheduledActions.append($0) },
            requestSaveAs: {
                saveAsRequestCount += 1
                return true
            }
        )

        flow.configurationSucceeded()
        flow.configurationSheetDidDismiss()
        scheduledActions.removeFirst()()
        flow.configurationSheetDidDismiss()

        #expect(saveAsRequestCount == 1)
    }

    @Test func allocationFailureKeepsConfigurationActiveAndNeverRequestsSaveAs() {
        var scheduledActions: [@MainActor () -> Void] = []
        var saveAsRequestCount = 0
        let flow = InitialDocumentFlowCoordinator(
            needsInitialConfiguration: true,
            schedule: { scheduledActions.append($0) },
            requestSaveAs: {
                saveAsRequestCount += 1
                return true
            }
        )

        flow.configurationFailed()
        flow.configurationSheetDidDismiss()

        #expect(flow.presentsConfiguration)
        #expect(scheduledActions.isEmpty)
        #expect(saveAsRequestCount == 0)
    }

    @Test func anOpenedDocumentBypassesConfigurationAndInitialSaveAs() {
        var scheduledActions: [@MainActor () -> Void] = []
        var saveAsRequestCount = 0
        let flow = InitialDocumentFlowCoordinator(
            needsInitialConfiguration: false,
            schedule: { scheduledActions.append($0) },
            requestSaveAs: {
                saveAsRequestCount += 1
                return true
            }
        )

        flow.configurationSucceeded()
        flow.configurationSheetDidDismiss()

        #expect(!flow.presentsConfiguration)
        #expect(scheduledActions.isEmpty)
        #expect(saveAsRequestCount == 0)
    }

    @Test func failedSaveAsRoutingStaysPendingAndASuccessfulRetryCompletesExactlyOnce() {
        var scheduledActions: [@MainActor () -> Void] = []
        var outcomes = [false, true]
        var requestCount = 0
        let flow = InitialDocumentFlowCoordinator(
            needsInitialConfiguration: true,
            schedule: { scheduledActions.append($0) },
            requestSaveAs: {
                requestCount += 1
                return outcomes.removeFirst()
            }
        )

        flow.configurationSucceeded()
        flow.configurationSheetDidDismiss()
        scheduledActions.removeFirst()()

        #expect(flow.hasPendingInitialSave)
        #expect(flow.initialSaveFailure != nil)
        #expect(requestCount == 1)

        flow.retryInitialSaveAs()
        #expect(scheduledActions.count == 1)
        scheduledActions.removeFirst()()

        #expect(!flow.hasPendingInitialSave)
        #expect(flow.initialSaveFailure == nil)
        #expect(requestCount == 2)

        flow.retryInitialSaveAs()
        flow.configurationSheetDidDismiss()
        #expect(scheduledActions.isEmpty)
        #expect(requestCount == 2)
    }

    @Test func repeatedDismissalsWhileSaveAsIsScheduledCannotQueueDuplicatePanels() {
        var scheduledActions: [@MainActor () -> Void] = []
        var requestCount = 0
        let flow = InitialDocumentFlowCoordinator(
            needsInitialConfiguration: true,
            schedule: { scheduledActions.append($0) },
            requestSaveAs: {
                requestCount += 1
                return true
            }
        )

        flow.configurationSucceeded()
        flow.configurationSheetDidDismiss()
        flow.configurationSheetDidDismiss()

        #expect(scheduledActions.count == 1)
        scheduledActions.removeFirst()()
        #expect(requestCount == 1)
    }

    @Test func nativeSaveRequesterFocusesOwningWindowAndTargetsItsDocument() {
        var receivedSelector: Selector?
        var receivedTarget: Any?
        var receivedSenderWasNil = false
        var focusedWindow: NSWindow?
        let owningWindow = NSWindow()
        let document = NSDocument()
        let requester = NativeDocumentSaveAsRequester(
            owningWindow: { owningWindow },
            documentForWindow: { $0 === owningWindow ? document : nil },
            focusWindow: { focusedWindow = $0 },
            sendAction: { selector, target, sender in
                receivedSelector = selector
                receivedTarget = target
                receivedSenderWasNil = sender == nil
                return true
            }
        )

        #expect(requester.request())
        #expect(receivedSelector.map(NSStringFromSelector) == "saveDocumentAs:")
        #expect(receivedTarget as? NSDocument === document)
        #expect(receivedSenderWasNil)
        #expect(focusedWindow === owningWindow)
    }

    @Test func missingOwnerNeverFallsBackToKeyOrMainDocument() {
        let keyWindowForPaintingB = NSWindow()
        let paintingB = NSDocument()
        let paintingBWindowController = NSWindowController(window: keyWindowForPaintingB)
        paintingB.addWindowController(paintingBWindowController)
        NSDocumentController.shared.addDocument(paintingB)
        keyWindowForPaintingB.makeKeyAndOrderFront(nil)
        keyWindowForPaintingB.makeMain()
        defer {
            keyWindowForPaintingB.orderOut(nil)
            NSDocumentController.shared.removeDocument(paintingB)
        }
        var receivedTarget: Any?
        let requester = NativeDocumentSaveAsRequester(
            owningWindow: { nil },
            focusWindow: { _ in },
            sendAction: { _, target, _ in
                receivedTarget = target
                return true
            }
        )

        #expect(!requester.request())
        #expect(receivedTarget == nil)
    }

    @Test func ownerForPaintingATakesIdentityOverKeyAndMainPaintingB() {
        let ownerWindowForPaintingA = NSWindow()
        let keyWindowForPaintingB = NSWindow()
        let paintingA = NSDocument()
        let paintingB = NSDocument()
        let paintingBWindowController = NSWindowController(window: keyWindowForPaintingB)
        paintingB.addWindowController(paintingBWindowController)
        NSDocumentController.shared.addDocument(paintingB)
        keyWindowForPaintingB.makeKeyAndOrderFront(nil)
        keyWindowForPaintingB.makeMain()
        defer {
            keyWindowForPaintingB.orderOut(nil)
            NSDocumentController.shared.removeDocument(paintingB)
        }
        var resolvedWindows: [NSWindow] = []
        var receivedTarget: Any?
        let requester = NativeDocumentSaveAsRequester(
            owningWindow: { ownerWindowForPaintingA },
            documentForWindow: { window in
                resolvedWindows.append(window)
                return window === ownerWindowForPaintingA ? paintingA : paintingB
            },
            focusWindow: { _ in },
            sendAction: { _, target, _ in
                receivedTarget = target
                return true
            }
        )

        #expect(requester.request())
        #expect(resolvedWindows.count == 1)
        #expect(resolvedWindows.first === ownerWindowForPaintingA)
        #expect(receivedTarget as? NSDocument === paintingA)
        #expect(receivedTarget as? NSDocument !== paintingB)
    }

    @Test func nativeSaveRequesterReturnsFalseWhenNoDocumentOwnsAnyCandidateWindow() {
        var sentAction = false
        let requester = NativeDocumentSaveAsRequester(
            owningWindow: { NSWindow() },
            documentForWindow: { _ in nil },
            focusWindow: { _ in },
            sendAction: { _, _, _ in
                sentAction = true
                return true
            }
        )

        #expect(!requester.request())
        #expect(!sentAction)
    }

    @Test func mountedWindowProbeSuppliesTheOwningWindowBeforeDismissalSchedulingRuns() {
        let locator = StudioDocumentWindowLocator()
        let probe = StudioDocumentWindowProbe(locator: locator)
        let window = NSWindow()
        window.contentView = probe
        var scheduledActions: [@MainActor () -> Void] = []
        var requestedWindow: NSWindow?
        let flow = InitialDocumentFlowCoordinator(
            needsInitialConfiguration: true,
            schedule: { scheduledActions.append($0) },
            requestSaveAs: {
                requestedWindow = locator.window
                return locator.window != nil
            }
        )

        flow.configurationSucceeded()
        flow.configurationSheetDidDismiss()

        #expect(requestedWindow == nil)
        #expect(scheduledActions.count == 1)
        scheduledActions.removeFirst()()
        #expect(requestedWindow === window)
        #expect(!flow.hasPendingInitialSave)
    }

    @Test func ownerDetachedBeforeScheduledSaveCannotRedirectToAnotherPainting() {
        let locator = StudioDocumentWindowLocator()
        let probe = StudioDocumentWindowProbe(locator: locator)
        let ownerWindowForPaintingA = NSWindow()
        ownerWindowForPaintingA.contentView = probe
        let keyWindowForPaintingB = NSWindow()
        let paintingB = NSDocument()
        let paintingBWindowController = NSWindowController(window: keyWindowForPaintingB)
        paintingB.addWindowController(paintingBWindowController)
        NSDocumentController.shared.addDocument(paintingB)
        keyWindowForPaintingB.makeKeyAndOrderFront(nil)
        keyWindowForPaintingB.makeMain()
        defer {
            keyWindowForPaintingB.orderOut(nil)
            NSDocumentController.shared.removeDocument(paintingB)
        }
        var scheduledActions: [@MainActor () -> Void] = []
        var receivedTarget: Any?
        let requester = NativeDocumentSaveAsRequester(
            owningWindow: { locator.window },
            documentForWindow: { $0 === keyWindowForPaintingB ? paintingB : nil },
            focusWindow: { _ in },
            sendAction: { _, target, _ in
                receivedTarget = target
                return true
            }
        )
        let flow = InitialDocumentFlowCoordinator(
            needsInitialConfiguration: true,
            schedule: { scheduledActions.append($0) },
            requestSaveAs: { requester.request() }
        )

        flow.configurationSucceeded()
        flow.configurationSheetDidDismiss()
        ownerWindowForPaintingA.contentView = NSView()
        scheduledActions.removeFirst()()

        #expect(locator.window == nil)
        #expect(receivedTarget == nil)
        #expect(flow.hasPendingInitialSave)
        #expect(flow.initialSaveFailure != nil)
    }

    @Test func environmentGatedNativeDocumentSaveHostExercisesCancelSaveAndOverwrite() async throws {
        guard ProcessInfo.processInfo.environment["WATERCOLOR_RUN_DOCUMENT_UI_HOST"] == "1" else {
            return
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watercolor-save-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let firstURL = directory.appendingPathComponent("Initial.watercolor")
        let secondURL = directory.appendingPathComponent("Explicit Save As.watercolor")
        let document = NativeSaveAutomationDocument(payload: Data("first".utf8))
        let window = NSWindow()
        let windowController = NSWindowController(window: window)
        document.addWindowController(windowController)
        NSDocumentController.shared.addDocument(document)
        defer { NSDocumentController.shared.removeDocument(document) }
        let requester = NativeDocumentSaveAsRequester(owningWindow: { window })
        var saves = document.saveEvents.makeAsyncIterator()

        document.nextSaveAsURL = nil
        #expect(requester.request())
        #expect(document.fileURL == nil)

        document.nextSaveAsURL = firstURL
        #expect(requester.request())
        #expect(await saves.next() == .succeeded)
        #expect(document.fileURL == firstURL)
        #expect(try Data(contentsOf: firstURL) == Data("first".utf8))

        document.payload = Data("second".utf8)
        document.updateChangeCount(.changeDone)
        #expect(
            NSApplication.shared.sendAction(
                #selector(NSDocument.save(_:)),
                to: document,
                from: nil
            )
        )
        #expect(await saves.next() == .succeeded)
        #expect(document.fileURL == firstURL)
        #expect(try Data(contentsOf: firstURL) == Data("second".utf8))

        document.nextSaveAsURL = secondURL
        #expect(requester.request())
        #expect(await saves.next() == .succeeded)
        #expect(document.fileURL == secondURL)
        #expect(try Data(contentsOf: secondURL) == Data("second".utf8))

        print("Retained native save host artifacts at \(directory.path)")
    }
}

@MainActor
private final class NativeSaveAutomationDocument: NSDocument {
    enum SaveResult: Equatable, Sendable {
        case succeeded
        case failed(String)
    }

    var payload: Data
    var nextSaveAsURL: URL?
    let saveEvents: AsyncStream<SaveResult>
    private let saveEventContinuation: AsyncStream<SaveResult>.Continuation

    init(payload: Data) {
        self.payload = payload
        (saveEvents, saveEventContinuation) = AsyncStream.makeStream(of: SaveResult.self)
        super.init()
    }

    override class var autosavesInPlace: Bool { true }

    override func data(ofType typeName: String) throws -> Data {
        payload
    }

    override func saveAs(_ sender: Any?) {
        guard let nextSaveAsURL else { return }
        save(
            to: nextSaveAsURL,
            ofType: "com.watercolorstudio.painting",
            for: .saveAsOperation
        ) { _ in }
    }

    override func save(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            completionHandler(error)
            if let error {
                self?.saveEventContinuation.yield(.failed(error.localizedDescription))
            } else {
                self?.saveEventContinuation.yield(.succeeded)
            }
        }
    }
}
