import SwiftUI
import Charts

struct ChatView: View {
    @Environment(AppStore.self) private var store
    @State private var message = ""
    @State private var selectedMembers: Set<UUID> = []
    private var messages: [MaisonDocument] { store.documents(of: "chat").sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }.filter { doc in
        guard let record = store.record(for: doc) else { return false }
        if record.audience == "household" { return selectedMembers.isEmpty }
        return record.ownerId == store.userId || (record.allowedMemberIds.contains(store.userId ?? UUID.zero) && Set(record.allowedMemberIds.filter { $0 != store.userId }) == selectedMembers)
    } }
    var body: some View {
        VStack(spacing: 0) {
            Menu {
                Button { selectedMembers = [] } label: { Label("Tout le foyer", systemImage: selectedMembers.isEmpty ? "checkmark" : "person.3") }
                Divider()
                ForEach(store.members.filter { $0.userId != store.userId }) { member in
                    Button { if selectedMembers.contains(member.userId) { selectedMembers.remove(member.userId) } else { selectedMembers.insert(member.userId) } } label: { Label(member.displayName, systemImage: selectedMembers.contains(member.userId) ? "checkmark.circle.fill" : "circle") }
                }
            } label: { Label(selectedMembers.isEmpty ? "Tout le foyer" : "Discussion · \(selectedMembers.count) personne(s)", systemImage: "person.2") }.padding(.horizontal)
            ScrollViewReader { proxy in ScrollView { LazyVStack(spacing: 10) { ForEach(messages) { item in ChatBubble(document: item, mine: item.title == store.displayName).id(item.id) } }.padding() }.onChange(of: messages.count) { _, _ in if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } } }
            HStack(spacing: 9) { TextField("Message chiffré…", text: $message, axis: .vertical).lineLimit(1...4).textFieldStyle(.roundedBorder); Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)).foregroundStyle(Color.maisonTeal) }.disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }.padding()
        }.navigationTitle("Messages").toolbar { ToolbarItem(placement: .topBarTrailing) { Button { Task { await store.sync() } } label: { Image(systemName: "arrow.clockwise") } } }
    }
    private func send() {
        guard let user = store.userId else { return }
        let allowed = selectedMembers.isEmpty ? [] : Array(selectedMembers.union([user]))
        let doc = MaisonDocument(kind: "chat", title: store.displayName, detail: message, date: .now, allowedMembers: allowed, category: selectedMembers.isEmpty ? "foyer" : "privé")
        let audience = selectedMembers.isEmpty ? "household" : "members"
        let current = message; message = ""
        Task { await store.save(doc, audience: audience, allowed: allowed); if store.errorMessage != nil { message = current } }
    }
}

private struct ChatBubble: View {
    var document: MaisonDocument; var mine: Bool
    var body: some View { HStack { if mine { Spacer(minLength: 42) }; VStack(alignment: .leading, spacing: 4) { if !mine { Text(document.title).font(.caption2.weight(.semibold)).foregroundStyle(Color.maisonTeal) }; Text(document.detail ?? "").font(.body); Text(document.date?.formatted(date: .omitted, time: .shortened) ?? "").font(.caption2).foregroundStyle(.secondary) }.padding(11).background(mine ? Color.maisonMint : Color.white, in: RoundedRectangle(cornerRadius: 16)); if !mine { Spacer(minLength: 42) } } }
}

struct HouseholdView: View {
    @Environment(AppStore.self) private var store; @State private var invite = false
    var body: some View { List {
        Section("Foyer") { if let household = store.selectedHousehold { LabeledContent("Nom", value: store.householdNames[household.id] ?? "Foyer"); LabeledContent("Ton rôle", value: household.householdRole.label); LabeledContent("Membres", value: "\(store.members.count)") } }
        Section("Membres") { ForEach(store.members) { member in HStack { Image(systemName: member.householdRole == .child ? "figure.child" : "person.crop.circle").foregroundStyle(Color.maisonTeal); VStack(alignment: .leading) { Text(member.displayName); Text(member.householdRole.label).font(.caption).foregroundStyle(.secondary) }; Spacer(); if store.currentRole == .admin && member.userId != store.userId { Button(role: .destructive) { Task { await store.removeMember(member.userId) } } label: { Image(systemName: "person.crop.circle.badge.xmark") }.buttonStyle(.borderless).accessibilityLabel("Retirer \(member.displayName)") } } } }
        if store.currentRole == .admin { Section { Button { invite = true } label: { Label("Inviter une personne", systemImage: "person.badge.plus") } } }
        Section("Confidentialité") { Label("Les contenus du foyer sont chiffrés sur les appareils.", systemImage: "lock.shield"); Text("Le serveur reçoit des blocs chiffrés et les métadonnées strictement nécessaires au partage et aux rôles.").font(.footnote).foregroundStyle(.secondary) }
    }.navigationTitle("Membres du foyer").toolbar { ToolbarItem(placement: .topBarTrailing) { Button { Task { await store.sync() } } label: { Image(systemName: "arrow.clockwise") } } }.sheet(isPresented: $invite) { InviteMemberSheet() }.task { if let id = store.selectedHousehold?.id, let people = try? await MaisonAPI(address: store.serverAddress, token: store.token).members(id) { store.members = people } } }
}

