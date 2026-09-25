# sunshine-virtual-monitor — notes de travail

Fork de `Cynary/sunshine-virtual-monitor`. Scripts PowerShell branchés sur les
hooks `global_prep_cmd` de Sunshine : ils créent un écran virtuel à la
résolution exacte du client Moonlight, éteignent les écrans physiques pendant
la session, et restaurent tout à la déconnexion.

Ces notes sont en français ; les messages de commit et les PR vers l'amont
doivent être en anglais.

## Environnement de test

- Windows 11 (24H2)
- RTX 4080, pilote NVIDIA
- Deux écrans physiques : HKC 27E3QK (2560x1440@240, HDR off) et
  EVE ES07E2D (2560x1440@240, HDR on)
- VDD by MTT (`Root\MttVDD`), settings dans `C:\VirtualDisplayDriver\vdd_settings.xml`
- Sunshine 2026.914.233613
- Clients : iPad Pro (2732x2048@120), iPhone (2202x1179@120), Apple TV, PC portable

Le pilote VDD est **désactivé au repos** (Gestionnaire de périphériques) et
activé par le script au démarrage de la session.

## Configuration Sunshine associée

- `dd_configuration_option = disabled` — **obligatoire**. Sunshine applique sa
  config d'affichage *avant* le `do_cmd`, donc avant que le VDD existe :
  `ensure_only_display` échoue systématiquement avec `DevicePrepFailed`.
- `output_name` = device_id du VDD (facultatif si le script le rend principal,
  mais le GUID change à chaque réinstallation du pilote — fragile).
- `dd_config_revert_on_disconnect = enabled`
- Côté Moonlight : « Optimize game settings » coché, sinon le client n'envoie
  pas sa résolution.

## Branches et déploiement

- Branches locales, une par PR, chacune partant de `upstream/main` :
  `fix/log-display-name`, `fix/converge-single-display`, `fix/hdr-target-vdd`.
  `integration` = fusion des trois (sans conflit) ; c'est la version à déployer.
