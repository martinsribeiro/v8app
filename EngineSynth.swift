import AVFoundation

/// Síntese física do Mercedes-AMG M156 (6.2 V8 atmosférico, cambota cross-plane).
///
/// Modelo de guia de onda (waveguide) do escape, por banco:
///   válvula de escape → 4 corredores de comprimentos desiguais → coletor 4-em-1
///   → tubo intermédio → junção H (tubo de cruzamento entre bancos)
///   → tubo descendente → silenciador (câmara de expansão) → ponteira (extremidade aberta) → radiação.
/// Cada troço é uma linha de atraso bidirecional com perdas; as junções são de dispersão
/// (conservação de pressão/caudal com admitâncias proporcionais à secção).
/// Fontes: pulso de blowdown por cilindro (frente abrupta + decaimento), com variabilidade
/// de combustão ciclo-a-ciclo e jitter de fase em ralenti; ruído de escoamento modulado pelo caudal;
/// pós-combustão no escape (estalos) em desaceleração; ruído de admissão; mecânico; motor de arranque.
final class EngineSynth {
    enum Param: Int, CaseIterable {
        case rpm, load, throttle, ignition, starter, volume, interior, crackle, popCount, speakerBoost
        case caught, crankRpm          // escritos pelo DSP durante o arranque
    }

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let params = UnsafeMutablePointer<Float>.allocate(capacity: Param.allCases.count)
    private var dsp: M156DSP?
    private var routeObserver: NSObjectProtocol?

    init() {
        params.initialize(repeating: 0, count: Param.allCases.count)
        params[Param.volume.rawValue] = 1
    }

    deinit { params.deallocate() }

    func set(_ p: Param, _ v: Double) { params[p.rawValue] = Float(v) }
    func get(_ p: Param) -> Double { Double(params[p.rawValue]) }

    func start() throws {
        guard source == nil else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try? session.setPreferredSampleRate(48_000)
        try? session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
        updateRoute()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateRoute()
        }

        let sr = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let rate = sr > 0 ? sr : 48_000
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        let dsp = M156DSP(sampleRate: Float(rate), params: params)
        self.dsp = dsp

        let node = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard buffers.count >= 2,
                  let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            dsp.render(frames: Int(frameCount), left: l, right: r)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        engine.prepare()
        try engine.start()
        source = node
    }

    func stop() {
        engine.stop()
        if let s = source { engine.detach(s) }
        source = nil
        dsp = nil
        if let o = routeObserver { NotificationCenter.default.removeObserver(o) }
        routeObserver = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// No altifalante do iPhone não há graves abaixo de ~150 Hz: ativa o reforço psicoacústico.
    private func updateRoute() {
        let speaker = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
        set(.speakerBoost, speaker ? 1 : 0)
    }
}

// MARK: - Blocos DSP

struct RNG {
    var s: UInt32 = 0x9E37_79B9
    @inline(__always) mutating func next() -> Float {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5
        return Float(s) * (1 / Float(UInt32.max))
    }
    @inline(__always) mutating func bipolar() -> Float { next() * 2 - 1 }
    @inline(__always) mutating func gauss() -> Float { (next() + next() + next() - 1.5) * 2 }
}

struct Delay {
    let buf: UnsafeMutablePointer<Float>
    let n: Int
    var w = 0
    init(samples: Int) {
        n = max(1, samples)
        buf = .allocate(capacity: n)
        buf.initialize(repeating: 0, count: n)
    }
    @inline(__always) func read() -> Float { buf[w] }
    @inline(__always) mutating func write(_ x: Float) { buf[w] = x; w += 1; if w == n { w = 0 } }
    func free() { buf.deallocate() }
}

