# MaisonZen — cahier des charges et état du projet

## Vision

MaisonZen est une application familiale gratuite, calme et simple à utiliser pour organiser la maison, les dépenses et les rappels. L’interface utilise des couleurs douces, des boutons faciles à toucher et une navigation adaptée à l’iPhone et à l’iPad.

Le projet comprend une application iOS pour la phase de test avec la famille, une application Android séparée prévue dans `Android/`, et un serveur familial auto-hébergé. La version iOS est native SwiftUI. Le serveur est prévu pour un PC Windows à la maison.

## Périmètre complet du test familial

Toutes les fonctions ci-dessous font partie de la version de test visée, même si elles étaient auparavant classées comme évolutions futures.

### Compte et foyer

- Compte obligatoire, sans mode invité : adresse e-mail, mot de passe et vérification par code reçu par e-mail.
- Mot de passe oublié avec code envoyé par e-mail.
- Création de plusieurs foyers et invitation des membres qui ont déjà créé et vérifié un compte.
- Rôles : administrateur, adulte/parent, enfant et locataire.
- Le créateur du foyer est administrateur. Lui seul peut inviter et retirer un membre.
- Les personnes du foyer peuvent créer les tâches et les événements partagés.
- Connexions Apple et Google réservées à une évolution future.

### Abonnements et dépenses

- Un abonnement comprend son nom, son prix, sa date de prochain paiement, sa fréquence, sa catégorie, ses personnes concernées et son caractère privé ou familial.
- Rappels de paiement calculés à partir de la prochaine échéance et de la fréquence.
- Les dépenses personnelles sont visibles et modifiables par leur auteur.
- Les dépenses du foyer sont visibles seulement par les adultes et l’administrateur; seuls ces rôles peuvent les modifier ou les supprimer.
- Les enfants et les locataires ne voient pas les budgets adultes. Ils gardent accès à leurs propres dépenses.

### Rappels, tâches et planning

- Rappels personnels, adressés à un autre membre ou envoyés à tout le foyer.
- Date, heure, répétition et mode silencieux configurables.
- Les rappels peuvent aussi être mis en silence globalement sur un appareil.
- Tâches et devoirs avec échéance, répétition, attribution et état terminé.
- Planning familial partagé où les membres peuvent ajouter des événements.
- Les notifications de cette version sont locales sur les appareils après synchronisation. Les notifications Apple à distance ne sont pas intégrées.

### Frigo et recettes

- Ajout manuel de tout produit, avec quantité, lieu de rangement et date de péremption.
- Scan de codes-barres; le serveur interroge Open Food Facts pour retrouver le nom, la marque et la quantité. Si le code ne donne aucun résultat, la saisie manuelle reste disponible.
- Rappels locaux avant péremption.
- Recettes gratuites intégrées à l’application, avec temps, ingrédients, étapes, repas et portions.
- Filtres par repas, régime et allergies configurés sur l’appareil; comparaison indicative avec les ingrédients présents dans le frigo.
- Une recette peut être ajoutée au planning.
- La commande d’ingrédients n’est pas incluse.

### Messages, appels et tablette

- Chat du foyer et conversations dirigées vers une ou plusieurs personnes.
- Appels audio entre membres, depuis un iPhone ou un iPad, y compris lorsque l’iPad est en mode dashboard.
- Mode muet et commandes pour accepter, refuser et terminer un appel.
- Dashboard facultatif, activé dans les réglages de chaque iPad; il ne s’impose pas aux autres appareils.
- Widgets de résumé, dépenses, rappels, tâches, abonnements et repas. Leur ordre, leur largeur et le type de graphique sont mémorisés sur l’appareil.
- Accès depuis le dashboard aux dépenses, au planning, au frigo, aux recettes, aux messages, aux appels et aux membres.

## Règles de confidentialité et de sécurité

