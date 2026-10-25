import SwiftUI

struct FridgeView: View {
    @Environment(AppStore.self) private var store; @State private var showAdd = false
    private var products: [MaisonDocument] { store.documents(of: "food").sorted { ($0.expirationDate ?? .distantFuture) < ($1.expirationDate ?? .distantFuture) } }
    var body: some View {
        List {
            Section { VStack(alignment: .leading, spacing: 6) { Text("À consommer bientôt").font(.headline); let soon = products.filter { ($0.expirationDate ?? .distantFuture) <= Calendar.current.date(byAdding: .day, value: 3, to: .now)! }; Text(soon.isEmpty ? "Rien n’arrive bientôt à expiration." : "\(soon.count) produit(s) à vérifier dans les trois prochains jours.").font(.subheadline).foregroundStyle(.secondary) }.padding(.vertical, 4) }
            ForEach(products) { item in HStack(spacing: 12) { Image(systemName: item.storagePlace == "Congélateur" ? "snowflake" : item.storagePlace == "Placard" ? "cabinet" : "refrigerator").foregroundStyle(Color.maisonTeal).frame(width: 27); VStack(alignment: .leading, spacing: 4) { Text(item.title).fontWeight(.medium); Text("\(item.storagePlace ?? "Frigo") · \(item.quantity ?? "1")").font(.caption).foregroundStyle(.secondary); if let expiry = item.expirationDate { Text(expiryText(expiry)).font(.caption).foregroundStyle(expiry < .now ? .red : Color.maisonTeal) } }; Spacer(); if let barcode = item.barcode, !barcode.isEmpty { Image(systemName: "barcode").foregroundStyle(.tertiary) } }.swipeActions { Button("Supprimer", role: .destructive) { Task { await store.delete(item) } } } }
        }.navigationTitle("Frigo & placards").toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showAdd = true } label: { Image(systemName: "plus") } } }.sheet(isPresented: $showAdd) { FoodEditor() }
    }
    private func expiryText(_ date: Date) -> String { date < .now ? "Date dépassée" : "À consommer avant le \(date.formatted(date: .abbreviated, time: .omitted))" }
}

private struct FoodEditor: View {
    @Environment(AppStore.self) private var store; @Environment(\.dismiss) private var dismiss
    @State private var name = ""; @State private var brand = ""; @State private var barcode = ""; @State private var quantity = "1"; @State private var storage = "Frigo"; @State private var expiration = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now; @State private var showScanner = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Produit") { TextField("Nom du produit", text: $name); TextField("Marque (facultatif)", text: $brand); TextField("Quantité", text: $quantity); Picker("Rangement", selection: $storage) { Text("Frigo").tag("Frigo"); Text("Congélateur").tag("Congélateur"); Text("Placard").tag("Placard") } }
                Section("Code-barres") { TextField("Code (facultatif)", text: $barcode).keyboardType(.numberPad); Button { showScanner = true } label: { Label("Scanner le code-barres", systemImage: "barcode.viewfinder") }; Text("Si le produit n’est pas reconnu, tu peux saisir son nom à la main.").font(.footnote).foregroundStyle(.secondary) }
                Section("Péremption") { DatePicker("À consommer avant", selection: $expiration, displayedComponents: .date); Text("MaisonZen rappellera la date trois jours avant, sur les appareils du foyer.").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Ajouter un produit")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Enregistrer") { let notifyDate = Calendar.current.date(byAdding: .day, value: -3, to: expiration).map { max($0, .now) }; let doc = MaisonDocument(kind: "food", title: name, detail: brand, date: expiration, barcode: barcode, expirationDate: expiration, storagePlace: storage, quantity: quantity, notifyAt: notifyDate); Task { await store.save(doc, audience: "household"); dismiss() } }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) } }
            .fullScreenCover(isPresented: $showScanner) { BarcodeScanner { value in barcode = value; showScanner = false; Task { if let product = await store.lookupProduct(value) { name = product.name ?? name; brand = product.brand ?? brand; quantity = product.quantity ?? quantity } } } }
        }
    }
}

