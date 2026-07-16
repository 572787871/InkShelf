import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showingEmailLogin = false
    @State private var isSigningInWithApple = false
    @State private var accountMessage: String?
    @State private var signedInAccount: AccountIdentity?
    private let authenticator: any AccountAuthenticating

    init(authenticator: any AccountAuthenticating = PendingAccountAuthenticator()) {
        self.authenticator = authenticator
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("账号") {
                    if let signedInAccount {
                        LabeledContent("当前账号", value: signedInAccount.displayName)
                    } else {
                        Button(action: beginAppleSignIn) {
                            HStack {
                                Label("使用 Apple 账号登录", systemImage: "apple.logo")
                                Spacer()
                                if isSigningInWithApple { ProgressView().controlSize(.small) }
                            }
                        }
                        .disabled(isSigningInWithApple)

                        Button {
                            showingEmailLogin = true
                        } label: {
                            Label("使用邮箱登录", systemImage: "envelope")
                        }
                    }
                    Text("认证接口已独立预留，接入账号服务后可用于阅读进度和书架同步。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("导入与存储") {
                    Label("TXT / Markdown / EPUB", systemImage: "doc.badge.plus")
                    Text("书籍只保存在本机 App 沙盒内，不会上传。删除 App 会同时删除书架内容。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("AI 朗读") {
                    HStack { Label("配音引擎", systemImage: "waveform"); Spacer(); Text("等待接入").foregroundStyle(.secondary) }
                    Text("工程已定义章节预处理、播放、暂停、句子定位与状态同步接口，可直接接入后续 AI 语音服务。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("关于") {
                    LabeledContent("应用", value: "墨架 InkShelf")
                    LabeledContent("版本", value: "1.0.0")
                    NavigationLink("隐私说明") { PrivacyView() }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .sheet(isPresented: $showingEmailLogin) {
            EmailLoginView(authenticator: authenticator) { identity in
                signedInAccount = identity
            }
        }
        .alert(
            "账号登录",
            isPresented: Binding(
                get: { accountMessage != nil },
                set: { if !$0 { accountMessage = nil } }
            )
        ) {
            Button("知道了", role: .cancel) { accountMessage = nil }
        } message: {
            Text(accountMessage ?? "")
        }
    }

    private func beginAppleSignIn() {
        guard !isSigningInWithApple else { return }
        isSigningInWithApple = true
        Task { @MainActor in
            defer { isSigningInWithApple = false }
            do {
                signedInAccount = try await authenticator.signInWithApple()
            } catch {
                accountMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

struct AccountIdentity: Equatable, Sendable {
    let id: String
    let displayName: String
    let email: String?
}

protocol AccountAuthenticating: Sendable {
    func signInWithApple() async throws -> AccountIdentity
    func signIn(email: String, password: String) async throws -> AccountIdentity
}

enum AccountAuthenticationError: LocalizedError {
    case appleNotConfigured
    case emailNotConfigured

    var errorDescription: String? {
        switch self {
        case .appleNotConfigured:
            return "Apple 账号登录接口已预留，接入 Apple 授权与服务端校验后即可启用。"
        case .emailNotConfigured:
            return "邮箱登录接口已预留，接入账号服务端后即可启用。"
        }
    }
}

struct PendingAccountAuthenticator: AccountAuthenticating {
    func signInWithApple() async throws -> AccountIdentity {
        throw AccountAuthenticationError.appleNotConfigured
    }

    func signIn(email: String, password: String) async throws -> AccountIdentity {
        throw AccountAuthenticationError.emailNotConfigured
    }
}

struct EmailLoginInput {
    let email: String
    let password: String

    var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var validationMessage: String? {
        let parts = normalizedEmail.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              parts[1].contains("."),
              !parts[1].hasPrefix("."),
              !parts[1].hasSuffix(".") else {
            return "请输入有效的邮箱地址。"
        }
        guard password.count >= 6 else { return "密码至少需要 6 位。" }
        return nil
    }
}

private struct EmailLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    let authenticator: any AccountAuthenticating
    let onSignedIn: (AccountIdentity) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("邮箱账号") {
                    TextField("邮箱", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                        .textContentType(.password)
                }
                Section {
                    Button(action: submit) {
                        HStack {
                            Spacer()
                            if isSubmitting { ProgressView().controlSize(.small) }
                            Text(isSubmitting ? "正在登录…" : "登录")
                            Spacer()
                        }
                    }
                    .disabled(isSubmitting)
                }
                Section {
                    Text("邮箱和密码只会提交给后续接入的账号服务；当前版本不会保存或上传。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("邮箱登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .alert(
            "无法登录",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func submit() {
        let input = EmailLoginInput(email: email, password: password)
        if let validationMessage = input.validationMessage {
            errorMessage = validationMessage
            return
        }
        guard !isSubmitting else { return }
        isSubmitting = true
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                let identity = try await authenticator.signIn(
                    email: input.normalizedEmail,
                    password: password
                )
                onSignedIn(identity)
                dismiss()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

private struct PrivacyView: View {
    var body: some View {
        List {
            Text("墨架不会收集、分析或上传你的阅读文件、阅读进度和书签。所有数据默认仅保存在设备本地。")
            Text("未来启用 AI 朗读时，应用会在发送任何正文前明确展示所使用的服务、数据范围和隐私条款，并再次征得同意。")
        }.navigationTitle("隐私说明")
    }
}
