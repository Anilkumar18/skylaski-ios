import Foundation
import NetworkExtension
import os.log

protocol TunnelsManagerListDelegate: AnyObject {
    func tunnelAdded(at index: Int)
    func tunnelModified(at index: Int)
    func tunnelMoved(from oldIndex: Int, to newIndex: Int)
    func tunnelRemoved(at index: Int, tunnel: TunnelContainer)
}

protocol TunnelsManagerActivationDelegate: AnyObject {
    func tunnelActivationAttemptFailed(tunnel: TunnelContainer, error: TunnelsManagerActivationAttemptError) // startTunnel wasn't called or failed
    func tunnelActivationAttemptSucceeded(tunnel: TunnelContainer) // startTunnel succeeded
    func tunnelActivationFailed(tunnel: TunnelContainer, error: TunnelsManagerActivationError) // status didn't change to connected
    func tunnelActivationSucceeded(tunnel: TunnelContainer) // status changed to connected
}

class TunnelsManager {
    fileprivate var tunnels: [TunnelContainer]
    weak var tunnelsListDelegate: TunnelsManagerListDelegate?
    weak var activationDelegate: TunnelsManagerActivationDelegate?
    private var statusObservationToken: AnyObject?
    private var waiteeObservationToken: AnyObject?
    private var configurationsObservationToken: AnyObject?
    private var catalinaWorkaround: Any?

