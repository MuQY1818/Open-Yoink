import SwiftUI
import XCTest
@testable import OpenYoink

@MainActor
final class IslandModuleContainerTests: XCTestCase {
    func testLifecycleIsIdempotentAndDisabledRuntimeStops() {
        let runtime = RuntimeSpy(id: .timer)
        let coordinator = IslandActivityCoordinator()
        let container = makeContainer(runtime: runtime, coordinator: coordinator)
        let enabled = IslandModuleConfiguration(
            enabledModuleIDs: [.timer], pinnedModuleIDs: [.timer]
        )

        container.apply(configuration: enabled, isActive: true)
        container.apply(configuration: enabled, isActive: true)
        XCTAssertEqual(runtime.startCount, 1)

        container.apply(configuration: .init(enabledModuleIDs: [], pinnedModuleIDs: []),
                        isActive: true)
        container.apply(configuration: .init(enabledModuleIDs: [], pinnedModuleIDs: []),
                        isActive: true)
        XCTAssertEqual(runtime.stopCount, 1)
    }

    func testEventsAreConsumedAndCancelledOnStop() async {
        let runtime = RuntimeSpy(id: .timer)
        let coordinator = IslandActivityCoordinator()
        let container = makeContainer(runtime: runtime, coordinator: coordinator)
        let enabled = IslandModuleConfiguration(
            enabledModuleIDs: [.timer], pinnedModuleIDs: []
        )
        container.apply(configuration: enabled, isActive: true)
        runtime.publish(.publishActivity(activity(id: "first")))
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(coordinator.activities["first"]?.moduleID, .timer)

        container.stopAll()
        runtime.publish(.publishActivity(activity(id: "late")))
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(coordinator.activities["first"])
        XCTAssertNil(coordinator.activities["late"])
    }

    func testRuntimeCannotPublishActivityForAnotherModule() async {
        let runtime = RuntimeSpy(id: .timer)
        let coordinator = IslandActivityCoordinator()
        let container = makeContainer(runtime: runtime, coordinator: coordinator)
        container.apply(configuration: .init(enabledModuleIDs: [.timer], pinnedModuleIDs: []),
                        isActive: true)
        runtime.publish(.publishActivity(.init(
            id: "forged", moduleID: .battery, priority: .systemWarning,
            title: "Forged", detail: nil, systemImage: "xmark", expiresAt: nil
        )))
        await Task.yield()
        XCTAssertNil(coordinator.activities["forged"])
    }

    private func makeContainer(
        runtime: RuntimeSpy,
        coordinator: IslandActivityCoordinator
    ) -> IslandModuleContainer {
        IslandModuleContainer(
            registrations: [.init(
                descriptor: runtime.descriptor,
                runtime: runtime,
                makeContentView: { _ in AnyView(EmptyView()) }
            )],
            coordinator: coordinator
        )
    }

    private func activity(id: String) -> IslandActivity {
        .init(id: id, moduleID: .timer, priority: .timerFinished,
              title: id, detail: nil, systemImage: "timer", expiresAt: nil)
    }
}

@MainActor
private final class RuntimeSpy: IslandModuleRuntime {
    let descriptor: IslandModuleDescriptor
    let events: AsyncStream<IslandModuleEvent>
    private let continuation: AsyncStream<IslandModuleEvent>.Continuation
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(id: IslandModuleID) {
        descriptor = .init(id: id, title: id.rawValue,
                           systemImage: "circle", order: 0, isCore: false)
        var captured: AsyncStream<IslandModuleEvent>.Continuation?
        events = AsyncStream { captured = $0 }
        continuation = captured!
    }

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func publish(_ event: IslandModuleEvent) { continuation.yield(event) }
}
