#!/usr/bin/env bash
# PHASE 2b (optionnel) — Sépare le clip webcam d'une présentation en flux caméra
# isolés, par détection d'image (BBB ne publie aucune métadonnée de webcams).
#
# Travaille sur output/NN/webcam.mp4 (déjà produit par bbb_make_clips.sh) : on
# n'analyse que les présentations demandées, pas toute la session.
#
# Méthode : échantillonne le clip, détecte la grille de webcams BBB au fil du
# temps (boîte de contenu sur fond blanc + coupures aux divisions égales via la
# chute de corrélation entre colonnes/rangées, cellules vides ignorées), segmente
# en plages de disposition stable, puis découpe chaque tuile active.
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
VIDEO_CODEC="${VIDEO_CODEC:-h264_videotoolbox}"
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
WHITE, WIN, SEAM_THR, EMPTY = 240, 2, 0.86, 0.92
imgs   = [np.asarray(I.open(f).convert("RGB")) for f in files]
grays  = [im.mean(2) for im in imgs]
whites = [(im > WHITE).all(2) for im in imgs]
rh, rw = grays[0].shape; N = len(files); sx, sy = W/rw, H/rh
def bbox(w):
    r=w.mean(1); c=w.mean(0); rc=np.where(r<.985)[0]; cc=np.where(c<.985)[0]
    return None if len(rc)<3 or len(cc)<3 else (int(cc.min()),int(cc.max()),int(rc.min()),int(rc.max()))
def colc(g,y0,y1):
    S=g[y0:y1+1]; M=S-S.mean(0)
    return (M[:,:-1]*M[:,1:]).sum(0)/(np.sqrt((M[:,:-1]**2).sum(0)*(M[:,1:]**2).sum(0))+1e-6)
def rowc(g,x0,x1):
    S=g[:,x0:x1+1]; M=S-S.mean(1,keepdims=1)
    return (M[:-1]*M[1:]).sum(1)/(np.sqrt((M[:-1]**2).sum(1)*(M[1:]**2).sum(1))+1e-6)
def decide(p,a0,a1,mx):
    best=1
    for C in range(2,mx+1):
        if all(p[max(0,a0+k*(a1-a0+1)//C-3):a0+k*(a1-a0+1)//C+4].min()<SEAM_THR for k in range(1,C)):
            best=C
    return best
def count(i):
    bb=bbox(whites[i])
    if not bb: return 0
    x0,x1,y0,y1=bb; lo,hi=max(0,i-WIN),min(N,i+WIN+1)
    C=decide(np.mean([colc(grays[j],y0,y1) for j in range(lo,hi)],0),x0,x1,3)
    R=decide(np.mean([rowc(grays[j],x0,x1) for j in range(lo,hi)],0),y0,y1,2)
    n=0
    for r in range(R):
        for c in range(C):
            cx0=x0+c*(x1-x0+1)//C; cx1=x0+(c+1)*(x1-x0+1)//C
            cy0=y0+r*(y1-y0+1)//R; cy1=y0+(r+1)*(y1-y0+1)//R
            if whites[i][cy0:cy1,cx0:cx1].mean()<EMPTY: n+=1
    return max(n,1)
cnt=[count(i) for i in range(N)]
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
    bbs=[bbox(whites[i]) for i in range(a,b+1)]; bbs=[x for x in bbs if x]
    if not bbs: continue
    A=np.array(bbs); x0,x1,y0,y1=[int(np.median(A[:,k])) for k in range(4)]
    lo,hi=a,b+1
    C=decide(np.mean([colc(grays[j],y0,y1) for j in range(lo,hi)],0),x0,x1,3)
    R=decide(np.mean([rowc(grays[j],x0,x1) for j in range(lo,hi)],0),y0,y1,2)
    mw=np.mean([whites[j].astype(np.float32) for j in range(lo,hi)],axis=0)  # fraction blanc/pixel
    cells=[]
    for r in range(R):
        for c in range(C):
            cx0=x0+c*(x1-x0+1)//C; cx1=x0+(c+1)*(x1-x0+1)//C
            cy0=y0+r*(y1-y0+1)//R; cy1=y0+(r+1)*(y1-y0+1)//R
            cells.append((cx0,cy0,cx1,cy1, mw[cy0:cy1,cx0:cx1].mean()<EMPTY))
    K=sum(1 for cc in cells if cc[4])
    start=a*step; end=DUR if si==len(mseg)-1 else min((b+1)*step, DUR)
    if K<2:
        print(f"{start:.2f} {end:.2f} 0 0 0 0 0 {K} {C}x{R}"); continue
    k=0
    for (cx0,cy0,cx1,cy1,active) in cells:
        if not active: continue
        k+=1
        # on garde la tuile ENTIÈRE (ratio de cellule uniforme, réutilisable en gabarit)
        x=ev(cx0*sx); y=ev(cy0*sy); w=ev((cx1-cx0)*sx); h=ev((cy1-cy0)*sy)
        if x+w>W: w=ev(W-x)
        if y+h>H: h=ev(H-y)
        print(f"{start:.2f} {end:.2f} {x} {y} {w} {h} {k} {K} {C}x{R}")
PY
)
  rm -rf "$tmp"
    fi

    outdir="output/${nn}/webcams"; mkdir -p "$outdir"; : > "$outdir/manifest.txt"
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

        fc=""
        cmd=(ffmpeg -y -nostdin -v error -ss "$start" -i "$wc")
        idx=0
        while read -r _s _e x y w h kcam _K _grid; do
            idx=$((idx+1))
            fc+="[0:v]crop=${w}:${h}:${x}:${y}[v${idx}];"
        done < "$cams_tmp"
        fc="${fc%;}"
        cmd+=(-filter_complex "$fc")

        idx=0
        while read -r _s _e x y w h kcam _K _grid; do
            idx=$((idx+1))
            out="$outdir/seg$(printf '%04d' "${start%.*}")s_cam${kcam}-of-${K}.mp4"
            cmd+=(-map "[v${idx}]" -map 0:a? -t "$dur" -c:v "$VIDEO_CODEC" -b:v "$VIDEO_BITRATE" -c:a aac -b:a "$AUDIO_BITRATE" -movflags +faststart "$out")
            made=$((made+1))
            echo "  $(hms "$start")–$(hms "$end")  cam ${kcam}/${K} (${grid})  crop ${w}x${h}+${x}+${y} -> ${out##*/}" | tee -a "$outdir/manifest.txt"
        done < "$cams_tmp"

        if [ "$DRY_RUN" = "1" ]; then
            echo "  DRY_RUN=1 — encodage ffmpeg ignoré"
        else
            "${cmd[@]}"
        fi
        rm -f "$cams_tmp"
    done < "$segf"

    rm -f "$planf" "$segf"
  echo "[${nn}] ${made} clip(s) caméra dans $outdir"
done