    init(tunnelProviders: [NETunnelProviderManager]) {
        tunnels = tunnelProviders.map { TunnelContainer(tunnel: $0) }.sorted { TunnelsManager.tunnelNameIsLessThan($0.name, $1.name) }
        startObservingTunnelStatuses()
        startObservingTunnelConfigurations()
        #if os(macOS)
        if #available(macOS 10.15, *) {
            self.catalinaWorkaround = CatalinaWorkaround(tunnelsManager: self)
        }
        #endif
    }

    static func create(completionHandler: @escaping (Result<TunnelsManager, TunnelsManagerError>) -> Void) {
        #if targetEnvironment(simulator)
        completionHandler(.success(TunnelsManager(tunnelProviders: MockTunnels.createMockTunnels())))
        #else
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error = error {
                wg_log(.error, message: "Failed to load tunnel provider managers: \(error)")
                completionHandler(.failure(TunnelsManagerError.systemErrorOnListingTunnels(systemError: error)))
                return
            }

            var tunnelManagers = managers ?? []
            var refs: Set<Data> = []
            var tunnelNames: Set<String> = []
            for (index, tunnelManager) in tunnelManagers.enumerated().reversed() {
                if let tunnelName = tunnelManager.localizedDescription {
                    tunnelNames.insert(tunnelName)
                }
                guard let proto = tunnelManager.protocolConfiguration as? NETunnelProviderProtocol else { continue }
                if proto.migrateConfigurationIfNeeded(called: tunnelManager.localizedDescription ?? "unknown") {
                    tunnelManager.saveToPreferences { _ in }
                }
                #if os(iOS)
                let passwordRef = proto.verifyConfigurationReference() ? proto.passwordReference : nil
                #elseif os(macOS)
                let passwordRef: Data?
                if proto.providerConfiguration?["UID"] as? uid_t == getuid() {
                    passwordRef = proto.verifyConfigurationReference() ? proto.passwordReference : nil
                } else {
                    passwordRef = proto.passwordReference // To handle multiple users in macOS, we skip verifying
                }
                #else
                #error("Unimplemented")
                #endif
                if let ref = passwordRef {
                    refs.insert(ref)
                } else {
                    wg_log(.info, message: "Removing orphaned tunnel with non-verifying keychain entry: \(tunnelManager.localizedDescription ?? "<unknown>")")
                    tunnelManager.removeFromPreferences { _ in }
                    tunnelManagers.remove(at: index)
                }
            }
            #if os(macOS)
            if #available(macOS 10.15, *) {
                // Don't delete orphaned keychain refs. We need them to restore tunnels as a workaround.
            } else {
                Keychain.deleteReferences(except: refs)
            }
            #else
            Keychain.deleteReferences(except: refs)
            #endif
            #if os(iOS)
            RecentTunnelsTracker.cleanupTunnels(except: tunnelNames)
            #endif
            completionHandler(.success(TunnelsManager(tunnelProviders: tunnelManagers)))
        }
        #endif
    }

    func reload() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let self = self else { return }

            let loadedTunnelProviders = managers ?? []

            for (index, currentTunnel) in self.tunnels.enumerated().reversed() {
                if !loadedTunnelProviders.contains(where: { $0.isEquivalentTo(currentTunnel) }) {
                    // Tunnel was deleted outside the app
                    self.tunnels.remove(at: index)
                    self.tunnelsListDelegate?.tunnelRemoved(at: index, tunnel: currentTunnel)
                }
            }
            for loadedTunnelProvider in loadedTunnelProviders {
                if let matchingTunnel = self.tunnels.first(where: { loadedTunnelProvider.isEquivalentTo($0) }) {
                    matchingTunnel.tunnelProvider = loadedTunnelProvider
                    matchingTunnel.refreshStatus()
                } else {
                    // Tunnel was added outside the app
                    if let proto = loadedTunnelProvider.protocolConfiguration as? NETunnelProviderProtocol {
                        if proto.migrateConfigurationIfNeeded(called: loadedTunnelProvider.localizedDescription ?? "unknown") {
                            loadedTunnelProvider.saveToPreferences { _ in }
                        }
                    }
                    let tunnel = TunnelContainer(tunnel: loadedTunnelProvider)
                    self.tunnels.append(tunnel)
                    self.tunnels.sort { TunnelsManager.tunnelNameIsLessThan($0.name, $1.name) }
                    self.tunnelsListDelegate?.tunnelAdded(at: self.tunnels.firstIndex(of: tunnel)!)
                }
            }
        }
    }

    func add(tunnelConfiguration: TunnelConfiguration, onDemandOption: ActivateOnDemandOption = .off, completionHandler: @escaping (Result<TunnelContainer, TunnelsManagerError>) -> Void) {
        let tunnelName = tunnelConfiguration.name ?? ""
        if tunnelName.isEmpty {
            completionHandler(.failure(TunnelsManagerError.tunnelNameEmpty))
            return
        }

        if tunnels.contains(where: { $0.name == tunnelName }) {
            completionHandler(.failure(TunnelsManagerError.tunnelAlreadyExistsWithThatName))
            return
        }

        let tunnelProviderManager = NETunnelProviderManager()
        tunnelProviderManager.setTunnelConfiguration(tunnelConfiguration)
        tunnelProviderManager.isEnabled = true

        onDemandOption.apply(on: tunnelProviderManager)

        let activeTunnel = tunnels.first { $0.status == .active || $0.status == .activating }

        tunnelProviderManager.saveToPreferences { [weak self] error in
            guard error == nil else {
                wg_log(.error, message: "Add: Saving configuration failed: \(error!)")
                (tunnelProviderManager.protocolConfiguration as? NETunnelProviderProtocol)?.destroyConfigurationReference()
                completionHandler(.failure(TunnelsManagerError.systemErrorOnAddTunnel(systemError: error!)))
                return
            }

            guard let self = self else { return }

            #if os(iOS)
            // HACK: In iOS, adding a tunnel causes deactivation of any currently active tunnel.
            // This is an ugly hack to reactivate the tunnel that has been deactivated like that.
            if let activeTunnel = activeTunnel {
                if activeTunnel.status == .inactive || activeTunnel.status == .deactivating {
                    self.startActivation(of: activeTunnel)
                }
                if activeTunnel.status == .active || activeTunnel.status == .activating {
                    activeTunnel.status = .restarting
                }
            }
            #endif

            let tunnel = TunnelContainer(tunnel: tunnelProviderManager)
            self.tunnels.append(tunnel)
            self.tunnels.sort { TunnelsManager.tunnelNameIsLessThan($0.name, $1.name) }
            self.tunnelsListDelegate?.tunnelAdded(at: self.tunnels.firstIndex(of: tunnel)!)
            completionHandler(.success(tunnel))
        }
    }

    func addMultiple(tunnelConfigurations: [TunnelConfiguration], completionHandler: @escaping (UInt, TunnelsManagerError?) -> Void) {
        addMultiple(tunnelConfigurations: ArraySlice(tunnelConfigurations), numberSuccessful: 0, lastError: nil, completionHandler: completionHandler)
    }

    private func addMultiple(tunnelConfigurations: ArraySlice<TunnelConfiguration>, numberSuccessful: UInt, lastError: TunnelsManagerError?, completionHandler: @escaping (UInt, TunnelsManagerError?) -> Void) {
        guard let head = tunnelConfigurations.first else {
            completionHandler(numberSuccessful, lastError)
            return
        }
        let tail = tunnelConfigurations.dropFirst()
        add(tunnelConfiguration: head) { [weak self, tail] result in
            DispatchQueue.main.async {
                var numberSuccessfulCount = numberSuccessful
                var lastError: TunnelsManagerError?
                switch result {
                case .failure(let error):
                    lastError = error
                case .success:
                    numberSuccessfulCount = numberSuccessful + 1
                }
                self?.addMultiple(tunnelConfigurations: tail, numberSuccessful: numberSuccessfulCount, lastError: lastError, completionHandler: completionHandler)
            }
        }
    }

    func modify(tunnel: TunnelContainer, tunnelConfiguration: TunnelConfiguration, onDemandOption: ActivateOnDemandOption, completionHandler: @escaping (TunnelsManagerError?) -> Void) {
        let tunnelName = tunnelConfiguration.name ?? ""
        if tunnelName.isEmpty {
            completionHandler(TunnelsManagerError.tunnelNameEmpty)
            return
        }

        let tunnelProviderManager = tunnel.tunnelProvider
        let oldName = tunnelProviderManager.localizedDescription ?? ""
        let isNameChanged = tunnelName != oldName
        if isNameChanged {
            guard !tunnels.contains(where: { $0.name == tunnelName }) else {
                completionHandler(TunnelsManagerError.tunnelAlreadyExistsWithThatName)
                return
            }
            tunnel.name = tunnelName
        }

        var isTunnelConfigurationChanged = false
        if tunnelProviderManager.tunnelConfiguration != tunnelConfiguration {
            tunnelProviderManager.setTunnelConfiguration(tunnelConfiguration)
            isTunnelConfigurationChanged = true
        }
        tunnelProviderManager.isEnabled = true

        let isActivatingOnDemand = !tunnelProviderManager.isOnDemandEnabled && onDemandOption != .off
        onDemandOption.apply(on: tunnelProviderManager)

        tunnelProviderManager.saveToPreferences { [weak self] error in
            guard error == nil else {
                //TODO: the passwordReference for the old one has already been removed at this point and we can't easily roll back!
                wg_log(.error, message: "Modify: Saving configuration failed: \(error!)")
                completionHandler(TunnelsManagerError.systemErrorOnModifyTunnel(systemError: error!))
                return
            }
            guard let self = self else { return }
            if isNameChanged {
                let oldIndex = self.tunnels.firstIndex(of: tunnel)!
                self.tunnels.sort { TunnelsManager.tunnelNameIsLessThan($0.name, $1.name) }
                let newIndex = self.tunnels.firstIndex(of: tunnel)!
                self.tunnelsListDelegate?.tunnelMoved(from: oldIndex, to: newIndex)
                #if os(iOS)
                RecentTunnelsTracker.handleTunnelRenamed(oldName: oldName, newName: tunnelName)
                #endif
            }
            self.tunnelsListDelegate?.tunnelModified(at: self.tunnels.firstIndex(of: tunnel)!)

            if isTunnelConfigurationChanged {
                if tunnel.status == .active || tunnel.status == .activating || tunnel.status == .reasserting {
                    // Turn off the tunnel, and then turn it back on, so the changes are made effective
                    tunnel.status = .restarting
                    (tunnel.tunnelProvider.connection as? NETunnelProviderSession)?.stopTunnel()
                }
            }

            if isActivatingOnDemand {
                // Reload tunnel after saving.
                // Without this, the tunnel stopes getting updates on the tunnel status from iOS.
                tunnelProviderManager.loadFromPreferences { error in
                    tunnel.isActivateOnDemandEnabled = tunnelProviderManager.isOnDemandEnabled
                    guard error == nil else {
                        wg_log(.error, message: "Modify: Re-loading after saving configuration failed: \(error!)")
                        completionHandler(TunnelsManagerError.systemErrorOnModifyTunnel(systemError: error!))
                        return
                    }
                    completionHandler(nil)
                }
            } else {
                completionHandler(nil)
            }
        }
    }

    func remove(tunnel: TunnelContainer, completionHandler: @escaping (TunnelsManagerError?) -> Void) {
        let tunnelProviderManager = tunnel.tunnelProvider
        #if os(macOS)
        if tunnel.isTunnelAvailableToUser {
            (tunnelProviderManager.protocolConfiguration as? NETunnelProviderProtocol)?.destroyConfigurationReference()
        }
        #elseif os(iOS)
        (tunnelProviderManager.protocolConfiguration as? NETunnelProviderProtocol)?.destroyConfigurationReference()
        #else
        #error("Unimplemented")
        #endif
        tunnelProviderManager.removeFromPreferences { [weak self] error in
            guard error == nil else {
                wg_log(.error, message: "Remove: Saving configuration failed: \(error!)")
                completionHandler(TunnelsManagerError.systemErrorOnRemoveTunnel(systemError: error!))
                return
            }
            if let self = self, let index = self.tunnels.firstIndex(of: tunnel) {
                self.tunnels.remove(at: index)
                self.tunnelsListDelegate?.tunnelRemoved(at: index, tunnel: tunnel)
            }
            completionHandler(nil)

            #if os(iOS)
            RecentTunnelsTracker.handleTunnelRemoved(tunnelName: tunnel.name)
            #endif
        }
    }

    func removeMultiple(tunnels: [TunnelContainer], completionHandler: @escaping (TunnelsManagerError?) -> Void) {
        removeMultiple(tunnels: ArraySlice(tunnels), completionHandler: completionHandler)
    }

    private func removeMultiple(tunnels: ArraySlice<TunnelContainer>, completionHandler: @escaping (TunnelsManagerError?) -> Void) {
        guard let head = tunnels.first else {
            completionHandler(nil)
            return
        }
        let tail = tunnels.dropFirst()
        remove(tunnel: head) { [weak self, tail] error in
            DispatchQueue.main.async {
                if let error = error {
                    completionHandler(error)
                } else {
                    self?.removeMultiple(tunnels: tail, completionHandler: completionHandler)
                }
            }
        }
    }

    func numberOfTunnels() -> Int {
        return tunnels.count
    }

    func tunnel(at index: Int) -> TunnelContainer {
        return tunnels[index]
    }

    func mapTunnels<T>(transform: (TunnelContainer) throws -> T) rethrows -> [T] {
        return try tunnels.map(transform)
    }

    func index(of tunnel: TunnelContainer) -> Int? {
        return tunnels.firstIndex(of: tunnel)
    }

    func tunnel(named tunnelName: String) -> TunnelContainer? {
        return tunnels.first { $0.name == tunnelName }
    }

    func waitingTunnel() -> TunnelContainer? {
        return tunnels.first { $0.status == .waiting }
    }

    func tunnelInOperation() -> TunnelContainer? {
        if let waitingTunnelObject = waitingTunnel() {
            return waitingTunnelObject
        }
        return tunnels.first { $0.status != .inactive }
    }

    func startActivation(of tunnel: TunnelContainer) {
        guard tunnels.contains(tunnel) else { return } // Ensure it's not deleted
        guard tunnel.status == .inactive else {
            activationDelegate?.tunnelActivationAttemptFailed(tunnel: tunnel, error: .tunnelIsNotInactive)
            return
        }

        if let alreadyWaitingTunnel = tunnels.first(where: { $0.status == .waiting }) {
            alreadyWaitingTunnel.status = .inactive
        }

        if let tunnelInOperation = tunnels.first(where: { $0.status != .inactive }) {
            wg_log(.info, message: "Tunnel '\(tunnel.name)' waiting for deactivation of '\(tunnelInOperation.name)'")
            tunnel.status = .waiting
            activateWaitingTunnelOnDeactivation(of: tunnelInOperation)
            if tunnelInOperation.status != .deactivating {
                startDeactivation(of: tunnelInOperation)
            }
            return
        }

        #if targetEnvironment(simulator)
        tunnel.status = .active
        #else
        tunnel.startActivation(activationDelegate: activationDelegate)
        #endif

        #if os(iOS)
        RecentTunnelsTracker.handleTunnelActivated(tunnelName: tunnel.name)
        #endif
    }

    func startDeactivation(of tunnel: TunnelContainer) {
        tunnel.isAttemptingActivation = false
        guard tunnel.status != .inactive && tunnel.status != .deactivating else { return }
        #if targetEnvironment(simulator)
        tunnel.status = .inactive
        #else
        tunnel.startDeactivation()
        #endif
    }

    func refreshStatuses() {
        tunnels.forEach { $0.refreshStatus() }
    }

    private func activateWaitingTunnelOnDeactivation(of tunnel: TunnelContainer) {
        waiteeObservationToken = tunnel.observe(\.status) { [weak self] tunnel, _ in
            guard let self = self else { return }
            if tunnel.status == .inactive {
                if let waitingTunnel = self.tunnels.first(where: { $0.status == .waiting }) {
                    waitingTunnel.startActivation(activationDelegate: self.activationDelegate)
                }
                self.waiteeObservationToken = nil
            }
        }
    }

    private func startObservingTunnelStatuses() {
        statusObservationToken = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: OperationQueue.main) { [weak self] statusChangeNotification in
            guard let self = self,
                let session = statusChangeNotification.object as? NETunnelProviderSession,
                let tunnelProvider = session.manager as? NETunnelProviderManager,
                let tunnel = self.tunnels.first(where: { $0.tunnelProvider == tunnelProvider }) else { return }

            wg_log(.debug, message: "Tunnel '\(tunnel.name)' connection status changed to '\(tunnel.tunnelProvider.connection.status)'")

            if tunnel.isAttemptingActivation {
                if session.status == .connected {
                    tunnel.isAttemptingActivation = false
                    self.activationDelegate?.tunnelActivationSucceeded(tunnel: tunnel)
                } else if session.status == .disconnected {
                    tunnel.isAttemptingActivation = false
                    if let (title, message) = lastErrorTextFromNetworkExtension(for: tunnel) {
                        self.activationDelegate?.tunnelActivationFailed(tunnel: tunnel, error: .activationFailedWithExtensionError(title: title, message: message, wasOnDemandEnabled: tunnelProvider.isOnDemandEnabled))
                    } else {
                        self.activationDelegate?.tunnelActivationFailed(tunnel: tunnel, error: .activationFailed(wasOnDemandEnabled: tunnelProvider.isOnDemandEnabled))
                    }
                }
            }

            if tunnel.status == .restarting && session.status == .disconnected {
                tunnel.startActivation(activationDelegate: self.activationDelegate)
                return
            }

            tunnel.refreshStatus()
        }
    }

    func startObservingTunnelConfigurations() {
        configurationsObservationToken = NotificationCenter.default.addObserver(forName: .NEVPNConfigurationChange, object: nil, queue: OperationQueue.main) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                // We schedule reload() in a subsequent runloop to ensure that the completion handler of loadAllFromPreferences
                // (reload() calls loadAllFromPreferences) is called after the completion handler of the saveToPreferences or
                // removeFromPreferences call, if any, that caused this notification to fire. This notification can also fire
                // as a result of a tunnel getting added or removed outside of the app.
                self?.reload()
            }
        }
    }

    static func tunnelNameIsLessThan(_ a: String, _ b: String) -> Bool {
        return a.compare(b, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive, .numeric]) == .orderedAscending
    }
}

