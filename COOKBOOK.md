# Cookbook — de l'enregistrement BBB à la vidéo publiée

Le chemin le plus court, et les recettes pour les cas particuliers.
Les explications complètes sont dans [README.md](README.md).

## Installation (une seule fois)

```bash
brew install ffmpeg resvg jq
pip3 install numpy pillow
```

## Le parcours complet

**Deux étapes : vous préparez le config, le script fait tout le reste.**

```bash
# 1. Visionnez l'enregistrement BBB (via son URL de lecture) et notez les coupes.
#    Préparez un config (voir « L'étape manuelle » ci-dessous), ex. rlq-20260715.yaml

# 2. Une seule commande : téléchargement + clips + caméras + composition, tout.
./bbb_all.sh 0fd9362b0262e546caf2c07d030316c51f906692-1784147446537 rlq-20260715.yaml
```

L'ID est la partie `…-<timestamp>` de l'URL de lecture. Le dossier de sortie
(`2026-07-15/`) est déduit de sa date. Sans `NUM` en fin de commande, toutes les
présentations du config sont composées ; ajoutez-en pour en cibler certaines
(`./bbb_all.sh <id> rlq-20260715.yaml 01 02`).

Résultat : `2026-07-15/output/01/RLQ-MTL-20260715-OpenComb.NadineG.FR.1080p.h264.mp4`

Pour lancer une phase seule (ex. recomposer sans re-télécharger) :

```bash
./bbb_make_clips.sh   2026-07-15 encode 01   # clips
./bbb_split_webcams.sh 2026-07-15 01         # caméras
./bbb_compose.sh      2026-07-15 01          # vidéo finale
```

Intro : déposez `2026-07-15/intro.jpg` (commune à la session) avant l'étape 2,
ou laissez le script générer un carton. `./bbb_download_event_bg.sh "<url>"` la
récupère depuis la page d'événement.

## L'étape manuelle : le config

Le config est un `presentations_cut.yaml` que **vous préparez** : paramètres
globaux + une entrée par présentation avec ses coupes et son présentateur. C'est
le seul travail à la main. (Astuce : lancez une fois `bbb_download.sh <id>` pour
obtenir un gabarit pré-rempli depuis `shapes.svg`, ou partez d'un ancien config.)

```yaml
brand: "RLQ"          # valeurs globales, reprises dans le nom de fichier
city: "MTL"
date: "20260715"
language: "FR"
format: "1080p"
encoding: "h264"

presentations:
  - num: "01"                    # nomme output/01/
    start: "0:00:06"             # H:MM:SS ou secondes
    end: "1:01:11"
    presenter: "Nadine Giasson"  # OBLIGATOIRE — affiché en bas à gauche
    short_title: "OpenComb"      # OBLIGATOIRE — va dans le nom de fichier
    info: "OpenComb"             # libre, indicatif
    webcams_priority: [1, 2]     # ordre des slots caméra (haut, milieu, bas)
```

`presenter` et `short_title` sont obligatoires : sans eux la phase 3 s'arrête
avec `metadata manquante ou vide`.

---

## Recettes

### Essayer avant de rendre une heure de vidéo

```bash
COMPOSE_LIMIT=20 ./bbb_compose.sh 2026-07-15 01
```

Rend 20 secondes au lieu de 60 minutes : de quoi vérifier le cadrage, les
caméras et le bandeau du nom.

Le rendu d'essai est écrit sous un nom distinct `…​.preview.mp4` (jamais confondu
avec la vidéo finale). Relancez sans `COMPOSE_LIMIT` pour produire le vrai
fichier ; supprimez les `*.preview.mp4` quand vous n'en avez plus besoin.

### Mettre une image d'intro (carton de 0–4 s)

Déposez une image dans le dossier de la session — **une seule suffit pour toutes
les présentations** :

```bash
2026-07-15/intro.jpg              # commune à la session
```

Pour une intro différente sur une présentation précise, mettez-la dans son
dossier de sortie (prioritaire) : `2026-07-15/output/02/intro.png`. Formats
acceptés : `.jpeg`, `.jpg`, `.png`. Sans image, un carton est **généré** à partir
du titre. `bbb_download_event_bg.sh` enregistre justement dans
`<dossier>/intro.jpg`.

### Une présentation sans diapos (partage d'écran seulement)

Rien à faire, c'est géré. Un diaporama montré *à travers* un partage d'écran ne
produit pas de `slides.mp4` : le deskshare occupe alors la zone principale.

### Refaire une seule présentation

```bash
./bbb_make_clips.sh 2026-07-15 encode 02
./bbb_compose.sh 2026-07-15 02
```

Les autres dossiers `output/NN/` et leurs lignes du `manifest.txt` ne sont pas
touchés.

### Les caméras sont dans le mauvais ordre

