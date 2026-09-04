import AppKit
import Combine
import CoreImage.CIFilterBuiltins
import SwiftUI

struct BilibiliLoginSheet: View {
    @ObservedObject var model: DownloadViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var qrCode: BilibiliQRCode?
    @State private var qrImage: NSImage?
    @State private var message = "正在获取 B 站登录二维码…"
    @State private var isLoading = false
    @State private var isPolling = false

    private let pollTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.title2)
                    .foregroundStyle(.pink)
                VStack(alignment: .leading, spacing: 3) {
                    Text("登录 B 站")
                        .font(.headline)
                    Text("使用 B 站官方扫码接口；BiliFetch 不读取或保存账号、密码。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(16)

            Divider()

            VStack(spacing: 18) {
                if model.isBilibiliLoggedIn {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 96))
                        .foregroundStyle(.green)
                    Text("B 站账号已连接")
                        .font(.title2.bold())
                } else if let qrImage {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 260, height: 260)
                        .padding(16)
                        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Text("请使用哔哩哔哩手机客户端扫码并确认")
                        .font(.headline)
                } else if isLoading {
                    ProgressView()
                        .controlSize(.large)
                    Text("正在生成二维码…")
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "qrcode")
                        .font(.system(size: 90))
                        .foregroundStyle(.secondary)
                    Text("二维码尚未就绪")
                        .font(.headline)
                }

                Label(message, systemImage: statusSymbol)
                    .font(.callout)
                    .foregroundStyle(model.isBilibiliLoggedIn ? Color.green : Color.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)

            Divider()

            HStack(spacing: 12) {
                if model.isBilibiliLoggedIn {
                    Button("退出登录") {
                        model.logOutBilibili {
                            message = "已清除 B 站登录状态，可重新扫码。"
                            requestQRCode()
                        }
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                if !model.isBilibiliLoggedIn {
                    Button("刷新二维码", action: requestQRCode)
                        .buttonStyle(.borderedProminent)
                        .tint(.pink)
                        .disabled(isLoading)
                } else {
                    Button("完成") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .tint(.pink)
                }
            }
            .padding(14)
        }
        .frame(minWidth: 620, minHeight: 590)
        .onAppear {
            if model.isBilibiliLoggedIn {
                message = "下载时将使用当前账号可用的最高画质。"
            } else {
                requestQRCode()
            }
        }
        .onReceive(pollTimer) { _ in pollQRCode() }
    }

    private var statusSymbol: String {
        if model.isBilibiliLoggedIn { return "checkmark.circle.fill" }
        if qrCode != nil { return "iphone.and.arrow.forward" }
        return "info.circle"
    }

    private func requestQRCode() {
        guard !isLoading else { return }
        qrCode = nil
        qrImage = nil
        isLoading = true
        isPolling = false
        message = "正在获取 B 站登录二维码…"
        model.generateBilibiliQRCode { result in
            isLoading = false
            switch result {
            case .success(let code):
                qrCode = code
                qrImage = makeQRCode(from: code.loginURL.absoluteString)
                message = "等待扫码…"
            case .failure(let error):
                message = error.localizedDescription
            }
        }
    }

    private func pollQRCode() {
        guard !model.isBilibiliLoggedIn, !isPolling, let qrCode else { return }
        isPolling = true
        model.pollBilibiliQRCode(key: qrCode.key) { result in
            isPolling = false
            switch result {
            case .success(.waitingForScan):
                message = "等待扫码…"
            case .success(.waitingForConfirmation):
                message = "已扫码，请在手机上确认登录。"
            case .success(.expired):
                self.qrCode = nil
                qrImage = nil
                message = "二维码已过期，请点击“刷新二维码”。"
            case .success(.authenticated):
                self.qrCode = nil
                qrImage = nil
                message = "登录成功，下载时将使用当前账号可用的最高画质。"
            case .failure(let error):
                message = error.localizedDescription
            }
        }
    }

    private func makeQRCode(from value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
