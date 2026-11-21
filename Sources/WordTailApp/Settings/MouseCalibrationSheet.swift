import Combine
import SwiftUI
import WordTailCore

struct MouseCalibrationSheet: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: SettingsViewModel

    @State private var isMeasuring: Bool = false
    @State private var measuredPixels: Double = 0
    @State private var statusMessage: String = "Prepare a 10 cm reference along a ruler or trackpad edge."
    @State private var isError: Bool = false

    private let sampleTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "ruler.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LinearUI.accent)
                    .frame(width: 30, height: 30)
                    .background(LinearUI.accent.opacity(scheme == .dark ? 0.18 : 0.11), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text("Mouse Distance Calibration")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Current multiplier: \(String(format: "%.2f×", vm.mouseCalibrationFactor))")
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            LinearCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Click **Start Measuring** below.")
                    Text("2. Place your cursor near one end of a 10 cm mark and move smoothly 10 cm in a straight line.")
                    Text("3. Click **Finish & Apply** to save the scaling factor.")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MEASURED MOVEMENT")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.tertiary)
                    Text("\(Int(measuredPixels.rounded())) px")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(isMeasuring ? LinearUI.accent : Color.primary)
                }

                Spacer()

                let estimatedMeters = measuredPixels * vm.mouseCalibrationFactor * KeyStatsAggregateSnapshot.metersPerPixel
                VStack(alignment: .trailing, spacing: 2) {
                    Text("AT CURRENT SCALE")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.tertiary)
                    Text(String(format: "%.1f cm", estimatedMeters * 100.0))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(LinearUI.subtleFill(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(statusMessage)
                .font(.system(size: 11.5, weight: isError ? .medium : .regular))
                .foregroundStyle(isError ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if abs(vm.mouseCalibrationFactor - 1.0) > 0.01 {
                    LinearActionButton(title: "Reset 1.00×", icon: "arrow.counterclockwise") {
                        vm.resetMouseCalibrationFactor()
                        statusMessage = "Calibration multiplier reset to 1.00×."
                        isError = false
                    }
                }

                Spacer()

                LinearActionButton(title: "Close", icon: nil) {
                    vm.cancelMouseCalibration()
                    dismiss()
                }

                if isMeasuring {
                    Button {
                        if let res = vm.finishMouseCalibration() {
                            isMeasuring = false
                            measuredPixels = res.pixels
                            isError = false
                            statusMessage = "Saved \(String(format: "%.2f×", res.factor)) from \(Int(res.pixels.rounded())) px measured across 10 cm."
                        } else {
                            isError = true
                            statusMessage = "Move at least 40 px before finishing, then try again."
                        }
                    } label: {
                        Text("Finish & Apply")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 26)
                            .background(LinearUI.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        vm.beginMouseCalibration()
                        measuredPixels = 0
                        isMeasuring = true
                        isError = false
                        statusMessage = "Recording mouse movement… Glide 10 cm now, then click Finish & Apply."
                    } label: {
                        Text("Start Measuring")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 26)
                            .background(LinearUI.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(18)
        .frame(width: 410)
        .onReceive(sampleTimer) { _ in
            guard isMeasuring else { return }
            measuredPixels = vm.currentMouseCalibrationPixels()
        }
        .onDisappear {
            vm.cancelMouseCalibration()
        }
    }
}
