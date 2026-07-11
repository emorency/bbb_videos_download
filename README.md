# Découpe des enregistrements BigBlueButton

Outils pour transformer un enregistrement BigBlueButton (BBB) — une longue
session unique — en **clips par présentation**, puis, si on le souhaite, en
**vidéo finale composée** (fond + diapos/deskshare + caméras isolées + nom +
logo) selon un [gabarit 1920×1080][gabarit].

[gabarit]: https://claude.ai/code/artifact/0d9616f0-de4b-4538-ba85-97faa8e9ea14

Pour chaque présentation, la phase 2 produit des pistes **alignées sur la même
fenêtre de temps** :

- `webcam.mp4` — grille des caméras + audio
- `deskshare.mp4` — partage d'écran (s'il y en a eu)
- `slides.mp4` — les diapos, chacune affichée au moment où elle l'était en direct

Déposées au même point sur une timeline, elles se superposent automatiquement —
et la phase 3 les assemble pour vous selon le gabarit.

## Prérequis

```bash
brew install ffmpeg resvg jq
pip3 install numpy pillow      # phases 2b et 3 (détection caméras + composition)
```

(`ffmpeg`/`ffprobe`, `resvg`, `jq`, `python3` + `numpy`/`pillow`, plus `curl`
déjà présent sur macOS. `resvg` rend les diapos SVG plus fidèlement que
`rsvg-convert`, qui ignore les fonds à très grandes coordonnées des SVG BBB
issus de PDF.)

## Flux de travail par phases

### PHASE 1 — Tout télécharger

```bash
# Le plus simple : juste l'ID d'enregistrement (la partie …-<timestamp>)
./bbb_download.sh <recording_id>
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
# NUM | DEBUT    | FIN      | NOM                  | INFO
01    | 0:00:00  | 0:07:36  |                      | 28 diapos — Bienvenue aux...
02    | 0:07:36  | 0:25:16  | Jérémy Viau-Trudel   | 3 diapos — L'objection-sociocratique...
```

Le `NUM` nomme les sorties : clips `output/NUM/` et sélection en phase 2
(`... encode 01 03`). Les diapos, elles, restent dans les dossiers d'origine
`01/`…`05/` (une par présentation détectée). La colonne **`NOM`** (facultative)
est le nom du présentateur, affiché en bas à gauche de la vidéo composée (phase
3) ; vide = pas de bandeau.

#### Scinder une présentation en plusieurs clips

Si une « présentation » détectée contient en fait plusieurs exposés à séparer,
ajoutez simplement une ligne avec un **NUM unique** et une **sous-plage**
`DEBUT`/`FIN`. La webcam et le deskshare sont coupés par le temps, et les diapos
sont automatiquement tirées de la présentation d'origine que recouvre la plage.

```
# NUM | DEBUT    | FIN      | NOM        | INFO
05a   | 1:38:26  | 2:05:00  | Alice      | Exposé A
05b   | 2:05:00  | 2:38:03  | Bob        | Exposé B
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

### PHASE 2b — Isoler les caméras (optionnel)

BBB fusionne toutes les webcams en une grille dans `webcam.mp4`, sans métadonnée
de disposition. Pour en extraire des flux caméra séparés :

```bash
./bbb_split_webcams.sh <dossier> NUM...      # ex : ... 2026-07-07 02
```

- Détection par image : boîte de contenu sur le fond blanc + coupures aux
  divisions égales de la grille (chute de corrélation), plages de disposition
  stable segmentées, chaque caméra active découpée.
- Sortie : `output/NN/webcams/segSSSs_camK-of-N.mp4` (**max 3 caméras**, ratio de
  cellule conservé). `STEP=<s>` change le pas d'échantillonnage (défaut 4 s).

### PHASE 3 — Composer la vidéo finale (optionnel)

```bash
./bbb_compose.sh <dossier> NUM...            # ex : ... 2026-07-07 02
```

Assemble, par présentation, la vidéo finale selon le [gabarit][gabarit] :

- **carton d'intro** (`output/NN/intro.jpeg`, sinon généré) pendant 4 s ;
- **fond** `assets/blue-background.png` ;
- **contenu** : `slides.mp4` (remplacé par `deskshare.mp4` pendant un partage) ;
- **caméras** isolées (phase 2b) dans des emplacements fixes 16:9 avec ombre
  portée, affichées seulement quand elles ont une image ;
- **nom** du présentateur (colonne `NOM`) en bas à gauche ;
- **logo** `assets/Tux-FleurDeLys-…png` en bas à droite.

Sortie : **`output/NN/final.mp4`** (1920×1080, H.264, 30 fps, MP4).
`COMPOSE_LIMIT=<s>` pour un rendu d'essai court. Les assets (fond, logo) doivent
être dans `assets/`.

## Scripts

| Script | Rôle |
|--------|------|
| `bbb_download.sh` | **Phase 1** : télécharge tout + génère `presentations_cut.txt`. |
| `bbb_make_clips.sh` | **Phase 2** : génère les clips alignés par présentation (webcam / deskshare / slides). |
| `bbb_split_webcams.sh` | **Phase 2b** : isole les caméras de `webcam.mp4` par détection d'image. |
| `bbb_compose.sh` | **Phase 3** : compose la vidéo finale (fond + contenu + caméras + nom + logo). |

## Données locales

Le dépôt ne versionne que les scripts et cette doc. Tout le contenu produit par
les scripts reste **local** (voir `.gitignore`) :

- les dossiers d'enregistrement datés (`2026-07-07/`…) avec `webcams.mp4`,
  `deskshare.mp4`, les diapos, les métadonnées et `presentations_cut.txt` ;
- les clips et la vidéo finale (`final.mp4`) générés dans `output/`.

Chaque enregistrement se retélécharge avec `bbb_download.sh` et se régénère avec
les phases suivantes : rien de tout cela n'a besoin d'être commité.

Les assets de composition (`assets/blue-background.png`, le logo et les
`output/NN/intro.jpeg`) doivent être présents localement pour la phase 3 ; ils
sont ignorés par défaut — ajoutez-les au dépôt si vous le voulez autonome.

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
- **Caméras isolées (phase 2b)** : `webcam.mp4` est une grille composée par BBB,
  sans métadonnée de disposition. La détection repère la boîte de contenu (fond
  blanc), puis les coupures aux divisions égales de la grille via la chute de
  corrélation entre colonnes/rangées adjacentes (moyennée dans le temps pour
  résister au bruit), segmente les dispositions stables et recadre chaque tuile.
