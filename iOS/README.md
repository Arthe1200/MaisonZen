# Application iOS MaisonZen

Application native SwiftUI pour iPhone et iPad, avec iOS 17 comme version minimale du projet Xcode. Le projet Xcode est `MaisonZen.xcodeproj`; le package WebRTC iOS est téléchargé par Swift Package Manager.

## Ouvrir et signer sur Mac

1. Copie le dossier du projet sur un Mac avec Xcode installé.
2. Ouvre `MaisonZen.xcodeproj` dans Xcode et laisse Swift Package Manager résoudre WebRTC.
3. Dans la cible **MaisonZen**, onglet **Signing & Capabilities**, sélectionne ton équipe personnelle Apple. Xcode peut demander un identifiant de bundle unique; remplace `fr.maisonzen.app` si nécessaire.
4. Connecte l’iPhone ou l’iPad, sélectionne-le comme destination, puis lance l’app avec **Run**. Le premier lancement peut demander d’activer le mode développeur sur l’appareil.
5. Dans MaisonZen, entre l’adresse IP du PC familial sur le Wi-Fi local pour le serveur de développement. Crée un compte et vérifie le code renvoyé par le serveur de développement.

Le projet ne peut pas être compilé, signé, simulé ni installé depuis Windows. Le poste de création n’a pas Xcode, le SDK iOS, un simulateur Apple ou un appareil connecté; la résolution du package et la compilation Apple restent à faire sur Mac.

## Compilation depuis Windows avec GitHub Actions

Le workflow `.github/workflows/ios-build.yml` utilise une machine virtuelle macOS GitHub. Il compile le projet sans certificat Apple, fabrique `MaisonZen-unsigned.ipa` et le publie dans les artefacts de l’exécution. Sur GitHub, ouvre **Actions → MaisonZen iOS build → Run workflow**, puis télécharge l’artefact `MaisonZen-iOS-unsigned`.

Sur Windows, décompresse l’artefact, ouvre Sideloadly, glisse `MaisonZen-unsigned.ipa`, connecte l’iPhone et lance l’installation avec ton identifiant Apple. Sideloadly signe alors l’application pour ton appareil. Avec un compte Apple gratuit, l’installation doit être renouvelée périodiquement.

Le dépôt doit être public pour utiliser les runners standard GitHub gratuitement sans quota privé. Ne place jamais de mot de passe, certificat, clé privée, secret serveur ou code de récupération dans le dépôt.

## Capacités présentes dans le code

- Compte e-mail, inscription, vérification, connexion et récupération de mot de passe.
- Foyers, invitations, rôles administrateur/adulte/enfant/locataire et contrôles d’accès.
- Abonnements et dépenses privées ou réservées aux adultes.
- Rappels et répétition, tâches/devoirs, planning, silence des notifications.
- Frigo, scan de codes-barres, saisie manuelle, recettes gratuites et filtres d’allergies/régimes.
- Chat, appel audio WebRTC et interface de dashboard pour iPad.
- Chiffrement côté appareil, trousseau Apple et sauvegarde de récupération protégée par code.

Cette liste décrit les écrans et flux écrits; la compilation Xcode et les essais fonctionnels sur matériel Apple ne sont pas encore validés.

## Installation personnelle pour test

Le compte gratuit Apple avec Personal Team permet le lancement personnel sur un maximum de trois appareils, avec des profils qui expirent après sept jours. Pour un test familial de deux à trois mois avec ce compte, il faut re-signer et réinstaller régulièrement. TestFlight et la distribution à davantage d’appareils demandent l’adhésion Apple Developer payante ([compte Apple Developer](https://developer.apple.com/help/account/basics/about-your-developer-account), [guide de démarrage](https://developer.apple.com/get-started/)).

## Limites à tester / compléter

- Les notifications sont planifiées localement après synchronisation; aucun push APNs n’est configuré.
- Les appels entrants n’avertissent pas l’utilisateur quand l’application est arrêtée ou suspendue sans relais de notification.
- Les appels à distance nécessitent une configuration TURN. Les appels locaux doivent d’abord être validés sur deux appareils réels.
- Les recettes sont une petite sélection intégrée au code; les filtres sont indicatifs et ne remplacent pas la vérification des ingrédients et étiquettes.
- Les dépenses personnelles ont une clé dérivée de la clé privée du compte; les fiches adultes utilisent une clé séparée distribuée aux adultes et administrateurs. Les données ordinaires du foyer utilisent la clé commune.
- La rotation des clés après retrait d’un membre n’est pas encore implémentée. Le retrait coupe sa session et ses accès serveur, mais ne peut pas effacer les contenus déjà téléchargés sur son appareil.
