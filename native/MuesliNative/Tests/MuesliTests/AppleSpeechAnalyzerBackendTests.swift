import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Apple SpeechAnalyzer backend")
struct AppleSpeechAnalyzerBackendTests {
    @Test("volatile results do not duplicate finalized text")
    func accumulatorIgnoresVolatileResults() {
        var accumulator = AppleSpeechTranscriptAccumulator()
        accumulator.receive(text: "draft", isFinal: false, start: 0, end: 0.5)
        accumulator.receive(text: "Final words", isFinal: true, start: 0, end: 1.25)

        #expect(accumulator.text == "Final words")
        #expect(accumulator.segments.count == 1)
        #expect(accumulator.segments[0].start == 0)
        #expect(accumulator.segments[0].end == 1.25)
    }

    @Test("final segments are normalized and joined")
    func accumulatorBuildsTimestampedTranscript() {
        var accumulator = AppleSpeechTranscriptAccumulator()
        accumulator.receive(text: "  First segment ", isFinal: true, start: -1, end: 1)
        accumulator.receive(text: "Second segment  ", isFinal: true, start: 1, end: .infinity)

        #expect(accumulator.text == "First segment Second segment")
        #expect(accumulator.segments.map(\.text) == ["First segment", "Second segment"])
        #expect(accumulator.segments[0].start == 0)
        #expect(accumulator.segments[1].end == 1)
    }

    @Test("final results preserve Apple punctuation and line breaks")
    func accumulatorPreservesResultFormatting() {
        var accumulator = AppleSpeechTranscriptAccumulator()
        accumulator.receive(text: "Hello", isFinal: true, start: 0, end: 0.5)
        accumulator.receive(text: ",", isFinal: true, start: 0.5, end: 0.6)
        accumulator.receive(text: "\nNext line", isFinal: true, start: 0.6, end: 1.5)

        #expect(accumulator.text == "Hello,\nNext line")
        #expect(accumulator.segments.map(\.text) == ["Hello", ",", "Next line"])
    }

    @Test("locale resolver uses exact or language-equivalent supported locale")
    func localeResolverUsesSupportedEquivalent() async throws {
        let exactResolver = AppleSpeechLocaleResolver { locale in
            locale.identifier(.bcp47) == "en-IN" ? locale : nil
        }
        let exact = try await exactResolver.resolve(Locale(identifier: "en-IN"))
        #expect(exact.identifier(.bcp47) == "en-IN")

        let languageResolver = AppleSpeechLocaleResolver { locale in
            locale.language.languageCode?.identifier == "en" && locale.region == nil
                ? Locale(identifier: "en-US")
                : nil
        }
        let languageEquivalent = try await languageResolver.resolve(Locale(identifier: "en-IN"))
        #expect(languageEquivalent.identifier(.bcp47) == "en-US")
    }

    @Test("locale resolver rejects unsupported languages")
    func localeResolverRejectsUnsupportedLanguage() async {
        let resolver = AppleSpeechLocaleResolver { _ in nil }

        do {
            _ = try await resolver.resolve(Locale(identifier: "zz-ZZ"))
            Issue.record("Expected an unsupported-locale error")
        } catch AppleSpeechAnalyzerError.unsupportedLocale(let identifier) {
            #expect(identifier == "zz-ZZ")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("concurrent preparation requests share one operation")
    func preparationRequestsAreCoalesced() async throws {
        let cache = AppleSpeechPreparationTaskCache()
        let counter = AppleSpeechTestCounter()

        async let first = cache.value(for: "en-US") {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(100))
            return Locale(identifier: "en-US")
        }
        async let second = cache.value(for: "en-US") {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(100))
            return Locale(identifier: "en-US")
        }

        let locales = try await [first, second]
        #expect(locales.allSatisfy { $0.identifier(.bcp47) == "en-US" })
        #expect(await counter.value == 1)
    }

