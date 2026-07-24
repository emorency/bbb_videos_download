#!/usr/bin/env bash
# PHASE 2b (optionnel) — Sépare le clip webcam d'une présentation en flux caméra
# isolés, par détection d'image (BBB ne publie aucune métadonnée de webcams).
#
# Travaille sur output/NN/webcam.mp4 (déjà produit par bbb_make_clips.sh) : on
# n'analyse que les présentations demandées, pas toute la session.
#
# Méthode : échantillonne le clip, détecte les vraies tuiles webcam BBB (vidéos
# pleines de tailles/proportions variées sur fond blanc, parfois accolées) par
# découpe récursive — gouttières blanches puis sauts de couverture — sans supposer
# de grille régulière. Segmente en plages de disposition stable, puis recadre
# chaque tuile au plus juste (les bandes blanches de pillarbox sont retirées).
#
# Sortie : output/NN/webcams/segSSSs_camK-of-N.mp4  (+ manifest.txt)
# En analyse auto, les segments à 1 seule caméra ne sont pas découpés
# (utiliser webcam.mp4). En mode manuel, une seule cellule active est extraite.
#
# Prérequis : ffmpeg, python3 avec numpy et Pillow (pip3 install numpy pillow).
# Usage : bbb_split_webcams.sh <dossier> NUM...
#   ex : bbb_split_webcams.sh 2026-07-07 04 05
#
# Modes manuels (bypass analyse):
#   FORCE_GRID=2x2 FORCE_ACTIVE=1,2,3 ./bbb_split_webcams.sh <dossier> <NUM>
#   MANUAL_PLAN=webcams_plan.txt ./bbb_split_webcams.sh <dossier> <NUM>
#
# Format MANUAL_PLAN (temps en secondes, MM:SS, HH:MM:SS, ou "end"):
#   # start end grid active [bbox]
#   0:00  3:20  2x2  1,2,3
#   3:20  end   3x2  1,3,4,5  0:0:1920:1080
#
# active: indices de cellules ligne par ligne, 1..(cols*rows), ou "-" / "all".
# bbox: x:y:w:h de la zone grille, optionnel (défaut: image entière).

set -euo pipefail