Dans le YAML, `webcams_priority: [2, 1]` met cam2 en haut et cam1 au milieu.
Relancez la phase 3 seulement — la 2b n'a pas besoin d'être refaite.

### La détection de grille se trompe

```bash
# grille connue : saute l'analyse d'image
FORCE_GRID=2x2 FORCE_ACTIVE=1,2,3 ./bbb_split_webcams.sh 2026-07-15 01

# la grille change en cours de clip : plan manuel
MANUAL_PLAN=splits.txt ./bbb_split_webcams.sh 2026-07-15 01
```

### Deux exposés dans une seule présentation détectée

Deux entrées, deux `num`, deux sous-plages :

```yaml
  - num: "05a"
    start: "1:38:26"
    end: "2:05:00"
    presenter: "Alice Tremblay"
    short_title: "Expose_A"
  - num: "05b"
    start: "2:05:00"
    end: "2:38:03"
    presenter: "Bob Gagnon"
    short_title: "Expose_B"
```

Gardez chaque coupe à l'intérieur d'une seule présentation d'origine pour que
les diapos suivent.

### Un glitch d'une seconde au début

```bash
DRY_RUN=1 ./bbb_recut_sync.sh 2026-07-15 01 1   # aperçu
./bbb_recut_sync.sh 2026-07-15 01 1
```

Toutes les pistes sont recoupées avec le même décalage : la synchro tient.

### Retirer un passage au milieu (toutes pistes en synchro)

```bash
# coupe le segment [50:58, 53:13] de chaque piste et raccorde
./bbb_recut_sync.sh 2026-07-15 01 0:50:58 0:53:13

# avec un fondu enchaîné de 0.5 s au raccord
XFADE=0.5 ./bbb_recut_sync.sh 2026-07-15 01 0:50:58 0:53:13
```

Le raccord est net à l'image près. `webcams/` est exclu — relancez la phase 2b
si vous recomposez. Recomposez la phase 3 pour régénérer le final.

> ⚠️ Réécrit les fichiers sur place. Faites d'abord un `DRY_RUN=1`.

### Les diapos (slides.mp4) sont plus courtes que le clip

Normal si le présentateur a partagé ses diapos par **partage d'écran** au lieu de
l'outil diapos de BBB : `slides.mp4` ne contient que les diapos BBB, donc il ne
couvre qu'une partie de la fenêtre. La phase 3 cale la durée finale sur la piste
la plus longue (webcam/deskshare), pas sur les diapos — la vidéo finale reste
complète.

### Publier sur YouTube (privé par défaut)

```bash
./bbb_upload_youtube.py 2026-07-15/output/01/RLQ-MTL-20260715-OpenComb.NadineG.FR.1080p.h264.mp4 \
  --title "Rencontres Linux Québec — OpenComb" \
  --description "Session RLQ du 15 juillet 2026" \
  --privacy private

# vérifier le payload sans rien envoyer
./bbb_upload_youtube.py <video> --dry-run
```

---

## Dépannage

| Message | Cause | Solution |
|---|---|---|
| `ni slides.mp4 ni deskshare.mp4 — ignoré` | phase 2 pas lancée pour ce NUM | `./bbb_make_clips.sh <dossier> encode <NUM>` |
| `avertissement : zone principale vide` | ni diapo ni partage dans la fenêtre | vérifier `start`/`end` dans le YAML |
| `metadata manquante ou vide` | `short_title` ou `presenter` absent | compléter l'entrée du YAML |
| `⚠ clips générés pour la fenêtre […] mais le YAML dit […]` | `start`/`end` changés après la coupe | relancer `./bbb_make_clips.sh <dossier> encode <NUM>` |
| `l'interpréteur '…' n'a pas Pillow` (ou numpy) | le `python3` du PATH n'a pas les modules | `pip3 install numpy pillow`, ou suivre la ligne `PYTHON=…` suggérée |
| `0 caméra(s)` en phase 3 | phase 2b pas lancée pour ce NUM | `./bbb_split_webcams.sh <dossier> <NUM>` |
| `h264_videotoolbox indisponible` | encodeur matériel absent | bascule seule sur libx264 (plus lent) ; `BBB_STRICT_HW=1` pour échouer au lieu de basculer |

## Combien de temps ça prend

Ordres de grandeur pour **une heure** de source, sur un Mac Apple Silicon :

| Étape | Durée | Disque |
|---|---|---|
| 1 — téléchargement | selon le lien | ~3 Gio |
| 2 — clips | ~30 min (3 pistes à ~10 min) | ~3 Gio |
| 2b — caméras | quelques minutes | faible |
| 3 — composition | ~10 min | ~1 Gio |

L'encodage matériel tourne à environ 6× le temps réel par piste. C'est le
plafond du moteur vidéo de la puce : le paralléliser n'apporte rien.
