import SwiftUI
import Charts

struct HomeView: View {
    @Environment(AppStore.self) private var store
    @State private var showingCreateHousehold = false
    @State private var showingJoin = false
    @State private var showingInvite = false

    var body: some View {
        NavigationStack {
            Group {
                if store.households.isEmpty { emptyHome }
                else { dashboard }
            }
            .background(Color.maisonCanvas.ignoresSafeArea())
            .navigationTitle("MaisonZen")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(store.households) { house in Button(store.householdNames[house.id] ?? "Mon foyer") { Task { await store.select(house) } } }
                        Divider()
                        Button("Créer un foyer", systemImage: "plus") { showingCreateHousehold = true }
                        Button("Rejoindre un foyer", systemImage: "person.badge.plus") { showingJoin = true }
                        if store.currentRole == .admin { Button("Inviter un membre", systemImage: "paperplane") { showingInvite = true } }
                    } label: { Image(systemName: "line.3.horizontal").font(.title3).foregroundStyle(Color.maisonInk) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await store.sync() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Synchroniser")
                }
            }
            .refreshable { await store.sync() }
            .sheet(isPresented: $showingCreateHousehold) { CreateHouseholdSheet() }
            .sheet(isPresented: $showingJoin) { JoinHouseholdSheet() }
            .sheet(isPresented: $showingInvite) { InviteMemberSheet() }
            .task { if store.households.isEmpty { await store.loadHouseholds() } }
        }
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bonjour, \(store.displayName)").font(.title2.weight(.semibold)).foregroundStyle(Color.maisonInk)
                        Text(store.householdNames[store.selectedHousehold?.id ?? UUID()] ?? "Ton foyer").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "sun.max.fill").font(.title2).foregroundStyle(Color(red: 0.88, green: 0.65, blue: 0.27))
                }
                summaryCard
                HStack(spacing: 12) {
                    MetricCard(title: "Abonnements", value: "\(store.documents(of: "subscription").count)", symbol: "arrow.trianglehead.2.clockwise.rotate.90", color: .maisonTeal)
                    MetricCard(title: "Rappels", value: "\(upcomingReminders.count)", symbol: "bell.badge", color: Color(red: 0.75, green: 0.52, blue: 0.31))
                }
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeading(title: "À venir", subtitle: "Tes prochains rappels")
                    if upcomingReminders.isEmpty { EmptyHint(text: "Aucun rappel prévu pour le moment.", symbol: "checkmark.circle") }
                    ForEach(upcomingReminders.prefix(3)) { reminder in DocumentRow(document: reminder, symbol: "bell", trailing: reminder.date?.formatted(date: .abbreviated, time: .shortened) ?? "") }
                }
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeading(title: "Ton espace", subtitle: "Tout le foyer, au même endroit")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 11) {
                        HomeTile(title: "Abonnements", subtitle: "Paiements réguliers", icon: "creditcard") { SubscriptionsView() }
                        HomeTile(title: "Dépenses", subtitle: "Privées et communes", icon: "chart.pie") { ExpensesView() }
                        HomeTile(title: "Rappels", subtitle: "Dates et notifications", icon: "bell") { RemindersView() }
                        HomeTile(title: "Tâches", subtitle: "À faire ensemble", icon: "checklist") { TasksView() }
                        HomeTile(title: "Planning", subtitle: "La semaine du foyer", icon: "calendar") { CalendarView() }
                        HomeTile(title: "Frigo", subtitle: "Produits et péremption", icon: "refrigerator") { FridgeView() }
                        HomeTile(title: "Recettes", subtitle: "Idées pour les repas", icon: "fork.knife") { RecipesView() }
                        HomeTile(title: "Messages", subtitle: "Le chat du foyer", icon: "bubble.left.and.bubble.right") { ChatView() }
                        HomeTile(title: "Appels", subtitle: "Appel audio familial", icon: "phone") { CallsView() }
                        HomeTile(title: "Tableau de bord", subtitle: "Mode tablette", icon: "rectangle.3.group") { FamilyDashboardView() }
                    }
                }
                if store.isBusy { ProgressView("Synchronisation sécurisée…").frame(maxWidth: .infinity).padding(.top, 5) }
            }
            .padding(18)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
    }

    private var summaryCard: some View {
        let interval = Calendar.current.dateInterval(of: .month, for: .now)
        let total = store.documents.reduce(0.0) { sum, item in
            if item.kind == "subscription" { return sum + MaisonMoney.monthlyAmount(for: item) }
            if item.kind == "expense", let date = item.date, interval?.contains(date) == true { return sum + (item.amount ?? 0) }
            return sum
        }
        return VStack(alignment: .leading, spacing: 14) {
            HStack { Label("Dépenses suivies", systemImage: "chart.bar.fill").font(.subheadline.weight(.medium)); Spacer(); Text("Ce mois").font(.caption).padding(.horizontal, 10).padding(.vertical, 5).background(.white.opacity(0.55), in: Capsule()) }
            Text(total, format: .currency(code: Locale.current.currency?.identifier ?? "EUR")).font(.system(size: 33, weight: .semibold, design: .rounded))
            if !store.documents.filter({ $0.kind == "expense" || $0.kind == "subscription" }).isEmpty {
                Chart(store.documents.filter { $0.kind == "expense" || $0.kind == "subscription" }.prefix(6)) { item in
                    BarMark(x: .value("Élément", item.title), y: .value("Montant", item.amount ?? 0)).foregroundStyle(Color.maisonTeal.gradient).cornerRadius(4)
                }.frame(height: 75).chartXAxis(.hidden).chartYAxis(.hidden)
            } else { Text("Ajoute un abonnement ou une dépense pour commencer.").font(.caption).opacity(0.8) }
        }
        .foregroundStyle(Color.maisonInk)
        .padding(18)
        .background(LinearGradient(colors: [Color.maisonMint, Color(red: 0.91, green: 0.94, blue: 0.89)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 24))
    }
    private var emptyHome: some View {
        VStack(spacing: 16) {
            Image(systemName: "house.and.flag").font(.system(size: 50)).foregroundStyle(Color.maisonTeal)
            Text("Crée ton premier foyer").font(.title2.weight(.semibold))
            Text("Tu pourras ensuite inviter les personnes avec qui tu partages la maison.").multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Créer un foyer") { showingCreateHousehold = true }.buttonStyle(.borderedProminent).tint(.maisonTeal)
            Button("J’ai un code d’invitation") { showingJoin = true }.buttonStyle(.bordered)
        }.padding(28).frame(maxWidth: 420).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var upcomingReminders: [MaisonDocument] { store.documents(of: "reminder").filter { !$0.completed && ($0.date ?? .distantPast) >= Calendar.current.startOfDay(for: .now) }.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) } }
}

