import AppKit
import SwiftUI

struct ScanSplashView: View {
    let progress: Double

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .stroke(Color.accentColor.opacity(0.18), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                logo
            }
            .frame(width: 180, height: 180)

            VStack(spacing: 7) {
                Text("Mac Superpowers")
                    .font(.title.bold())
                Text("Analisando seu Mac… \(Int((progress * 100).rounded()))%")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mac Superpowers analisando seu Mac, \(Int((progress * 100).rounded())) por cento")
    }

    @ViewBuilder
    private var logo: some View {
        if let url = Bundle.module.url(forResource: "AppIcon-1024", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 132, height: 132)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 74))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
        }
    }
}
