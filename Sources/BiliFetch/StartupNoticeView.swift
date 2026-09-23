import SwiftUI

struct StartupNoticeView: View {
    static let message = "本软件仅供学习交流使用，首先确保您有权下载用户视频，如无请于下载后24小时删除下载内容。下载者涉及版权侵权等问题和软件作者无关，请勿触犯法律法规，正确正当使用本软件！"
    let acknowledge: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("软件使用声明", systemImage: "info.circle.fill")
                .font(.system(size: 24, weight: .semibold))

            Text(Self.message)
                .font(.system(size: 16))
                .lineSpacing(7)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(spacing: 12) {
                Spacer()
                Button("退出软件") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button("我已知晓", action: acknowledge)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: 670)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
