import SwiftUI
import AtlasCore

/// The live TfL JamCam monitor. It takes the hero slot when a camera is
/// selected, so the map and the bottom dock keep their layout.
struct CameraMonitor: View {
    let camera: JamCam
    let compact: Bool
    let onLocate: () -> Void
    let onClose: () -> Void

    @State private var refreshNonce = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 120)) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    LiveDot(color: AtlasTheme.rose)
                    Text("TFL JAMCAM")
                        .font(.system(size: 8.5, weight: .black))
                        .tracking(2)
                        .foregroundStyle(AtlasTheme.rose)
                    Spacer(minLength: 8)
                    Text(camera.isAvailable ? "LIVE" : "OFFLINE")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(camera.isAvailable ? AtlasTheme.rose : Color.white.opacity(0.4))
                }

                snapshot(at: context.date)

                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(camera.name)
                            .font(.system(size: 16, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                        Text(camera.view.isEmpty ? "TfL traffic camera" : camera.view)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(AtlasTheme.secondaryText)
                            .lineLimit(1)
                        Text("Refreshes every 2 min")
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.35))
                    }
                    Spacer(minLength: 4)
                    Button {
                        refreshNonce &+= 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 30, height: 30)
                            .foregroundStyle(.white.opacity(0.85))
                            .background(Color.white.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Refresh camera")

                    Button(action: onLocate) {
                        Image(systemName: "scope")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 30, height: 30)
                            .foregroundStyle(.white.opacity(0.85))
                            .background(Color.white.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Locate camera")

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 30, height: 30)
                            .foregroundStyle(.white.opacity(0.75))
                            .background(Color.white.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close camera")
                }
            }
            .padding(12)
            .frame(maxWidth: compact ? .infinity : 340, alignment: .leading)
            .glass(radius: 23, tint: AtlasTheme.rose)
        }
    }

    @ViewBuilder
    private func snapshot(at date: Date) -> some View {
        ZStack {
            Color.black.opacity(0.82)

            if camera.isAvailable {
                AsyncImage(
                    url: snapshotURL(at: date),
                    transaction: Transaction(animation: .easeInOut(duration: 0.2))
                ) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    case .failure:
                        placeholder(icon: "video.slash", text: "Feed unavailable")
                    case .empty:
                        VStack(spacing: 8) {
                            ProgressView().tint(.white.opacity(0.8))
                            Text("Connecting…")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.45))
                        }
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                placeholder(icon: "video.slash", text: "Camera offline")
            }
        }
        .aspectRatio(352.0 / 288.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        }
        .overlay(alignment: .topLeading) {
            if camera.isAvailable {
                HStack(spacing: 4) {
                    Circle().fill(AtlasTheme.rose).frame(width: 5, height: 5)
                    Text("LIVE")
                        .font(.system(size: 7.5, weight: .black, design: .monospaced))
                        .tracking(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.55), in: Capsule())
                .padding(8)
            }
        }
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(AtlasTheme.rose.opacity(0.7))
            Text(text)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.5))
        }
    }

    /// TfL overwrites the same S3 object, so use a two-minute cache key and a
    /// manual nonce to force a fresh frame.
    private func snapshotURL(at date: Date) -> URL? {
        guard let base = camera.imageURL,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return camera.imageURL
        }
        let window = Int(date.timeIntervalSince1970 / 120)
        components.queryItems = [URLQueryItem(name: "t", value: "\(window)-\(refreshNonce)")]
        return components.url
    }
}
