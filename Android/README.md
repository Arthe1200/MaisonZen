# Version Android de Maison Zen

La version Android est une application native Kotlin avec Jetpack Compose. Elle se connecte au même serveur familial et utilise le même format de données chiffrées que la version iOS.

## Fonctions disponibles

- Création de compte, vérification par e-mail, connexion, réinitialisation du mot de passe et code de récupération des clés.
- Création et sélection de foyers, invitations par rôle et retrait d’un membre par l’administrateur.
- Accueil, tâches et devoirs, rappels personnels ou de foyer, calendrier et notifications locales.
- Abonnements et dépenses personnelles ; dépenses du foyer réservées aux adultes.
- Messages de foyer ou privés, chiffrés comme les autres fiches.
- Inventaire du frigo, scan du code-barres, recherche Open Food Facts par le serveur et saisie manuelle.
- Recettes gratuites filtrées par régime et allergies, ajoutables au planning.
- Mode d’affichage tableau de bord pour tablette.

Les appels audio et les widgets déplaçables du tableau de bord ne sont pas encore implémentés dans ce client Android. L’inventaire et les recettes sont synchronisés avec le foyer ; il faut donc que le serveur tourne pour les consulter sur plusieurs appareils.

## Préparer le serveur

L’application utilise le serveur hébergé sur le PC de la maison. Suis d’abord [les étapes du serveur Windows](../Server/README.md), puis laisse-le actif pendant l’utilisation.

Dans l’application, indique l’adresse IPv4 du PC avec le port `5080`, par exemple `http://192.168.1.168:5080`. L’adresse peut être différente sur ton réseau : consulte `ipconfig` sur le PC. Le téléphone et le PC doivent être sur le même Wi-Fi, et le pare-feu Windows doit autoriser le serveur sur le réseau privé.

Le build **Debug** autorise HTTP pour les tests locaux. Une version distribuée devra utiliser une adresse HTTPS.

## Télécharger et installer l’APK de test

Le workflow [MaisonZen Android build](../.github/workflows/android-build.yml) crée l’APK lorsqu’un changement Android est poussé sur GitHub. Pour lancer le workflow manuellement :

1. Ouvre le dépôt MaisonZen sur GitHub et va dans **Actions**.
2. Choisis **MaisonZen Android build**, puis **Run workflow**.
3. Ouvre l’exécution terminée avec succès et télécharge l’artefact `MaisonZen-Android-debug`.
4. Décompresse l’artefact : il contient `app-debug.apk`.
5. Installe le fichier sur le téléphone, par exemple avec Android Debug Bridge :

```powershell
adb install -r .\app-debug.apk
```

Tu peux aussi copier l’APK sur le téléphone et l’ouvrir. Android demandera éventuellement d’autoriser l’installation depuis cette source.

## Première utilisation

1. Démarre le serveur sur le PC.
2. Ouvre Maison Zen et saisis son adresse réseau.
3. Crée un compte avec une adresse e-mail et un mot de passe d’au moins 12 caractères. Confirme l’adresse avec le code reçu ; en développement local, le serveur peut afficher le code dans sa console ou sa réponse.
4. Crée un foyer. Pour inviter quelqu’un, cette personne doit d’abord avoir vérifié son compte. L’administrateur choisit ensuite son rôle et lui transmet le code d’invitation.
5. Autorise les notifications Android pour recevoir les rappels. Le scanner de codes-barres utilise le module Google Play Services ; l’ajout manuel reste disponible.

Les rappels sont programmés localement sur chaque téléphone après synchronisation. Une notification silencieuse n’émet pas de son. Les répétitions sont prises en charge pour les rappels et abonnements.

## Données et récupération

Les notes, événements, tâches et autres fiches sont chiffrés sur le téléphone avec AES-GCM. Les clés de foyer sont échangées sous enveloppe ECDH P-256 et les clés de l’appareil sont conservées avec Android Keystore. Les dépenses personnelles utilisent une clé distincte ; le serveur limite aussi leur accès au propriétaire. Les dépenses partagées utilisent une clé adulte et sont accessibles aux adultes du foyer.

Dans **Réglages → Créer / mettre à jour la sauvegarde**, Maison Zen génère un code de récupération et dépose sur le serveur une copie chiffrée des clés. Garde le code ailleurs que sur le téléphone. Lors d’une première connexion sur un autre appareil, l’application le demande avant de synchroniser les foyers.

Les clés locales protégées par Android Keystore ne sont pas sauvegardées par Android. Sans le code de récupération, un appareil neuf ne peut pas ouvrir les données déjà chiffrées.

## Compilation locale

Installe Android Studio avec Android SDK API 36 et JDK 17, puis ouvre le dossier `Android`. Pour produire un APK de débogage depuis PowerShell avec Gradle 8.13 installé :

```powershell
gradle -p Android :app:assembleDebug
```

L’APK est créé dans `Android/app/build/outputs/apk/debug/app-debug.apk`.
