import Foundation
import Network

struct PhysicalPath {
    let interface: NWInterface
    let generation: UInt64
}

/// All state belongs to the helper's one serial network queue.
final class PhysicalNetwork {
    private let queue: DispatchQueue
    private let preferredName: String?
    private let monitors: [(NWInterface.InterfaceType, NWPathMonitor)]
    private var candidates: [NWInterface.InterfaceType: NWPath] = [:]
    private(set) var current: PhysicalPath?
    private var generation: UInt64 = 0
    var onChange: (() -> Void)?

    init(queue: DispatchQueue, preferredName: String?) {
        self.queue = queue
        self.preferredName = preferredName
        monitors = [(.wiredEthernet, NWPathMonitor(requiredInterfaceType: .wiredEthernet)),
                    (.wifi, NWPathMonitor(requiredInterfaceType: .wifi))]
    }

    func start() {
        for (kind, monitor) in monitors {
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                self.candidates[kind] = path
                self.generation &+= 1
                let selected = [NWInterface.InterfaceType.wiredEthernet, .wifi].compactMap { type -> NWInterface? in
                    guard let candidate = self.candidates[type], candidate.status == .satisfied else { return nil }
                    return candidate.availableInterfaces.first {
                        $0.type == type && (self.preferredName == nil || $0.name == self.preferredName)
                    }
                }.first
                self.current = selected.map { PhysicalPath(interface: $0, generation: self.generation) }
                self.onChange?()
            }
            monitor.start(queue: queue)
        }
    }
}