- Les fiches du foyer sont chiffrées sur l’appareil en AES-GCM avant envoi. Le serveur stocke et synchronise le texte chiffré et les métadonnées d’accès nécessaires.
- Les données personnelles utilisent une clé dérivée de la clé privée du compte. Les fiches réservées aux adultes utilisent une clé adulte distincte, transmise uniquement aux rôles adulte et administrateur. Les données générales du foyer utilisent la clé commune.
- Les clés sont échangées sous forme d’enveloppes chiffrées avec ECDH P-256 et conservées dans le trousseau Apple. Une sauvegarde de récupération chiffrée, contenant les clés nécessaires, est protégée par un code détenu par l’utilisateur.
- Les mots de passe sont stockés sous forme de dérivés PBKDF2 avec sel. Les e-mails et noms de profil sont chiffrés au repos sur le serveur; le serveur doit pouvoir vérifier l’adresse et afficher le nom du membre.
- Les rôles et listes de membres sont nécessaires à l’application des droits. Le chiffrement des contenus ne masque pas ces métadonnées au serveur.
- L’accès adulte/enfant/locataire aux dépenses est contrôlé par le serveur et par les clés de chiffrement distinctes. Le serveur refuse aussi les modifications qui changeraient l’audience ou le propriétaire d’une fiche existante.
- Retirer un membre ferme ses connexions temps réel et lui interdit les prochaines requêtes. Cela ne peut pas effacer les données qu’il a déjà téléchargées sur son appareil; la rotation des clés de foyer après retrait reste à concevoir.
- Le serveur de production refuse HTTP et exige HTTPS. Pour les essais à la maison, HTTP est toléré uniquement en configuration Development sur un réseau de confiance.
- Aucun contenu de foyer n’est envoyé à un service analytique. La recherche de produit envoie uniquement le code-barres à Open Food Facts par l’intermédiaire du serveur familial.
- La base SQLite et ses sauvegardes contiennent des fiches déjà chiffrées côté appareil, mais également les métadonnées de compte, de membres et de droits. Les secrets de serveur doivent être sauvegardés séparément de la base.

## Architecture du dépôt

```text
Android/                  Projet Android (à réaliser après validation de l’API)
iOS/MaisonZen/            Application native SwiftUI iPhone et iPad
Server/                   API .NET, SQLite, comptes, droits, synchronisation
assets/                   Logo vectoriel et outil de génération d’icône
PLAN-MAISONZEN.md         Ce cahier des charges et l’état vérifiable
```

L’API est le point de synchronisation entre les appareils. Elle utilise SQLite, des sessions signées, des codes par e-mail, des invitations à durée limitée, le contrôle des révisions et des tombstones pour les suppressions. La connexion temps réel relaie les mises à jour et les messages de signalisation d’appel.

## Test de la famille

- Durée prévue : deux à trois mois.
- Parcours et fiche de retour : `TEST-FAMILLE.md`.
- La famille utilise ses appareils Apple; l’application iOS doit être signée et installée depuis un Mac équipé de Xcode.
- Les retours sont consignés dans un document transmis au projet.
- Le test doit vérifier séparément les comptes, invitations, rôles, droits financiers, rappels, répétitions, synchronisation, frigo, recettes, conversations, appels et mode tablette.
- Apple permet les essais personnels avec un compte gratuit et un Personal Team, mais les profils de provisionnement expirent après sept jours et l’installation personnelle est limitée à trois appareils. Pour une famille plus nombreuse ou TestFlight, le programme Apple Developer payant est requis. Prévoir une nouvelle signature et installation chaque semaine avec le compte gratuit ([compte Apple Developer](https://developer.apple.com/help/account/basics/about-your-developer-account), [guide de démarrage Apple](https://developer.apple.com/get-started/)).
- Xcode doit être installé sur un Mac compatible; les exigences dépendent de sa version ([configuration système Xcode](https://developer.apple.com/xcode/system-requirements)).

## État technique au 25 octobre 2026

- Le serveur compile sous .NET 10 et son scénario d’intégration HTTP passe sur les flux de compte, récupération chiffrée, rôles, visibilité, suppression, révisions et configuration d’appel.
- Le projet Xcode et les écrans iOS sont présents dans `iOS/`.
- Ce poste est sous Windows et n’a ni Xcode ni les SDK Apple; la compilation SwiftUI, la résolution réelle de WebRTC, la signature, l’installation et les essais sur appareils Apple n’ont donc pas pu être effectués ici.
- La configuration production du serveur (certificat HTTPS, e-mail SMTP, secrets persistants et relais TURN pour les appels hors réseau local) doit être installée sur le PC familial avant un test internet.
- Les notifications distantes en arrière-plan, l’appel entrant lorsque l’application est fermée, OAuth Apple/Google, l’application Android et l’audit de sécurité indépendant ne sont pas livrés dans cette base.

## Décisions produit

- Nom : **MaisonZen**.
- Modèle économique : gratuit, sans abonnement ni option payante.
- Style : inspiré de la simplicité des interfaces Apple, sans reprendre leur logo ni leur identité graphique.
- Appareils : iPhone et iPad Apple pour le test; Android dans un projet séparé.
- Logo : `assets/maisonzen-logo.svg`; icône iOS dérivée du logo dans l’asset catalog.
- Les données du foyer sont hébergées par la famille sur son propre ordinateur.