    @Test("cancelling one preparation waiter preserves shared work for the other")
    func cancellingOnePreparationWaiterPreservesSharedWork() async throws {
        let cache = AppleSpeechPreparationTaskCache()
        let operation = AppleSpeechControllablePreparation()

        let first = Task {
            try await cache.value(for: "en-US") {
                try await operation.run()
            }
        }
        await operation.waitUntilStarted()
        let second = Task {
            try await cache.value(for: "en-US") {
                Issue.record("Coalesced waiter unexpectedly started a second operation")
                return Locale(identifier: "en-US")
            }
        }
        await waitForWaiterCount(2, in: cache, localeIdentifier: "en-US")

        first.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await first.value
        }
        #expect(!(await operation.wasCancelled))

        await operation.succeed()
        let locale = try await second.value
        #expect(locale.identifier(.bcp47) == "en-US")
        #expect(await operation.startCount == 1)
    }

    @Test("retry waits for cancelled preparation to drain before starting")
    func retryWaitsForCancelledPreparationToDrain() async throws {
        let cache = AppleSpeechPreparationTaskCache()
        let operation = AppleSpeechControllablePreparation()
        let retryCounter = AppleSpeechTestCounter()

        let waiter = Task {
            try await cache.value(for: "en-US") {
                try await operation.run()
            }
        }
        await operation.waitUntilStarted()
        waiter.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await waiter.value
        }
        await operation.waitUntilCancelled()

        let retry = Task {
            try await cache.value(for: "en-US") {
                await retryCounter.increment()
                return Locale(identifier: "en-US")
            }
        }
        await waitForWaiterCount(1, in: cache, localeIdentifier: "en-US")
        #expect(await retryCounter.value == 0)

        await operation.finishCancellation()
        let locale = try await retry.value
        #expect(locale.identifier(.bcp47) == "en-US")
        #expect(await retryCounter.value == 1)
    }

    @Test("failed preparation is removed so a later attempt can retry")
    func failedPreparationCanRetry() async throws {
        let cache = AppleSpeechPreparationTaskCache()
        let counter = AppleSpeechTestCounter()

        do {
            _ = try await cache.value(for: "en-US") {
                await counter.increment()
                throw AppleSpeechTestError.preparationFailed
            }
            Issue.record("Expected the first preparation to fail")
        } catch AppleSpeechTestError.preparationFailed {
            // Expected path.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let locale = try await cache.value(for: "en-US") {
            await counter.increment()
            return Locale(identifier: "en-US")
        }

        #expect(locale.identifier(.bcp47) == "en-US")
        #expect(await counter.value == 2)
    }

    @Test("language preference defaults to the system locale")
    func languagePreferenceDefaultsToSystemLocale() {
        #expect(AppleSpeechLanguageOption.normalize(nil) == AppleSpeechLanguageOption.systemIdentifier)
        #expect(AppleSpeechLanguageOption.normalize("  ") == AppleSpeechLanguageOption.systemIdentifier)
        #expect(
            AppleSpeechLanguageOption.requestedLocale(for: AppleSpeechLanguageOption.systemIdentifier)
                .identifier(.bcp47) == Locale.current.identifier(.bcp47)
        )
    }

    @Test("language preference preserves an explicit locale")
    func languagePreferencePreservesExplicitLocale() {
        #expect(AppleSpeechLanguageOption.normalize(" en-US ") == "en-US")
        #expect(
            AppleSpeechLanguageOption.requestedLocale(for: "en-US").identifier(.bcp47) == "en-US"
        )
    }

    @Test("reservation reconciliation keeps only the selected locale")
    func reservationReconciliationKeepsSelectedLocale() {
        let releases = AppleSpeechReservationPolicy.localesToRelease(
            [Locale(identifier: "en-US"), Locale(identifier: "fr-FR"), Locale(identifier: "de-DE")],
            keeping: Locale(identifier: "fr-FR")
        )

        #expect(releases.map { $0.identifier(.bcp47) } == ["en-US", "de-DE"])
    }

    private func waitForWaiterCount(
        _ count: Int,
        in cache: AppleSpeechPreparationTaskCache,
        localeIdentifier: String
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while await cache.waiterCount(for: localeIdentifier) != count {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for \(count) preparation waiters")
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("backend is system managed and only catalogued when supported")
    func backendMetadata() {
        let option = BackendOption.appleSpeechAnalyzer

        #expect(option.backend == "apple-speech")
        #expect(option.isSystemManaged)
        #expect(option.supportsMeetingTranscription)
        #expect(!BackendOption.experimental.contains(option))
        if #available(macOS 26.0, *), AppleSpeechAnalyzerTranscriber.isSupportedOnCurrentSystem {
            #expect(BackendOption.systemManaged.contains(option))
            #expect(BackendOption.all.contains(option))
            // Parakeet Unified is the preferred onboarding model; Apple Speech
            // stays available in the catalog but is not the default.
            #expect(BackendOption.onboardingDefault == .parakeetUnified)
            #expect(!BackendOption.onboarding.contains(option))
        } else {
            #expect(!BackendOption.systemManaged.contains(option))
            #expect(!BackendOption.all.contains(option))
            #expect(BackendOption.onboardingDefault == .parakeetUnified)
            #expect(!BackendOption.onboarding.contains(option))
        }
    }

    @Test("supported catalogue keeps Apple Speech available without making it the default")
    func supportedCatalogue() {
        let catalog = BackendOption.catalog(appleSpeechAvailable: true)

        #expect(catalog.systemManaged == [.appleSpeechAnalyzer])
        #expect(catalog.all.contains(.appleSpeechAnalyzer))
        #expect(catalog.onboardingDefault == .parakeetUnified)
        #expect(catalog.onboarding.first == .parakeetUnified)
        #expect(!catalog.onboarding.contains(.appleSpeechAnalyzer))
    }

    @Test("unsupported catalogue falls back to Parakeet")
    func unsupportedCatalogue() {
        let catalog = BackendOption.catalog(appleSpeechAvailable: false)

        #expect(catalog.systemManaged.isEmpty)
        #expect(!catalog.all.contains(.appleSpeechAnalyzer))
        #expect(catalog.onboardingDefault == .parakeetUnified)
        #expect(!catalog.onboarding.contains(.appleSpeechAnalyzer))
    }
}