- Remotes : `origin` = fork `pauloducap`, `upstream` = `Cynary`.
- Identité git locale au dépôt : `pauloducap@users.noreply.github.com`.
- Sunshine exécute les scripts depuis `C:\Users\paul\Documents\sunshine-vdm\`
  (copie manuelle, avec `vsynctoggle` et `multimonitortool-x64`), pas depuis ce
  dépôt. Recopier `setup_sunvdm.ps1` après chaque modification.
- `gh` n'est pas installé : ouvrir les PR depuis le navigateur.

## Corrections déjà appliquées (committées sur les branches `fix/*`)

### 1. Boucle de convergence sortait trop tôt

`setup_sunvdm.ps1`, boucle de convergence :

```diff
-if ($virtual.active -and $active.Count -le 2) { break }
+if ($virtual.active -and $active.Count -le 1) { break }
```

Avec `-le 2`, la boucle sort dès qu'il reste le VDD **plus un** écran physique.
Symptôme : un écran reste allumé, log `sunshine display diable complete` sans
erreur. Le `-le 2` semble intentionnel (message `rdp intact`) pour préserver une
session RDP — à rendre configurable plutôt qu'à coder en dur.

Répond à l'issue #16 (« Fail to disable displays on Win11 24H2 »).

### 2. HDR appliqué au mauvais écran

`$displays[0]` désigne une entrée arbitraire — chez nous un écran physique, qui
se **rallumait** au moment du `EnableHdr()`. C'était la cause réelle du
« un écran revient après la boucle ».

Piège : l'entrée dont `source.description -eq $vdd_name` a un `hdrInfo` **nul**.
Il faut rafraîchir chaque entrée avec `GetRefreshedDisplay` et retenir celle
dont la `Description` rafraîchie mentionne le VDD (`VDD by MTT via <adaptateur>`).

Vérifié à la main :

```powershell
$d = WindowsDisplayManager\GetAllPotentialDisplays
$r = WindowsDisplayManager\GetRefreshedDisplay($d[0])
$r.HdrInfo   # HdrSupported=True HdrEnabled=True BitDepth=10
$r.DisableHdr()   # renvoie True, HdrEnabled passe à False
```

### 3. Balayage final

Windows réactive un écran après `SetResolution`. Boucle de 10 passes à 400 ms
qui redésactive tout ce qui n'est pas le VDD. Attention au faux positif :
si le VDD n'est pas trouvé, ne pas afficher « sweep clean ».

### 4. Log inutilisable

`Write-Host "disabling $d"` affiche le type de l'objet, pas le nom de l'écran.
Remplacer par `$($d.source.name)`. Trivial, mais c'est ce qui a permis de
diagnostiquer tout le reste.

## Bugs restants, non corrigés

### `Get-Int` / `Get-Bool` : fallback par arguments mort

Dans une fonction PowerShell, `$args` désigne les arguments **de la fonction**,
pas ceux du script. `$args[$argIndex]` est donc toujours vide. Seule la voie par
variables d'environnement fonctionne. Quiconque suit l'ancienne documentation —
celle qui passe `%SUNSHINE_CLIENT_WIDTH%` en paramètre, comme le fork VR le fait
encore — obtient `missing SUNSHINE_CLIENT_WIDTH`.

Correctif : capturer `$script:args` au niveau du script, ou déclarer un bloc
`param()`.

### Chemins codés en dur

`C:\VirtualDisplayDriver\vdd_settings.xml` est en dur alors que le VDD 25.x
publie son emplacement dans le registre (`SettingsPath`). Et le `Get-Content`
du XML n'a aucun `Test-Path` : fichier ailleurs, le script explose avant même
d'avoir commencé.

### `option.txt` est un vestige

Les écritures dans `C:\IddSampleDriver\option.txt` visent l'ancien
IddSampleDriver, pas le VDD de MTT. Crée un dossier inutile sur les machines
modernes. À conditionner.

### Le patch XML écrit `<refresh>` au lieu de `<refresh_rate>`

Le schéma du VDD de MTT utilise `<refresh_rate>` ; le script teste `$_.refresh`
et crée un nœud `<refresh>`. Conséquences : les résolutions ajoutées via VDD
Control ne sont **jamais** reconnues (le script patche quand même et redémarre
le pilote), et le nœud ajouté est ignoré par le pilote. Ça marche malgré tout
parce que les `g_refresh_rate` globaux (60/90/120/144/165/244) s'appliquent à
toutes les résolutions. Le XML local contient déjà un nœud parasite
`2732x2048 <refresh>120</refresh>` ; l'iPhone (2202x1179@120) déclenchera le
patch + redémarrage à sa première connexion.

Correctif : comparer largeur/hauteur seulement (ou `refresh_rate` + globaux),
écrire `<refresh_rate>`.

### Le patch XML redémarre le pilote en plein setup

Quand la résolution demandée n'est pas dans le XML, le script patche et
`Disable-PnpDevice` sans attente derrière. Observé : `exited with code [1]` et
session ratée. Faire le patch **avant** toute capture d'état, avec attente de
stabilisation.

### `Throw` partout

Le moindre accroc HDR avorte le script — et Sunshine annule alors le lancement
de l'application, laissant les écrans à moitié configurés sans teardown.
Dégrader proprement avec des avertissements.

### Ordre dangereux dans le teardown

`teardown_sunvdm.ps1` désactive le VDD **avant** de restaurer les écrans. Si
`UpdateDisplaysFromFile` échoue ses 5 tentatives, il lève une exception et il ne
reste plus aucun écran actif. Restaurer d'abord, désactiver le VDD ensuite.
Manque aussi un garde sur l'absence de `state.json` / `display_state.json`.

### Aucune récupération après crash

PC redémarré en pleine session : les écrans physiques restent désactivés, rien
ne les rallume. Bloquant sur une machine sans écran. Prévoir un
`restore_sunvdm.ps1` autonome.

### `$vdd_name` prend `[0]` aveuglément

Si plusieurs périphériques d'affichage correspondent aux motifs (reliquat
d'IddSampleDriver + VDD de MTT), le choix est arbitraire.

## Améliorations envisagées

- `config.json` à côté des scripts : motifs de nom du VDD, chemin du XML,
  tolérance RDP, nombre de tentatives, niveau de log
- Log horodaté, avec niveaux
- `restore_sunvdm.ps1` de secours
- PSScriptAnalyzer en CI

## Comment tester

Lancer un stream depuis un client, puis lire `sunvdm.log` :

- `sweep clean: virtual display is alone` → les écrans physiques sont bien éteints
- `hdr check: supported=... enabled=... target=...` puis `hdr final: enabled=...`
  → la bascule HDR a suivi le client
- `WARNING:` en préfixe → quelque chose n'a pas convergé

Dans le log de Sunshine, vérifier :

- `Capture size` = résolution du client (et pas celle d'un écran physique)
- `Offset : 0x0`
- `Virtual Desktop` = exactement la résolution du VDD, sans addition

État de référence pendant une session, via MultiMonitorTool :

```powershell
& ".\multimonitortool-x64\MultiMonitorTool.exe" /stext monitors.txt
```

Seul `MTT1337` doit être `Active : Yes`.

## Cas non couvert

Changer de mode HDR/SDR exige de quitter la session et d'en relancer une : le
`do_cmd` ne s'exécute qu'au démarrage. Piste : deux entrées d'application dans
Sunshine (« Desktop HDR » / « Desktop SDR »).

Nouveau client : si sa résolution n'est pas déjà dans le XML du VDD, le script
patche et redémarre le pilote en pleine session (voir bug plus haut). Ajouter
les résolutions à l'avance dans VDD Control.

## Stratégie amont

Le dépôt d'origine accepte les contributions extérieures (PR #3, #7, #10, #12
fusionnées). Viser des PR petites et séparées plutôt qu'un gros bloc :

1. Le log (`$($d.source.name)`) — trivial, crée le contact
2. Convergence `-le 1` + balayage final — répond à l'issue #16
3. HDR sur le bon écran
4. Le reste
