import Foundation
import Combine
import UIKit

/// Dinâmica do M156 (C63 AMG W204): binário real aproximado, inércia, travão-motor,
/// regulador de ralenti, limitador às 7200 rpm, caixa 7G-Tronic com estalo nas passagens
/// a fundo e "blip" de acelerador nas reduções. Corre a 60 Hz na main thread.
final class EngineModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable { case garage = "Ponto morto", road = "Estrada"; var id: String { rawValue } }
    enum Perspective: String, CaseIterable, Identifiable { case exterior = "Exterior", interior = "Habitáculo"; var id: String { rawValue } }

    static let idle = 680.0, redline = 7200.0, limiter = 7200.0
    private let gears = [4.38, 2.86, 1.92, 1.37, 1.00, 0.82, 0.73]
    private let finalDrive = 2.82, wheelR = 0.334, mass = 1730.0, inertia = 0.55

    @Published private(set) var rpm = 0.0
    @Published private(set) var gear = 1
    @Published private(set) var speedKmh = 0.0
    @Published private(set) var running = false
    @Published private(set) var cranking = false
    @Published private(set) var limiterOn = false
    @Published var mode: Mode = .garage { didSet { if mode == .garage { v = 0; gearIdx = 0 } } }
    @Published var perspective: Perspective = .exterior { didSet { synth.set(.interior, perspective == .interior ? 1 : 0) } }

    var throttle = 0.0
    var brake = 0.0
    /// Modo carro real: velocidade medida (m/s) e aceleração longitudinal (g). nil = carro virtual.
    var realSpeed: Double?
    var realAccelG = 0.0

    let synth = EngineSynth()
    private var timer: Timer?
    private var crankT = 0.0, v = 0.0, gearIdx = 0
    private var shiftT = 0.0, blipT = 0.0, load = 0.0, crackleE = 0.0
    private var limiterCut = false
    private var popCount = 0.0
    private var sinceStart = 0.0, catchT = 0.0
    private let haptic = UIImpactFeedbackGenerator(style: .rigid)

    /// Curva de binário (Nm) aproximada do M156 de 457 cv: ~600 Nm às 5000, 457 cv às 6800.
    private func torque(_ r: Double) -> Double {
        let R: [Double] = [0, 1000, 2000, 3000, 4000, 5000, 6000, 6800, 7200, 7600]
        let T: [Double] = [250, 380, 450, 510, 570, 600, 590, 478, 440, 380]
        if r <= 0 { return 250 }
        for i in 1..<R.count where r < R[i] {
            let t = (r - R[i - 1]) / (R[i] - R[i - 1])
            return T[i - 1] + t * (T[i] - T[i - 1])
        }
        return 380
    }

    func toggleIgnition() {
        if running || cranking { stopEngine() } else { startEngine() }
    }

    private func startEngine() {
        do { try synth.start() } catch { print("Áudio: \(error)") }
        synth.set(.interior, perspective == .interior ? 1 : 0)
        crankT = 0
        synth.set(.caught, 0)
        cranking = true
        UIApplication.shared.isIdleTimerDisabled = true
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.step(1.0 / 60.0) }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func stopEngine() {
        running = false
        cranking = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func step(_ dt: Double) {
        var starter = 0.0
        var ignition = false
        var r = rpm

        if cranking {
            // a cambota é simulada no DSP (motor de arranque + compressões); aqui só se espera que pegue
            crankT += dt
            starter = 1
            r = synth.get(.crankRpm)
            if synth.get(.caught) > 0.5 || crankT > 5 {
                cranking = false; running = true
                sinceStart = 0; catchT = 0.35
                synth.set(.caught, 0)
            }
            load = 0
        } else if !running {
            r = max(0, r - 900 * dt)
            v = max(0, v - 3 * dt)
            if r <= 0 && v <= 0 {
                timer?.invalidate(); timer = nil
                publish(r: 0)
                synth.set(.rpm, 0); synth.set(.starter, 0); synth.set(.ignition, 0)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, !self.running, !self.cranking else { return }
                    self.synth.stop()
                }
                return
            }
        } else {
            sinceStart += dt
            let idleNow = Self.idle + (1350 - Self.idle) * exp(-sinceStart / 4)   // ralenti alto a frio
            if shiftT > 0 { shiftT -= dt }
            if r >= Self.limiter { limiterCut = true }
            if r < Self.limiter - 180 { limiterCut = false }
            ignition = !limiterCut && shiftT <= 0
            // Carro real: o acelerador equivalente é a força que o C63 precisaria para reproduzir
            // a aceleração medida a esta velocidade (inclui resistência do ar e rolamento),
            // dividida pela força máxima disponível nesta mudança. Velocidade de cruzeiro → carga parcial.
            var pedal = throttle
            if mode == .road, let vs = realSpeed {
                let g = gears[gearIdx] * finalDrive
                let fMax = min(torque(max(r, 1500)) * g * 0.88 / wheelR, 9000)
                let fReq = mass * realAccelG * 9.81 + 0.36 * vs * vs + (vs > 0.5 ? 190 : 0)
                pedal = realAccelG < -0.05 ? 0 : min(1, max(0, fReq / fMax))
                if vs < 0.5 && realAccelG < 0.03 { pedal = 0 }          // parado
            }
            var eff = ignition ? pedal : 0
            if blipT > 0 { blipT -= dt; eff = max(eff, 0.55) }
            if catchT > 0 { catchT -= dt; eff = max(eff, 0.65 * catchT / 0.35) }   // o motor pega com força
            let idleAssist = 0.10 + max(-0.1, min(1, (idleNow - r) / 150)) * 0.25
            let effT = max(eff, ignition ? idleAssist : 0)

            switch mode {
            case .garage:
                let tq = torque(r) * effT
                let friction = 14 + 0.008 * r + (1 - effT) * (10 + 0.018 * r)   // atrito + bombagem
                var w = r * 2 * .pi / 60
                w += (tq - friction) / inertia * dt
                r = max(0, w * 60 / (2 * .pi))
            case .road:
                let g = gears[gearIdx] * finalDrive
                let fEngine = min(torque(r) * eff * g * 0.88 / wheelR, 9000)        // limite de tração
                let fEngBrake = r > Self.idle + 150 ? (1 - eff) * (30 + r * 0.02) * g / wheelR : 0
                if let vs = realSpeed {
                    v = vs
                } else {
                    let f = fEngine - fEngBrake - brake * 13000 - 0.36 * v * v - (v > 0.1 ? 190 : 0)
                    v = max(0, v + f / mass * dt)
                }
                let wheel = v / wheelR * g * 60 / (2 * .pi)
                let target = (gearIdx == 0 && wheel < 1800)
                    ? max(wheel, Self.idle + eff * 2200)                             // conversor de binário
                    : max(Self.idle * 0.95, wheel)
                r += (target - r) * min(1, 16 * dt)
                let up = pedal > 0.6 ? 7000 : (pedal < 0.05 ? 6900 : 2200 + 3000 * pedal)
                let braking = realSpeed != nil ? realAccelG < -0.15 : brake > 0.2
                let down = braking ? 2700.0 : (pedal < 0.6 ? 1300.0 : 3200.0)
                if r > up && gearIdx < gears.count - 1 && shiftT <= 0 {
                    gearIdx += 1; shiftT = 0.09
                    if pedal > 0.6 { popCount += 1; synth.set(.popCount, popCount) }
                    haptic.impactOccurred()
                } else if gearIdx > 0 && r < down && shiftT <= 0 {
                    gearIdx -= 1; blipT = 0.16
                }
            }
            r = max(0, r)
            let targetLoad = r < Self.limiter ? eff : 0
            load += (targetLoad - load) * min(1, 14 * dt)

            // energia de pós-combustão ao levantar o pé em altas rotações
            if pedal < 0.05 && r > 3000 { crackleE = max(crackleE, min(1, (r - 2500) / 4000)) }
            if pedal > 0.1 { crackleE = 0 }
            crackleE *= exp(-dt / 1.6)
            if r < 1600 { crackleE *= 0.9 }
        }

        synth.set(.rpm, r)
        synth.set(.load, load)
        synth.set(.throttle, throttle)
        synth.set(.ignition, ignition ? 1 : 0)
        synth.set(.starter, starter)
        synth.set(.crackle, crackleE)
        publish(r: r)
    }

    private func publish(r: Double) {
        rpm = r
        gear = gearIdx + 1
        speedKmh = v * 3.6
        limiterOn = limiterCut && running
    }
}
