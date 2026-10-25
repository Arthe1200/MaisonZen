package fr.maisonzen.android

import android.Manifest
import android.app.DatePickerDialog
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.TaskAlt
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.UUID
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val store by viewModels<AppStore>()

    @OptIn(ExperimentalMaterial3Api::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme(
                colorScheme = androidx.compose.material3.lightColorScheme(
                    primary = androidx.compose.ui.graphics.Color(0xFF4A8F83),
                    secondary = androidx.compose.ui.graphics.Color(0xFFC68C69),
                    background = androidx.compose.ui.graphics.Color(0xFFF5F4EF),
                    surface = androidx.compose.ui.graphics.Color(0xFFFFFEFA)
                )
            ) {
                val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { }
                LaunchedEffect(store.isSignedIn) {
                    if (store.isSignedIn && Build.VERSION.SDK_INT >= 33) permission.launch(Manifest.permission.POST_NOTIFICATIONS)
                }
                MaisonZenApp(store)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MaisonZenApp(store: AppStore) {
    var menuOpen by remember { mutableStateOf(false) }
    var createKind by remember { mutableStateOf<String?>(null) }
    var editingDocument by remember { mutableStateOf<MaisonDocument?>(null) }
    var householdDialog by remember { mutableStateOf(false) }
    var chatDialog by remember { mutableStateOf(false) }

    if (!store.isSignedIn) {
        AuthScreen(store)
        return
    }
    if (store.recoveryNeeded) {
        RecoveryScreen(store)
        return
    }
    if (store.selectedHousehold == null) {
        HouseholdSetup(store)
        return
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Column { Text("Maison Zen", fontWeight = FontWeight.SemiBold); Text(store.selectedName, style = MaterialTheme.typography.labelMedium) } },
                actions = {
                    BoxMenu(store, onOpen = { menuOpen = true })
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        listOf("Accueil", "Rappels", "Tâches", "Budget", "Abonnements", "Planning", "Messages", "Frigo", "Recettes", "Foyer", "Réglages").forEach { page ->
                            DropdownMenuItem(text = { Text(page) }, onClick = { store.currentPage = page; menuOpen = false })
                        }
                    }
                }
            )
        },
        bottomBar = {
            NavigationBar {
                listOf("Accueil" to Icons.Default.Home, "Planning" to Icons.Default.CalendarMonth, "Tâches" to Icons.Default.TaskAlt, "Rappels" to Icons.Default.Notifications, "Menu" to Icons.Default.Menu).forEach { (label, icon) ->
                    NavigationBarItem(
                        selected = if (label == "Menu") store.currentPage in setOf("Budget", "Abonnements", "Messages", "Frigo", "Recettes", "Foyer", "Réglages") else store.currentPage == label,
                        onClick = { if (label == "Menu") menuOpen = true else store.currentPage = label },
                        icon = { androidx.compose.material3.Icon(icon, contentDescription = label) },
                        label = { Text(label) }
                    )
                }
            }
        },
        floatingActionButton = {
            when (store.currentPage) {
                "Messages" -> FloatingActionButton(onClick = { chatDialog = true }) { androidx.compose.material3.Icon(Icons.Default.Add, "Écrire") }
                "Accueil", "Réglages", "Foyer" -> Unit
                else -> FloatingActionButton(onClick = { createKind = kindForPage(store.currentPage) }) { androidx.compose.material3.Icon(Icons.Default.Add, "Ajouter") }
            }
        }
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            store.errorMessage?.let { MessageBanner(it, error = true) }
            store.infoMessage?.let { MessageBanner(it, error = false) }
            if (store.isBusy) androidx.compose.material3.LinearProgressIndicator(Modifier.fillMaxWidth())
            when (store.currentPage) {
                "Accueil", "Tableau de bord" -> Dashboard(store)
                "Rappels", "Tâches", "Abonnements", "Planning", "Dépenses" -> DocumentsPage(store, store.currentPage) { doc -> editingDocument = doc; createKind = doc.kind }
                "Budget" -> BudgetPage(store) { doc -> editingDocument = doc; createKind = doc.kind }
                "Frigo" -> FridgePage(store, onNew = { createKind = "food" }) { doc -> editingDocument = doc; createKind = doc.kind }
                "Recettes" -> RecipesPage(store)
                "Messages" -> ChatPage(store, onNew = { chatDialog = true })
                "Foyer" -> FamilyPage(store, onCreateHousehold = { householdDialog = true })
                "Réglages" -> SettingsPage(store)
                else -> Dashboard(store)
            }
        }
    }

    createKind?.let { kind ->
        DocumentEditor(store, kind, editingDocument, onClose = { createKind = null; editingDocument = null })
    }
    if (householdDialog) HouseholdDialog(store) { householdDialog = false }
    if (chatDialog) ChatComposer(store) { chatDialog = false }
}

