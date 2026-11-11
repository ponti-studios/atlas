import SwiftUI

#if os(macOS)
import AppKit
#endif

// MARK: - Palette

enum AtlasTheme {
    static let background = Color(red: 0.024, green: 0.035, blue: 0.065)
    static let ink = Color(red: 0.047, green: 0.063, blue: 0.106)
    static let lime = Color(red: 0.486, green: 1.000, blue: 0.769)
    static let cyan = Color(red: 0.357, green: 0.839, blue: 1.000)
    static let amber = Color(red: 1.000, green: 0.741, blue: 0.322)
    static let coral = Color(red: 1.000, green: 0.427, blue: 0.478)
    static let violet = Color(red: 0.702, green: 0.596, blue: 1.000)
    static let rose = Color(red: 1.000, green: 0.435, blue: 0.682)
    static let secondaryText = Color.white.opacity(0.58)
    static let hairline = Color.white.opacity(0.10)
}

// MARK: - Features

enum AtlasFeature: Int, CaseIterable, Identifiable {
    case walks, places, flights, parcels, tfl, cameras

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .walks: return "Walks"
        case .places: return "Places"
        case .flights: return "Flights"
        case .parcels: return "Parcels"
        case .tfl: return "TFL"
        case .cameras: return "Cameras"
        }
    }

    var eyebrow: String {
        switch self {
        case .walks: return "WALKS / ARCHIVE"
        case .places: return "PLACES / SAVED"
        case .flights: return "FLIGHTS / ITINERARY"
        case .parcels: return "PARCELS / TRACKING"
        case .tfl: return "TFL / NETWORK"
        case .cameras: return "CAMERAS / LIVE"
        }
    }

    var icon: String {
        switch self {
        case .walks: return "figure.walk"
        case .places: return "mappin.and.ellipse"
        case .flights: return "airplane"
        case .parcels: return "shippingbox.fill"
        case .tfl: return "tram.fill"
        case .cameras: return "video.fill"
        }
    }

    var accent: Color {
        switch self {
        case .walks: return AtlasTheme.lime
        case .places: return AtlasTheme.cyan
        case .flights: return AtlasTheme.violet
        case .parcels: return AtlasTheme.amber
        case .tfl: return AtlasTheme.coral
        case .cameras: return AtlasTheme.rose
        }
    }

    var blurb: String {
        switch self {
        case .walks: return "Every route you have walked, drawn on the map."
        case .places: return "The coordinates that matter, pinned and glowing."
        case .flights: return "Great-circle paths between the airports on your itinerary."
        case .parcels: return "Live last-known positions for everything in transit."
        case .tfl: return "The London network, station by station."
        case .cameras: return "Live TfL traffic cameras across London's roads."
        }
    }
}

// MARK: - Selection

enum AtlasSelection: Equatable, Hashable {
    case walk(UUID)
    case place(UUID)
    case flight(UUID)
    case parcel(UUID)
    case station(String)
    case camera(String)
}

// MARK: - Cards & stats

struct AtlasCard: Identifiable {
    let id: String
    let selection: AtlasSelection
    let title: String
    let subtitle: String
    let badge: String
    let icon: String
    let metric: String
}

struct HeroStat: Identifiable {
    let id: String
    let label: String
    let value: String
}

// MARK: - Glass

struct AtlasGlass: ViewModifier {
    var radius: CGFloat = 20
    var tint: Color = AtlasTheme.lime
    var strength: Double = 0.46

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(AtlasTheme.background.opacity(strength))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [tint.opacity(0.52), Color.white.opacity(0.10), Color.white.opacity(0.03)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.42), radius: 26, x: 0, y: 14)
            .shadow(color: tint.opacity(0.08), radius: 18)
    }
}

extension View {
    func glass(radius: CGFloat = 20, tint: Color = AtlasTheme.lime, strength: Double = 0.46) -> some View {
        modifier(AtlasGlass(radius: radius, tint: tint, strength: strength))
    }
}

// MARK: - Live dot

struct LiveDot: View {
    let color: Color
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: color, radius: pulsing ? 7 : 2)
            .scaleEffect(pulsing ? 1.25 : 0.85)
            .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

// MARK: - macOS window chrome

#if os(macOS)
/// Blends the window title bar into the map so the base layer runs edge to edge.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            FrameProbe.shared.attach(window: window)
            window.appearance = NSAppearance(named: .darkAqua)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = NSColor(red: 0.024, green: 0.035, blue: 0.065, alpha: 1)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif

// MARK: - TFL line colours

enum TFLPalette {
    static func color(for line: String) -> Color {
        switch line.lowercased() {
        case "central": return Color(red: 0.898, green: 0.176, blue: 0.192)
        case "victoria": return Color(red: 0.000, green: 0.635, blue: 0.851)
        case "bakerloo": return Color(red: 0.702, green: 0.416, blue: 0.153)
        case "northern": return Color(red: 0.878, green: 0.878, blue: 0.898)
        case "jubilee": return Color(red: 0.549, green: 0.549, blue: 0.580)
        case "piccadilly": return Color(red: 0.000, green: 0.149, blue: 0.600)
        case "district": return Color(red: 0.000, green: 0.502, blue: 0.302)
        case "circle": return Color(red: 0.949, green: 0.800, blue: 0.000)
        case "metropolitan": return Color(red: 0.600, green: 0.000, blue: 0.251)
        case "hammersmith & city": return Color(red: 0.949, green: 0.600, blue: 0.639)
        case "waterloo & city": return Color(red: 0.549, green: 0.780, blue: 0.851)
        case "elizabeth": return Color(red: 0.400, green: 0.302, blue: 0.549)
        default: return AtlasTheme.lime
        }
    }
}