struct CallsView: View {
    @Environment(AppStore.self) private var store
    @State private var service: AudioCallService?
    @State private var selectedMember: UUID?
    var body: some View {
        Group {
            if let service { CallControls(service: service, selectedMember: $selectedMember) }
            else { ProgressView("Connexion au foyer…") }
        }
        .navigationTitle("Appels audio")
        .task { if service == nil { let instance = AudioCallService(store: store); service = instance; await instance.connect() } }
    }
}

private struct CallControls: View {
    @Environment(AppStore.self) private var store
    @State private var service: AudioCallService
    @Binding var selectedMember: UUID?
    init(service: AudioCallService, selectedMember: Binding<UUID?>) { _service = State(initialValue: service); _selectedMember = selectedMember }
    var body: some View { List {
        Section { VStack(spacing: 14) { Image(systemName: service.activePeerId == nil && service.incomingCallerId == nil ? "phone.circle.fill" : "waveform.circle.fill").font(.system(size: 70)).foregroundStyle(Color.maisonTeal); Text(service.status).font(.headline); if let peer = service.activePeerId, let name = store.members.first(where: { $0.userId == peer })?.displayName { Text("Avec \(name)").foregroundStyle(.secondary) }; if service.incomingCallerId != nil { HStack { Button("Refuser", role: .destructive) { Task { await service.rejectCall() } }.buttonStyle(.bordered); Button("Répondre") { Task { await service.acceptCall() } }.buttonStyle(.borderedProminent).tint(.maisonTeal) } } else if service.activePeerId != nil { HStack { Button(service.isMuted ? "Réactiver" : "Muet") { service.toggleMute() }.buttonStyle(.bordered); Button("Raccrocher", role: .destructive) { Task { await service.hangUp() } }.buttonStyle(.borderedProminent) } }; if let error = service.callError { Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center) }; Text("La voix et la signalisation d’appel sont chiffrées. Le relais TURN familial est nécessaire pour certains réseaux.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }.frame(maxWidth: .infinity).padding(.vertical, 12) }
        Section("Appeler un membre") { ForEach(store.members.filter { $0.userId != store.userId }) { member in Button { selectedMember = member.userId } label: { HStack { Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(Color.maisonTeal); Text(member.displayName).foregroundStyle(.primary); Spacer(); if selectedMember == member.userId { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.maisonTeal) } } } } }
        if let selectedMember, service.activePeerId == nil, service.incomingCallerId == nil { Section { Button { Task { await service.startCall(to: selectedMember) } } label: { Label("Appeler", systemImage: "phone.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).tint(.green) } }
    } }
}

struct FamilyDashboardView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("maisonzen.dashboard.order") private var savedOrder = "Résumé|Rappels|Tâches|Abonnements|Repas"
    @AppStorage("maisonzen.dashboard.wide") private var savedWide = "Résumé"
    @State private var editMode = false
    @AppStorage("maisonzen.chart.style") private var chartType = "Camembert"
    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
    private var order: [String] { let stored = savedOrder.split(separator: "|").map(String.init); let defaults = ["Résumé", "Rappels", "Tâches", "Abonnements", "Repas"]; return stored.isEmpty ? defaults : stored.filter { defaults.contains($0) } + defaults.filter { !stored.contains($0) } }
    private var wide: Set<String> { Set(savedWide.split(separator: "|").map(String.init)) }
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 16) {
        HStack { VStack(alignment: .leading) { Text(store.householdNames[store.selectedHousehold?.id ?? UUID()] ?? "MaisonZen").font(.largeTitle.bold()); Text(Date.now.formatted(date: .complete, time: .shortened)).foregroundStyle(.secondary) }; Spacer(); Button(editMode ? "Terminé" : "Modifier") { editMode.toggle() }.buttonStyle(.bordered) }
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(order, id: \.self) { item in widget(item).frame(minHeight: wide.contains(item) ? 210 : 145).gridCellColumns(wide.contains(item) ? 2 : 1).draggable(item).dropDestination(for: String.self) { items, _ in guard let moved = items.first, let from = order.firstIndex(of: moved), let to = order.firstIndex(of: item) else { return false }; var reordered = order; reordered.move(fromOffsets: IndexSet(integer: from), toOffset: to); savedOrder = reordered.joined(separator: "|"); return true }.overlay(alignment: .topTrailing) { if editMode { Button { var sizes = wide; if sizes.contains(item) { sizes.remove(item) } else { sizes.insert(item) }; savedWide = sizes.sorted().joined(separator: "|") } label: { Image(systemName: wide.contains(item) ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").padding(8).background(.white.opacity(0.85), in: Circle()) }.buttonStyle(.plain).padding(8) } } }
        }.animation(.snappy, value: order)
        LazyVGrid(columns: columns, spacing: 12) {
            HomeTile(title: "Dépenses", subtitle: "Privées et du foyer", icon: "chart.pie", destination: ExpensesView())
            HomeTile(title: "Planning", subtitle: "Événements partagés", icon: "calendar", destination: CalendarView())
            HomeTile(title: "Frigo", subtitle: "Produits et dates", icon: "refrigerator", destination: FridgeView())
            HomeTile(title: "Recettes", subtitle: "Repas et préférences", icon: "fork.knife", destination: RecipesView())
            HomeTile(title: "Messages", subtitle: "Discussions du foyer", icon: "bubble.left.and.bubble.right", destination: ChatView())
            HomeTile(title: "Appels", subtitle: "Audio familial", icon: "phone", destination: CallsView())
            HomeTile(title: "Membres", subtitle: "Rôles et invitations", icon: "person.3", destination: HouseholdView())
        }
    }.padding(18).frame(maxWidth: 1100).frame(maxWidth: .infinity) }.navigationTitle("Tableau de bord").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }.accessibilityLabel("Réglages") } }.background(Color.maisonCanvas.ignoresSafeArea()) }

    @ViewBuilder private func widget(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(name, systemImage: icon(name)).font(.headline).foregroundStyle(Color.maisonInk)
            switch name {
            case "Résumé":
                let interval = Calendar.current.dateInterval(of: .month, for: .now)
                let total = store.documents.reduce(0.0) { sum, item in
                    if item.kind == "subscription" { return sum + MaisonMoney.monthlyAmount(for: item) }
                    if item.kind == "expense", let date = item.date, interval?.contains(date) == true { return sum + (item.amount ?? 0) }
                    return sum
                }
                Text(total, format: .currency(code: Locale.current.currency?.identifier ?? "EUR")).font(.largeTitle.bold())
                Picker("Graphique", selection: $chartType) { ForEach(["Camembert", "Courbe", "Colonnes"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                spendingChart.frame(height: 130)
            case "Rappels": ForEach(store.documents(of: "reminder").filter { !$0.completed }.prefix(3)) { Text($0.title).font(.subheadline); if let d = $0.date { Text(d.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) } }
            case "Tâches": ForEach(store.documents(of: "task").filter { !$0.completed }.prefix(3)) { Label($0.title, systemImage: "circle").font(.subheadline) }
            case "Abonnements": ForEach(store.documents(of: "subscription").prefix(3)) { Text($0.title).font(.subheadline); Text(($0.amount ?? 0), format: .currency(code: Locale.current.currency?.identifier ?? "EUR")).font(.caption).foregroundStyle(.secondary) }
            default: Text(store.documents(of: "calendar").first?.title ?? "Aucun repas planifié").font(.subheadline)
            }
            if editMode { Text("Glisse pour déplacer · bouton pour redimensionner").font(.caption2).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.white, in: RoundedRectangle(cornerRadius: 22))
    }
    private func icon(_ name: String) -> String { switch name { case "Résumé": "chart.pie.fill"; case "Rappels": "bell"; case "Tâches": "checklist"; case "Abonnements": "creditcard"; default: "fork.knife" } }
    @ViewBuilder private var spendingChart: some View {
        let values = store.documents.filter { $0.kind == "expense" || $0.kind == "subscription" }.prefix(6)
        if chartType == "Camembert" {
            Chart(values) { item in SectorMark(angle: .value("Montant", item.kind == "subscription" ? MaisonMoney.monthlyAmount(for: item) : item.amount ?? 0), innerRadius: .ratio(0.56)).foregroundStyle(by: .value("Catégorie", item.category ?? item.title)) }
        } else if chartType == "Courbe" {
            Chart(values) { item in LineMark(x: .value("Élément", item.title), y: .value("Montant", item.kind == "subscription" ? MaisonMoney.monthlyAmount(for: item) : item.amount ?? 0)).foregroundStyle(Color.maisonTeal); PointMark(x: .value("Élément", item.title), y: .value("Montant", item.kind == "subscription" ? MaisonMoney.monthlyAmount(for: item) : item.amount ?? 0)).foregroundStyle(Color.maisonTeal) }
        } else {
            Chart(values) { item in BarMark(x: .value("Élément", item.title), y: .value("Montant", item.kind == "subscription" ? MaisonMoney.monthlyAmount(for: item) : item.amount ?? 0)).foregroundStyle(Color.maisonTeal).cornerRadius(4) }
        }
    }
}

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var address = ""
    @State private var dashboardMode = UserDefaults.standard.bool(forKey: "maisonzen.dashboard")
    @State private var permissionText = "Notifications non configurées"
    @State private var showRecoveryCode = false
    @State private var showRestore = false
    @AppStorage("maisonzen.notifications.silent") private var silentNotifications = false
    var body: some View { Form {
        Section("Compte") { LabeledContent("Connecté en tant que", value: store.displayName); LabeledContent("Adresse", value: store.email.isEmpty ? "Compte MaisonZen" : store.email); Button("Se déconnecter", role: .destructive) { store.signOut() } }
        Section("Serveur familial") { TextField("Adresse HTTPS du serveur", text: $address).textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled(); Button("Enregistrer l’adresse") { store.serverAddress = address }; Text("Les adresses HTTP ne conviennent qu’aux essais sur réseau local. Utilise HTTPS pour les connexions internet.").font(.footnote).foregroundStyle(.secondary) }
        Section("Tablette") { Toggle("Activer le mode dashboard", isOn: $dashboardMode).onChange(of: dashboardMode) { _, value in UserDefaults.standard.set(value, forKey: "maisonzen.dashboard"); store.dashboardMode = value }; Text("Le dashboard affiche les widgets du foyer en plein écran. Il peut être activé uniquement sur les tablettes choisies.").font(.footnote).foregroundStyle(.secondary) }
        Section("Notifications") { Text(permissionText); Button("Autoriser les notifications") { Task { let granted = await LocalReminderScheduler.requestPermission(); permissionText = granted ? "Notifications autorisées sur cet appareil" : "Autorisation refusée dans les réglages iOS" } }; Toggle("Mettre les notifications en silencieux", isOn: $silentNotifications).tint(.maisonTeal).onChange(of: silentNotifications) { _, _ in Task { await store.sync() } }; Text("Le mode silencieux général concerne cet appareil. Chaque rappel peut aussi être configuré individuellement.").font(.footnote).foregroundStyle(.secondary) }
        Section("Sécurité") { Label("Clés de chiffrement conservées dans le trousseau de cet appareil", systemImage: "key.horizontal"); Label("Les fiches sont chiffrées avant synchronisation", systemImage: "lock.fill"); Text("Garde une copie sûre de tes accès : sans la clé privée de cet appareil, les données chiffrées ne peuvent pas être récupérées par le serveur.").font(.footnote).foregroundStyle(.secondary) }
        Section("Récupération chiffrée") {
            Button("Créer ou afficher mon code de récupération") { Task { if await store.createRecoveryBackup() != nil { showRecoveryCode = true } } }
            Button("Restaurer mes clés sur cet appareil") { showRestore = true }
            Text("Le serveur ne stocke que la sauvegarde chiffrée. Garde le code de récupération dans un endroit sûr : sans lui, cette sauvegarde ne pourra pas être ouverte.").font(.footnote).foregroundStyle(.secondary)
        }
    }.navigationTitle("Réglages").onAppear { address = store.serverAddress }.sheet(isPresented: $showRecoveryCode) { if let code = store.recoveryCodeForDisplay { RecoveryCodeSheet(code: code) } }.sheet(isPresented: $showRestore) { RestoreRecoverySheet() } }
}

private struct RecoveryCodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    var code: String
    var body: some View { NavigationStack { VStack(spacing: 18) { Image(systemName: "key.horizontal.fill").font(.system(size: 42)).foregroundStyle(Color.maisonTeal); Text("Code de récupération").font(.title2.bold()); Text("Enregistre ce code dans un endroit sûr. Il permet de restaurer les clés du foyer sur un nouvel appareil.").multilineTextAlignment(.center).foregroundStyle(.secondary); Text(code).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding(14).frame(maxWidth: .infinity).background(Color.maisonCanvas, in: RoundedRectangle(cornerRadius: 14)); ShareLink(item: code) { Label("Enregistrer ou partager le code", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).tint(.maisonTeal); Button("J’ai enregistré mon code") { dismiss() }.buttonStyle(.bordered) }.padding(24).navigationTitle("Sauvegarde chiffrée").navigationBarTitleDisplayMode(.inline) }.presentationDetents([.medium, .large]) }
}

private struct RestoreRecoverySheet: View {
    @Environment(AppStore.self) private var store; @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    var body: some View { NavigationStack { Form { Section("Code de récupération") { TextField("Colle le code enregistré", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled(); Text("Connecte-toi d’abord au même compte, puis saisis le code conservé lors de la sauvegarde.").font(.footnote).foregroundStyle(.secondary) } }.navigationTitle("Restaurer les clés").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Restaurer") { Task { await store.restoreRecoveryBackup(code: code); if store.errorMessage == nil { dismiss() } } }.disabled(code.isEmpty) } } }.presentationDetents([.medium]) }
}