/// Troço de tubo: duas linhas de atraso (sentido jusante f e montante b) com atrito e perdas de AF.
struct Pipe {
    var f: Delay, b: Delay
    let g: Float, a: Float
    var lf: Float = 0, lb: Float = 0
    init(meters: Float, loss: Float, fc: Float, sr: Float) {
        let n = Int((meters / M156DSP.cGas * sr).rounded())
        f = Delay(samples: n); b = Delay(samples: n)
        g = loss; a = 1 - exp(-2 * Float.pi * fc / sr)
    }
    @inline(__always) mutating func writeF(_ x: Float) { lf += a * (x - lf); f.write(lf * g) }
    @inline(__always) mutating func writeB(_ x: Float) { lb += a * (x - lb); b.write(lb * g) }
    func free() { f.free(); b.free() }
}

struct Biquad {
    var b0: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
    init(bandpass f: Float, q: Float, gain: Float, sr: Float) {
        let w = 2 * Float.pi * f / sr
        let alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha
        b0 = alpha / a0 * gain; b2 = -alpha / a0 * gain
        a1 = -2 * cos(w) / a0; a2 = (1 - alpha) / a0
    }
    @inline(__always) mutating func run(_ x: Float) -> Float {
        let y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

/// Um banco (4 cilindros) e a sua linha de escape até à ponteira.
struct ExhaustBank {
    var r0, r1, r2, r3: Pipe
    var coll, down, chamber, tail: Pipe
    var raspBP: Biquad
    var tailLP: Float = 0, radLP: Float = 0
    var burst: Float = 0, burstDecay: Float = 0, spike: Float = 0
    let tailCoef: Float, radCoef: Float

    init(side: Int, sr: Float) {
        let L: [Float] = side == 0 ? [0.42, 0.51, 0.47, 0.56] : [0.45, 0.49, 0.53, 0.44]
        r0 = Pipe(meters: L[0], loss: 0.997, fc: 15000, sr: sr)
        r1 = Pipe(meters: L[1], loss: 0.997, fc: 15000, sr: sr)
        r2 = Pipe(meters: L[2], loss: 0.997, fc: 15000, sr: sr)
        r3 = Pipe(meters: L[3], loss: 0.997, fc: 15000, sr: sr)
        coll = Pipe(meters: side == 0 ? 0.90 : 0.95, loss: 0.995, fc: 12000, sr: sr)
        down = Pipe(meters: side == 0 ? 1.60 : 1.65, loss: 0.993, fc: 9000, sr: sr)
        chamber = Pipe(meters: 0.38, loss: 0.975, fc: 6000, sr: sr)
        tail = Pipe(meters: side == 0 ? 0.68 : 0.72, loss: 0.995, fc: 10000, sr: sr)
        raspBP = Biquad(bandpass: side == 0 ? 1800 : 2100, q: 0.8, gain: 1, sr: sr)
        tailCoef = 1 - exp(-2 * Float.pi * 1900 / sr)   // reflexão na ponta aberta: só graves voltam
        radCoef = 1 - exp(-2 * Float.pi * 80 / sr)      // radiação ≈ passa-alto 1.ª ordem
    }

    func free() { for p in [r0, r1, r2, r3, coll, down, chamber, tail] { p.free() } }

    /// Avança uma amostra. src = pulsos dos 4 cilindros; xin = onda vinda do tubo de cruzamento.
    /// Devolve (pressão radiada, onda a enviar para o cruzamento).
    @inline(__always)
    mutating func step(_ s0: Float, _ s1: Float, _ s2: Float, _ s3: Float,
                       xin: Float, load: Float, rpm: Float, rng: inout RNG) -> (Float, Float) {
        // leituras (todas antes de qualquer escrita)
        let f0 = r0.f.read(), f1 = r1.f.read(), f2 = r2.f.read(), f3 = r3.f.read()
        let b0 = r0.b.read(), b1 = r1.b.read(), b2 = r2.b.read(), b3 = r3.b.read()
        let cf = coll.f.read(), cb = coll.b.read()
        let df = down.f.read(), db = down.b.read()
        let chf = chamber.f.read(), chb = chamber.b.read()
        let tf = tail.f.read(), tb = tail.b.read()

        // válvula: aberta absorve parte da onda de retorno, fechada reflete
        r0.writeF(s0 + (s0 > 0.0005 ? 0.35 : 0.92) * b0)
        r1.writeF(s1 + (s1 > 0.0005 ? 0.35 : 0.92) * b1)
        r2.writeF(s2 + (s2 > 0.0005 ? 0.35 : 0.92) * b2)
        r3.writeF(s3 + (s3 > 0.0005 ? 0.35 : 0.92) * b3)

        // coletor 4-em-1 (admitâncias 1,1,1,1 | 2.2)
        let pj = 2 * (f0 + f1 + f2 + f3 + 2.2 * cb) / 6.2
        r0.writeB(pj - f0); r1.writeB(pj - f1); r2.writeB(pj - f2); r3.writeB(pj - f3)
        coll.writeF(pj - cb)

        // junção H (2.2 | 2.2 | 1.1)
        let ph = 2 * (2.2 * cf + 2.2 * db + 1.1 * xin) / 5.5
        coll.writeB(ph - cf)
        let burstV = burst * 0.55 * rng.bipolar() + spike
        spike = 0; burst *= burstDecay
        down.writeF(ph - db + burstV)
        let cross = ph - xin

        // silenciador: expansão 2.2 → 8 → 2.4
        let pm = 2 * (2.2 * df + 8 * chb) / 10.2
        down.writeB(pm - df); chamber.writeF(pm - chb)
        let po = 2 * (8 * chf + 2.4 * tb) / 10.4
        chamber.writeB(po - chf); tail.writeF(po - tb)

        // ponta aberta + radiação
        tailLP += tailCoef * (tf - tailLP)
        let refl = -0.88 * tailLP
        tail.writeB(refl)
        let u = tf - refl
        radLP += radCoef * (u - radLP)
        let rasp = raspBP.run(rng.bipolar()) * max(0, u) * (0.15 + 0.85 * load) * (0.3 + 0.7 * min(1, rpm / 6500)) * 2.5
        return ((u - radLP) * 3 + rasp, cross)
    }

    mutating func trigger(amp: Float, spike sp: Float, decay: Float) {
        burst = max(burst, amp); spike = sp; burstDecay = decay
    }
}

// MARK: - Motor

final class M156DSP {
    static let cGas: Float = 520     // velocidade do som nos gases de escape (~400 °C), m/s

    // Mercedes: 1–4 banco A, 5–8 banco B. Ordem de ignição 1-5-4-2-6-3-7-8.
    private static let order = [1, 5, 4, 2, 6, 3, 7, 8]
    private static let evoDeg: Float = 128            // abertura da válvula de escape, ° após PMS
    private static let exhaustOpenDeg: Float = 250

    private let sr: Float
    private let p: UnsafeMutablePointer<Float>
    private var rng = RNG()
    private var bankA: ExhaustBank, bankB: ExhaustBank
    private var cross: Pipe
    private var theta: Float = 0       // ângulo de cambota 0..720
    private var rpm: Float = 0
    private var cylAmp = [Float](repeating: 1, count: 8)
    private var cylJit = [Float](repeating: 0, count: 8)
    private var in1, in2, in3, mech, boom: Biquad
    private var lpI1: Float = 0, lpI2: Float = 0
    private var bassLP: Float = 0, bassHP: Float = 0, bassPrev: Float = 0
    private var dcX: (Float, Float) = (0, 0), dcY: (Float, Float) = (0, 0)
    private var gain: Float = 0
    // ---- arranque (cambota simulada à taxa de áudio) ----
    private var crankMode = 0          // 0 normal, 1 motor de arranque engrenado, 2 pegou
    private var omega: Float = 0, crankTime: Float = 0, fireStart: Float = 0, sinceCatch: Float = 0
    private var lastStarter: Float = 0, consecFires = 0, crankLoad: Float = 0
    private var cylFiring = [Bool](repeating: false, count: 8)
    private var armF: Float = 0, armAmp: Float = 0, phMesh: Float = 0, phArm: Float = 0, meshLP: Float = 0, spinT: Float = 0
    private var click1: Float = 0, click2: Float = 0, click2Done = true
    private var solA, solB, clunk, housing, brush: Biquad
    private let click1Decay, click2Decay, armDecay: Float
    private var lastPop: Float = 0
    // coeficientes dependentes da taxa de amostragem
    private let rpmCoef, gainCoef, dcPole, cabinCoef, bassCoef, popDecay: Float

    init(sampleRate: Float, params: UnsafeMutablePointer<Float>) {
        let sr = sampleRate
        self.sr = sr; p = params
        bankA = ExhaustBank(side: 0, sr: sr)
        bankB = ExhaustBank(side: 1, sr: sr)
        cross = Pipe(meters: 0.25, loss: 0.995, fc: 6000, sr: sr)
        in1 = Biquad(bandpass: 170, q: 2.0, gain: 1.0, sr: sr)
        in2 = Biquad(bandpass: 520, q: 3.0, gain: 0.7, sr: sr)
        in3 = Biquad(bandpass: 1350, q: 2.5, gain: 0.45, sr: sr)
        mech = Biquad(bandpass: 4200, q: 0.8, gain: 1, sr: sr)
        boom = Biquad(bandpass: 55, q: 1.5, gain: 1, sr: sr)
        rpmCoef = 1 - exp(-1 / (0.014 * sr))
        gainCoef = 1 - exp(-1 / (0.04 * sr))
        dcPole = exp(-2 * Float.pi * 23 / sr)
        cabinCoef = 1 - exp(-2 * Float.pi * 700 / sr)
        bassCoef = 1 - exp(-2 * Float.pi * 140 / sr)
        popDecay = exp(-1 / (0.006 * sr))
        solA = Biquad(bandpass: 2600, q: 4.0, gain: 1, sr: sr)      // solenoide: estalo metálico
        solB = Biquad(bandpass: 850, q: 3.0, gain: 1, sr: sr)
        clunk = Biquad(bandpass: 380, q: 2.0, gain: 1, sr: sr)      // pinhão a engrenar na coroa
        housing = Biquad(bandpass: 1150, q: 2.5, gain: 1, sr: sr)   // ressonância da carcaça
        brush = Biquad(bandpass: 3600, q: 1.2, gain: 1, sr: sr)     // escovas/comutador
        click1Decay = exp(-1 / (0.012 * sr))
        click2Decay = exp(-1 / (0.03 * sr))
        armDecay = exp(-1 / (0.22 * sr))
    }

    @inline(__always) private func gaussBump(_ x: Float, _ c: Float, _ w: Float) -> Float {
        let d = (x - c) / w
        return exp(-d * d)
    }

    /// Dinâmica da cambota com o motor de arranque: binário do motor DC (linear com a velocidade),
    /// compressão de cada cilindro (resiste antes do PMS, devolve parte depois), atrito a frio
    /// e as primeiras combustões. Daqui sai o "rrr-rrr" a 4 compressões por rotação.
    @inline(__always) private func crankStep() {
        crankTime += 1 / sr
        if crankTime > 0.035 && !click2Done { click2 = 1; click2Done = true }
        let engage: Float = crankTime < 0.07 ? 0 : min(1, (crankTime - 0.07) / 0.05)
        let t0: Float = 330, w0: Float = 330 * 2 * .pi / 60, j: Float = 0.45
        let ts = engage * t0 * max(0, 1 - omega / w0)
        let tfric: Float = (engage > 0 || omega > 0) ? 55 + 0.6 * omega : 0
        var tc: Float = 0, tcomp: Float = 0
        for k in 0..<8 {
            var a = theta - Float(k) * 90
            if a > 360 { a -= 720 }
            if a < -360 { a += 720 }
            if a > -160 && a < 0 {
                let c = 330 * gaussBump(a, -28, 24); tc += c; tcomp += c
            } else if a >= 0 && a < 120 {
                tc -= 250 * gaussBump(a, 28, 24)
                if cylFiring[M156DSP.order[k] - 1] { tc -= 1100 * gaussBump(a, 22, 26) }
            }
        }
        crankLoad = min(1, tcomp / 330)
        omega = max(0, omega + (ts - tfric - tc) / j / sr)
        rpm = omega * 60 / (2 * .pi)
        if rpm > 560 && consecFires >= 3 {
            crankMode = 2; sinceCatch = 0; spinT = 0; click1 = 0.5
            p[EngineSynth.Param.caught.rawValue] = 1
        }
        p[EngineSynth.Param.crankRpm.rawValue] = rpm
    }

    /// Engrenamento pinhão (10 dentes) / coroa (130): f = rotação da cambota × 130.
    /// Induzido com redutor planetário 4:1: f = cambota × 13 × 4. Escovas = ruído modulado pela corrente.
    @inline(__always) private func starterSound() -> Float {
        var clicks: Float = 0
        if click1 > 0.001 {
            let n = rng.bipolar() * click1
            clicks += (solA.run(n) + 0.6 * solB.run(n)) * 2.2
            click1 *= click1Decay
        }
        if click2 > 0.001 {
            let n = rng.bipolar() * click2
            clicks += clunk.run(n) * 3 + solB.run(n) * 0.8
            click2 *= click2Decay
        }
        var engF: Float = 0, amp: Float = 0, ld: Float = 0
        if crankMode == 1 && crankTime > 0.07 {
            engF = omega / (2 * .pi); armF = engF * 52; amp = 1; ld = crankLoad; armAmp = 1
        } else if armAmp > 0.002 {                      // desengrenou: induzido livre acelera e depois para
            spinT += 1 / sr
            let target: Float = spinT < 0.06 ? 400 * 52 / 60 : 0
            armF += (target - armF) * (spinT < 0.06 ? 0.0006 : 0.00008) * (48_000 / sr)
            armAmp *= armDecay
            engF = armF / 52; amp = armAmp; ld = 0.15
        }
        var st: Float = 0
        if amp > 0 {
            phMesh += engF * 130 / sr; if phMesh > 1 { phMesh -= 1 }
            phArm += armF / sr; if phArm > 1 { phArm -= 1 }
            let mesh: Float = phMesh < 0.18 ? 1 : -0.22             // impacto de dente
            meshLP += 0.35 * (mesh - meshLP)
            let arm = sin(2 * .pi * phArm) + 0.5 * sin(4 * .pi * phArm)
            let br = brush.run(rng.bipolar()) * (0.3 + 0.7 * ld)
            let raw = meshLP * (0.25 + 0.75 * ld) + 0.45 * arm * (0.4 + 0.6 * ld) + br * 0.35
            st = (0.5 * raw + housing.run(raw) * 1.4) * amp * 0.09
        }
        return st + clicks * 0.35
    }


    deinit { bankA.free(); bankB.free(); cross.free() }

    @inline(__always) private func pulse(_ phi: Float, _ a: Float, _ disp: Float) -> Float {
        guard phi >= 0, phi < M156DSP.exhaustOpenDeg, rpm > 1 else { return 0 }
        let t = phi / (6 * rpm)                                  // s desde a abertura
        let td: Float = 0.0011 + 0.2 * (24 / (6 * rpm))
        let blow = a * 1.25 * (1 - exp(-t / 0.00018)) * exp(-t / td)
        return blow + disp * sin(Float.pi * phi / M156DSP.exhaustOpenDeg)
    }

    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let rpmT = p[EngineSynth.Param.rpm.rawValue]
        let load = p[EngineSynth.Param.load.rawValue]
        let throttle = p[EngineSynth.Param.throttle.rawValue]
        let ign = p[EngineSynth.Param.ignition.rawValue] > 0.5
        let starter = p[EngineSynth.Param.starter.rawValue]
        let volume = p[EngineSynth.Param.volume.rawValue]
        let interior = p[EngineSynth.Param.interior.rawValue] > 0.5
        let crackle = p[EngineSynth.Param.crackle.rawValue]
        let popCount = p[EngineSynth.Param.popCount.rawValue]
        let boost = p[EngineSynth.Param.speakerBoost.rawValue] > 0.5

        // estalo de passagem de caixa (Sport+)
        if popCount != lastPop {
            lastPop = popCount
            bankA.trigger(amp: 0.6 + 0.4 * rng.next(), spike: 0.9, decay: popDecay)
            bankB.trigger(amp: 0.6 + 0.4 * rng.next(), spike: 0.9, decay: popDecay)
        }
        let crackleProb = 28 * crackle / sr
        let gainTarget: Float = (rpmT > 1 || starter > 0 || rpm > 30 || armAmp > 0.002) ? volume : 0
        let pi = Float.pi

        for i in 0..<frames {
            // chave rodada → solenoide, pinhão engrena, cambota passa a ser simulada aqui
            if starter > 0.5 && lastStarter <= 0.5 && crankMode != 1 {
                crankMode = 1; crankTime = 0; consecFires = 0
                omega = rpm * 2 * pi / 60
                fireStart = 0.6 + 0.4 * rng.next()
                click1 = 1; click2Done = false
                for c in 0..<8 { cylFiring[c] = false; cylAmp[c] = 0 }
                gain = volume
            }
            lastStarter = starter
            if crankMode == 1 {
                crankStep()
            } else if crankMode == 2 {
                sinceCatch += 1 / sr
                if rpmT >= rpm * 0.85 || sinceCatch > 0.12 { crankMode = 0 }     // o modelo assumiu
                else {
                    omega += 2000 / sr; rpm = omega * 60 / (2 * pi)
                    p[EngineSynth.Param.crankRpm.rawValue] = rpm
                }
            } else {
                rpm += (rpmT - rpm) * rpmCoef
            }
            gain += (gainTarget - gain) * gainCoef
            let prevTheta = theta
            theta += rpm * 6 / sr
            if theta >= 720 { theta -= 720 }
            let cranking = crankMode == 1
            let loadEff: Float = cranking ? 0.55 : load

            // ---- fontes por cilindro ----
            var sA0: Float = 0, sA1: Float = 0, sA2: Float = 0, sA3: Float = 0
            var sB0: Float = 0, sB1: Float = 0, sB2: Float = 0, sB3: Float = 0
            var intake: Float = 0
            let idleness = max(0, 1 - rpm / 2500)
            let base: Float = 0.15 + 0.15 * max(0, min(1, (2500 - rpm) / 1500))
            let rpmFac: Float = 0.8 + 0.2 * min(1, rpm / 6000)
            for k in 0..<8 {
                let cyl = M156DSP.order[k]
                let ci = cyl - 1
                let tdc = Float(k) * 90
                var rel = theta - tdc; if rel < 0 { rel += 720 }
                var relPrev = prevTheta - tdc; if relPrev < 0 { relPrev += 720 }
                if rel < relPrev {                         // novo ciclo de combustão deste cilindro
                    let sigma: Float = 0.04 + 0.16 * (1 - load) * idleness
                    if cranking {                               // primeiras explosões irregulares (rica a frio)
                        let pf: Float = crankTime < fireStart ? 0 : min(0.9, (crankTime - fireStart) / 0.25)
                        let fire = rng.next() < pf
                        cylFiring[ci] = fire
                        consecFires = fire ? consecFires + 1 : 0
                        cylAmp[ci] = fire ? 0.7 + 0.6 * rng.next() : 0
                    } else {
                        cylFiring[ci] = false
                        cylAmp[ci] = ign ? max(0, 1 + sigma * rng.gauss()) : 0
                    }
                    cylJit[ci] = (rng.next() - 0.5) * 6 * idleness
                }
                let a = cylAmp[ci] * (base + (1 - base) * loadEff) * rpmFac + 0.045
                let s = pulse(rel - M156DSP.evoDeg - cylJit[ci], a, 0.10 * (0.4 + 0.6 * load))
                switch ci {
                case 0: sA0 = s
                case 1: sA1 = s
                case 2: sA2 = s
                case 3: sA3 = s
                case 4: sB0 = s
                case 5: sB1 = s
                case 6: sB2 = s
                default: sB3 = s
                }
                var iphi = rel - 350; if iphi < 0 { iphi += 720 }
                if iphi < 240 { intake -= sin(pi * iphi / 240) * (0.15 + 0.85 * throttle) }
            }

            // pós-combustão aleatória no escape em desaceleração
            if load < 0.05 && ign && crackleProb > 0 && rng.next() < crackleProb {
                let amp = (0.15 + 0.6 * rng.next()) * (0.4 + 0.6 * crackle)
                let dec = exp(-1 / ((0.002 + 0.005 * rng.next()) * sr))
                if rng.next() < 0.5 { bankA.trigger(amp: amp, spike: amp * 1.5, decay: dec) }
                else { bankB.trigger(amp: amp, spike: amp * 1.5, decay: dec) }
            }

            // ---- escape ----
            let xA = cross.b.read(), xB = cross.f.read()
            let (radA, crossA) = bankA.step(sA0, sA1, sA2, sA3, xin: xA, load: load, rpm: rpm, rng: &rng)
            let (radB, crossB) = bankB.step(sB0, sB1, sB2, sB3, xin: xB, load: load, rpm: rpm, rng: &rng)
            cross.writeF(crossA)
            cross.writeB(crossB)

            // ---- admissão, mecânica, arranque ----
            let rn = min(1.2, rpm / 7200)
            let ia = intake * (0.25 + rn)
            let ins = in1.run(ia) + in2.run(ia) * (0.3 + 0.7 * load) + in3.run(ia) * load * rn
            let mch = mech.run(rng.bipolar()) * (0.008 + 0.06 * rn) * (0.7 + 0.3 * sin(theta * pi / 90))
            let st = (crankMode != 0 || armAmp > 0.002 || click1 > 0.001 || click2 > 0.001) ? starterSound() : 0

            var L: Float, R: Float
            if !interior {                                    // exterior, atrás do carro
                L = radA + 0.6 * radB + 0.12 * ins + 0.05 * mch + st
                R = radB + 0.6 * radA + 0.12 * ins + 0.05 * mch + st
            } else {                                          // habitáculo
                let ex = 0.5 * (radA + radB)
                lpI1 += cabinCoef * (ex - lpI1); lpI2 += cabinCoef * (lpI1 - lpI2)
                let bm = boom.run(ex)
                let common = 1.1 * lpI2 + 1.6 * bm + 0.45 * ins + 0.08 * mch + st
                L = common + 0.12 * radA
                R = common + 0.12 * radB
            }

            // reforço de graves para o altifalante do telefone (harmónicos da fundamental)
            if boost {
                let mono = 0.5 * (L + R)
                bassLP += bassCoef * (mono - bassLP)
                let h = abs(bassLP)                           // retificação → dobra a frequência
                let hp = h - bassPrev + 0.995 * bassHP; bassPrev = h; bassHP = hp
                L += 1.4 * hp; R += 1.4 * hp
            }

            var vL = L * 0.75, vR = R * 0.75
            let oL = vL - dcX.0 + dcPole * dcY.0; dcX.0 = vL; dcY.0 = oL
            let oR = vR - dcX.1 + dcPole * dcY.1; dcX.1 = vR; dcY.1 = oR
            vL = tanh(oL); vR = tanh(oR)
            left[i] = vL * 0.85 * gain
            right[i] = vR * 0.85 * gain
        }
    }
}