[ $# -lt 2 ] && { echo "Usage: $0 <dossier> NUM..." >&2; exit 1; }
caller_pwd="$PWD"
rec_dir="$1"; shift
cd "$rec_dir"

STEP="${STEP:-4}"   # secondes entre images échantillonnées (env STEP=... pour changer)
VERBOSE="${VERBOSE:-0}"
DRY_RUN="${DRY_RUN:-0}"
FORCE_GRID="${FORCE_GRID:-}"
FORCE_ACTIVE="${FORCE_ACTIVE:-}"
FORCE_BBOX="${FORCE_BBOX:-}"
MANUAL_PLAN="${MANUAL_PLAN:-}"
MANUAL_SEGMENTS="${MANUAL_SEGMENTS:-}"
VENC="${BBB_VENC:-${VIDEO_CODEC:-h264_videotoolbox}}"
STRICT_HW="${BBB_STRICT_HW:-0}"
VIDEO_BITRATE="${VIDEO_BITRATE:-8M}"
AUDIO_BITRATE="${AUDIO_BITRATE:-128k}"

# Interpréteur Python : doit avoir numpy et Pillow. Le python3 par défaut du PATH
# peut être un pyenv/venv qui ne les a pas ; PYTHON=... impose un autre.
PYTHON="${PYTHON:-python3}"
if ! "$PYTHON" -c "import numpy, PIL" 2>/dev/null; then
  echo "Erreur : l'interpréteur '$PYTHON' n'a pas numpy et/ou Pillow (PIL)." >&2
  echo "  → installez-les : pip3 install numpy pillow" >&2
  echo "  → ou pointez PYTHON vers un interpréteur qui les a :" >&2
  for c in /opt/homebrew/bin/python3 /usr/local/bin/python3 \
           /Library/Frameworks/Python.framework/Versions/*/bin/python3; do
    [ -x "$c" ] && "$c" -c "import numpy, PIL" 2>/dev/null \
      && { echo "      relancez avec :  PYTHON=$c $0 ..." >&2; break; }
  done
  exit 1
fi

log() { [ "$VERBOSE" = "1" ] && echo "$*"; }

append_video_codec_args() {  # <codec> appends ffmpeg args to global cmd array
    local codec="$1"

    case "$codec" in
        h264_videotoolbox)
            cmd+=(-c:v h264_videotoolbox -b:v "$VIDEO_BITRATE" -pix_fmt yuv420p -r 30 -profile:v high -prio_speed 1)
            ;;
        libx264)
            cmd+=(-c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p -r 30)
            ;;
        *)
            cmd+=(-c:v "$codec" -b:v "$VIDEO_BITRATE")
            ;;
    esac
}

build_segment_cmd() {  # <codec> <start> <dur> <input> <cams_tmp> <outdir>
    local codec="$1" start="$2" dur="$3" input="$4" cams_file="$5" outdir="$6"
    local fc="" idx=0 out kcam K grid x y w h _s _e _K _grid

    cmd=(ffmpeg -y -nostdin -v error -ss "$start" -i "$input")
    while read -r _s _e x y w h kcam _K _grid; do
        idx=$((idx+1))
        fc+="[0:v]crop=${w}:${h}:${x}:${y}[v${idx}];"
    done < "$cams_file"
    fc="${fc%;}"
    cmd+=(-filter_complex "$fc")

    idx=0
    while read -r _s _e x y w h kcam K grid; do
        idx=$((idx+1))
        out="$outdir/seg$(printf '%04d' "${start%.*}")s_cam${kcam}-of-${K}.mp4"
        cmd+=(-map "[v${idx}]" -map 0:a? -t "$dur")
        append_video_codec_args "$codec"
        cmd+=(-c:a aac -b:a "$AUDIO_BITRATE" -movflags +faststart "$out")
    done < "$cams_file"
}

even_dim() {
    local v="$1"
    v=$((v - (v % 2)))
    [ "$v" -lt 2 ] && v=2
    echo "$v"
}

even_coord() {
    local v="$1"
    v=$((v - (v % 2)))
    [ "$v" -lt 0 ] && v=0
    echo "$v"
}

time_to_seconds() {  # <time> <duration>
    awk -v t="$1" -v dur="$2" '
    BEGIN {
        if (tolower(t) == "end") { printf "%.3f", dur; exit }
        n = split(t, a, ":")
        if (n == 1) s = t + 0
        else if (n == 2) s = (a[1] * 60) + a[2]
        else if (n == 3) s = (a[1] * 3600) + (a[2] * 60) + a[3]
        else exit 2
        if (s < 0) exit 3
        printf "%.3f", s
    }'
}

validate_grid() {  # <grid>
    local grid="$1" cols rows
    cols="${grid%x*}"
    rows="${grid#*x}"
    [[ "$cols" =~ ^[0-9]+$ && "$rows" =~ ^[0-9]+$ && "$cols" -ge 1 && "$rows" -ge 1 ]]
}

resolve_manual_plan() {  # <requested_path> <nn>
    local requested="$1" nn="$2"

    if [ -f "$requested" ]; then
        printf '%s\n' "$requested"
        return 0
    fi

    case "$requested" in
        /*) return 1 ;;
    esac

    if [ -f "$caller_pwd/$requested" ]; then
        printf '%s\n' "$caller_pwd/$requested"
        return 0
    fi

    if [ -f "output/${nn}/${requested}" ]; then
        printf '%s\n' "output/${nn}/${requested}"
        return 0
    fi

    return 1
}

build_manual_plan() {  # <W> <H> <DUR> <nn>, reads plan lines on stdin
    local W="$1" H="$2" DUR="$3" nn="$4"
    local line start_raw end_raw grid active bbox extra start end cols rows bx by bw bh total active_list
    local idx k c r x y w h segment_lines

    while IFS= read -r line; do
        line="${line%%#*}"
        [ -z "$(printf '%s' "$line" | tr -d '[:space:]')" ] && continue

        start_raw=""; end_raw=""; grid=""; active=""; bbox=""; extra=""
        read -r start_raw end_raw grid active bbox extra <<< "$line"
        if [ -n "${extra:-}" ] || [ -z "${start_raw:-}" ] || [ -z "${end_raw:-}" ] || [ -z "${grid:-}" ]; then
            echo "[${nn}] ligne MANUAL_PLAN invalide: ${line}" >&2
            return 1
        fi

        if ! validate_grid "$grid"; then
            echo "[${nn}] grille invalide dans MANUAL_PLAN: ${grid} (format attendu: CxR)." >&2
            return 1
        fi
        cols="${grid%x*}"
        rows="${grid#*x}"
        total=$((cols * rows))

        start="$(time_to_seconds "$start_raw" "$DUR")" || { echo "[${nn}] début invalide: ${start_raw}" >&2; return 1; }
        end="$(time_to_seconds "$end_raw" "$DUR")" || { echo "[${nn}] fin invalide: ${end_raw}" >&2; return 1; }
        if ! awk -v s="$start" -v e="$end" -v d="$DUR" 'BEGIN{exit !(s < e && e <= d + 0.001)}'; then
            echo "[${nn}] plage invalide: ${start_raw}..${end_raw} (durée clip ${DUR}s)." >&2
            return 1
        fi

        if [ -z "${active:-}" ] || [ "$active" = "-" ] || [ "$active" = "all" ]; then
            active_list="$(seq 1 "$total" | tr '\n' ',' | sed 's/,$//')"
        else
            active_list="$active"
        fi

        bx=0; by=0; bw="$W"; bh="$H"
        if [ -n "${bbox:-}" ] && [ "$bbox" != "-" ]; then
            oldIFS="$IFS"; IFS=':'; set -- $bbox; IFS="$oldIFS"
            bx="${1:-0}"; by="${2:-0}"; bw="${3:-$W}"; bh="${4:-$H}"
        fi

        bx=$(even_coord "$bx"); by=$(even_coord "$by"); bw=$(even_dim "$bw"); bh=$(even_dim "$bh")
        if [ $((bx + bw)) -gt "$W" ]; then bw=$(even_dim $((W - bx))); fi
        if [ $((by + bh)) -gt "$H" ]; then bh=$(even_dim $((H - by))); fi

        k=0
        segment_lines=""
        for idx in $(echo "$active_list" | tr ',;' ' '); do
            [ -z "$idx" ] && continue
            if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "$total" ]; then
                echo "[${nn}] index caméra invalide dans MANUAL_PLAN: ${idx} (1..${total})" >&2
                return 1
            fi
            k=$((k+1))
            c=$(((idx - 1) % cols))
            r=$(((idx - 1) / cols))
            x=$(even_coord $((bx + (c * bw) / cols)))
            y=$(even_coord $((by + (r * bh) / rows)))
            w=$(even_dim $((((c + 1) * bw) / cols - (c * bw) / cols)))
            h=$(even_dim $((((r + 1) * bh) / rows - (r * bh) / rows)))
            if [ $((x + w)) -gt "$W" ]; then w=$(even_dim $((W - x))); fi
            if [ $((y + h)) -gt "$H" ]; then h=$(even_dim $((H - y))); fi
            segment_lines+="${start} ${end} ${x} ${y} ${w} ${h} ${k} X ${cols}x${rows}"$'\n'
        done
        if [ "$k" -eq 0 ]; then
            echo "[${nn}] aucune caméra active valide dans MANUAL_PLAN: ${line}" >&2
            return 1
        fi
        printf '%s' "$segment_lines" | awk -v K="$k" '{ $8=K; print }'
    done
}

sample_frames() {  # <input_webcam> <tmp_dir> <step> <duration>
    local in="$1" outdir="$2" step="$3" dur="$4"

    # Avec un STEP élevé, extraire quelques images par seeks successifs est
    # souvent bien plus rapide que décoder tout le clip en continu.
    if awk -v s="$step" 'BEGIN{exit !(s>=60)}'; then
        local t=0 idx=1 total
        total=$(awk -v d="$dur" -v s="$step" 'BEGIN{print int(d/s)+1}')
        echo "  échantillonnage rapide: ~${total} image(s) (STEP=${step}s)"
        while awk -v t="$t" -v d="$dur" 'BEGIN{exit !(t<=d+1e-6)}'; do
            [ "$VERBOSE" = "1" ] && echo "    frame ${idx}/${total} @ ${t}s"
            ffmpeg -nostdin -v error -ss "$t" -i "$in" -frames:v 1 -vf "scale=960:-2" "$outdir/f$(printf '%05d' "$idx").png"
            idx=$((idx+1))
            t=$(awk -v a="$t" -v s="$step" 'BEGIN{printf "%.3f", a+s}')
        done
    else
        echo "  échantillonnage continu (STEP=${step}s) …"
        ffmpeg -nostdin -v error -i "$in" -vf "fps=1/${step},scale=960:-2" "$outdir/f%05d.png"
    fi
}

for nn in "$@"; do
  wc="output/${nn}/webcam.mp4"
  if [ ! -f "$wc" ]; then
    echo "[${nn}] $wc introuvable — lancez d'abord bbb_make_clips.sh ${nn}"; continue
  fi
  W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width  -of csv=p=0 "$wc")
  H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$wc")
  DUR=$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 "$wc")
  echo "[${nn}] analyse de $wc (${W}x${H}, ${DUR}s) …"

    if [ -n "$MANUAL_PLAN" ] || [ -n "$MANUAL_SEGMENTS" ] || [ -n "$FORCE_GRID" ]; then
        if [ -n "$MANUAL_PLAN" ] || [ -n "$MANUAL_SEGMENTS" ]; then
            plan_path=""
            if [ -n "$MANUAL_PLAN" ] && ! plan_path="$(resolve_manual_plan "$MANUAL_PLAN" "$nn")"; then
                echo "[${nn}] MANUAL_PLAN introuvable: ${MANUAL_PLAN}" >&2
                continue
            fi
            if [ -n "$MANUAL_PLAN" ]; then
                plan=$(build_manual_plan "$W" "$H" "$DUR" "$nn" < "$plan_path") || continue
                echo "  plan manuel: ${plan_path}"
            else
                plan=$(printf '%s\n' "$MANUAL_SEGMENTS" | tr ';' '\n' | build_manual_plan "$W" "$H" "$DUR" "$nn") || continue
            fi
            echo "  mode manuel: plan de durées fourni, analyse auto ignorée"
        else
        cols="${FORCE_GRID%x*}"
        rows="${FORCE_GRID#*x}"
        if ! validate_grid "$FORCE_GRID"; then
            echo "[${nn}] FORCE_GRID invalide (${FORCE_GRID}). Format attendu: CxR (ex: 2x2)." >&2
            continue
        fi

        bx=0; by=0; bw="$W"; bh="$H"
        if [ -n "$FORCE_BBOX" ]; then
            oldIFS="$IFS"; IFS=':'; set -- $FORCE_BBOX; IFS="$oldIFS"
            bx="${1:-0}"; by="${2:-0}"; bw="${3:-$W}"; bh="${4:-$H}"
        fi

        bx=$(even_coord "$bx"); by=$(even_coord "$by"); bw=$(even_dim "$bw"); bh=$(even_dim "$bh")
        if [ $((bx + bw)) -gt "$W" ]; then bw=$(even_dim $((W - bx))); fi
        if [ $((by + bh)) -gt "$H" ]; then bh=$(even_dim $((H - by))); fi

        total=$((cols * rows))
        active_list="${FORCE_ACTIVE}"
        [ -z "$active_list" ] && active_list="$(seq 1 "$total" | tr '\n' ',' | sed 's/,$//')"

        plan=""
        k=0
        for idx in $(echo "$active_list" | tr ',;' ' '); do
            [ -z "$idx" ] && continue
            if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "$total" ]; then
                echo "[${nn}] index caméra invalide dans FORCE_ACTIVE: ${idx} (1..${total})" >&2
                continue
            fi
            k=$((k+1))
            c=$(((idx - 1) % cols))
            r=$(((idx - 1) / cols))
            x=$(even_coord $((bx + (c * bw) / cols)))
            y=$(even_coord $((by + (r * bh) / rows)))
            w=$(even_dim $((((c + 1) * bw) / cols - (c * bw) / cols)))
            h=$(even_dim $((((r + 1) * bh) / rows - (r * bh) / rows)))
            plan+="0.00 ${DUR} ${x} ${y} ${w} ${h} ${k} X ${cols}x${rows}"$'\n'
        done

        if [ "$k" -eq 0 ]; then
            echo "[${nn}] aucune caméra active valide (FORCE_ACTIVE=${FORCE_ACTIVE})." >&2
            continue
        fi

        # Remplace le marqueur K total (X) par la valeur finale k.
        plan="$(printf '%s' "$plan" | awk -v K="$k" '{ $8=K; print }')"
        echo "  mode manuel: grille ${cols}x${rows}, ${k} caméra(s) active(s), analyse auto ignorée"
        fi
    else

  tmp=$(mktemp -d)
    sample_frames "$wc" "$tmp" "$STEP" "$DUR"
    echo "  analyse Python …"

  plan=$("$PYTHON" - "$tmp" "$STEP" "$W" "$H" "$DUR" <<'PY'
import sys, glob, numpy as np, PIL.Image as I
frames_dir, step, W, H, DUR = sys.argv[1], float(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5])
files = sorted(glob.glob(f"{frames_dir}/f*.png"))
if not files: sys.exit(0)
grays = np.stack([np.asarray(I.open(f).convert("RGB")).mean(2) for f in files])
N, rh, rw = grays.shape; sx, sy = W/rw, H/rh
# Les webcams BBB sont des tuiles vidéo PLEINES posées sur fond blanc, de tailles
# et de proportions différentes (portrait, paysage, etc.), parfois accolées sans
# gouttière. On ne suppose donc PAS une grille régulière : on détecte les vraies
# tuiles par découpe récursive (gouttières blanches + sauts de couverture), puis
# on recadre chaque tuile au plus juste (sans les bandes blanches de pillarbox).
MINT   = max(8, int(0.045 * rw))   # côté minimal d'une tuile (px échantillonnés)
MINGAP = max(2, int(0.004 * rw))   # largeur minimale d'une gouttière blanche
MINSTEP = 0.15                     # saut de couverture séparant deux tuiles accolées

def content(gs):
    # Tuile = pixel non-blanc dans une FRACTION des trames (vote majoritaire, donc
    # robuste aux transitoires et au bruit d'encodage) OU structure spatiale
    # persistante. La gouttière blanche (plate + fixe) ne remplit aucun des deux.
    dark = (gs < 248).mean(0)
    g = gs.mean(0)
    gx = np.abs(np.diff(g, axis=1, prepend=g[:, :1]))
    gy = np.abs(np.diff(g, axis=0, prepend=g[:1, :]))
    return (dark > 0.40) | ((gx + gy) > 8.0)

def zero_runs(cov, minrun):     # plages où la couverture est nulle (gouttières)
    out=[]; s=None
    for i,v in enumerate(cov):
        if v<=1e-9 and s is None: s=i
        elif v>1e-9 and s is not None:
            if i-s>=minrun: out.append((s,i))
            s=None
    if s is not None and len(cov)-s>=minrun: out.append((s,len(cov)))
    return out

def best_step(cov, minband, minstep):   # meilleur point de rupture de plateau
    # N'accepte une coupure que si les DEUX côtés sont des plateaux PLATS (écart-type
    # absolu faible) : une vraie frontière de cellule est une marche nette entre deux
    # niveaux stables. Une bande de letterbox/pillarbox blanche À L'INTÉRIEUR d'une
    # cellule produit au contraire une « bosse » (niveau A → B → A) : tout point de
    # coupe y laisse un côté non plat, donc elle est rejetée (plus de fausses tranches).
    n=len(cov)
    if n < 2*minband: return None
    ps =np.concatenate([[0.0], np.cumsum(cov)])
    ps2=np.concatenate([[0.0], np.cumsum(cov*cov)])
    best=None; bestd=minstep
    for p in range(minband, n-minband+1):
        lm=(ps[p]-ps[0])/p; rm=(ps[n]-ps[p])/(n-p)
        d=abs(lm-rm)
        if d<=bestd: continue
        lv=max(0.0,(ps2[p]-ps2[0])/p - lm*lm)**0.5
        rv=max(0.0,(ps2[n]-ps2[p])/(n-p) - rm*rm)**0.5
        if lv>0.12 or rv>0.12: continue
        bestd=d; best=p
    return best

def decompose(M, x0,x1,y0,y1, out, depth=0):
    sub=M[y0:y1, x0:x1]
    ys=np.where(sub.any(1))[0]; xs=np.where(sub.any(0))[0]
    if len(xs)==0 or len(ys)==0: return
    x0,x1 = x0+int(xs[0]), x0+int(xs[-1])+1      # recadrage serré sur le contenu
    y0,y1 = y0+int(ys[0]), y0+int(ys[-1])+1
    w,h = x1-x0, y1-y0
    if depth>12 or (w<MINT and h<MINT): out.append((x0,y0,x1,y1)); return
    colcov=M[y0:y1, x0:x1].mean(0); rowcov=M[y0:y1, x0:x1].mean(1)
    vg=[g for g in zero_runs(colcov,MINGAP) if g[0]>0 and g[1]<w]   # gouttière verticale
    if vg:
        cuts=[0]+[(s+e)//2 for s,e in vg]+[w]
        for i in range(len(cuts)-1): decompose(M,x0+cuts[i],x0+cuts[i+1],y0,y1,out,depth+1)
        return
    hg=[g for g in zero_runs(rowcov,MINGAP) if g[0]>0 and g[1]<h]   # gouttière horizontale
    if hg:
        cuts=[0]+[(s+e)//2 for s,e in hg]+[h]
        for i in range(len(cuts)-1): decompose(M,x0,x1,y0+cuts[i],y0+cuts[i+1],out,depth+1)
        return
    ps=best_step(rowcov, max(MINT//2,3), MINSTEP)    # tuiles empilées, largeurs ≠
    if ps is not None:
        decompose(M,x0,x1,y0,y0+ps,out,depth+1); decompose(M,x0,x1,y0+ps,y1,out,depth+1); return
    pv=best_step(colcov, max(MINT//2,3), MINSTEP)    # tuiles côte à côte, hauteurs ≠
    if pv is not None:
        decompose(M,x0,x0+pv,y0,y1,out,depth+1); decompose(M,x0+pv,x1,y0,y1,out,depth+1); return
    out.append((x0,y0,x1,y1))

def detect(M):
    out=[]; decompose(M,0,M.shape[1],0,M.shape[0],out)
    out=[t for t in out if (t[2]-t[0])>=MINT and (t[3]-t[1])>=MINT]
    out.sort(key=lambda t:(round(t[1]/(0.22*M.shape[0])), t[0]))   # ordre lecture: rangées puis colonnes
    return out

# Nombre de caméras par trame (fenêtre ±1) pour segmenter le temps ; la géométrie
# fine est ensuite (re)calculée par segment sur toutes ses trames.
def count_at(i):
    lo,hi=max(0,i-1),min(N,i+2)
    return max(1, len(detect(content(grays[lo:hi]))))
cnt=[count_at(i) for i in range(N)]
sm=[max(set(cnt[max(0,i-1):i+2]),key=cnt[max(0,i-1):i+2].count) for i in range(N)]
# absorbe les plages plus courtes que MINF images (bruit de détection) ; les
# plages adjacentes de même nombre de caméras se recollent alors naturellement.
MINF=max(3, int(round(20/step)))     # ~20 s minimum par segment
def rle(x):
    r=[]; s=0
    for i in range(1,len(x)+1):
        if i==len(x) or x[i]!=x[s]: r.append([x[s],s,i-1]); s=i
    return r
changed=True
while changed:
    changed=False
    for val,a,b in rle(sm):
        if b-a+1<MINF:
            fill = sm[a-1] if a>0 else (sm[b+1] if b+1<N else val)
            for i in range(a,b+1): sm[i]=fill
            changed=True; break
mseg=[[a,b] for _,a,b in rle(sm)]
def ev(v): v=int(round(v)); return v-(v%2)
for si,(a,b) in enumerate(mseg):
    tiles=detect(content(grays[a:b+1]))
    K=len(tiles)
    start=a*step; end=DUR if si==len(mseg)-1 else min((b+1)*step, DUR)
    if K<2:
        print(f"{start:.2f} {end:.2f} 0 0 0 0 0 {K} {K}cam"); continue
    for k,(tx0,ty0,tx1,ty1) in enumerate(tiles, start=1):
        x=ev(tx0*sx); y=ev(ty0*sy); w=ev((tx1-tx0)*sx); h=ev((ty1-ty0)*sy)
        if x+w>W: w=ev(W-x)
        if y+h>H: h=ev(H-y)
        print(f"{start:.2f} {end:.2f} {x} {y} {w} {h} {k} {K} {K}cam")
PY
)
  rm -rf "$tmp"
    fi

    outdir="output/${nn}/webcams"; mkdir -p "$outdir"; : > "$outdir/manifest.txt"
    # Purge les clips d'une exécution précédente : sinon un ancien découpage
    # (plus de segments/caméras) resterait mélangé au nouveau et polluerait la
    # phase 3 (qui prend tous les seg*_cam*.mp4 du dossier).
    rm -f "$outdir"/seg*_cam*.mp4
  hms(){ awk -v s="$1" 'BEGIN{printf "%d:%02d", s/60, int(s)%60}'; }
  made=0
    planf="$outdir/.split_plan.tmp"
    segf="$outdir/.split_segments.tmp"
    printf '%s\n' "$plan" > "$planf"

    # Segments uniques qui ont au moins une tuile à extraire. En auto, les
    # segments à 1 caméra restent sans crop; en manuel, une seule tuile active
    # doit quand même être encodée.
    awk '$7>0 && $5>0 && $6>0{print $1" "$2" "$8" "$9}' "$planf" | awk '!seen[$0]++' > "$segf"
    seg_count=$(wc -l < "$segf" | tr -d ' ')
    echo "  segments à encoder: ${seg_count}"

    # Notes informatives pour les segments à 1 caméra.
    awk '$7==0{print "  "$1" "$2" "$9}' "$planf" | while read -r start end grid; do
        echo "  $(hms "$start")–$(hms "$end")  1 cam (${grid}) — utiliser webcam.mp4" | tee -a "$outdir/manifest.txt"
    done

    # Optimisation majeure: un seul décodage par segment, crops en parallèle via filter_complex.
    seg_idx=0
    while read -r start end K grid; do
        [ -z "${start:-}" ] && continue
        seg_idx=$((seg_idx+1))
        dur=$(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.3f", b-a}')
        echo "  encodage segment ${seg_idx}/${seg_count}: $(hms "$start")–$(hms "$end") (${K} cam)"

        cams_tmp="$outdir/.cams_${start//./_}_${end//./_}.tmp"
        awk -v s="$start" -v e="$end" -v k="$K" '$1==s && $2==e && $8==k {print}' "$planf" > "$cams_tmp"

        build_segment_cmd "$VENC" "$start" "$dur" "$wc" "$cams_tmp" "$outdir"

        while read -r _s _e x y w h kcam _K _grid; do
            out="$outdir/seg$(printf '%04d' "${start%.*}")s_cam${kcam}-of-${K}.mp4"
            made=$((made+1))
            echo "  $(hms "$start")–$(hms "$end")  cam ${kcam}/${K} (${grid})  crop ${w}x${h}+${x}+${y} -> ${out##*/}" | tee -a "$outdir/manifest.txt"
        done < "$cams_tmp"

        if [ "$DRY_RUN" = "1" ]; then
            echo "  DRY_RUN=1 — encodage ffmpeg ignoré"
        else
            if ! "${cmd[@]}"; then
                if [ "$VENC" = "h264_videotoolbox" ] && [ "$STRICT_HW" != "1" ]; then
                    echo "  (h264_videotoolbox indisponible, fallback libx264)" >&2
                    build_segment_cmd "libx264" "$start" "$dur" "$wc" "$cams_tmp" "$outdir"
                    "${cmd[@]}"
                else
                    rm -f "$cams_tmp"
                    exit 1
                fi
            fi
        fi
        rm -f "$cams_tmp"
    done < "$segf"

    rm -f "$planf" "$segf"
  echo "[${nn}] ${made} clip(s) caméra dans $outdir"
done
