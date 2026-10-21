# Hopora VPN

Appli Android : 50 serveurs VPN gratuits (50 IP différentes, dans de nombreux pays) issus du projet universitaire VPN Gate. Une publicité s'affiche avant chaque connexion, puis le serveur s'ouvre dans l'appli gratuite « OpenVPN for Android » avec un profil au chiffrement renforcé (AES-256-GCM en priorité).

## 1. Obtenir l'APK gratuitement (sans installer Flutter)

1. Sur github.com, créez un dépôt nommé `hopora-vpn` (bouton **New**).
2. **uploading an existing file** → glissez tout le contenu de ce dossier, y compris `.github`.
   Si le dossier caché `.github` ne passe pas : **Add file → Create new file**, nom `.github/workflows/build-apk.yml`, collez le contenu du fichier.
3. **Commit changes**. La construction démarre seule (environ 5 minutes).
4. Onglet **Actions** → dernière exécution → **Artifacts** → **HoporaVPN-apk** (un .zip contenant `app-release.apk`).

Sans réglage, l'APK utilise les **publicités de test** de Google (marquées « Test Ad ») : parfait pour vérifier que tout marche.

## 2. Gagner de l'argent : brancher vos vraies publicités

1. Créez un compte gratuit sur **admob.google.com** (avec votre compte Google ; un particulier peut s'inscrire).
2. **Applications → Ajouter une application** → Android → « Hopora VPN ». Notez l'**ID d'application** (`ca-app-pub-…~…`).
3. Dans l'application, **Blocs d'annonces → Interstitiel**. Notez l'**ID du bloc** (`ca-app-pub-…/…`).
4. **Confidentialité et messagerie → RGPD** : créez et publiez le message de consentement (obligatoire en Europe ; l'appli l'affiche automatiquement).
5. Sur GitHub, dans votre dépôt : **Settings → Secrets and variables → Actions → New repository secret** :
   - `ADMOB_APP_ID` = l'ID d'application
   - `ADMOB_INTERSTITIAL_ID` = l'ID du bloc interstitiel
6. **Actions → Construire l'APK Hopora → Run workflow** : le nouvel APK contient vos vraies pubs.

Ne cliquez jamais sur vos propres publicités : AdMob bloque les comptes pour ça.

## 3. Installer et utiliser

1. Ouvrez `app-release.apk` sur le téléphone ou la tablette (autorisez « Installer des applis inconnues »).
2. Installez **OpenVPN for Android** (gratuit, Play Store, éditeur Arne Schwabe).
3. Dans Hopora : choisissez un serveur → **Se connecter** → pub → validez l'import dans OpenVPN → touchez le profil.
4. Revenez dans Hopora et vérifiez « Votre IP actuelle ».

## À savoir

- Le tunnel est chiffré par OpenVPN (TLS + AES). Hopora demande AES-256-GCM en priorité ; si un vieux serveur ne le gère pas, la connexion reste chiffrée avec son algorithme d'origine (souvent AES-128-CBC).
- Les serveurs sont prêtés par des bénévoles et changent souvent : actualisez la liste si l'un ne répond plus. Le bénévole peut voir le trafic non chiffré (sites http) et VPN Gate garde des journaux : pas pour la banque ni les données sensibles.
- Les revenus AdMob sont à déclarer aux impôts.
- Publication Google Play : une appli de type VPN peut exiger un compte développeur d'organisation (entreprise).
