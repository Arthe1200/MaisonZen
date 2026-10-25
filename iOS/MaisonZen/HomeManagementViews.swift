import SwiftUI

struct SubscriptionsView: View {
    @Environment(AppStore.self) private var store
    @State private var editing = false
    @State private var selectedSubscription: MaisonDocument?
    var body: some View {
        List {
            Section { summary }
            Section("Paiements réguliers") {
                if store.documents(of: "subscription").isEmpty { Text("Aucun abonnement ajouté.").foregroundStyle(.secondary) }
                ForEach(store.documents(of: "subscription")) { item in
                    HStack { VStack(alignment: .leading, spacing: 4) { Text(item.title).fontWeight(.medium); Text("\(item.category ?? "Autre") · \(item.recurrence ?? "Mensuel")").font(.caption).foregroundStyle(.secondary); if let date = item.date { Text("Prochain paiement : \(date.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) } }; Spacer(); Text(item.amount ?? 0, format: .currency(code: Locale.current.currency?.identifier ?? "EUR")).fontWeight(.semibold) }.contentShape(Rectangle()).onTapGesture { selectedSubscription = item; editing = true }
                        .swipeActions { Button("Supprimer", role: .destructive) { Task { await store.delete(item) } }; Button("Modifier", systemImage: "pencil") { selectedSubscription = item; editing = true }.tint(.maisonTeal) }
                }
            }
        }.navigationTitle("Abonnements").toolbar { ToolbarItem(placement: .topBarTrailing) { Button { selectedSubscription = nil; editing = true } label: { Image(systemName: "plus") } } }.sheet(isPresented: $editing) { SubscriptionEditor(document: selectedSubscription, shared: selectedSubscription.flatMap { store.record(for: $0)?.audience == "adults" } ?? true) }
    }
    private var summary: some View { let total = store.documents(of: "subscription").reduce(0) { $0 + MaisonMoney.monthlyAmount(for: $1) }; return VStack(alignment: .leading, spacing: 5) { Text("Total mensuel estimé").font(.caption).foregroundStyle(.secondary); Text(total, format: .currency(code: Locale.current.currency?.identifier ?? "EUR")).font(.title2.bold()); Text("Les montants annuels et hebdomadaires sont ramenés à une moyenne mensuelle.").font(.caption2).foregroundStyle(.secondary) }.padding(.vertical, 5) }
}

struct SubscriptionEditor: View {
    @Environment(AppStore.self) private var store; @Environment(\.dismiss) private var dismiss
    private let document: MaisonDocument?
    @State private var name: String; @State private var amount: String; @State private var category: String; @State private var recurrence: String; @State private var date: Date; @State private var shared: Bool; @State private var silent: Bool; @State private var concernedMembers: Set<UUID>
    private let categories = ["Streaming", "Téléphone", "Logement", "Transport", "Assurance", "Internet", "Sport", "Autre"]
    private let frequencies = ["Chaque semaine", "Chaque mois", "Chaque année"]
    init(document: MaisonDocument? = nil, shared: Bool = true) { self.document = document; _name = State(initialValue: document?.title ?? ""); _amount = State(initialValue: document?.amount.map { String($0) } ?? ""); _category = State(initialValue: document?.category ?? "Streaming"); _recurrence = State(initialValue: document?.recurrence ?? "Chaque mois"); _date = State(initialValue: document?.date ?? .now); _shared = State(initialValue: shared); _silent = State(initialValue: document?.isSilent ?? false); _concernedMembers = State(initialValue: Set(document?.allowedMembers ?? [])) }
    var body: some View { NavigationStack { Form {
        Section("Abonnement") { TextField("Nom", text: $name); TextField("Prix", text: $amount).keyboardType(.decimalPad); Picker("Catégorie", selection: $category) { ForEach(categories, id: \.self) { Text($0) } }; Picker("Fréquence", selection: $recurrence) { ForEach(frequencies, id: \.self) { Text($0) } }; DatePicker("Prochain paiement", selection: $date, displayedComponents: .date) }
        Section("Visibilité") { if store.isAdult { Toggle("Abonnement du foyer (adultes)", isOn: $shared).disabled(document != nil) }; Text(store.isAdult && shared ? "Les dépenses du foyer sont réservées aux adultes." : "Cet abonnement reste privé sur ton compte.").font(.footnote).foregroundStyle(.secondary); if document != nil { Text("La visibilité est conservée lors de la modification.").font(.footnote).foregroundStyle(.secondary) } }
        Section("Personnes concernées") { ForEach(store.members) { member in Toggle(member.displayName, isOn: Binding(get: { concernedMembers.contains(member.userId) }, set: { selected in if selected { concernedMembers.insert(member.userId) } else { concernedMembers.remove(member.userId) } })) }; Toggle("Rappel silencieux", isOn: $silent) }
    }.navigationTitle(document == nil ? "Nouvel abonnement" : "Modifier l’abonnement").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Enregistrer") { save() }.disabled(name.isEmpty || Double(amount.replacingOccurrences(of: ",", with: ".")) == nil || (Double(amount.replacingOccurrences(of: ",", with: ".")) ?? -1) < 0) } } } }
    private func save() { guard let value = Double(amount.replacingOccurrences(of: ",", with: ".")), value >= 0 else { return }; let people = Array(concernedMembers); let doc = MaisonDocument(id: document?.id ?? UUID(), kind: "subscription", title: name, amount: value, category: category, date: date, recurrence: recurrence, allowedMembers: people, notifyAt: date, isSilent: silent); let oldRecord = document.flatMap { store.record(for: $0) }; Task { await store.save(doc, audience: oldRecord?.audience ?? (shared && store.isAdult ? "adults" : "owner"), ownerId: oldRecord?.ownerId ?? (shared ? nil : store.userId), allowed: oldRecord?.allowedMemberIds ?? people); dismiss() } }
}

struct ExpensesView: View {
    @Environment(AppStore.self) private var store
    @State private var editing = false
    @State private var selectedExpense: MaisonDocument?
    @State private var showShared = true
    private var rows: [MaisonDocument] { store.documents(of: "expense").filter { document in guard let record = store.record(for: document) else { return false }; return showShared ? record.audience == "adults" : record.audience == "owner" } }
    var body: some View {
        VStack(spacing: 0) {
            Picker("Dépenses", selection: $showShared) { Text("Foyer").tag(true); Text("Personnelles").tag(false) }.pickerStyle(.segmented).padding()
            if !store.isAdult && showShared { ContentUnavailableView("Réservé aux adultes", systemImage: "lock", description: Text("Les dépenses communes sont visibles uniquement par les adultes du foyer.")) }
            else if rows.isEmpty { ContentUnavailableView("Aucune dépense", systemImage: "chart.pie", description: Text("Ajoute une dépense pour commencer le suivi.")) }
            else { List { ForEach(rows) { item in HStack { VStack(alignment: .leading) { Text(item.title); Text(item.category ?? "Dépense").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(item.amount ?? 0, format: .currency(code: Locale.current.currency?.identifier ?? "EUR")) }.contentShape(Rectangle()).onTapGesture { selectedExpense = item; editing = true }.swipeActions { Button("Supprimer", role: .destructive) { Task { await store.delete(item) } }; Button("Modifier", systemImage: "pencil") { selectedExpense = item; editing = true }.tint(.maisonTeal) } } } }
        }.navigationTitle("Dépenses").toolbar { ToolbarItem(placement: .topBarTrailing) { Button { selectedExpense = nil; editing = true } label: { Image(systemName: "plus") } } }.sheet(isPresented: $editing) { ExpenseEditor(document: selectedExpense, shared: selectedExpense.flatMap { store.record(for: $0)?.audience == "adults" } ?? false) }
    }
}

private struct ExpenseEditor: View {
    @Environment(AppStore.self) private var store; @Environment(\.dismiss) private var dismiss
    private let document: MaisonDocument?
    @State private var name: String; @State private var amount: String; @State private var category: String; @State private var shared: Bool; @State private var date: Date
    private let categories = ["Courses", "Logement", "Transport", "Santé", "Loisirs", "Autre"]
    init(document: MaisonDocument? = nil, shared: Bool = false) { self.document = document; _name = State(initialValue: document?.title ?? ""); _amount = State(initialValue: document?.amount.map { String($0) } ?? ""); _category = State(initialValue: document?.category ?? "Courses"); _shared = State(initialValue: shared); _date = State(initialValue: document?.date ?? .now) }
    var body: some View { NavigationStack { Form { Section("Dépense") { TextField("Description", text: $name); TextField("Montant", text: $amount).keyboardType(.decimalPad); Picker("Catégorie", selection: $category) { ForEach(categories, id: \.self) { Text($0) } }; DatePicker("Date", selection: $date, displayedComponents: .date) }; Section("Confidentialité") { if store.isAdult { Toggle("Dépense commune du foyer", isOn: $shared).disabled(document != nil) }; Text(shared ? "Visible uniquement par les adultes." : "Visible uniquement par toi.").font(.footnote).foregroundStyle(.secondary); if document != nil { Text("La visibilité est conservée lors de la modification.").font(.footnote).foregroundStyle(.secondary) } } }.navigationTitle(document == nil ? "Nouvelle dépense" : "Modifier la dépense").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Enregistrer") { guard let value = Double(amount.replacingOccurrences(of: ",", with: ".")), value >= 0 else { return }; let doc = MaisonDocument(id: document?.id ?? UUID(), kind: "expense", title: name, amount: value, category: category, date: date); let oldRecord = document.flatMap { store.record(for: $0) }; Task { await store.save(doc, audience: oldRecord?.audience ?? (shared && store.isAdult ? "adults" : "owner"), ownerId: oldRecord?.ownerId ?? (shared ? nil : store.userId), allowed: oldRecord?.allowedMemberIds ?? []); dismiss() } }.disabled(name.isEmpty || Double(amount.replacingOccurrences(of: ",", with: ".")) == nil || (Double(amount.replacingOccurrences(of: ",", with: ".")) ?? -1) < 0) } } } }
}

struct RemindersView: View {
    @Environment(AppStore.self) private var store; @State private var editing = false
    var body: some View { List { if store.documents(of: "reminder").isEmpty { Text("Aucun rappel pour le moment.").foregroundStyle(.secondary) }; ForEach(store.documents(of: "reminder")) { item in HStack { Image(systemName: item.completed ? "checkmark.circle.fill" : "bell").foregroundStyle(item.completed ? .green : Color.maisonTeal); VStack(alignment: .leading) { Text(item.title); Text([item.date?.formatted(date: .abbreviated, time: .shortened), item.recurrence].compactMap{$0}.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }; Spacer(); if item.isSilent { Image(systemName: "bell.slash").foregroundStyle(.secondary) } }.swipeActions { Button("Terminé") { var changed = item; changed.completed = true; Task { await store.save(changed, audience: store.record(for: item)?.audience ?? "household", ownerId: store.record(for: item)?.ownerId, allowed: store.record(for: item)?.allowedMemberIds ?? []) } }; Button("Supprimer", role: .destructive) { Task { await store.delete(item) } } } } }.navigationTitle("Rappels").toolbar { ToolbarItem(placement: .topBarTrailing) { Button { editing = true } label: { Image(systemName: "plus") } } }.sheet(isPresented: $editing) { ReminderEditor() } }
}

struct ReminderEditor: View {
    @Environment(AppStore.self) private var store; @Environment(\.dismiss) private var dismiss
    @State private var title = ""; @State private var detail = ""; @State private var date = Date(); @State private var recurrence = "Aucune"; @State private var recipient = "all"; @State private var silent = false
    private let frequencies = ["Aucune", "Chaque jour", "Chaque semaine", "Chaque mois", "Chaque année"]
    var body: some View { NavigationStack { Form { Section("Rappel") { TextField("Titre", text: $title); TextField("Détail (facultatif)", text: $detail); DatePicker("Date et heure", selection: $date); Picker("Répétition", selection: $recurrence) { ForEach(frequencies, id: \.self) { Text($0) } }; Toggle("Mode silencieux", isOn: $silent) }; Section("Destinataire") { Picker("Envoyer à", selection: $recipient) { Text("Tout le foyer").tag("all"); Text("Moi uniquement").tag("me"); ForEach(store.members) { member in Text(member.displayName).tag(member.userId.uuidString) } } } }.navigationTitle("Nouveau rappel").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Enregistrer") { save() }.disabled(title.isEmpty) } } } }
    private func save() { let recipientId = UUID(uuidString: recipient); let doc = MaisonDocument(kind: "reminder", title: title, detail: detail, date: date, recurrence: recurrence, recipientId: recipientId, allowedMembers: [store.userId, recipientId].compactMap { $0 }, notifyAt: date, isSilent: silent); let audience = recipient == "all" ? "household" : recipient == "me" ? "owner" : "members"; Task { await store.save(doc, audience: audience, ownerId: audience == "owner" ? store.userId : nil, allowed: audience == "members" ? doc.allowedMembers : []); dismiss() } }
}

struct TasksView: View {
    @Environment(AppStore.self) private var store; @State private var editing = false; @State private var showCompleted = false
    var body: some View { List { Section { Toggle("Afficher les tâches terminées", isOn: $showCompleted) }; ForEach(store.documents(of: "task").filter { showCompleted || !$0.completed }) { task in HStack(spacing: 12) { Button { var changed = task; changed.completed.toggle(); Task { await save(changed) } } label: { Image(systemName: task.completed ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(task.completed ? .green : Color.maisonTeal) }.buttonStyle(.plain); VStack(alignment: .leading) { Text(task.title).strikethrough(task.completed); if let due = task.date { Text("Pour le \(due.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }; if let recipientId = task.recipientId, let person = store.members.first(where: { $0.userId == recipientId }) { Text("Pour \(person.displayName)").font(.caption).foregroundStyle(Color.maisonTeal) } }; Spacer() }.swipeActions { Button("Supprimer", role: .destructive) { Task { await store.delete(task) } } } } }.navigationTitle("Tâches & devoirs").toolbar { ToolbarItem(placement: .topBarTrailing) { Button { editing = true } label: { Image(systemName: "plus") } } }.sheet(isPresented: $editing) { TaskEditor() } }
    private func save(_ task: MaisonDocument) async { await store.save(task, audience: "household") }
}

struct TaskEditor: View {
    @Environment(AppStore.self) private var store; @Environment(\.dismiss) private var dismiss
    @State private var title = ""; @State private var detail = ""; @State private var due = Date(); @State private var assigned = ""; @State private var recurrence = "Aucune"
    var body: some View { NavigationStack { Form { Section("Tâche") { TextField("Titre ou devoir", text: $title); TextField("Détail", text: $detail); DatePicker("Échéance", selection: $due); Picker("Répétition", selection: $recurrence) { ForEach(["Aucune", "Chaque jour", "Chaque semaine", "Chaque mois", "Chaque année"], id: \.self) { Text($0) } } }; Section("Attribuer à") { Picker("Personne", selection: $assigned) { Text("Tout le foyer").tag(""); ForEach(store.members) { Text($0.displayName).tag($0.userId.uuidString) } } } }.navigationTitle("Nouvelle tâche").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Ajouter") { let target = UUID(uuidString: assigned); let doc = MaisonDocument(kind: "task", title: title, detail: detail, date: due, recurrence: recurrence, recipientId: target, allowedMembers: [store.userId, target].compactMap{$0}, notifyAt: due); Task { await store.save(doc, audience: "household"); dismiss() } }.disabled(title.isEmpty) } } } }
}

struct CalendarView: View {
    @Environment(AppStore.self) private var store; @State private var showEditor = false; @State private var selectedDay = Date()
    private var eventsThisWeek: [MaisonDocument] { let interval = Calendar.current.dateInterval(of: .weekOfYear, for: selectedDay); return store.documents(of: "calendar").filter { guard let date = $0.date else { return false }; return interval?.contains(date) == true }.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) } }
    var body: some View { VStack { DatePicker("Semaine du foyer", selection: $selectedDay, displayedComponents: .date).datePickerStyle(.graphical).padding(.horizontal); List { if eventsThisWeek.isEmpty { Text("Aucun événement cette semaine.").foregroundStyle(.secondary) }; ForEach(eventsThisWeek) { event in DocumentRow(document: event, symbol: "calendar", trailing: event.date?.formatted(date: .abbreviated, time: .shortened) ?? "") } }.listStyle(.plain) }.navigationTitle("Planning partagé").toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showEditor = true } label: { Image(systemName: "plus") } } }.sheet(isPresented: $showEditor) { CalendarEventEditor() } }
}

private struct CalendarEventEditor: View {
    @Environment(AppStore.self) private var store; @Environment(\.dismiss) private var dismiss; @State private var title = ""; @State private var date = Date(); @State private var detail = ""
    var body: some View { NavigationStack { Form { TextField("Événement", text: $title); TextField("Détail", text: $detail); DatePicker("Date et heure", selection: $date) }.navigationTitle("Ajouter au planning").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Ajouter") { let doc = MaisonDocument(kind: "calendar", title: title, detail: detail, date: date); Task { await store.save(doc, audience: "household"); dismiss() } }.disabled(title.isEmpty) } } } }
}
