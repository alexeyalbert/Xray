import SwiftUI

struct TicklessSimilaritySlider: NSViewRepresentable {
    @Binding var value: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: value,
            minValue: 0,
            maxValue: 0.95,
            target: context.coordinator,
            action: #selector(Coordinator.valueChanged(_:))
        )
        slider.controlSize = .small
        slider.sliderType = .linear
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        slider.isContinuous = true
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        if abs(slider.doubleValue - value) > 0.0001 {
            slider.doubleValue = value
        }
    }

    final class Coordinator: NSObject {
        @Binding private var value: Double

        init(value: Binding<Double>) {
            _value = value
        }

        @objc func valueChanged(_ sender: NSSlider) {
            value = (sender.doubleValue * 100).rounded() / 100
        }
    }
}