private func lastErrorTextFromNetworkExtension(for tunnel: TunnelContainer) -> (title: String, message: String)? {
    guard let lastErrorFileURL = FileManager.networkExtensionLastErrorFileURL else { return nil }
    guard let lastErrorData = try? Data(contentsOf: lastErrorFileURL) else { return nil }
    guard let lastErrorStrings = String(data: lastErrorData, encoding: .utf8)?.splitToArray(separator: "\n") else { return nil }
    guard lastErrorStrings.count == 2 && tunnel.activationAttemptId == lastErrorStrings[0] else { return nil }

    if let extensionError = PacketTunnelProviderError(rawValue: lastErrorStrings[1]) {
        return extensionError.alertText
    }

    return (tr("alertTunnelActivationFailureTitle"), tr("alertTunnelActivationFailureMessage"))
}

class TunnelContainer: NSObject {
    @objc dynamic var name: String
    @objc dynamic var status: TunnelStatus

    @objc dynamic var isActivateOnDemandEnabled: Bool

    var isAttemptingActivation = false {
        didSet {
            if isAttemptingActivation {
                self.activationTimer?.invalidate()
                let activationTimer = Timer(timeInterval: 5 /* seconds */, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    wg_log(.debug, message: "Status update notification timeout for tunnel '\(self.name)'. Tunnel status is now '\(self.tunnelProvider.connection.status)'.")
                    switch self.tunnelProvider.connection.status {
                    case .connected, .disconnected, .invalid:
                        self.activationTimer?.invalidate()
                        self.activationTimer = nil
                    default:
                        break
                    }
                    self.refreshStatus()
                }
                self.activationTimer = activationTimer
                RunLoop.main.add(activationTimer, forMode: .common)
            }
        }
    }
    var activationAttemptId: String?
    var activationTimer: Timer?
    var deactivationTimer: Timer?

