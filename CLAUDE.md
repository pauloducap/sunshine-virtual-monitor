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
  `fix/log-display-name`, `fix/converge-single-display`, `fix/hdr-target-vdd`,
  `fix/vdd-xml-refresh-rate`, `fix/teardown-restore-first`,
  `fix/script-args-fallback`, `fix/legacy-option-txt`,
  `fix/vdd-device-selection`, `fix/no-half-configured-displays`, plus
  `feat/crash-recovery` (empilée sur `fix/teardown-restore-first`).
  `integration` = fusion de toutes ; c'est la version à déployer (trois
  scripts : setup, teardown, restore).
- Merge auto : chaque branche `fix/*` terminée est fusionnée dans
  `integration`, puis `integration` dans `main` (merge classique, pas
  fast-forward : `main` porte en plus les commits de notes), poussée et
  déployée. Vérifier le contenu déployé, pas seulement le code de retour.
- Remotes : `origin` = fork `pauloducap`, `upstream` = `Cynary`.
- Identité git locale au dépôt : `pauloducap@users.noreply.github.com`.
- Sunshine exécute les scripts depuis `C:\Users\paul\Documents\sunshine-vdm\`
  (copie manuelle, avec `vsynctoggle` et `multimonitortool-x64`), pas depuis ce
  dépôt. Recopier `setup_sunvdm.ps1` après chaque modification.
- `gh` est installé et authentifié (`pauloducap`). PR amont ouvertes le
  25/09/2026 : #29 (log), #30 (convergence + sweep), #31 (HDR), #32 (XML
  `refresh_rate` + redémarrage pilote) ; le 30/09/2026 : #33 (teardown), #34
  (arguments), #35 (`option.txt`), #36 (sélection du VDD), #37 (pas d'écrans
  à moitié configurés).
  Paul n'a que le droit `pull` sur l'amont : seul Cynary peut fusionner.
  La PR #28
  « Integration » (tout en bloc, ouverte par erreur via le bouton GitHub du
  fork) a été fermée. Attention : « Compare & pull request » sur le fork cible
  Cynary par défaut.
- `main` du fork = `integration` (fast-forward) + `CLAUDE.md`. Ne jamais
  ouvrir de PR amont depuis `main` ou `integration` : elles embarquent ces notes.

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

### 5. Patch XML : `<refresh>` au lieu de `<refresh_rate>`, redémarrage sans attente

Le schéma du VDD de MTT utilise `<refresh_rate>` par résolution et des
`<g_refresh_rate>` globaux (60/90/120/144/165/244) valables pour toutes les
résolutions. Le script testait `$_.refresh` : aucun mode ne matchait jamais,
chaque nouveau client ajoutait un nœud parasite `<refresh>` (trois accumulés
dans le XML local : 2732x2048@120, 1920x1080@144…) et redémarrait le pilote.

Nouveau bloc (branche `fix/vdd-xml-refresh-rate`, PR #32) : mode reconnu si
largeur/hauteur existent et que le taux est soit le `refresh_rate` propre, soit
un taux global ; écriture en `<refresh_rate>` ; chemin du XML lu dans le
registre `SettingsPath` avec `Test-Path` ; si un patch est nécessaire et que le
pilote tourne, `Disable-PnpDevice` puis attente réelle de l'arrêt ; patch
déplacé **avant** la capture d'état. Validé en session réelle le 28/09/2026
(iPhone 2202x1179@120 HDR on) : aucun patch, XML intact, HDR activé sur le VDD,
`sweep clean`, teardown OK.

### 6. Teardown : restaurer avant de couper le VDD

Branche `fix/teardown-restore-first`, PR #33. Ordre : vsync si `state.json`
existe → `Disable-PnpDevice` du VDD → restauration (5 essais) → en dernier
recours `MultiMonitorTool /enable` sur tout écran inactif, sans `Throw`.

**Erreur corrigée le 01/10/2026** : la première version restaurait les écrans
*avant* de couper le VDD. Résultat en vraie session : écrans physiques mis en
mode **Dupliquer** sur une seule sortie, et Windows a mémorisé cette disposition
pour la combinaison {HKC, EVE, VDD} → chaque session suivante démarrait
dupliquée. Cause : WindowsDisplayManager associe sorties et moniteurs par `id`
**sans l'`adapterId`** ; le VDD est sur sa propre « carte » dont les ids
(source 0…) recoupent ceux de la RTX, et le module enregistre avec
`SaveToDatabase`. Ne **jamais** appeler `UpdateDisplaysFromFile` / `Enable()`
du module tant que le VDD est actif. Gardes sur `state.json`, `display_state.json` et VDD introuvable.
Testé à blanc seulement (état courant rejoué sur lui-même) ; **pas encore en fin
de session réelle**. L'ancien teardown est gardé dans
`sunshine-vdm\teardown_sunvdm.ps1.bak`.

Les nœuds parasites `<refresh>` du XML local sont inoffensifs (ignorés par le
pilote) ; à nettoyer à la main dans VDD Control si on veut un XML propre.

### 7. Récupération après crash (`restore_sunvdm.ps1`)

Branche `feat/crash-recovery`, **empilée sur** `fix/teardown-restore-first`.
Pas de PR amont pour l'instant : l'ouvrir une fois #33 fusionnée (sinon la PR
afficherait aussi les commits de #33), après rebase sur `upstream/main`.

- `setup` écrit `session.lock` après la capture d'état ; `teardown` le supprime.
- Si `session.lock` existe déjà au setup, la session précédente n'a jamais été
  démontée : on **garde** le `display_state.json` existant au lieu de capturer
  la disposition de streaming (VDD seul) comme état à restaurer.
- `restore_sunvdm.ps1` : lance le teardown si le marqueur date d'avant le
  dernier démarrage (max de `LastBootUpTime` et de l'événement Kernel-Boot 27,
  pour couvrir le démarrage rapide). `-Force` restaure sans condition.
  `-Install` / `-Uninstall` gèrent la tâche planifiée `sunvdm-restore`
  (à l'ouverture de session, privilèges élevés) — à lancer dans un PowerShell
  administrateur. Sortie dans `sunvdm_restore.log`.
- Conflit à la fusion dans `integration` (bloc de capture déplacé par #32),
  résolu à la main : même conflit à prévoir lors du rebase amont.

Décision du 30/09/2026 : **pas de tâche planifiée** sur la machine de Paul
(« on reste classique »). `-Install` reste dans le script pour l'amont, mais
ici le restore ne s'utilise qu'à la main, avec `-Force`, en cas de besoin.

Testé à blanc (pas de marqueur / marqueur récent / marqueur ancien, affichage
inchangé). Le marqueur côté setup et le cas réel « reboot en pleine session »
ne sont **pas** testés.

### 8. Derniers bugs connus (30/09/2026)

- **Arguments positionnels** (`fix/script-args-fallback`, #34) : `$args` dans
  une fonction = arguments de la fonction. Arguments du script gardés dans
  `$scriptArgs`. Reproduit avec l'ancien code, corrigé, variables d'env.
  toujours prioritaires.
- **`option.txt`** (`fix/legacy-option-txt`, #35) : écrit seulement si
  `C:\IddSampleDriver` existe, jamais créé. Chez Paul le dossier existe (créé
  par l'ancien script, contient seulement les modes) : tant qu'il est là, le
  script continue d'y écrire, sans effet. Supprimable à la main.
- **Sélection du VDD** (`fix/vdd-device-selection`, #36) : même bloc dans
  setup et teardown ; priorité aux périphériques présents, puis à VDD by MTT
  (`Root\MttVDD`) ; avertissement si plusieurs candidats. Testé sur la machine
  et avec `Get-PnpDevice` simulé (4 cas).
- **`Throw`** (`fix/no-half-configured-displays`, #37) : Sunshine ne lance pas
  l'`undo` d'un `do` qui échoue. VDD absent → nouvelles tentatives, puis
  `Undo-Setup` (lance le teardown puis échoue) ; topologie non convergée →
  avertissement et on streame quand même ; `SetResolution` → avertissement.
  Les `Throw` d'avant toute modification (paramètres, VDD introuvable,
  sauvegarde d'état) sont gardés. Testé avec la vraie boucle et des doublures
  du module d'affichage (5 scénarios), pas en session réelle.

### 9. Écrans physiques en mode Dupliquer (01/10/2026)

Branche `fix/duplicated-displays` (pas de PR amont pour l'instant). En mode
Dupliquer, deux moniteurs partagent une sortie et `MultiMonitorTool /disable`
ne peut pas la couper (41 essais ratés, bureau capturé 4480x1440).
`Set-VirtualDisplayOnly` : `QueryDisplayConfig` des chemins actifs, nom GDI de
chaque source résolu **avec son adapterId**, flag actif retiré sur tout ce qui
n'est pas la sortie du VDD, puis `SetDisplayConfig` (validation puis
`Apply|UseSupplied|AllowChanges|SaveToDatabase`) — l'équivalent de
« Déconnecter cet affichage ». Le `SaveToDatabase` répare aussi la disposition
mémorisée. Utilisé dans la boucle de convergence et le balayage final,
MultiMonitorTool en repli.

Diagnostic vérifié sur l'état réel : `\\.\DISPLAY2` → HKC **et** EVE, VDD sur un
autre adaptateur. Validation Windows OK sans application ; **l'application
réelle n'a pas encore tourné en session**. Attention : `PointL` du module est
déclaré en `long` (64 bits) au lieu de 32 — ne pas lire/écrire
`sourceMode.position` via ces structures.

Plus aucun autre bug connu non corrigé.

## Améliorations envisagées

- `config.json` à côté des scripts : motifs de nom du VDD, chemin du XML,
  tolérance RDP, nombre de tentatives, niveau de log
- Log horodaté, avec niveaux
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
