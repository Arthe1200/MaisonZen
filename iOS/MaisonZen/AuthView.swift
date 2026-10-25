import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Group {
            if store.token == nil { AuthView() }
            else if store.isBusy && store.displayName.isEmpty { ProgressView("Connexion sécurisée…") }
            else if sizeClass == .regular && store.dashboardMode { NavigationStack { FamilyDashboardView() } }
            else { HomeView() }
        }
        .alert("MaisonZen", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .alert("MaisonZen", isPresented: Binding(get: { store.infoMessage != nil }, set: { if !$0 { store.infoMessage = nil } })) {
            Button("OK", role: .cancel) { store.infoMessage = nil }
        } message: { Text(store.infoMessage ?? "") }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await store.refreshForeground() } } }
    }
}

struct AuthView: View {
    @Environment(AppStore.self) private var store
    @State private var mode: Mode = .login
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var showServerSettings = false

    enum Mode { case login, create, verify, forgotPassword, resetPassword }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    logo
                    VStack(spacing: 7) {
                        Text(mode == .verify ? "Vérifie ton adresse" : mode == .create ? "Créer un compte" : mode == .forgotPassword ? "Mot de passe oublié" : mode == .resetPassword ? "Nouveau mot de passe" : "Bienvenue chez toi")
                            .font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(Color.maisonInk)
                        Text(mode == .verify || mode == .resetPassword ? "Saisis le code reçu par e-mail." : "Une maison mieux organisée, en toute simplicité.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    VStack(spacing: 13) {
                        if mode == .create { TextField("Ton prénom", text: $name).textContentType(.givenName).textFieldStyle(.roundedBorder) }
                        if mode != .verify { TextField("Adresse e-mail", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.emailAddress).textFieldStyle(.roundedBorder) }
                        if mode == .login || mode == .create || mode == .resetPassword { SecureField(mode == .resetPassword ? "Nouveau mot de passe (12 caractères minimum)" : "Mot de passe (12 caractères minimum)", text: $password).textContentType(mode == .login ? .password : .newPassword).textFieldStyle(.roundedBorder) }
                        if mode == .verify || mode == .resetPassword { TextField("Code à 6 chiffres", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode).textFieldStyle(.roundedBorder) }
                    }
                    Button(action: submit) {
                        HStack { if store.isBusy { ProgressView().tint(.white) }; Text(primaryTitle).fontWeight(.semibold) }
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent).tint(.maisonTeal).disabled(store.isBusy || !canSubmit)
                    if mode == .login {
                        Button("Créer un compte") { mode = .create }
                            .font(.subheadline).foregroundStyle(Color.maisonTeal)
                        Button("Mot de passe oublié ?") { mode = .forgotPassword }
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if mode == .create {
                        Button("J’ai déjà un compte") { mode = .login }
                            .font(.subheadline).foregroundStyle(Color.maisonTeal)
                    } else if mode == .forgotPassword {
                        Button("Retour à la connexion") { mode = .login }
                            .font(.subheadline).foregroundStyle(Color.maisonTeal)
                    } else if let devCode = store.developmentCode {
                        Text("Code de test local : \(devCode)").font(.footnote.monospaced()).foregroundStyle(.secondary)
                    }
                    Button { showServerSettings = true } label: {
                        Label("Adresse du serveur familial", systemImage: "server.rack").font(.footnote)
                    }.foregroundStyle(.secondary).padding(.top, 12)
                    Text("Tes données de foyer sont chiffrées sur ton appareil avant synchronisation.")
                        .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 18)
                }
                .padding(24).frame(maxWidth: 440).frame(maxWidth: .infinity, minHeight: 650)
            }
            .background(Color.maisonCanvas.ignoresSafeArea())
            .sheet(isPresented: $showServerSettings) { ServerAddressSheet() }
        }
    }

    private var logo: some View {
        Image("MaisonZenMark").resizable().scaledToFit().frame(width: 112, height: 112).padding(.bottom, 4)
    }
    private var primaryTitle: String { switch mode { case .verify: "Vérifier et continuer"; case .create: "Créer mon compte"; case .forgotPassword: "Envoyer un code"; case .resetPassword: "Changer le mot de passe"; case .login: "Se connecter" } }
    private var canSubmit: Bool { switch mode { case .verify: code.count >= 6; case .forgotPassword: !email.isEmpty; case .resetPassword: code.count >= 6 && password.count >= 12; case .create: !email.isEmpty && password.count >= 12 && !name.isEmpty; case .login: !email.isEmpty && !password.isEmpty } }
    private func submit() {
        Task {
            switch mode {
            case .login: await store.login(email: email, password: password)
            case .create:
                await store.register(name: name, email: email, password: password)
                if store.pendingEmail == email { mode = .verify }
            case .verify:
                await store.verify(code: code)
            case .forgotPassword:
                await store.requestPasswordReset(email: email)
                if store.pendingEmail == email { mode = .resetPassword }
            case .resetPassword:
                await store.resetPassword(code: code, newPassword: password)
                if store.infoMessage != nil { mode = .login; password = ""; code = "" }
            }
        }
    }
}

private struct ServerAddressSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Serveur de la maison") {
                    TextField("https://maison.exemple.fr", text: $draft).textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                    Text("Sur le réseau local, utilise l’adresse IP de l’ordinateur serveur. En accès distant, configure HTTPS et un VPN.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connexion")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Enregistrer") { store.serverAddress = draft; dismiss() } } }
            .onAppear { draft = store.serverAddress }
        }
        .presentationDetents([.medium])
    }
}