    fileprivate var tunnelProvider: NETunnelProviderManager

    var tunnelConfiguration: TunnelConfiguration? {
        return tunnelProvider.tunnelConfiguration
    }

    var onDemandOption: ActivateOnDemandOption {
        return ActivateOnDemandOption(from: tunnelProvider)
    }

    #if os(macOS)
    var isTunnelAvailableToUser: Bool {
        return (tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["UID"] as? uid_t == getuid()
    }
    #endif

    init(tunnel: NETunnelProviderManager) {
        name = tunnel.localizedDescription ?? "Unnamed"
        let status = TunnelStatus(from: tunnel.connection.status)
        self.status = status
        isActivateOnDemandEnabled = tunnel.isOnDemandEnabled
        tunnelProvider = tunnel
        super.init()
    }

    func getRuntimeTunnelConfiguration(completionHandler: @escaping ((TunnelConfiguration?) -> Void)) {
        guard status != .inactive, let session = tunnelProvider.connection as? NETunnelProviderSession else {
            completionHandler(tunnelConfiguration)
            return
        }
        guard nil != (try? session.sendProviderMessage(Data([ UInt8(0) ]), responseHandler: {
            guard self.status != .inactive, let data = $0, let base = self.tunnelConfiguration, let settings = String(data: data, encoding: .utf8) else {
                completionHandler(self.tunnelConfiguration)
                return
            }
            completionHandler((try? TunnelConfiguration(fromUapiConfig: settings, basedOn: base)) ?? self.tunnelConfiguration)
        })) else {
            completionHandler(tunnelConfiguration)
            return
        }
    }

    func refreshStatus() {
        if status == .restarting {
            return
        }
        status = TunnelStatus(from: tunnelProvider.connection.status)
        isActivateOnDemandEnabled = tunnelProvider.isOnDemandEnabled
    }

    fileprivate func startActivation(recursionCount: UInt = 0, lastError: Error? = nil, activationDelegate: TunnelsManagerActivationDelegate?) {
        if recursionCount >= 8 {
            wg_log(.error, message: "startActivation: Failed after 8 attempts. Giving up with \(lastError!)")
            activationDelegate?.tunnelActivationAttemptFailed(tunnel: self, error: .failedBecauseOfTooManyErrors(lastSystemError: lastError!))
            return
        }

        wg_log(.debug, message: "startActivation: Entering (tunnel: \(name))")

        status = .activating // Ensure that no other tunnel can attempt activation until this tunnel is done trying

        guard tunnelProvider.isEnabled else {
            // In case the tunnel had gotten disabled, re-enable and save it,
            // then call this function again.
            wg_log(.debug, staticMessage: "startActivation: Tunnel is disabled. Re-enabling and saving")
            tunnelProvider.isEnabled = true
            tunnelProvider.saveToPreferences { [weak self] error in
                guard let self = self else { return }
                if error != nil {
                    wg_log(.error, message: "Error saving tunnel after re-enabling: \(error!)")
                    activationDelegate?.tunnelActivationAttemptFailed(tunnel: self, error: .failedWhileSaving(systemError: error!))
                    return
                }
                wg_log(.debug, staticMessage: "startActivation: Tunnel saved after re-enabling, invoking startActivation")
                self.startActivation(recursionCount: recursionCount + 1, lastError: NEVPNError(NEVPNError.configurationUnknown), activationDelegate: activationDelegate)
            }
            return
        }

        // Start the tunnel
        do {
            wg_log(.debug, staticMessage: "startActivation: Starting tunnel")
            isAttemptingActivation = true
            let activationAttemptId = UUID().uuidString
            self.activationAttemptId = activationAttemptId
            try (tunnelProvider.connection as? NETunnelProviderSession)?.startTunnel(options: ["activationAttemptId": activationAttemptId])
            wg_log(.debug, staticMessage: "startActivation: Success")
            activationDelegate?.tunnelActivationAttemptSucceeded(tunnel: self)
        } catch let error {
            isAttemptingActivation = false
            guard let systemError = error as? NEVPNError else {
                wg_log(.error, message: "Failed to activate tunnel: Error: \(error)")
                status = .inactive
                activationDelegate?.tunnelActivationAttemptFailed(tunnel: self, error: .failedWhileStarting(systemError: error))
                return
            }
            guard systemError.code == NEVPNError.configurationInvalid || systemError.code == NEVPNError.configurationStale else {
                wg_log(.error, message: "Failed to activate tunnel: VPN Error: \(error)")
                status = .inactive
                activationDelegate?.tunnelActivationAttemptFailed(tunnel: self, error: .failedWhileStarting(systemError: systemError))
                return
            }
            wg_log(.debug, staticMessage: "startActivation: Will reload tunnel and then try to start it.")
            tunnelProvider.loadFromPreferences { [weak self] error in
                guard let self = self else { return }
                if error != nil {
                    wg_log(.error, message: "startActivation: Error reloading tunnel: \(error!)")
                    self.status = .inactive
                    activationDelegate?.tunnelActivationAttemptFailed(tunnel: self, error: .failedWhileLoading(systemError: systemError))
                    return
                }
                wg_log(.debug, staticMessage: "startActivation: Tunnel reloaded, invoking startActivation")
                self.startActivation(recursionCount: recursionCount + 1, lastError: systemError, activationDelegate: activationDelegate)
            }
        }
    }

    fileprivate func startDeactivation() {
        wg_log(.debug, message: "startDeactivation: Tunnel: \(name)")
        (tunnelProvider.connection as? NETunnelProviderSession)?.stopTunnel()
    }
}

extension NETunnelProviderManager {
    fileprivate static var cachedConfigKey: UInt8 = 0