@Composable
private fun BoxMenu(store: AppStore, onOpen: () -> Unit) {
    androidx.compose.material3.IconButton(onClick = onOpen) { androidx.compose.material3.Icon(Icons.Default.Menu, "Menu") }
}

private fun kindForPage(page: String): String = when (page) {
    "Rappels" -> "reminder"
    "Tâches" -> "task"
    "Abonnements" -> "subscription"
    "Dépenses", "Budget" -> "expense"
    "Frigo" -> "food"
    else -> "calendar"
}

@Composable
private fun AuthScreen(store: AppStore) {
    var registering by rememberSaveable { mutableStateOf(false) }
    var name by rememberSaveable { mutableStateOf("") }
    var email by rememberSaveable { mutableStateOf("") }
    var password by rememberSaveable { mutableStateOf("") }
    var code by rememberSaveable { mutableStateOf("") }
    var newPassword by rememberSaveable { mutableStateOf("") }
    var resetting by rememberSaveable { mutableStateOf(false) }
    var server by rememberSaveable { mutableStateOf(store.serverAddress) }
    val verifying = store.currentPage == "Vérification"
    val resetCode = store.currentPage == "Code réinitialisation"
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.Center) {
        Text("Maison Zen", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
        Text("Le quotidien de la maison, organisé simplement.", Modifier.padding(top = 6.dp, bottom = 22.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
        Card {
            Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(when { verifying -> "Vérifier l’adresse e-mail"; resetCode -> "Nouveau mot de passe"; resetting -> "Réinitialiser le mot de passe"; registering -> "Créer un compte"; else -> "Se connecter" }, style = MaterialTheme.typography.titleLarge)
                if (resetCode) {
                    Text("Saisis le code reçu par e-mail et choisis un nouveau mot de passe d’au moins 12 caractères.")
                    OutlinedTextField(code, { code = it }, label = { Text("Code de réinitialisation") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
                    OutlinedTextField(newPassword, { newPassword = it }, label = { Text("Nouveau mot de passe") }, modifier = Modifier.fillMaxWidth(), visualTransformation = PasswordVisualTransformation(), singleLine = true)
                    Button(onClick = { store.resetPassword(code, newPassword); resetting = false }, enabled = code.length == 6 && newPassword.length >= 12 && !store.isBusy, modifier = Modifier.fillMaxWidth()) { Text("Modifier le mot de passe") }
                    TextButton(onClick = { store.currentPage = "Accueil"; resetting = false }) { Text("Retour") }
                } else if (verifying) {
                    Text("Saisis le code reçu par e-mail. En environnement de développement, le serveur peut afficher le code directement.")
                    OutlinedTextField(code, { code = it }, label = { Text("Code à 6 chiffres") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
                    Button(onClick = { store.verify(code) }, enabled = code.length == 6 && !store.isBusy, modifier = Modifier.fillMaxWidth()) { Text("Vérifier et continuer") }
                } else if (resetting) {
                    OutlinedTextField(email, { email = it }, label = { Text("Adresse e-mail du compte") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
                    Button(onClick = { store.setServerAddress(server); store.requestPasswordReset(email) }, enabled = email.isNotBlank() && !store.isBusy, modifier = Modifier.fillMaxWidth()) { Text("Envoyer le code") }
                    TextButton(onClick = { resetting = false }) { Text("Retour à la connexion") }
                } else {
                    if (registering) OutlinedTextField(name, { name = it }, label = { Text("Nom affiché") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
                    OutlinedTextField(email, { email = it }, label = { Text("Adresse e-mail") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
                    OutlinedTextField(password, { password = it }, label = { Text("Mot de passe (12 caractères minimum)") }, modifier = Modifier.fillMaxWidth(), visualTransformation = PasswordVisualTransformation(), singleLine = true)
                    OutlinedTextField(server, { server = it }, label = { Text("Adresse du serveur") }, supportingText = { Text("Ex. http://192.168.1.168:5080 — même Wi‑Fi que le PC") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
                    Button(onClick = {
                        store.setServerAddress(server)
                        if (registering) store.register(name, email, password) else store.login(email, password)
                    }, enabled = !store.isBusy && email.isNotBlank() && password.isNotBlank() && (!registering || name.isNotBlank()), modifier = Modifier.fillMaxWidth()) {
                        Text(if (registering) "Créer mon compte" else "Connexion")
                    }
                    TextButton(onClick = { registering = !registering }) { Text(if (registering) "J’ai déjà un compte" else "Créer un compte") }
                    if (!registering) TextButton(onClick = { resetting = true }) { Text("Mot de passe oublié ?") }
                }
                store.errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                store.infoMessage?.let { Text(it, color = MaterialTheme.colorScheme.primary) }
                if (store.isBusy) CircularProgressIndicator(Modifier.size(28.dp))
            }
        }
    }
}

@Composable
private fun HouseholdSetup(store: AppStore) {
    var dialog by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        Text("Bienvenue, ${store.displayName}", style = MaterialTheme.typography.headlineSmall)
        Text("Crée ton foyer ou rejoins-en un avec un code d’invitation.", Modifier.padding(vertical = 14.dp))
        Button(onClick = { dialog = true }) { Text("Créer ou rejoindre un foyer") }
        TextButton(onClick = { store.signOut() }) { Text("Se déconnecter") }
        store.errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    }
    if (dialog) HouseholdDialog(store) { dialog = false }
}

@Composable
private fun HouseholdDialog(store: AppStore, onClose: () -> Unit) {
    var name by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    AlertDialog(onDismissRequest = onClose, title = { Text("Foyer") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedTextField(name, { name = it }, label = { Text("Nom du nouveau foyer") }, modifier = Modifier.fillMaxWidth())
            Button(onClick = { store.createHousehold(name); onClose() }, enabled = name.isNotBlank()) { Text("Créer le foyer") }
            Text("Ou rejoindre un foyer", style = MaterialTheme.typography.titleSmall)
            OutlinedTextField(code, { code = it }, label = { Text("Code d’invitation") }, modifier = Modifier.fillMaxWidth())
            OutlinedButton(onClick = { store.acceptInvite(code); onClose() }, enabled = code.isNotBlank()) { Text("Rejoindre") }
            store.errorMessage?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
    }, confirmButton = { TextButton(onClick = onClose) { Text("Fermer") } })
}

@Composable
private fun Dashboard(store: AppStore) {
    val tasks = store.documents.filter { it.kind == "task" && !it.completed }
    val reminders = store.documents.filter { it.kind == "reminder" && !it.completed }
    val next = store.documents.filter { it.date != null && !it.completed }.sortedBy { it.date }.take(4)
    LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { Spacer(Modifier.height(4.dp)); Text("Bonjour ${store.displayName.ifBlank { "" }}", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold); Text("Voici ce qui se passe à la maison.", color = MaterialTheme.colorScheme.onSurfaceVariant) }
        item { Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) { SummaryCard("À faire", tasks.size.toString(), Modifier.weight(1f)); SummaryCard("Rappels", reminders.size.toString(), Modifier.weight(1f)); SummaryCard("Personnes", store.members.size.toString(), Modifier.weight(1f)) } }
        item { Text("À venir", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Medium) }
        if (next.isEmpty()) item { EmptyCard("Ton planning est encore libre.") }
        items(next, key = { it.id }) { DocumentCard(store, it) }
        item { Text("Raccourcis", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Medium) }
        item { Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { listOf("Budget", "Frigo", "Messages").forEach { page -> FilterChip(selected = false, onClick = { store.currentPage = page }, label = { Text(page) }) } } }
    }
}

@Composable
private fun SummaryCard(title: String, value: String, modifier: Modifier = Modifier) {
    Card(modifier) { Column(Modifier.padding(14.dp)) { Text(value, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold); Text(title, style = MaterialTheme.typography.labelLarge) } }
}

@Composable
private fun DocumentsPage(store: AppStore, page: String, onEdit: (MaisonDocument) -> Unit) {
    val kinds = when (page) {
        "Rappels" -> setOf("reminder")
        "Tâches" -> setOf("task")
        "Abonnements" -> setOf("subscription")
        "Dépenses" -> setOf("expense")
        else -> setOf("calendar")
    }
    val list = store.documents.filter { it.kind in kinds }.sortedBy { it.date ?: Instant.MAX }
    LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(9.dp)) {
        item { Spacer(Modifier.height(8.dp)); Text(page, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold) }
        if (list.isEmpty()) item { EmptyCard("Aucun élément ici pour l’instant.") }
        items(list, key = { it.id }) { item -> DocumentCard(store, item, canComplete = page == "Tâches" || page == "Rappels", onEdit = if (store.canEdit(item)) ({ onEdit(item) }) else null) }
    }
}

@Composable
private fun BudgetPage(store: AppStore, onEdit: (MaisonDocument) -> Unit) {
    val expenses = store.documents.filter { it.kind == "expense" }
    val subscriptions = store.documents.filter { it.kind == "subscription" }
    val sharedTotal = expenses.filter { store.records[it.id]?.audience == "adults" }.sumOf { it.amount ?: 0.0 }
    val monthlySubscriptions = subscriptions.sumOf { item -> when (item.recurrence) { "Chaque semaine" -> (item.amount ?: 0.0) * 52 / 12; "Chaque année" -> (item.amount ?: 0.0) / 12; else -> item.amount ?: 0.0 } }
    LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(9.dp)) {
        item { Spacer(Modifier.height(8.dp)); Text("Budget", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold) }
        item { Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) { SummaryCard("Dépenses du foyer", "%.2f €".format(sharedTotal), Modifier.weight(1f)); SummaryCard("Abonnements / mois", "%.2f €".format(monthlySubscriptions), Modifier.weight(1f)) } }
        item { Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { FilterChip(false, { store.currentPage = "Dépenses" }, label = { Text("Ajouter dépense") }); FilterChip(false, { store.currentPage = "Abonnements" }, label = { Text("Voir abonnements") }) } }
        item { Text("Dépenses visibles pour ton compte", style = MaterialTheme.typography.titleMedium) }
        if (expenses.isEmpty()) item { EmptyCard("Aucune dépense enregistrée.") }
        items(expenses, key = { it.id }) { item -> DocumentCard(store, item, onEdit = if (store.canEdit(item)) ({ onEdit(item) }) else null) }
    }
}

@Composable
private fun FridgePage(store: AppStore, onNew: () -> Unit, onEdit: (MaisonDocument) -> Unit) {
    val foods = store.documents.filter { it.kind == "food" }.sortedBy { it.expirationDate ?: Instant.MAX }
    val urgent = foods.count { it.expirationDate?.isBefore(Instant.now().plus(3, ChronoUnit.DAYS)) == true }
    LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(9.dp)) {
        item { Spacer(Modifier.height(8.dp)); Text("Frigo & placards", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold); Text(if (urgent > 0) "$urgent produit(s) à vérifier dans les 3 prochains jours." else "Rien n’arrive bientôt à expiration.") }
        if (foods.isEmpty()) item { EmptyCard("Ajoute le contenu du frigo ou des placards.") }
        items(foods, key = { it.id }) { item -> DocumentCard(store, item, onEdit = if (store.canEdit(item)) ({ onEdit(item) }) else null) }
        item { OutlinedButton(onClick = onNew, modifier = Modifier.fillMaxWidth()) { androidx.compose.material3.Icon(Icons.Default.Add, null); Text(" Ajouter un produit") } }
    }
}

@Composable
private fun RecipesPage(store: AppStore) {
    var diet by rememberSaveable { mutableStateOf("Tout") }
    var allergies by rememberSaveable { mutableStateOf("") }
    var selected by remember { mutableStateOf<Recipe?>(null) }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            listOf("Tout", "Végétarien", "Végétalien", "Sans gluten").forEach { FilterChip(diet == it, { diet = it }, label = { Text(it) }) }
        }
        OutlinedTextField(allergies, { allergies = it }, label = { Text("Allergies à exclure (séparées par des virgules)") }, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp))
        LazyColumn(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(9.dp)) {
            item { Text("Recettes gratuites", style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(top = 10.dp)) }
            items(RECIPE_LIBRARY.filter { (diet == "Tout" || diet in it.tags) && it.allergens.none { allergen -> allergies.split(',').any { a -> a.trim().isNotEmpty() && allergen.contains(a.trim(), true) } } }, key = { it.title }) { recipe ->
                Card(Modifier.fillMaxWidth().clickable { selected = recipe }) { Column(Modifier.padding(16.dp)) { Text(recipe.title, fontWeight = FontWeight.SemiBold); Text("${recipe.meal} · ${recipe.duration} min · ${recipe.tags.joinToString()}", style = MaterialTheme.typography.bodySmall) } }
            }
        }
    }
    selected?.let { RecipeDialog(store, it) { selected = null } }
}

@Composable
private fun RecipeDialog(store: AppStore, recipe: Recipe, onClose: () -> Unit) {
    AlertDialog(onDismissRequest = onClose, title = { Text(recipe.title) }, text = {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            Text("Ingrédients", fontWeight = FontWeight.SemiBold)
            recipe.ingredients.forEach { Text("• $it") }
            Spacer(Modifier.height(12.dp)); Text("Préparation", fontWeight = FontWeight.SemiBold)
            recipe.steps.forEachIndexed { index, step -> Text("${index + 1}. $step") }
        }
    }, confirmButton = {
        Button(onClick = {
            val hour = if (recipe.meal == "Soir") 19 else 12
            val date = LocalDate.now().atTime(hour, 0).atZone(ZoneId.systemDefault()).toInstant()
            store.saveDocument(MaisonDocument(kind = "calendar", title = "Repas · ${recipe.title}", detail = "${recipe.meal} · ${recipe.duration} min", date = date, ingredients = recipe.ingredients), "household")
            onClose()
        }) { Text("Ajouter au planning") }
    }, dismissButton = { TextButton(onClick = onClose) { Text("Fermer") } })
}

private data class Recipe(val title: String, val meal: String, val duration: Int, val tags: List<String>, val allergens: List<String>, val ingredients: List<String>, val steps: List<String>)
private val RECIPE_LIBRARY = listOf(
    Recipe("Omelette aux légumes", "Midi", 20, listOf("Végétarien", "Sans gluten"), listOf("œuf"), listOf("œufs", "tomates", "fromage", "oignons"), listOf("Couper les légumes.", "Faire revenir les oignons et les tomates.", "Battre les œufs, ajouter le fromage et cuire à feu doux.")),
    Recipe("Pâtes tomate basilic", "Soir", 25, listOf("Végétarien", "Végétalien"), listOf("gluten"), listOf("pâtes", "tomates", "ail", "basilic"), listOf("Cuire les pâtes.", "Faire mijoter les tomates avec l’ail.", "Mélanger et ajouter le basilic.")),
    Recipe("Riz sauté aux légumes", "Midi", 25, listOf("Végétarien", "Végétalien", "Sans gluten"), listOf("soja"), listOf("riz", "carottes", "petits pois", "oignons"), listOf("Cuire le riz.", "Faire revenir les légumes.", "Ajouter le riz et faire sauter quelques minutes.")),
    Recipe("Gratin de pommes de terre", "Soir", 55, listOf("Végétarien", "Sans gluten"), listOf("lait"), listOf("pommes de terre", "crème", "fromage", "ail"), listOf("Préchauffer le four à 180 °C.", "Couper les pommes de terre.", "Ajouter crème, ail et fromage puis cuire 45 minutes.")),
    Recipe("Salade de lentilles", "Midi", 30, listOf("Végétarien", "Végétalien", "Sans gluten"), emptyList(), listOf("lentilles", "carottes", "oignons", "vinaigre"), listOf("Cuire les lentilles.", "Râper les carottes et couper l’oignon.", "Mélanger et assaisonner.")),
    Recipe("Soupe de légumes", "Soir", 35, listOf("Végétarien", "Végétalien", "Sans gluten"), emptyList(), listOf("carottes", "pommes de terre", "oignons", "bouillon"), listOf("Couper les légumes.", "Les cuire 25 minutes dans le bouillon.", "Mixer ou servir en morceaux."))
)

