import AppKit
import Testing
@testable import WatercolorStudio

@Suite @MainActor struct InitialDocumentFlowTests {
    @Test func coldLaunchRequestsAnUntitledDocumentInsteadOfAnOpenPanel() {
        let delegate = WatercolorStudioApplicationDelegate()

        #expect(delegate.applicationShouldOpenUntitledFile(.shared))
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
        var flow = InitialDocumentFlowCoordinator(needsInitialConfiguration: true)
        var saveAsRequestCount = 0

        #expect(flow.presentsConfiguration)
        flow.configurationSucceeded()

        #expect(!flow.presentsConfiguration)
        #expect(saveAsRequestCount == 0)

        flow.configurationSheetDidDismiss { saveAsRequestCount += 1 }
        flow.configurationSheetDidDismiss { saveAsRequestCount += 1 }

        #expect(saveAsRequestCount == 1)
    }

    @Test func successfulUseDefaultRequestsSaveAsOnceAfterTheConfigurationSheetDismisses() {
        var flow = InitialDocumentFlowCoordinator(needsInitialConfiguration: true)
        var saveAsRequestCount = 0

        flow.configurationSucceeded()
        flow.configurationSheetDidDismiss { saveAsRequestCount += 1 }
        flow.configurationSheetDidDismiss { saveAsRequestCount += 1 }

        #expect(saveAsRequestCount == 1)
    }

    @Test func allocationFailureKeepsConfigurationActiveAndNeverRequestsSaveAs() {
        var flow = InitialDocumentFlowCoordinator(needsInitialConfiguration: true)
        var saveAsRequestCount = 0

        flow.configurationFailed()
        flow.configurationSheetDidDismiss { saveAsRequestCount += 1 }

        #expect(flow.presentsConfiguration)
        #expect(saveAsRequestCount == 0)
    }

    @Test func anOpenedDocumentBypassesConfigurationAndInitialSaveAs() {
        var flow = InitialDocumentFlowCoordinator(needsInitialConfiguration: false)
        var saveAsRequestCount = 0

        flow.configurationSucceeded()
        flow.configurationSheetDidDismiss { saveAsRequestCount += 1 }

        #expect(!flow.presentsConfiguration)
        #expect(saveAsRequestCount == 0)
    }

    @Test func nativeSaveRequesterSendsTheStandardDocumentSaveAsResponderAction() {
        var receivedSelector: Selector?
        var receivedTargetWasNil = false
        var receivedSenderWasNil = false
        let requester = NativeDocumentSaveAsRequester { selector, target, sender in
            receivedSelector = selector
            receivedTargetWasNil = target == nil
            receivedSenderWasNil = sender == nil
            return true
        }

        #expect(requester.request())
        #expect(receivedSelector.map(NSStringFromSelector) == "saveDocumentAs:")
        #expect(receivedTargetWasNil)
        #expect(receivedSenderWasNil)
    }
}
