import SwiftUI

private enum AppSurfaceStyle {
    static let cornerRadius: CGFloat = 20
}

extension View {
    func appSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: AppSurfaceStyle.cornerRadius, style: .continuous)
        return background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }

    @ViewBuilder
    func appSecondaryAction() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func appPrimaryAction(tint: Color = .accentColor) -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent).tint(tint)
        } else {
            buttonStyle(.borderedProminent).tint(tint)
        }
    }
}