struct RecipesView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("maisonzen.recipes.diet") private var diet = "Tout"
    @AppStorage("maisonzen.recipes.allergies") private var allergyText = ""
    @State private var meal = "Tous les repas"
    private var available: Set<String> { Set(store.documents(of: "food").map { $0.title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) }) }
    private var results: [Recipe] {
        Recipe.library.filter { recipe in
            let dietOK = diet == "Tout" || recipe.tags.contains(diet)
            let mealOK = meal == "Tous les repas" || recipe.meal == meal
            let excluded = allergyText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            let safe = !recipe.allergens.contains(where: { allergen in excluded.contains(where: { allergen.localizedCaseInsensitiveContains($0) }) })
            return dietOK && mealOK && safe
        }
    }
    var body: some View {
        List {
            Section("Préférences") { Picker("Régime", selection: $diet) { ForEach(["Tout", "Végétarien", "Végétalien", "Sans gluten"], id: \.self) { Text($0) } }; Picker("Repas", selection: $meal) { ForEach(["Tous les repas", "Midi", "Soir"], id: \.self) { Text($0) } }; TextField("Allergies à exclure, séparées par des virgules", text: $allergyText) }
            Section { Text("Les recettes sont gratuites. Elles sont filtrées sur cet appareil selon tes préférences.").font(.footnote).foregroundStyle(.secondary) }
            ForEach(results) { recipe in
                NavigationLink { RecipeDetailView(recipe: recipe, available: available) } label: {
                    VStack(alignment: .leading, spacing: 5) { HStack { Text(recipe.title).font(.headline); Spacer(); Text(recipe.meal).font(.caption).padding(.horizontal, 8).padding(.vertical, 4).background(Color.maisonMint, in: Capsule()) }; Text("\(recipe.duration) min · \(recipe.tags.joined(separator: " · "))").font(.caption).foregroundStyle(.secondary); Text("\(recipe.ingredients.filter { containsIngredient($0) }.count)/\(recipe.ingredients.count) ingrédients disponibles").font(.caption).foregroundStyle(Color.maisonTeal) }
                    .padding(.vertical, 3)
                }
            }
        }.navigationTitle("Recettes")
    }
    private func containsIngredient(_ name: String) -> Bool { available.contains { $0.localizedCaseInsensitiveContains(name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)) || name.localizedCaseInsensitiveContains($0) } }
}

private struct RecipeDetailView: View {
    @Environment(AppStore.self) private var store
    var recipe: Recipe; var available: Set<String>
    var body: some View { List { Section("Ingrédients · \(recipe.portions) personnes") { ForEach(recipe.ingredients, id: \.self) { item in Label(item, systemImage: isAvailable(item) ? "checkmark.circle.fill" : "circle").foregroundStyle(isAvailable(item) ? Color.maisonTeal : Color.primary) } }; Section("Préparation") { ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in LabeledContent("\(index + 1)", value: step) } }; Section { Button { let doc = MaisonDocument(kind: "calendar", title: "Repas · \(recipe.title)", detail: "\(recipe.meal) · \(recipe.duration) min", date: Calendar.current.date(bySettingHour: recipe.meal == "Soir" ? 19 : 12, minute: 0, second: 0, of: .now), ingredients: recipe.ingredients); Task { await store.save(doc, audience: "household") } } label: { Label("Ajouter au planning du foyer", systemImage: "calendar.badge.plus") } } }.navigationTitle(recipe.title).navigationBarTitleDisplayMode(.inline) }
    private func isAvailable(_ item: String) -> Bool { available.contains { $0.localizedCaseInsensitiveContains(item.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)) || item.localizedCaseInsensitiveContains($0) } }
}

private struct Recipe: Identifiable {
    var id: String { title }; var title: String; var meal: String; var duration: Int; var tags: [String]; var allergens: [String]; var ingredients: [String]; var steps: [String]; var portions: Int = 4
    static let library: [Recipe] = [
        .init(title: "Omelette aux légumes", meal: "Midi", duration: 20, tags: ["Végétarien", "Sans gluten"], allergens: ["œuf"], ingredients: ["œufs", "tomates", "fromage", "oignons"], steps: ["Couper les légumes.", "Faire revenir les oignons et les tomates.", "Battre les œufs, verser dans la poêle et ajouter le fromage.", "Cuire à feu doux jusqu’à ce que l’omelette prenne."]),
        .init(title: "Pâtes tomate basilic", meal: "Soir", duration: 25, tags: ["Végétarien", "Végétalien"], allergens: ["gluten"], ingredients: ["pâtes", "tomates", "ail", "basilic"], steps: ["Cuire les pâtes.", "Faire mijoter les tomates avec l’ail.", "Mélanger et ajouter le basilic."]),
        .init(title: "Riz sauté aux légumes", meal: "Midi", duration: 25, tags: ["Végétarien", "Végétalien", "Sans gluten"], allergens: ["soja"], ingredients: ["riz", "carottes", "petits pois", "oignons"], steps: ["Cuire le riz puis l’égoutter.", "Faire revenir les légumes.", "Ajouter le riz et faire sauter quelques minutes."]),
        .init(title: "Gratin de pommes de terre", meal: "Soir", duration: 55, tags: ["Végétarien", "Sans gluten"], allergens: ["lait"], ingredients: ["pommes de terre", "crème", "fromage", "ail"], steps: ["Préchauffer le four à 180 °C.", "Couper les pommes de terre en rondelles.", "Ajouter la crème, l’ail et le fromage.", "Enfourner environ 45 minutes."]),
        .init(title: "Salade de lentilles", meal: "Midi", duration: 30, tags: ["Végétarien", "Végétalien", "Sans gluten"], allergens: [], ingredients: ["lentilles", "carottes", "oignons", "vinaigre"], steps: ["Cuire les lentilles.", "Râper les carottes et couper l’oignon.", "Mélanger et assaisonner."]),
        .init(title: "Soupe de légumes", meal: "Soir", duration: 35, tags: ["Végétarien", "Végétalien", "Sans gluten"], allergens: [], ingredients: ["carottes", "pommes de terre", "oignons", "bouillon"], steps: ["Couper les légumes.", "Les couvrir de bouillon et cuire 25 minutes.", "Mixer ou servir en morceaux."])
    ]
}