private actor AppleSpeechTestCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor AppleSpeechControllablePreparation {
    private(set) var startCount = 0
    private(set) var wasCancelled = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<Locale, Error>?
    private var pendingResult: Result<Locale, Error>?
    private var cancellationCompletion: CheckedContinuation<Void, Never>?
    private var cancellationMayFinish = false

    func run() async throws -> Locale {
        startCount += 1
        let started = startedWaiters
        startedWaiters.removeAll()
        started.forEach { $0.resume() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let pendingResult {
                    self.pendingResult = nil
                    continuation.resume(with: pendingResult)
                } else {
                    completion = continuation
                }
            }
        } onCancel: {
            Task {
                await self.noteCancellation()
                await self.waitForCancellationCompletion()
                await self.cancelOperation()
            }
        }
    }

    func waitUntilStarted() async {
        if startCount > 0 { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func waitUntilCancelled() async {
        if wasCancelled { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    func succeed() {
        complete(with: .success(Locale(identifier: "en-US")))
    }

    func finishCancellation() {
        cancellationMayFinish = true
        cancellationCompletion?.resume()
        cancellationCompletion = nil
    }

    private func noteCancellation() {
        guard !wasCancelled else { return }
        wasCancelled = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForCancellationCompletion() async {
        if cancellationMayFinish { return }
        await withCheckedContinuation { continuation in
            if cancellationMayFinish {
                continuation.resume()
            } else {
                cancellationCompletion = continuation
            }
        }
    }

    private func cancelOperation() {
        complete(with: .failure(CancellationError()))
    }

    private func complete(with result: Result<Locale, Error>) {
        if let completion {
            self.completion = nil
            completion.resume(with: result)
        } else {
            pendingResult = result
        }
    }
}

private enum AppleSpeechTestError: Error {
    case preparationFailed
}
