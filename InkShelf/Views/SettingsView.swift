import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var readAloud: ReadAloudService
    @State private var showingEmailAccount = false
    @State private var isSigningInWithApple = false
    @State private var isSigningOut = false
    @State private var accountMessage: String?
    @State private var signedInAccount: AccountIdentity?
    private let authenticator: any AccountAuthenticating

    init(authenticator: any AccountAuthenticating = PendingAccountAuthenticator()) {
        self.authenticator = authenticator
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("账号与同步") {
                    if let signedInAccount {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(signedInAccount.displayName)
                                if let email = signedInAccount.email {
                                    Text(email).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.title2)
                        }
                        Button("退出当前账号", role: .destructive, action: signOut)
                            .disabled(isSigningOut)
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
                            showingEmailAccount = true
                        } label: {
                            Label("邮箱登录或注册", systemImage: "envelope")
                        }
                    }
                    Text("认证接口已独立预留，接入账号服务后可用于阅读进度和书架同步。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("朗读") {
                    NavigationLink {
                        ReadAloudSettingsView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("功能设置")
                                Text(readAloud.canStartReading
                                    ? "\(readAloud.settings.provider.title) · 自动分角色"
                                    : "待配置语音服务")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "waveform")
                        }
                    }
                    Text("朗读设置只保留在这里。阅读页不会再弹出设置或显示声线选择。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("关于") {
                    LabeledContent("应用", value: "墨架 InkShelf")
                    LabeledContent("版本", value: "1.0.0")
                    LabeledContent("支持导入", value: "TXT / Markdown / EPUB")
                    Text("TXT 支持 UTF-8、UTF-16、GBK 和 GB18030 编码，导入后的书籍保存在本机。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    NavigationLink("隐私说明") { PrivacyView() }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .sheet(isPresented: $showingEmailAccount) {
            EmailAccountView(authenticator: authenticator) { identity in
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

    private func signOut() {
        guard !isSigningOut else { return }
        isSigningOut = true
        Task { @MainActor in
            defer { isSigningOut = false }
            do {
                try await authenticator.signOut()
                signedInAccount = nil
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
    func register(displayName: String, email: String, password: String) async throws -> AccountIdentity
    func requestPasswordReset(email: String) async throws
    func signOut() async throws
}

enum AccountAuthenticationError: LocalizedError {
    case appleNotConfigured
    case emailNotConfigured
    case registrationNotConfigured
    case passwordResetNotConfigured
    case signOutNotConfigured

    var errorDescription: String? {
        switch self {
        case .appleNotConfigured:
            return "Apple 账号登录接口已预留，接入 Apple 授权与服务端校验后即可启用。"
        case .emailNotConfigured:
            return "邮箱登录接口已预留，接入账号服务端后即可启用。"
        case .registrationNotConfigured:
            return "邮箱注册接口已预留，接入账号服务端后即可创建账号。"
        case .passwordResetNotConfigured:
            return "找回密码接口已预留，接入邮件服务后即可发送重置邮件。"
        case .signOutNotConfigured:
            return "退出登录接口已预留，接入账号服务后即可启用。"
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

    func register(displayName: String, email: String, password: String) async throws -> AccountIdentity {
        throw AccountAuthenticationError.registrationNotConfigured
    }

    func requestPasswordReset(email: String) async throws {
        throw AccountAuthenticationError.passwordResetNotConfigured
    }

    func signOut() async throws {
        throw AccountAuthenticationError.signOutNotConfigured
    }
}

struct EmailLoginInput {
    let email: String
    let password: String

    var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var validationMessage: String? {
        guard AccountInputValidator.isValidEmail(normalizedEmail) else { return "请输入有效的邮箱地址。" }
        guard password.count >= 6 else { return "密码至少需要 6 位。" }
        return nil
    }
}

struct EmailRegistrationInput {
    let displayName: String
    let email: String
    let password: String
    let passwordConfirmation: String
    let acceptedTerms: Bool

    var normalizedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var validationMessage: String? {
        guard normalizedDisplayName.count >= 2 else { return "昵称至少需要 2 个字符。" }
        guard AccountInputValidator.isValidEmail(normalizedEmail) else { return "请输入有效的邮箱地址。" }
        guard password.count >= 8 else { return "注册密码至少需要 8 位。" }
        guard password.rangeOfCharacter(from: .letters) != nil,
              password.rangeOfCharacter(from: .decimalDigits) != nil else {
            return "密码需要同时包含字母和数字。"
        }
        guard password == passwordConfirmation else { return "两次输入的密码不一致。" }
        guard acceptedTerms else { return "请先同意服务条款和隐私说明。" }
        return nil
    }
}

private enum AccountInputValidator {
    static func isValidEmail(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2
            && !parts[0].isEmpty
            && parts[1].contains(".")
            && !parts[1].hasPrefix(".")
            && !parts[1].hasSuffix(".")
    }
}

private enum EmailAccountMode: String, CaseIterable, Identifiable {
    case signIn = "登录"
    case register = "注册"

    var id: Self { self }
}

private struct EmailAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var mode = EmailAccountMode.signIn
    @State private var displayName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var passwordConfirmation = ""
    @State private var acceptedTerms = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var confirmationMessage: String?
    let authenticator: any AccountAuthenticating
    let onSignedIn: (AccountIdentity) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("账号操作", selection: $mode) {
                        ForEach(EmailAccountMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }

                Section(mode == .signIn ? "邮箱账号" : "创建账号") {
                    if mode == .register {
                        TextField("昵称", text: $displayName)
                            .textContentType(.name)
                    }
                    TextField("邮箱", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                        .textContentType(mode == .signIn ? .password : .newPassword)
                    if mode == .register {
                        SecureField("确认密码", text: $passwordConfirmation)
                            .textContentType(.newPassword)
                    }
                }

                if mode == .register {
                    Section {
                        Toggle("我已阅读并同意服务条款和隐私说明", isOn: $acceptedTerms)
                            .font(.footnote)
                    }
                }

                Section {
                    Button(action: submit) {
                        HStack {
                            Spacer()
                            if isSubmitting { ProgressView().controlSize(.small) }
                            Text(submitTitle)
                            Spacer()
                        }
                    }
                    .disabled(isSubmitting)

                    if mode == .signIn {
                        Button("忘记密码？", action: requestPasswordReset)
                            .frame(maxWidth: .infinity)
                            .disabled(isSubmitting)
                    }
                }
                Section {
                    Text("账号请求只会提交给后续接入的认证服务；当前版本不会保存或上传邮箱和密码。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("邮箱账号")
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
        .alert(
            "邮件已发送",
            isPresented: Binding(
                get: { confirmationMessage != nil },
                set: { if !$0 { confirmationMessage = nil } }
            )
        ) {
            Button("知道了", role: .cancel) { confirmationMessage = nil }
        } message: {
            Text(confirmationMessage ?? "")
        }
        .onChange(of: mode) { _, _ in
            errorMessage = nil
            password = ""
            passwordConfirmation = ""
        }
    }

    private var submitTitle: String {
        if isSubmitting { return mode == .signIn ? "正在登录…" : "正在创建…" }
        return mode == .signIn ? "登录" : "创建账号"
    }

    private func submit() {
        guard !isSubmitting else { return }
        switch mode {
        case .signIn:
            submitSignIn()
        case .register:
            submitRegistration()
        }
    }

    private func submitSignIn() {
        let input = EmailLoginInput(email: email, password: password)
        guard let validationMessage = input.validationMessage else {
            performAuthentication {
                try await authenticator.signIn(email: input.normalizedEmail, password: password)
            }
            return
        }
        errorMessage = validationMessage
    }

    private func submitRegistration() {
        let input = EmailRegistrationInput(
            displayName: displayName,
            email: email,
            password: password,
            passwordConfirmation: passwordConfirmation,
            acceptedTerms: acceptedTerms
        )
        guard let validationMessage = input.validationMessage else {
            performAuthentication {
                try await authenticator.register(
                    displayName: input.normalizedDisplayName,
                    email: input.normalizedEmail,
                    password: password
                )
            }
            return
        }
        errorMessage = validationMessage
    }

    private func performAuthentication(
        _ operation: @escaping () async throws -> AccountIdentity
    ) {
        isSubmitting = true
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                let identity = try await operation()
                onSignedIn(identity)
                dismiss()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func requestPasswordReset() {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard AccountInputValidator.isValidEmail(normalizedEmail) else {
            errorMessage = "请先输入有效的邮箱地址。"
            return
        }
        guard !isSubmitting else { return }
        isSubmitting = true
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                try await authenticator.requestPasswordReset(email: normalizedEmail)
                confirmationMessage = "如果该邮箱已注册，你将收到密码重置邮件。"
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
            Text("分角色识别在设备上完成。只有你在朗读设置中明确允许并开始朗读时，当前短句才会发送到你配置的小米 MiMo 或 OpenAI 兼容语音服务。API Key 保存在设备钥匙串中；服务方如何处理数据由其隐私政策决定。")
        }.navigationTitle("隐私说明")
    }
}