    var tunnelConfiguration: TunnelConfiguration? {
        if let cached = objc_getAssociatedObject(self, &NETunnelProviderManager.cachedConfigKey) as? TunnelConfiguration {
            return cached
        }
        let config = (protocolConfiguration as? NETunnelProviderProtocol)?.asTunnelConfiguration(called: localizedDescription)
        if config != nil {
            objc_setAssociatedObject(self, &NETunnelProviderManager.cachedConfigKey, config, objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        return config
    }

    func setTunnelConfiguration(_ tunnelConfiguration: TunnelConfiguration) {
        protocolConfiguration = NETunnelProviderProtocol(tunnelConfiguration: tunnelConfiguration, previouslyFrom: protocolConfiguration)
        localizedDescription = tunnelConfiguration.name
        objc_setAssociatedObject(self, &NETunnelProviderManager.cachedConfigKey, tunnelConfiguration, objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    func isEquivalentTo(_ tunnel: TunnelContainer) -> Bool {
        return localizedDescription == tunnel.name && tunnelConfiguration == tunnel.tunnelConfiguration
    }
}

#if os(macOS)
@available(macOS 10.15, *)
class CatalinaWorkaround {

    // In macOS Catalina, for some users, the tunnels get deleted arbitrarily
    // by the OS. It's not clear what triggers that.

    // As a workaround, in macOS Catalina, when we realize that tunnels have been
    // deleted outside the app, we reinstate those tunnels using the information
    // in the keychain.

    unowned let tunnelsManager: TunnelsManager
    private var configChangeSubscriber: Any?

    struct ReinstationData {
        let tunnelConfiguration: TunnelConfiguration
        let keychainPasswordRef: Data
    }

    init(tunnelsManager: TunnelsManager) {
        self.tunnelsManager = tunnelsManager

        // Attempt reinstation when there's a change in tunnel configurations,
        // which indicates that tunnels may have been deleted outside the app.
        // We use debounce to wait for all change notifications to arrive
        // before attempting to reinstate, so that we don't have saveToPreferences
        // being called while another saveToPreferences is in progress.
        self.configChangeSubscriber = NotificationCenter.default
            .publisher(for: .NEVPNConfigurationChange, object: nil)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .subscribe(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reinstateTunnelsDeletedOutsideApp()
        }

        // Attempt reinstation on app launch
        reinstateTunnelsDeletedOutsideApp()
    }

    func reinstateTunnelsDeletedOutsideApp() {
        let rd = reinstationDataForTunnelsDeletedOutsideApp()
        reinstateTunnels(ArraySlice(rd), completionHandler: nil)
    }

    private func reinstateTunnels(_ rdArray: ArraySlice<ReinstationData>, completionHandler: (() -> Void)?) {
        guard let head = rdArray.first else {
            completionHandler?()
            return
        }
        let tail = rdArray.dropFirst()
        self.tunnelsManager.reinstateTunnel(reinstationData: head) { _ in
            DispatchQueue.main.async {
                self.reinstateTunnels(tail, completionHandler: completionHandler)
            }
        }
    }

    private func reinstationDataForTunnelsDeletedOutsideApp() -> [ReinstationData] {
        let knownRefs: [Data] = self.tunnelsManager.tunnels
            .compactMap { $0.tunnelProvider.protocolConfiguration as? NETunnelProviderProtocol }
            .compactMap { $0.passwordReference }
        let knownRefsSet: Set<Data> = Set(knownRefs)
        var result: CFTypeRef?
        let ret = SecItemCopyMatching([kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: Bundle.main.bundleIdentifier as Any,
                                       kSecMatchLimit as String: kSecMatchLimitAll,
                                       kSecReturnAttributes as String: true,
                                       kSecReturnPersistentRef as String: true] as CFDictionary,
                                      &result)
        guard ret == errSecSuccess, let resultDicts = result as? [[String: Any]] else { return [] }
        let labelPrefix = "WireGuard Tunnel: "
        var reinstationData: [ReinstationData] = []
        for resultDict in resultDicts {
            guard let ref = resultDict[kSecValuePersistentRef as String] as? Data else { continue }
            guard let label = resultDict[kSecAttrLabel as String] as? String else { continue }
            guard label.hasPrefix(labelPrefix) else { continue }
            if !knownRefsSet.contains(ref) {
                let tunnelName = String(label.dropFirst(labelPrefix.count))
                if let configStr = Keychain.openReference(called: ref),
                    let config = try? TunnelConfiguration(fromWgQuickConfig: configStr, called: tunnelName) {
                    reinstationData.append(ReinstationData(tunnelConfiguration: config, keychainPasswordRef: ref))
                }
            }
        }
        return reinstationData
    }
}
#endif

#if os(macOS)
@available(macOS 10.15, *)
extension TunnelsManager {
    fileprivate func reinstateTunnel(reinstationData: CatalinaWorkaround.ReinstationData, completionHandler: @escaping (Bool) -> Void) {
        let tunnelName = reinstationData.tunnelConfiguration.name ?? ""
        if tunnelName.isEmpty {
            completionHandler(false)
            return
        }

        if tunnels.contains(where: { $0.name == tunnelName }) {
            completionHandler(false)
            return
        }

        let tunnelProviderProtocol = NETunnelProviderProtocol()
        guard let appId = Bundle.main.bundleIdentifier else { fatalError() }
        tunnelProviderProtocol.providerBundleIdentifier = "\(appId).network-extension"
        tunnelProviderProtocol.passwordReference = reinstationData.keychainPasswordRef
        tunnelProviderProtocol.providerConfiguration = ["UID": getuid()]
        tunnelProviderProtocol.serverAddress = {
            let endpoints = reinstationData.tunnelConfiguration.peers.compactMap { $0.endpoint }
            if endpoints.count == 1 {
                return endpoints[0].stringRepresentation
            } else if endpoints.isEmpty {
                return "Unspecified"
            } else {
                return "Multiple endpoints"
            }
        }()

        let tunnelProvider = NETunnelProviderManager()
        tunnelProvider.localizedDescription = tunnelName
        tunnelProvider.protocolConfiguration = tunnelProviderProtocol
        objc_setAssociatedObject(tunnelProvider, &NETunnelProviderManager.cachedConfigKey, reinstationData.tunnelConfiguration, objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        tunnelProvider.isEnabled = true

        tunnelProvider.saveToPreferences { [weak self] error in
            guard error == nil else {
                wg_log(.error, message: "Reinstate: Saving configuration failed: \(error!)")
                completionHandler(false)
                return
            }

            guard let self = self else { return }

            let tunnel = TunnelContainer(tunnel: tunnelProvider)
            self.tunnels.append(tunnel)
            self.tunnels.sort { TunnelsManager.tunnelNameIsLessThan($0.name, $1.name) }
            self.tunnelsListDelegate?.tunnelAdded(at: self.tunnels.firstIndex(of: tunnel)!)
            completionHandler(true)
        }
    }
}
#endif
