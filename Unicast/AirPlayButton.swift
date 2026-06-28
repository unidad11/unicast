import SwiftUI
import AVKit

/// Botón nativo de AirPlay: abre el selector de altavoces y dispositivos del sistema.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = UIColor(Theme.textSecondary)
        picker.activeTintColor = UIColor(Theme.accent)
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
