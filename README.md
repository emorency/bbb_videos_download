# Découpe des enregistrements BigBlueButton

Outils pour transformer un enregistrement BigBlueButton (BBB) — une longue
session unique — en **clips par présentation**, puis, si on le souhaite, en
**vidéo finale composée** (fond + diapos/deskshare + caméras isolées + nom +
logo) selon un [gabarit 1920×1080][gabarit].

[gabarit]: docs/layout.md

> **Pressé ?** [COOKBOOK.md](COOKBOOK.md) donne le parcours complet en cinq
> commandes, les recettes par situation et un tableau de dépannage. Ce
> README-ci détaille le pourquoi de chaque phase.

Pour chaque présentation, la phase 2 produit des pistes **alignées sur la même
fenêtre de temps** :

- `webcam.mp4` — grille des caméras + audio
- `deskshare.mp4` — partage d'écran (s'il y en a eu)
- `slides.mp4` — les diapos, chacune affichée au moment où elle l'était en direct
  (absent si le présentateur n'a pas utilisé les diapos BBB : un diaporama
  montré à travers un partage d'écran ne produit pas de `slides.mp4`)

Déposées au même point sur une timeline, elles se superposent automatiquement —
et la phase 3 les assemble pour vous selon le gabarit.

## Prérequis

```bash
brew install ffmpeg resvg jq
pip3 install numpy pillow      # phases 2b et 3 (détection caméras + composition)
pip3 install google-api-python-client google-auth-oauthlib google-auth-httplib2  # upload YouTube
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

# Ou un config.yaml portant un champ recording_id: — plus besoin de l'ID en argument
./bbb_download.sh rlq-20260707.yaml
#   Sans aucun argument, ./presentations_cut.yaml du dossier courant est lu s'il existe.
```

- On peut donner **soit l'URL de lecture complète, soit juste l'ID**
  d'enregistrement, **soit un `config.yaml`** contenant un champ
  `recording_id:` (alias `meeting_id:`). Avec un ID seul, l'hôte par défaut est
  `https://bbb3.services-conseils-linux.org` (modifiable via `BBB_HOST=...`).
- Quand un `config.yaml` est fourni, il est **installé** dans le dossier comme
  `presentations_cut.yaml` (avec sauvegarde horodatée si un fichier différent
  existait déjà — jamais d'écrasement silencieux).
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

puis génère **`presentations_cut.yaml`**.

### Éditer les points de coupe

Ouvrez `<dossier>/presentations_cut.yaml` et ajustez `start` et `end`
(format `H:MM:SS` ou secondes). Une entrée par présentation. Les valeurs de
départ sont détectées automatiquement à partir de `shapes.svg`.

Le YAML généré en phase 1 inclut aussi des valeurs globales par défaut pour le
naming (`brand`, `city`, `date`, `language`, `format`, `encoding`) ainsi qu'un
champ `recording_id:` rappelant l'ID BBB (pour pouvoir relancer `bbb_download.sh`
ou `bbb_all.sh` sans le repasser en argument). La `date` est déduite du dossier
d'enregistrement (ou du timestamp BBB), puis convertie en `YYYYMMDD`.
Si une présentation a une grille webcam fixe différente de l'auto-détection,
ajoutez `webcams_grid: "RxC"` (ex: `"2x3"` = 2 rangées, 3 colonnes) dans son
entrée YAML.
Vous pouvez aussi donner directement le nombre de webcams (`"1"`, `"2"`,
`"3"`, `"4"`, `"6"`) ; il est converti en grille égale
(`1->1x1`, `2->1x2`, `3->1x3`, `4->2x2`, `6->2x3`).
Si la grille change pendant la présentation, utilisez `webcams_plan` sous forme
structurée:

```yaml
webcams_plan:
  - start: "0:00"
    end: "12:30"
    grid: "2x3"
    active: [1, 2, 3, 4, 5]
  - start: "12:30"
    end: "end"
    grid: "2x2"
    active: [1, 2, 3]
```

Les horodatages de `webcams_plan` sont sur la timeline de la présentation
(`start`/`end` de l'entrée), donc vous pouvez réutiliser les mêmes repères
absolus que dans `presentations_cut.yaml`. Le script convertit ensuite en
relatif pour le clip en interne.

`end` est optionnel en YAML structuré:

- si absent, la fin du segment est le `start` du segment suivant;
- pour le dernier segment, si `end` est absent, la fin est `end` (fin du clip).

Le format historique en chaîne (`"start end grid active [bbox]; ..."`) reste
accepté, mais le format structuré est recommandé.

Exemple YAML :

```yaml
recording_id: "0fd9362b…-1784147446537"
brand: "RLQ"
city: "MTL"
date: "20260707"
language: "FR"
format: "1080p"
encoding: "h264"

presentations:
  - num: "01"
    start: "0:00:00"
    end: "0:07:36"
    presenter: "EtienneM_DenisF"
    info: "28 diapos — Bienvenue aux..."
    short_title: "Securisation_variables_environnement"
    webcams_priority: [2, 1, 3]
```

`webcams_priority` est utilisé en **phase 3** pour choisir l'ordre des caméras
dans les slots (haut, milieu, bas). Exemple `[2,1,3]` = cam2 en haut, cam1 au
milieu, cam3 en bas.

Nom de sortie (phase 3) :

`RLQ-City-Date-short_title.presenter.language.format.encoding.mp4`

En mode actuel de composition, `short_title` et `presenter` sont **obligatoires**
pour chaque entrée : si l'un des deux est vide ou absent, `bbb_compose.sh`
arrête avec une erreur explicite.

Exemple :

`RLQ-MTL-20260707-Securisation_variables_environnement.EtienneM_DenisF.FR.1080p.h264.mp4`

Le `presenter` reste affiché en **nom complet** dans la vidéo, mais dans le
nom de fichier il est converti en `Prenom` + initiale du dernier nom.
Exemple : `Martial Bigras` devient `MartialB`.

```text
# NUM | DEBUT    | FIN      | NOM                  | INFO
01    | 0:00:00  | 0:07:36  |                      | 28 diapos — Bienvenue aux...
02    | 0:07:36  | 0:25:16  | Jérémy Viau-Trudel   | 3 diapos — L'objection-sociocratique...
```

Le `num` nomme les sorties : clips `output/NUM/` et sélection en phase 2
(`... encode 01 03`). Les diapos, elles, restent dans les dossiers d'origine
`01/`…`05/` (une par présentation détectée). Le champ **`presenter`**
(facultatif) est le nom du présentateur, affiché en bas à gauche de la vidéo
composée (phase 3) ; vide = pas de bandeau.

#### Scinder une présentation en plusieurs clips

Si une « présentation » détectée contient en fait plusieurs exposés à séparer,
ajoutez simplement une entrée avec un **num unique** et une **sous-plage**
`start`/`end`. La webcam et le deskshare sont coupés par le temps, et les diapos
sont automatiquement tirées de la présentation d'origine que recouvre la plage.

```yaml
presentations:
  - num: "05a"
    start: "1:38:26"
    end: "2:05:00"
    presenter: "Alice"
    info: "Exposé A"
    webcams_priority: []
  - num: "05b"
    start: "2:05:00"
    end: "2:38:03"
    presenter: "Bob"
    info: "Exposé B"
    webcams_priority: []
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
  l'image-clé la plus proche. Sur les enregistrements mesurés ici, les
  images-clés sont espacées d'environ **10 s** : les bornes peuvent donc
  déraper de plusieurs secondes et les pistes se décaler entre elles.
  À vérifier sur un enregistrement donné :

  ```bash
  ffprobe -v error -select_streams v:0 -skip_frame nokey \
    -show_entries frame=pts_time -of csv=p=0 -read_intervals "%+60" webcams.mp4
  ```

- Les `NUM` correspondent au champ `num` de `presentations_cut.yaml`.
  Sans liste, toutes les présentations sont traitées.

Résultat dans `<dossier>/output/` :

```text
output/
├── 01/
│   ├── webcam.mp4
│   ├── deskshare.mp4      (si partage d'écran)
│   ├── slides.mp4
│   └── window.txt         (fenêtre [start,end] utilisée — voir ci-dessous)
├── 02/
│   └── ...
└── manifest.txt           (numéro → horaires → pistes → info)
```

`window.txt` mémorise la fenêtre de coupe employée. Si vous modifiez `start`/`end`
dans le YAML sans régénérer les clips, la **phase 3 vous avertit** que les clips
sont périmés et indique de relancer la phase 2 — c'est ce qui évite de composer
une vidéo à partir de clips qui ne correspondent plus.

Relancer une présentation ne met à jour que son dossier et sa ligne dans
`manifest.txt` ; les autres ne sont pas touchées.

Si vous voulez préparer l'intro avant le pipeline complet, lancez d'abord
`./bbb_init.sh <recording_id>` : le script crée les dossiers `NN/` et
`output/NN/` ainsi qu'un `presentations_cut.yaml` de base, ce qui vous permet
de copier `intro.jpg` au bon endroit avant `bbb_all.sh`.

### PHASE 2b — Isoler les caméras (optionnel)

BBB fusionne toutes les webcams en une grille dans `webcam.mp4`, sans métadonnée
de disposition. Pour en extraire des flux caméra séparés :

```bash
./bbb_split_webcams.sh <dossier> NUM...      # ex : ... 2026-07-07 02

# v3 : version plus robuste (OpenCV), meilleure détection des transitions
# de grille et des cams actives.
./bbb_split_webcams_v3.sh <dossier> NUM...
APPLY=1 ./bbb_split_webcams_v3.sh <dossier> 01
# mode hybride: OpenCV propose, l'utilisateur confirme/édite chaque segment
REVIEW=1 APPLY=1 SPLIT=1 ./bbb_split_webcams_v3.sh <dossier> 01
# revue sélective: ne demander que les segments changés ou peu fiables
REVIEW=1 REVIEW_MODE=smart REVIEW_CONFIDENCE=0.62 APPLY=1 SPLIT=1 ./bbb_split_webcams_v3.sh <dossier> 01

# GUI locale Qt (cockpit complet: phases + metadata + revue segments)
python3 bbb_webcams_plan_gui_qt.py <dossier> <NUM>
# ex:
python3 bbb_webcams_plan_gui_qt.py 2026-08-04 01

# si la grille est connue (bypass de l'analyse auto)
FORCE_GRID=2x2 FORCE_ACTIVE=1,2,3 ./bbb_split_webcams.sh <dossier> 01

# si la grille change dans le clip, fournir un plan manuel
# (ex: output/01/splits.txt peut être référencé par son nom court)
MANUAL_PLAN=webcams_plan.txt ./bbb_split_webcams.sh <dossier> 01
```

- Détection par image : boîte de contenu sur le fond blanc + coupures aux
  divisions égales de la grille (chute de corrélation), plages de disposition
  stable segmentées, chaque caméra active découpée.
- La v3 utilise OpenCV si disponible (`pip3 install opencv-python`) pour une
  analyse plus robuste des séparations de grille. Variables utiles :
  `DETECTOR=opencv|classic|auto` et `CV2_REQUIRED=1`.
- Pour une validation humaine assistée: `REVIEW=1` lance une revue interactive
  segment par segment (grille, ordre des webcams actives, bbox). Avec
  `REVIEW_IMAGES=1` (défaut), une image de référence est extraite pour chaque
  segment dans `output/NN/webcams/review_plan/`.
- `REVIEW_MODE` permet de filtrer les prompts: `all`, `changed`, `low`,
  `smart` (changed + low confidence). En mode `changed`, la revue vise surtout
  les segments de transition (changements de grille et micro-segments).
  Le seuil de confiance se règle avec
  `REVIEW_CONFIDENCE` (défaut `0.62`).
- `REVIEW_LONG_SEGMENT_SEC` (défaut `120`) permet d'ignorer en revue `changed`
  les longs segments stables à haute confiance.
- `REVIEW_STRICT=1` force un échec si la review interactive est demandée sans
  terminal interactif (`/dev/tty` indisponible). Par défaut (`0`), ces segments
  sont auto-acceptés.
- L'outil GUI Qt `bbb_webcams_plan_gui_qt.py` agit comme un cockpit:
  statut des phases, boutons d'exécution (`make_clips`, auto-plan v3, split,
  review webcams, compose), édition des champs YAML (start/end/presenter/
  short_title/info), revue visuelle des segments et sauvegarde d'un
  `webcams_plan.manual.txt`.
- La liste de grilles proposée dans la GUI couvre: `1x1`, `1x2`, `1x3`, `2x1`,
  `2x2`, `2x3`, `3x1`, `3x2`, `3x3`, avec saisie personnalisée possible
  (`RxC`).
- Sortie : `output/NN/webcams/segSSSs_camK-of-N.mp4` (ratio de cellule
  conservé). `STEP=<s>` change le pas d'échantillonnage (défaut 4 s).
- `VERBOSE=1` affiche la progression détaillée.
- `BBB_VENC=libx264` force explicitement `libx264` sur les phases 2, 2b et 3.
- En phase 2b, `VIDEO_CODEC=...` reste accepté comme alias de compatibilité,
  mais `BBB_VENC` est désormais la variable recommandée.
- Sans variable, la phase 2b essaie `h264_videotoolbox`, puis bascule
  automatiquement sur `libx264` si l'encodeur matériel n'est pas disponible.
- Pour forcer une grille webcam fixe d'une présentation, ajoutez
  `webcams_grid: "RxC"` (ex: `"2x3"` = 2 rangées, 3 colonnes) dans son entrée
  YAML.
- Raccourci accepté : un simple nombre (`1`, `2`, `3`, `4`, `6`) pour une
  grille égale correspondante.
- Pour des changements de grille en cours de présentation, ajoutez
  `webcams_plan` en YAML structuré (`start`, `end`, `grid`, `active`,
  `bbox` optionnel).
- Sur Debian et plus généralement sur Linux, `h264_videotoolbox` n'existe pas :
  utilisez `BBB_VENC=libx264` pour éviter l'avertissement, ou laissez le
  fallback automatique faire la bascule.
- Si vous connaissez déjà la disposition, `FORCE_GRID=<C>x<R>` et
  `FORCE_ACTIVE=...` permettent de **sauter l'analyse** (exemple : 2x2 avec
  la dernière case vide -> `FORCE_GRID=2x2 FORCE_ACTIVE=1,2,3`).
- Pour corriger manuellement les changements de grille, utilisez
  `MANUAL_PLAN=<fichier>`. Format :

```text
# start end grid active [bbox]
0:00  3:20  2x2  1,2,3
3:20  end   3x2  1,3,4,5  0:0:1920:1080
```

`start`/`end` acceptent secondes, `MM:SS`, `HH:MM:SS` ou `end`. `active` liste
les cellules ligne par ligne (`1..R*C`) ; utilisez `-` ou `all` pour toutes les
cellules. `bbox` est optionnel et recadre la zone de grille (`x:y:w:h`).
`MANUAL_PLAN=splits.txt` cherche aussi `output/NN/splits.txt`. Variante sans
fichier : `MANUAL_SEGMENTS='0:00 3:20 2x2 1,2,3; 3:20 end 3x2 1,3,4,5'`.

### Recut synchronisé d'une présentation

Applique le **même découpage à toutes les pistes** d'une présentation
(webcam/deskshare/slides/final) pour qu'elles restent alignées. Deux modes selon
le nombre d'arguments.

**Retirer les premières secondes** (glitch au début), 3 arguments :

```bash
./bbb_recut_sync.sh <dossier> <NUM> <start>
./bbb_recut_sync.sh 2026-07-14 01 1          # retire la 1re seconde
```

**Retirer un segment au milieu** et raccorder l'avant et l'après, 4 arguments :

```bash
./bbb_recut_sync.sh <dossier> <NUM> <start> <end>
./bbb_recut_sync.sh 2026-07-15 01 0:50:58 0:53:13   # coupe [50:58, 53:13]
```

- `start`/`end` acceptent secondes, `MM:SS` ou `H:MM:SS`. Le raccord est
  réencodé, donc **net à l'image près** (pas de dépendance aux images-clés).
- `XFADE=<s>` ajoute un **fondu enchaîné** (cross dissolve) au raccord du mode
  milieu, vidéo et audio. Le fondu consomme `XFADE` s de part et d'autre de la
  coupe (la vidéo est donc raccourcie d'autant en plus du segment retiré) ; il
  est ignoré si une des deux parties est plus courte que `XFADE`.

  ```bash
  XFADE=0.5 ./bbb_recut_sync.sh 2026-07-15 01 0:50:58 0:53:13
  ```

- `DRY_RUN=1` affiche le plan (plages gardées, durée estimée) sans rien écrire.
- Le sous-dossier `webcams/` est **exclu** : ces segments caméra ont une
  timeline partielle et seraient désynchronisés. Après un recut, relancez la
  phase 2b pour les régénérer depuis le `webcam.mp4` déjà coupé.
- Le fichier final composé (`RLQ-…mp4`) est inclus s'il est présent ; sinon
  recomposez (phase 3) après le recut.

### PHASE 3 — Composer la vidéo finale (optionnel)

```bash
./bbb_compose.sh <dossier> NUM...            # ex : ... 2026-07-07 02
```

Assemble, par présentation, la vidéo finale selon le [gabarit][gabarit] :

- **carton d'intro** **superposé** de 0 à 4 s (la durée totale n'augmente pas,
  l'audio démarre à t=0). L'image est cherchée dans cet ordre :
  `output/NN/intro.{jpeg,jpg,png}` (propre à une présentation), puis
  `<dossier>/intro.{jpeg,jpg,png}` (**commune à toute la session** — une seule
  image suffit pour toutes les présentations), sinon un carton est **généré** à
  partir du titre. `bbb_download_event_bg.sh` enregistre justement dans
  `<dossier>/intro.jpg` ;
- **fond** `assets/blue-background.png` ;
- **contenu** de la zone principale : `slides.mp4` et/ou `deskshare.mp4` — le
  partage d'écran s'affiche par-dessus les diapos pendant qu'il est actif.
  **L'un des deux suffit** : une présentation sans diapos (partage d'écran
  seulement) se compose normalement, et inversement ;
- **caméras** isolées (phase 2b) dans des emplacements fixes 16:9 avec ombre
  portée, affichées seulement quand elles ont une image ; layout fixe
  (voir [gabarit][gabarit]) :
  - 3 slots verticaux à droite (layout historique) ;
  - 1 slot additionnel en bas à droite, à gauche du logo et sous la zone
    deskshare/slides ;
  - `webcams_priority` continue de piloter l'affectation caméra -> slot
    (jusqu'à 4 slots).
- **nom** du présentateur (colonne `NOM`) en bas à gauche ;
- **logo** `assets/Tux-FleurDeLys-…png` en bas à droite.

Sortie : **`output/NN/RLQ-City-Date-short_title.presenter.language.format.encoding.mp4`**
(1920×1080, H.264, 30 fps, MP4), plus la **piste audio seule** sous le même nom
en `.m4a`. Elle est extraite de la vidéo finale par copie de flux — aucun
ré-encodage, ~1 s — et partage donc exactement son origine des temps
(t=0 = début du clip) et sa durée : elle se recale sur la vidéo sans décalage.
`BBB_AUDIO_TRACK=0` pour ne pas la produire.

L'audio n'est **pas ré-encodé** par la phase 3 : `webcam.mp4` contient déjà de
l'AAC-LC 48 kHz stéréo (phase 2) et la source BBB est à ~65 kb/s, donc un
ré-encodage ne serait qu'une 3ᵉ génération lossy pour ~2 min de CPU par vidéo. Le
flux est copié tel quel ; la seule conséquence est que la troncature à la durée
du clip tombe sur une frontière de paquet AAC (~21 ms). `BBB_AUDIO_REENCODE=1`
force le ré-encodage (AAC 192 kb/s), ce qui se produit aussi automatiquement si
le flux source n'est pas de l'AAC.
`COMPOSE_LIMIT=<s>` pour un rendu d'essai court : il est écrit sous un nom
distinct `…​.preview.mp4`, jamais confondu avec la vidéo finale. `PYTHON=<chemin>`
impose un interpréteur (utile si le `python3` par défaut n'a pas Pillow). Les
assets (fond, logo) doivent être dans `assets/`.

Pour accélérer encore un aperçu, vous pouvez baisser la qualité d'encodage :
`COMPOSE_CRF=33 COMPOSE_PRESET=ultrafast COMPOSE_BITRATE=1800k`.

### Tout-en-un : de l'ID à la vidéo finale (`bbb_all.sh`)

Après avoir **visionné l'enregistrement et noté les points de coupe**, préparez
un fichier de config (un `presentations_cut.yaml` : paramètres globaux +
présentations avec `start`/`end`/`presenter`/`short_title`). `bbb_all.sh` fait
alors **tout le pipeline** — téléchargement (phase 1) puis clips, caméras et
composition (phases 2/2b/3) — pour toutes les présentations du config :

```bash
./bbb_all.sh --preview <config.yaml> [NUM...]              # aperçu rapide (~10s/section)
./bbb_all.sh --preview <meeting_id | playback_url> <config.yaml> [NUM...]
./bbb_all.sh <config.yaml> [NUM...]                        # id lu dans le config
./bbb_all.sh <meeting_id | playback_url> <config.yaml> [NUM...]
./bbb_all.sh rlq-20260715.yaml
./bbb_all.sh 0fd9362b…-1784147446537 rlq-20260715.yaml
```

- Si le config contient un champ `recording_id:` (alias `meeting_id:`), l'**ID
  n'a pas à être passé** : `./bbb_all.sh rlq-20260715.yaml` suffit.
- Le **dossier de sortie** est déduit de la date de l'ID (comme `bbb_download.sh`).
  Le config est installé comme `<dossier>/presentations_cut.yaml` ; un fichier de
  coupe préexistant qui diffèrerait est **sauvegardé** (`.bak`) avant, jamais
  écrasé en silence.
- Sans `NUM`, **toutes** les présentations du config sont traitées ; sinon
  seulement celles listées.
- La seule étape manuelle reste le **repérage des coupes** : le config les porte,
  le script fait le reste.
- `--preview` (ou `PREVIEW=1`) active un rendu d'essai rapide :
  `MODE=copy`, `CLIP_LIMIT=10`, `COMPOSE_LIMIT=10`, encodage allégé
  (`COMPOSE_CRF=33`, `COMPOSE_PRESET=ultrafast`, `COMPOSE_BITRATE=1800k`),
  et échantillonnage webcam plus espacé (`STEP=8`).
- En preview, chaque cut prend 10 s puis est assemblé automatiquement dans
  `output/preview-assembled.mp4` (`PREVIEW_ASSEMBLE=0` pour désactiver).
- Si vous lancez preview avec un seul `NUM` qui contient `webcams_plan`, le mode
  preview prend 10 s de chaque entrée de `webcams_plan` puis assemble le tout
  (désactiver via `PREVIEW_FROM_WEBCAMS_PLAN=0`).
- `MODE=copy` passe la phase 2 en copie ; `SKIP_SPLIT=1` saute la 2b (pas de
  caméras isolées) ; `SKIP_COMPOSE=1` s'arrête après les clips. Les variables des
  scripts sous-jacents (`PYTHON`, `BBB_HOST`, `BBB_VENC`, …) sont héritées.
- Review webcams avant composition (optionnel) :

  ```bash
  REVIEW_WEBCAMS=1 ./bbb_all.sh <config.yaml> 01
  REVIEW_WEBCAMS=1 REVIEW_WEBCAMS_PAUSE=1 ./bbb_all.sh <config.yaml> 01
  ```

  Cela génère, pour chaque `NUM`, `output/NUM/webcams/review/contact-sheet.jpg`
  et `output/NUM/webcams/review/webcams-review.mp4`.
  Avec `REVIEW_WEBCAMS_PAUSE=1`, le pipeline s'arrête après la review webcam
  (avant la phase 3), pour validation manuelle.

## Scripts

| Script | Rôle |
| -------- | ------ |
| `bbb_all.sh` | Tout-en-un : télécharge (phase 1) puis clips/caméras/composition (2/2b/3) à partir d'un ID + un config de coupes. |
| `bbb_init.sh` | Prépare un dossier de session, crée `output/NN/` et génère un `presentations_cut.yaml` de base. |
| `bbb_download.sh` | **Phase 1** : télécharge tout + génère `presentations_cut.yaml`. |
| `bbb_make_clips.sh` | **Phase 2** : génère les clips alignés par présentation (webcam / deskshare / slides). |
| `bbb_split_webcams.sh` | **Phase 2b** : isole les caméras de `webcam.mp4` par détection d'image. |
| `bbb_recut_sync.sh` | Re-coupe toutes les pistes d'une présentation à l'identique (retrait tête ou segment milieu, fondu optionnel) ; synchro conservée. |
| `bbb_compose.sh` | **Phase 3** : compose la vidéo finale (fond + contenu + caméras + nom + logo). |
| `bbb_download_event_bg.sh` | Télécharge l'image de fond/bannière depuis une page d'événement (par défaut vers `YYYY-MM-DD/intro.jpg`). |
| `bbb_upload_youtube.py` | Upload d'une vidéo locale vers YouTube (mode **private** par défaut, OAuth local). |

### Upload YouTube (private)

Préparez d'abord un client OAuth Desktop depuis Google Cloud (YouTube Data API
v3 activée), puis placez le fichier JSON dans le dépôt sous :

`youtube_client_secret.json`

Commande typique (private par défaut) :

```bash
./bbb_upload_youtube.py 2026-07-14/output/01/RLQ-MTL-20260714-Bienvenue_RLQ.MartialB.FR.1080p.h264.mp4 \
  --title "Rencontres Linux Quebec - Bienvenue" \
  --description "Session RLQ" \
  --privacy private
```

Au premier lancement, un navigateur s'ouvre pour l'autorisation Google. Un token
est ensuite sauvegardé dans `~/.config/bbb_videos_download/youtube_token.json`.

## Données locales

Le dépôt ne versionne que les scripts et cette doc. Tout le contenu produit par
les scripts reste **local** (voir `.gitignore`) :

- les dossiers d'enregistrement datés (`2026-07-07/`…) avec `webcams.mp4`,
  `deskshare.mp4`, les diapos, les métadonnées et `presentations_cut.yaml` ;
- les clips et les vidéos finales générés dans `output/`.

Chaque enregistrement se retélécharge avec `bbb_download.sh` et se régénère avec
les phases suivantes : rien de tout cela n'a besoin d'être commité.

Les assets de composition (`assets/blue-background.png`, le logo et l'intro
`<dossier>/intro.jpg` — ou `output/NN/intro.*` pour une intro propre à une
présentation) doivent être présents localement pour la phase 3 ; ils sont
ignorés par défaut — ajoutez-les au dépôt si vous le voulez autonome. Sans image
d'intro, un carton est généré automatiquement à partir du titre.

Pour récupérer automatiquement une image de fond depuis une page d'événement
Rencontres Linux Québec :

```bash
./bbb_download_event_bg.sh "https://www.rencontres-linux.quebec/en_CA/event/rencontre-linux-ville-de-quebec-14-juillet-2026-114/register"
# -> enregistre par défaut dans 2026-07-14/intro.jpg

# ou avec un fichier de sortie explicite
./bbb_download_event_bg.sh "<url-evenement>" 2026-07-14/intro.jpg
```

Le script essaie d'abord `og:image`/`twitter:image`, puis un
`background-image:url(...)`, puis des balises `<img>`.

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
- **`slides.mp4` peut être plus court que le clip, c'est normal** : il ne
  contient que les diapos BBB de `shapes.svg`. Si le présentateur a montré ses
  diapos via un partage d'écran plutôt que par l'outil diapos de BBB, `shapes.svg`
  a peu (ou pas) d'entrées, et le clip diapos ne couvre alors qu'une fraction de
  la fenêtre. La phase 3 en tient compte : la durée finale est calée sur la plus
  longue piste (webcam/deskshare), pas sur les diapos, et la zone principale
  affiche le deskshare là où il n'y a pas de diapo.
- **Vitesse d'encodage** : les phases 2 et 3 encodent en matériel
  (`h264_videotoolbox`) à environ **6× le temps réel** par piste, soit ~10 min
  par heure de source et par piste. La phase 2 encode jusqu'à trois pistes à la
  suite (webcam, deskshare, diapos) : comptez ~30 min par heure de source.
  Les paralléliser n'apporte rien — le moteur vidéo de la puce est déjà saturé
  par une seule piste 1080p30.
  Ne pas ajouter `-realtime 1` aux options `h264_videotoolbox` : ce drapeau
  demande à l'encodeur de se caler sur le temps réel (utile en direct) et
  **divise le débit par deux** en traitement par lot, sans rien changer au
  résultat.
- **Débit des pistes intermédiaires** : `webcam.mp4` et `deskshare.mp4` sont
  réencodés à 6 Mbit/s. La source BBB tourne autour de 1,2 Mbit/s et ces
  fichiers sont de toute façon réencodés en phase 3 : monter le débit ne fait
  que gonfler le disque (14 Mbit/s produisait des clips de 6,5 Gio) sans rien
  gagner en qualité ni en vitesse.
- **Caméras isolées (phase 2b)** : `webcam.mp4` est une grille composée par BBB,
  sans métadonnée de disposition. La détection repère la boîte de contenu (fond
  blanc), puis les coupures aux divisions égales de la grille via la chute de
  corrélation entre colonnes/rangées adjacentes (moyennée dans le temps pour
  résister au bruit), segmente les dispositions stables et recadre chaque tuile.
