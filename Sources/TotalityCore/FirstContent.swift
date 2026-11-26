import Foundation

/// Holds the launch screen until each Home tile has its first content, but never past `cap`. The jobs
/// keep running after the cap; a tile then shows what it has, or its own loading or empty state.
public enum FirstContent {
    @MainActor
    public static func wait(for jobs: [@MainActor () async -> Void], cap: Duration) async {
        guard !jobs.isEmpty else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            var remaining = jobs.count
            func finish() {
                guard !finished else { return }
                finished = true
                done.resume()
            }
            for job in jobs {
                Task { @MainActor in
                    await job()
                    remaining -= 1
                    if remaining == 0 { finish() }
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: cap)
                finish()
            }
        }
    }
}
