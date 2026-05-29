import SwiftUI

enum IrisVariant: String, CaseIterable {
    case eye        // V1 - organic violet iris
    case aperture   // V2 - aperture-blade hybrid, teal/blue
    case minimal    // V3 - bold simplified iris

    var title: String {
        switch self {
        case .eye: return "V1 Iris eye (violet)"
        case .aperture: return "V2 Aperture-iris (teal)"
        case .minimal: return "V3 Minimal iris (violet)"
        }
    }
}

/// A single app-icon rendered at `size` points. All geometry is proportional
/// to `size`, so the same View renders crisply at 1024 or 16.
struct IrisIcon: View {
    let variant: IrisVariant
    let size: CGFloat

    var body: some View {
        ZStack {
            tile
            glyph
        }
        .frame(width: size, height: size)
    }

    // macOS-style squircle tile, full-bleed square canvas behind it.
    private var tile: some View {
        let corner = size * 0.2237 // Apple icon continuous-corner ratio
        return RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(tileGradient)
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: size * 0.006)
            )
    }

    private var tileGradient: LinearGradient {
        switch variant {
        case .eye:
            return LinearGradient(
                colors: [Color(red: 0.10, green: 0.06, blue: 0.20),
                         Color(red: 0.03, green: 0.02, blue: 0.08)],
                startPoint: .top, endPoint: .bottom)
        case .aperture:
            return LinearGradient(
                colors: [Color(red: 0.09, green: 0.12, blue: 0.16),
                         Color(red: 0.03, green: 0.04, blue: 0.07)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        case .minimal:
            return LinearGradient(
                colors: [Color(red: 0.14, green: 0.09, blue: 0.24),
                         Color(red: 0.05, green: 0.03, blue: 0.11)],
                startPoint: .top, endPoint: .bottom)
        }
    }

    @ViewBuilder
    private var glyph: some View {
        // ~14% inner padding -> glyph diameter is 72% of the tile.
        let pad = size * 0.14
        let d = size - pad * 2
        switch variant {
        case .eye: EyeIris(diameter: d)
        case .aperture: ApertureIris(diameter: d)
        case .minimal: MinimalIris(diameter: d)
        }
    }
}

// MARK: - V1 organic violet iris

private struct EyeIris: View {
    let diameter: CGFloat

    var body: some View {
        ZStack {
            // outer iris disc, violet -> indigo radial
            Circle()
                .fill(RadialGradient(
                    colors: [Color(red: 0.66, green: 0.42, blue: 0.92),
                             Color(red: 0.42, green: 0.22, blue: 0.78),
                             Color(red: 0.22, green: 0.10, blue: 0.46)],
                    center: .center, startRadius: 0, endRadius: diameter * 0.5))

            // radial striations
            ForEach(0..<48, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(i.isMultiple(of: 2) ? 0.10 : 0.04))
                    .frame(width: diameter * 0.012, height: diameter * 0.34)
                    .offset(y: -diameter * 0.205)
                    .rotationEffect(.degrees(Double(i) / 48 * 360))
            }

            // limbal ring (dark outer rim)
            Circle()
                .strokeBorder(Color.black.opacity(0.45), lineWidth: diameter * 0.04)

            // inner ring shadow around pupil
            Circle()
                .stroke(Color.black.opacity(0.5), lineWidth: diameter * 0.03)
                .frame(width: diameter * 0.40, height: diameter * 0.40)
                .blur(radius: diameter * 0.01)

            // pupil
            Circle()
                .fill(RadialGradient(
                    colors: [Color(red: 0.05, green: 0.02, blue: 0.10), .black],
                    center: .center, startRadius: 0, endRadius: diameter * 0.2))
                .frame(width: diameter * 0.36, height: diameter * 0.36)

            // specular highlight
            Circle()
                .fill(RadialGradient(
                    colors: [Color.white.opacity(0.95), Color.white.opacity(0.0)],
                    center: .center, startRadius: 0, endRadius: diameter * 0.075))
                .frame(width: diameter * 0.15, height: diameter * 0.15)
                .offset(x: -diameter * 0.12, y: -diameter * 0.14)
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - V2 aperture-iris hybrid (teal/blue, geometric)

private struct ApertureIris: View {
    let diameter: CGFloat
    private let blades = 6

    var body: some View {
        ZStack {
            // faint outer ring
            Circle()
                .stroke(Color(red: 0.20, green: 0.55, blue: 0.62).opacity(0.5),
                        lineWidth: diameter * 0.035)

            // aperture blades forming a hexagonal opening
            ForEach(0..<blades, id: \.self) { i in
                ApertureBlade()
                    .fill(LinearGradient(
                        colors: [Color(red: 0.25, green: 0.74, blue: 0.82),
                                 Color(red: 0.12, green: 0.42, blue: 0.62)],
                        startPoint: .top, endPoint: .bottom))
                    .overlay(
                        ApertureBlade()
                            .stroke(Color.black.opacity(0.35), lineWidth: diameter * 0.006)
                    )
                    .frame(width: diameter, height: diameter)
                    .rotationEffect(.degrees(Double(i) / Double(blades) * 360))
            }

            // central polygon opening = pupil
            RegularPolygon(sides: blades)
                .fill(RadialGradient(
                    colors: [Color(red: 0.02, green: 0.10, blue: 0.14), .black],
                    center: .center, startRadius: 0, endRadius: diameter * 0.18))
                .frame(width: diameter * 0.34, height: diameter * 0.34)
                .rotationEffect(.degrees(30))

            // specular glint on rim of opening
            Circle()
                .fill(RadialGradient(
                    colors: [Color.white.opacity(0.85), Color.white.opacity(0.0)],
                    center: .center, startRadius: 0, endRadius: diameter * 0.05))
                .frame(width: diameter * 0.1, height: diameter * 0.1)
                .offset(x: -diameter * 0.1, y: -diameter * 0.12)
        }
        .frame(width: diameter, height: diameter)
    }
}

/// One aperture blade: a curved wedge sweeping from the rim toward the center,
/// leaving a polygonal opening when 6 are overlaid.
private struct ApertureBlade: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = rect.width / 2
        var p = Path()
        // a wedge: outer arc + slanted inner edge tangent to the opening
        let openR = r * 0.34
        let a0 = Angle.degrees(-90 - 60)
        let a1 = Angle.degrees(-90 + 60)
        p.addArc(center: c, radius: r * 0.96, startAngle: a0, endAngle: a1, clockwise: false)
        // inner edge: a chord offset toward center creating a straight blade edge
        let inner = CGPoint(x: c.x + openR * cos(CGFloat(a1.radians)),
                            y: c.y + openR * sin(CGFloat(a1.radians)))
        p.addLine(to: inner)
        let innerStart = CGPoint(x: c.x + openR * cos(CGFloat(a0.radians)),
                                 y: c.y + openR * sin(CGFloat(a0.radians)))
        p.addLine(to: innerStart)
        p.closeSubpath()
        return p
    }
}

private struct RegularPolygon: Shape {
    let sides: Int
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = rect.width / 2
        var p = Path()
        for i in 0..<sides {
            let a = CGFloat(i) / CGFloat(sides) * 2 * .pi - .pi / 2
            let pt = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

// MARK: - V3 minimal iris (survives at 16px)

private struct MinimalIris: View {
    let diameter: CGFloat

    var body: some View {
        ZStack {
            // bold violet ring
            Circle()
                .strokeBorder(
                    AngularGradient(
                        colors: [Color(red: 0.70, green: 0.46, blue: 0.96),
                                 Color(red: 0.46, green: 0.26, blue: 0.86),
                                 Color(red: 0.70, green: 0.46, blue: 0.96)],
                        center: .center),
                    lineWidth: diameter * 0.18)

            // pupil
            Circle()
                .fill(Color(red: 0.06, green: 0.03, blue: 0.12))
                .frame(width: diameter * 0.34, height: diameter * 0.34)

            // single specular highlight
            Circle()
                .fill(Color.white.opacity(0.9))
                .frame(width: diameter * 0.10, height: diameter * 0.10)
                .offset(x: -diameter * 0.085, y: -diameter * 0.10)
        }
        .frame(width: diameter, height: diameter)
    }
}
