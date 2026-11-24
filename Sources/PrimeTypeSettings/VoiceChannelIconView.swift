import SwiftUI

struct VoiceChannelIconView: View {
    let channel: VoiceCloudChannel?
    var isError: Bool = false
    var size: CGFloat = 22
    var cornerRadius: CGFloat = 6

    var body: some View {
        Group {
            if isError {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(red: 0.88, green: 0.27, blue: 0.32))
                    Image(systemName: "exclamationmark")
                        .font(.system(size: round(size * 0.52), weight: .bold))
                        .foregroundStyle(.white)
                }
            } else if let channel, let nsImage = NSImage(named: channel.iconAssetName) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.accentColor)
                    Image(systemName: "mic.fill")
                        .font(.system(size: round(size * 0.50), weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
    }
}
