import Foundation
import CoreMotion
import CoreLocation
import simd

/// Converte os sensores em acelerador/travão e (no modo Força G) em velocidade real do carro.
/// - Inclinação: telemóvel na mão, em retrato; topo para longe = acelerar, para si = travar.
/// - Força G: telemóvel fixo no carro. A aceleração longitudinal real dá a carga do motor e a
///   velocidade (GPS fundido com o acelerómetro) dá as rotações através da caixa virtual.
final class MotionInput: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum Source: String, CaseIterable, Identifiable { case tilt = "Inclinação", gforce = "Força G"; var id: String { rawValue } }

    /// Como o telemóvel está montado no carro.
    enum Mount: String, CaseIterable, Identifiable {
        case auto = "Automática"
        case flatTopLeft = "Deitado, topo à esquerda"
        case flatTopRight = "Deitado, topo à direita"
        case flatTopForward = "Deitado, topo para a frente"
        case upright = "Suporte vertical"
        var id: String { rawValue }
    }

    @Published var source: Source = .tilt { didSet { calibrate(); updateLocation() } }
    @Published var mount: Mount = .auto { didSet { calibrate() } }
    @Published var sensitivity = 0.5          // 0...1
    @Published var invert = false
    @Published private(set) var throttle = 0.0
    @Published private(set) var brake = 0.0
    @Published private(set) var longitudinalG = 0.0
    @Published private(set) var status = ""
    /// Velocidade real estimada (m/s); nil fora do modo Força G.
    @Published private(set) var carSpeed: Double?
    @Published private(set) var gpsOK = false
    var available: Bool { manager.isDeviceMotionAvailable }

    private let manager = CMMotionManager()
    private let location = CLLocationManager()
    private var refAngle: Double?
    private var forward: SIMD3<Double>?
    private var gFiltered = 0.0
    private var needsCal = true
    // aprendizagem automática da direção "em frente"
    private var learnVec = SIMD3<Double>(0, 0, 0)
    private var learnTime = 0.0
    // fusão de velocidade
    private var vEst = 0.0
    private var lastGPS: Date?

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        location.activityType = .automotiveNavigation
    }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] m, _ in
            guard let self, let m else { return }
            self.handle(m)
        }
        updateLocation()
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        location.stopUpdatingLocation()
    }

    /// Inclinação: posição atual passa a ser a neutra.
    /// Força G: carro parado → zera a velocidade e (em Automática) volta a aprender a direção.
    func calibrate() {
        needsCal = true
        forward = nil
        learnVec = .zero
        learnTime = 0
        vEst = 0
    }

    private func updateLocation() {
        if source == .gforce {
            if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
            location.startUpdatingLocation()
        } else {
            location.stopUpdatingLocation()
            carSpeed = nil
            gpsOK = false
        }
    }

    // MARK: Sensores

    private func handle(_ m: CMDeviceMotion) {
        let g = SIMD3(m.gravity.x, m.gravity.y, m.gravity.z)
        let ua = SIMD3(m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z)   // em g, sem gravidade

        switch source {
        case .tilt:
            // 0° = de pé virado para o utilizador, 90° = deitado de ecrã para cima
            let angle = atan2(-g.z, -g.y) * 180 / .pi
            if needsCal || refAngle == nil { refAngle = angle; needsCal = false }
            var d = angle - (refAngle ?? angle)
            if invert { d = -d }
            let range = 40 - 28 * sensitivity                // 40° … 12° para acelerador a fundo
            let dead = 3.0
            throttle = clamp((d - dead) / range)
            brake = clamp((-d - dead) / range)
            longitudinalG = 0
            status = ""

        case .gforce:
            let gh = simd_normalize(g)
            let horiz = ua - simd_dot(ua, gh) * gh             // aceleração no plano da estrada
            if needsCal {
                needsCal = false
                gFiltered = 0
                if mount != .auto { forward = Self.fixedForward(mount, gravity: gh) }
            }
            if forward == nil && mount == .auto { learnForward(horiz) }
            guard let f = forward else {
                throttle = 0; brake = 0; longitudinalG = 0
                integrateSpeed(0)
                return
            }
            var a = simd_dot(horiz, f)                         // só a componente longitudinal; curvas ignoradas
            if invert { a = -a }
            gFiltered += (a - gFiltered) * 0.12                // ~0,13 s a 60 Hz
            longitudinalG = gFiltered
            integrateSpeed(gFiltered)
            let full = 0.45 - 0.33 * sensitivity               // 0,45 g … 0,12 g para acelerador a fundo
            throttle = clamp((gFiltered - 0.02) / full)
            brake = clamp((-gFiltered - 0.04) / (full * 1.3))
            status = gpsOK ? "" : "Sem GPS: velocidade estimada só pelo acelerómetro"
        }
    }

    /// Com o carro parado após Calibrar, a primeira aceleração sustentada é para a frente.
    private func learnForward(_ horiz: SIMD3<Double>) {
        status = "Calibrado. Arranque com o carro para aprender a direção."
        learnVec += (horiz - learnVec) * 0.08
        if simd_length(learnVec) > 0.07 {
            learnTime += 1.0 / 60.0
            if learnTime > 0.4 {
                forward = simd_normalize(learnVec)
                status = ""
            }
        } else {
            learnTime = max(0, learnTime - 1.0 / 60.0)
        }
    }

    /// Eixo "em frente" no referencial do telemóvel, projetado no plano horizontal.
    private static func fixedForward(_ mount: Mount, gravity gh: SIMD3<Double>) -> SIMD3<Double>? {
        let axis: SIMD3<Double>
        switch mount {
        case .flatTopLeft: axis = SIMD3(1, 0, 0)     // ecrã para cima, topo à esquerda → lado direito do ecrã aponta para a frente
        case .flatTopRight: axis = SIMD3(-1, 0, 0)
        case .flatTopForward: axis = SIMD3(0, 1, 0)
        case .upright: axis = SIMD3(0, 0, -1)        // ecrã para o condutor → traseira aponta para a frente
        case .auto: return nil
        }
        let h = axis - simd_dot(axis, gh) * gh
        return simd_length(h) > 0.2 ? simd_normalize(h) : nil
    }

    // MARK: Velocidade (acelerómetro + GPS)

    private func integrateSpeed(_ aG: Double) {
        vEst = max(0, vEst + aG * 9.81 / 60.0)
        if let t = lastGPS, Date().timeIntervalSince(t) > 3 { gpsOK = false }
        carSpeed = vEst
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.speed >= 0, loc.speedAccuracy >= 0, loc.speedAccuracy < 3 else { return }
        // o GPS (Doppler) é exato mas chega com ~1 s de atraso e a 1 Hz: corrige a deriva da integração
        vEst += (loc.speed - vEst) * 0.35
        lastGPS = Date()
        gpsOK = true
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if source == .gforce { manager.startUpdatingLocation() }
    }

    private func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
}
