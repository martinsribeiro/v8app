import SwiftUI

@main
struct V8App: App {
    var body: some Scene {
        WindowGroup { ContentView().preferredColorScheme(.dark) }
    }
}

struct ContentView: View {
    @StateObject private var engine = EngineModel()
    @StateObject private var motion = MotionInput()
    @State private var manualThrottle = 0.0

    private let accent = Color(red: 1.0, green: 0.36, blue: 0.12)

    var body: some View {
        VStack(spacing: 18) {
            Tachometer(rpm: engine.rpm, limiter: engine.limiterOn, accent: accent)
                .frame(maxWidth: 260)
                .overlay(alignment: .bottom) { readout }

            pedals

            Button(action: engine.toggleIgnition) {
                Text(engine.running || engine.cranking ? "DESLIGAR" : "START")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .tracking(2)
                    .frame(width: 130, height: 130)
                    .background(Circle().fill(engine.running ? Color(white: 0.15) : accent))
                    .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 3))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            controls
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.06, green: 0.06, blue: 0.07).ignoresSafeArea())
        .onAppear { motion.start() }
        .onReceive(motion.$throttle) { _ in feed() }
        .onChange(of: manualThrottle) { _ in feed() }
        .onChange(of: motion.source) { s in if s == .gforce { engine.mode = .road } }
    }

    private func feed() {
        if motion.available {
            engine.throttle = motion.throttle
            engine.brake = motion.brake
            engine.realSpeed = motion.source == .gforce ? motion.carSpeed : nil
            engine.realAccelG = motion.longitudinalG
        } else {
            engine.throttle = manualThrottle      // simulador / sem sensores
            engine.brake = 0
        }
    }

    private var readout: some View {
        HStack(alignment: .lastTextBaseline, spacing: 22) {
            VStack(spacing: 0) {
                Text(engine.mode == .road ? "\(engine.gear)" : "N")
                    .font(.system(size: 44, weight: .black, design: .rounded))
                Text("MUDANÇA").font(.caption2).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                Text("\(Int(engine.rpm.rounded()))")
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                Text("RPM").font(.caption2).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                Text("\(Int(engine.speedKmh.rounded()))")
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                Text("KM/H").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .offset(y: 10)
    }

    private var pedals: some View {
        VStack(spacing: 6) {
            Bar(label: "ACELERADOR", value: engine.throttle, color: accent)
            Bar(label: "TRAVÃO", value: engine.brake, color: .red)
            if motion.source == .gforce {
                Text(String(format: "%+.2f g longitudinal · %@", motion.longitudinalG, motion.gpsOK ? "GPS" : "sem GPS"))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if !motion.status.isEmpty {
                    Text(motion.status).font(.caption).foregroundStyle(accent).multilineTextAlignment(.center)
                }
            }
            if !motion.available {
                Slider(value: $manualThrottle, in: 0...1) { Text("Acelerador manual") }
                    .tint(accent)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Picker("Modo", selection: $engine.mode) {
                ForEach(EngineModel.Mode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Picker("Som", selection: $engine.perspective) {
                ForEach(EngineModel.Perspective.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Picker("Entrada", selection: $motion.source) {
                ForEach(MotionInput.Source.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if motion.source == .gforce {
                HStack {
                    Text("Telemóvel").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Picker("Telemóvel", selection: $motion.mount) {
                        ForEach(MotionInput.Mount.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.menu).tint(accent)
                }
            }
            HStack {
                Text("Sensibilidade").font(.footnote).foregroundStyle(.secondary)
                Slider(value: $motion.sensitivity, in: 0...1).tint(accent)
            }
            HStack {
                Toggle("Inverter", isOn: $motion.invert).font(.footnote).fixedSize()
                Spacer()
                Button(motion.source == .gforce ? "Calibrar (parado)" : "Calibrar", action: motion.calibrate)
                    .buttonStyle(.bordered).tint(accent)
            }
        }
    }
}

struct Bar: View {
    let label: String, value: Double, color: Color
    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(color).frame(width: max(0, geo.size.width * value))
                }
            }.frame(height: 8)
        }
    }
}

/// Conta-rotações 0–8000 rpm, zona vermelha a partir das 7200 (M156).
struct Tachometer: View {
    let rpm: Double, limiter: Bool, accent: Color
    private let maxRpm = 8000.0
    private let start = Angle.degrees(135), sweep = 270.0

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2 - 8
            func ang(_ v: Double) -> Angle { .degrees(start.degrees + sweep * v / maxRpm) }
            func pt(_ v: Double, _ rr: CGFloat) -> CGPoint {
                let a = ang(v).radians
                return CGPoint(x: c.x + CGFloat(cos(a)) * rr, y: c.y + CGFloat(sin(a)) * rr)
            }
            // zona vermelha
            var red = Path()
            red.addArc(center: c, radius: r - 6, startAngle: ang(EngineModel.redline), endAngle: ang(maxRpm), clockwise: false)
            ctx.stroke(red, with: .color(.red.opacity(0.85)), lineWidth: 10)
            // marcas
            for i in stride(from: 0.0, through: maxRpm, by: 250) {
                let major = i.truncatingRemainder(dividingBy: 1000) == 0
                var p = Path()
                p.move(to: pt(i, r - (major ? 24 : 14)))
                p.addLine(to: pt(i, r - 2))
                ctx.stroke(p, with: .color(.white.opacity(major ? 0.9 : 0.4)), lineWidth: major ? 3 : 1.2)
                if major {
                    let t = Text("\(Int(i / 1000))").font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundColor(.white)
                    ctx.draw(t, at: pt(i, r - 42))
                }
            }
            ctx.draw(Text("M156 · ×1000 rpm").font(.caption2).foregroundColor(.gray), at: CGPoint(x: c.x, y: c.y - r * 0.38))
            // ponteiro
            var needle = Path()
            needle.move(to: c)
            needle.addLine(to: pt(min(rpm, maxRpm), r - 10))
            ctx.stroke(needle, with: .color(limiter ? .red : accent), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)), with: .color(Color(white: 0.2)))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