private struct MetricCard: View {
    var title: String; var value: String; var symbol: String; var color: Color
    var body: some View { VStack(alignment: .leading, spacing: 10) { Image(systemName: symbol).foregroundStyle(color); Text(value).font(.title2.weight(.semibold)); Text(title).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(15).background(.white, in: RoundedRectangle(cornerRadius: 18)) }
}

struct HomeTile<Destination: View>: View {
    var title: String; var subtitle: String; var icon: String; @ViewBuilder var destination: () -> Destination
    var body: some View { NavigationLink { destination() } label: { HStack(alignment: .top, spacing: 11) { Image(systemName: icon).font(.title3).foregroundStyle(Color.maisonTeal).frame(width: 30); VStack(alignment: .leading, spacing: 4) { Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.maisonInk); Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2) }; Spacer(minLength: 0) }.padding(14).frame(maxWidth: .infinity, minHeight: 82, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 17)) }.buttonStyle(.plain) }
}

struct SectionHeading: View { var title: String; var subtitle: String? = nil; var body: some View { VStack(alignment: .leading, spacing: 2) { Text(title).font(.headline).foregroundStyle(Color.maisonInk); if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) } } } }
struct EmptyHint: View { var text: String; var symbol: String = "tray"; var body: some View { Label(text, systemImage: symbol).font(.subheadline).foregroundStyle(.secondary).padding(15).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 14)) } }
struct DocumentRow: View {
    @Environment(AppStore.self) private var store
    var document: MaisonDocument; var symbol: String = "circle"; var trailing: String = ""
    var body: some View { HStack(spacing: 12) { Image(systemName: symbol).foregroundStyle(Color.maisonTeal).frame(width: 24); VStack(alignment: .leading, spacing: 3) { Text(document.title).font(.subheadline.weight(.medium)).foregroundStyle(Color.maisonInk); if let detail = document.detail, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }; Spacer(); if let amount = document.amount { Text(amount, format: .currency(code: Locale.current.currency?.identifier ?? "EUR")).font(.subheadline.weight(.medium)) } else { Text(trailing).font(.caption).foregroundStyle(.secondary) } }.padding(13).background(.white, in: RoundedRectangle(cornerRadius: 14)) }
}

struct CreateHouseholdSheet: View {
    @Environment(AppStore.self) private var store; @Environment(\.dismiss) private var dismiss; @State private var name = "Famille"; @State private var busy = false
    var body: some View { NavigationStack { Form { TextField("Nom du foyer", text: $name); Text("La clé de chiffrement du foyer sera créée sur cet appareil et chiffrée pour ton compte.").font(.footnote).foregroundStyle(.secondary) }.navigationTitle("Nouveau foyer").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Créer") { Task { busy = true; await store.createHousehold(name: name); busy = false; dismiss() } }.disabled(name.isEmpty || busy) } } } }
}

struct JoinHouseholdSheet: View {
    @Environment(AppStore.self) private var store; @Environment(\.dismiss) private var dismiss; @State private var code = ""
    var body: some View { NavigationStack { Form { TextField("Code d’invitation", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled() }.navigationTitle("Rejoindre un foyer").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Rejoindre") { Task { await store.acceptInvite(code); dismiss() } }.disabled(code.isEmpty) } } } }
}

struct InviteMemberSheet: View {
    @Environment(AppStore.self) private var store; @Environment(\.dismiss) private var dismiss; @State private var email = ""; @State private var role: HouseholdRole = .adult; @State private var inviteCode: String?
    var body: some View { NavigationStack { Form { if let inviteCode { Section("Code à transmettre") { Text(inviteCode).font(.system(.body, design: .monospaced)); ShareLink(item: inviteCode) { Label("Partager le code", systemImage: "square.and.arrow.up") } }; Text("Le membre doit créer son compte puis saisir ce code.").font(.footnote).foregroundStyle(.secondary) } else { TextField("Adresse e-mail du membre", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never); Picker("Rôle", selection: $role) { Text("Adulte / parent").tag(HouseholdRole.adult); Text("Enfant").tag(HouseholdRole.child); Text("Locataire").tag(HouseholdRole.tenant) }; Text("Le compte invité doit déjà être créé pour que sa clé publique puisse recevoir la clé du foyer.").font(.footnote).foregroundStyle(.secondary) } }.navigationTitle("Inviter un membre").toolbar { ToolbarItem(placement: .cancellationAction) { Button(inviteCode == nil ? "Annuler" : "Fermer") { dismiss() } }; if inviteCode == nil { ToolbarItem(placement: .confirmationAction) { Button("Créer le code") { Task { inviteCode = await store.createInvite(email: email, role: role) } }.disabled(email.isEmpty) } } } } }
}
