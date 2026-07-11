# Découpe des enregistrements BigBlueButton

Outils pour transformer un enregistrement BigBlueButton (BBB) — une longue
session unique — en **clips par présentation** prêts à monter dans DaVinci
Resolve.

Pour chaque présentation, on obtient trois pistes **alignées sur la même
fenêtre de temps** :

- `webcam.mp4` — caméra + audio
- `deskshare.mp4` — partage d'écran (s'il y en a eu)
- `slides.mp4` — les diapos, chacune affichée au moment où elle l'était en direct

Déposées au même point sur la timeline Resolve, les trois pistes se
superposent automatiquement : à vous de choisir la mise en page finale.

## Prérequis

```bash
brew install ffmpeg resvg jq
```

(`ffmpeg`/`ffprobe`, `resvg`, `jq`, plus `curl` déjà présent sur macOS.
`resvg` rend les diapos SVG plus fidèlement que `rsvg-convert`, qui ignore les
fonds à très grandes coordonnées des SVG BBB issus de PDF.)

## Flux de travail en 2 phases

### PHASE 1 — Tout télécharger

```bash
# Le plus simple : juste l'ID d'enregistrement (la partie …-<timestamp>)
./bbb_download.sh 0fd9362b0262e546caf2c07d030316c51f906692-1783457208252
#   -> dossier nommé automatiquement d'après la date (ex: 2026-07-07)

# Ou l'URL complète, et/ou un dossier explicite
./bbb_download.sh "https://bbb3.services-conseils-linux.org/playback/presentation/2.3/<id>" 2026-07-07
```

- On peut donner **soit l'URL de lecture complète, soit juste l'ID**
  d'enregistrement. Avec un ID seul, l'hôte par défaut est
  `https://bbb3.services-conseils-linux.org` (modifiable via `BBB_HOST=...`).
- **Sans dossier**, il est nommé d'après la date tirée du timestamp de l'ID.
- L'URL de lecture est sauvegardée dans `<dossier>/README.md`.

> Il n'existe pas de « dernier enregistrement » automatique : le serveur exige
> le secret partagé de l'API BBB pour lister les enregistrements. On fournit
> donc l'ID/URL à la main (récupéré par courriel ou copié depuis la page).

Cela télécharge dans `<dossier>` :

- `webcams.mp4`, `deskshare.mp4` (vidéos de session)
- `shapes.svg`, `deskshare.xml`, `presentation_text.json` (données de timing)
- `NN/slideN.svg` (les diapos, un **dossier numéroté** — `01`, `02`… — par
  présentation, dans l'ordre de la session)

puis génère **`presentations_cut.txt`**.

### Éditer les points de coupe

Ouvrez `<dossier>/presentations_cut.txt` et ajustez les colonnes `DEBUT` et
`FIN` (format `H:MM:SS` ou secondes). Une présentation par ligne. Les valeurs
de départ sont détectées automatiquement à partir de `shapes.svg`.

```
# NUM | DEBUT    | FIN      | INFO
1     | 0:00:00  | 0:07:36  | 28 diapos — Bienvenue aux...
2     | 0:07:36  | 0:25:16  | 3 diapos — L'objection-sociocratique...
```

Le `NUM` nomme les sorties : clips `output/NUM/` et sélection en phase 2
(`... encode 01 03`). Les diapos, elles, restent dans les dossiers d'origine
`01/`…`05/` (une par présentation détectée).

#### Scinder une présentation en plusieurs clips

Si une « présentation » détectée contient en fait plusieurs exposés à séparer,
ajoutez simplement une ligne avec un **NUM unique** et une **sous-plage**
`DEBUT`/`FIN`. La webcam et le deskshare sont coupés par le temps, et les diapos
sont automatiquement tirées de la présentation d'origine que recouvre la plage.

```
# NUM | DEBUT    | FIN      | INFO
05a   | 1:38:26  | 2:05:00  | Exposé A
05b   | 2:05:00  | 2:38:03  | Exposé B
```

→ produit `output/05a/` et `output/05b/`, chacun avec les diapos de
la portion correspondante. (Gardez chaque coupe à l'intérieur d'une seule
présentation d'origine pour que les diapos soient correctes.)

### PHASE 2 — Générer les clips

```bash
./bbb_make_clips.sh <dossier> [encode|copy] [NUM...]
# ex :
./bbb_make_clips.sh 2026-07-07 encode 3        # seulement la présentation 3
./bbb_make_clips.sh 2026-07-07 encode 1 3 5    # quelques-unes
./bbb_make_clips.sh 2026-07-07 encode          # toutes
```

- **`encode`** (défaut) : bornes exactes et pistes parfaitement alignées
  (réencodage matériel h264_videotoolbox). Meilleure qualité pour le montage.
- **`copy`** : instantané et sans perte, mais les coupes s'alignent sur
  l'image-clé la plus proche (±1–2 s) — les pistes peuvent être légèrement
  décalées entre elles.
- Les `NUM` correspondent à la colonne `NUM` de `presentations_cut.txt`.
  Sans liste, toutes les présentations sont traitées.

Résultat dans `<dossier>/output/` :

```
output/
├── 01/
│   ├── webcam.mp4
│   ├── deskshare.mp4      (si partage d'écran)
│   └── slides.mp4
├── 02/
│   └── ...
└── manifest.txt           (numéro → horaires → pistes → info)
```

Relancer une présentation ne met à jour que son dossier et sa ligne dans
`manifest.txt` ; les autres ne sont pas touchées.

## Scripts

| Script | Rôle |
|--------|------|
| `bbb_download.sh` | **Phase 1** : télécharge tout + génère `presentations_cut.txt`. |
| `bbb_make_clips.sh` | **Phase 2** : génère les clips alignés par présentation (webcam / deskshare / slides). |

## Données locales

Le dépôt ne versionne que les scripts et cette doc. Tout le contenu produit par
les scripts reste **local** (voir `.gitignore`) :

- les dossiers d'enregistrement datés (`2026-07-07/`…) avec `webcams.mp4`,
  `deskshare.mp4`, les diapos, les métadonnées et `presentations_cut.txt` ;
- les clips générés dans `output/`.

Chaque enregistrement se retélécharge avec `bbb_download.sh` et se régénère avec
`bbb_make_clips.sh` : rien de tout cela n'a besoin d'être commité.

## Notes techniques

- **`deskshare.mp4` couvre toute la session** (même durée que `webcams.mp4`) et
  est **noir hors partage d'écran** — il est sur la même timeline que la
  webcam. C'est pourquoi la coupe se fait aux mêmes horodatages, sans remappage.
- La dernière diapo peut avoir un `out` aberrant (la réunion est restée ouverte
  après la fin de l'enregistrement) ; les fenêtres sont donc bornées à la durée
  réelle de la vidéo.
- Le clip diapos est rendu à partir des SVG avec **`resvg`** (rasterisés en
  1920×1080) séquencés sur les temps `in`/`out` de `shapes.svg` ; pendant un
  partage d'écran, la dernière diapo est maintenue. `resvg` est utilisé plutôt
  que `rsvg-convert` car ce dernier ignore les fonds/tracés à très grandes
  coordonnées des SVG BBB issus de PDF (fond de diapo manquant).
