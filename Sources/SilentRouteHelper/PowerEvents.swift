import Foundation
import IOKit
import IOKit.pwr_mgt

/// Sleep and wake, as the power manager reports them to a daemon. A wake
/// counts from a dark wake too (Power Nap, maintenance): the network is up
/// and sessions are used again.
final class PowerEvents: @unchecked Sendable {
    // iokit_common_msg(…): the macros themselves do not reach Swift.
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    private let onWake: @Sendable () -> Void
    private var root: io_connect_t = 0
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init?(queue: DispatchQueue, onWake: @escaping @Sendable () -> Void) {
        self.onWake = onWake
        let me = Unmanaged.passUnretained(self).toOpaque()
        root = IORegisterForSystemPower(me, &port, { refcon, _, type, argument in
            guard let refcon else { return }
            Unmanaged<PowerEvents>.fromOpaque(refcon).takeUnretainedValue().handle(type, argument)
        }, &notifier)
        guard root != 0, let port else { return nil }
        IONotificationPortSetDispatchQueue(port, queue)
    }

    private func handle(_ type: UInt32, _ argument: UnsafeMutableRawPointer?) {
        switch type {
        case Self.canSystemSleep, Self.systemWillSleep:
            // Every registered client must answer, or sleep waits 30 s for it.
            IOAllowPowerChange(root, Int(bitPattern: argument))
        case Self.systemHasPoweredOn:
            onWake()
        default:
            break
        }
    }
}
