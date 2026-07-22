#!/usr/bin/env bash
# PHASE 3 — Compose la vidéo finale d'une présentation selon le gabarit :
#   fond (assets) + contenu (diapos, deskshare pendant un partage) +
#   caméras isolées (emplacements fixes 16:9, ombre portée, affichées seulement
#   quand elles ont une image) + nom du présentateur (bas gauche) + logo (bas
#   droite). Chaque vidéo démarre par un carton d'intro de 4 s.
#
# Voir le gabarit (schéma à l'échelle) :
#   https://claude.ai/code/artifact/0d9616f0-de4b-4538-ba85-97faa8e9ea14
#
# Entrées (déjà produites par les phases 2 / 2b) :
#   output/NN/webcam.mp4 (audio), output/NN/slides.mp4 et output/NN/deskshare.mp4
#   (au moins l'un des deux : ils alimentent la zone principale, le deskshare
#   par-dessus les diapos pendant un partage), output/NN/webcams/*.mp4,
#   intro : output/NN/intro.{jpeg,jpg,png} (propre à la présentation) ou
#     <dossier>/intro.{jpeg,jpg,png} (commune à toute la session) ; sinon générée,
#   assets/blue-background.png, assets/Tux-FleurDeLys-…png, colonne NOM du cut,
#   et option webcams_priority (dans presentations_cut.yaml).
# Sortie : output/NN/<brand>-<city>-<date>-<short_title>.<presenter>.<lang>.<format>.<encoding>.mp4
#          (1920×1080, H.264, AAC, MP4) et la piste audio seule, même nom en .m4a
#
# Usage : bbb_compose.sh <dossier> NUM...    (ex : bbb_compose.sh 2026-07-07 02)
#   COMPOSE_LIMIT=<s> pour un rendu d'essai court.
#   BBB_AUDIO_TRACK=0 pour ne pas extraire la piste audio séparée.
#   BBB_AUDIO_REENCODE=1 pour ré-encoder l'audio au lieu de le copier.

set -euo pipefail
[ $# -lt 2 ] && { echo "Usage: $0 <dossier> NUM..." >&2; exit 1; }

# Police pour le nom / l'intro
FONT=""
for f in /System/Library/Fonts/Supplemental/Arial.ttf \
         /System/Library/Fonts/Helvetica.ttc \
         /Library/Fonts/Arial.ttf; do
  [ -f "$f" ] && { FONT="$f"; break; }
done
[ -z "$FONT" ] && echo "Attention : aucune police trouvée, le texte pourrait manquer." >&2

# Interpréteur Python : doit avoir Pillow (PIL). Le python3 par défaut du PATH
# peut être un pyenv/venv sans Pillow ; PYTHON=... permet d'en imposer un autre.
PYTHON="${PYTHON:-python3}"
if ! "$PYTHON" -c "import PIL" 2>/dev/null; then
  echo "Erreur : l'interpréteur '$PYTHON' n'a pas Pillow (module PIL)." >&2
  echo "  → installez-le : pip3 install pillow" >&2
  echo "  → ou pointez PYTHON vers un interpréteur qui l'a :" >&2
  for c in /opt/homebrew/bin/python3 /usr/local/bin/python3 \
           /Library/Frameworks/Python.framework/Versions/*/bin/python3; do
    [ -x "$c" ] && "$c" -c "import PIL" 2>/dev/null \
      && { echo "      relancez avec :  PYTHON=$c $0 ..." >&2; break; }
  done
  exit 1
fi

COMPOSE_FONT="$FONT" "$PYTHON" - "$@" <<'PY'
import sys, os, glob, re, subprocess, tempfile, unicodedata
from PIL import Image, ImageDraw, ImageFont

rec = sys.argv[1]; nums = sys.argv[2:]
os.chdir(rec)
FONT = os.environ.get("COMPOSE_FONT","")
LIMIT = os.environ.get("COMPOSE_LIMIT","")
VENC_NAME = os.environ.get("BBB_VENC", "h264_videotoolbox")
STRICT_HW = os.environ.get("BBB_STRICT_HW", "0") == "1"

BG   = "../assets/blue-background.png"
LOGO = "../assets/Tux-FleurDeLys-shadow-RLQ-v2-fondTransp.2160x2160.png"
for p in (BG, LOGO):
    if not os.path.exists(p): sys.exit(f"Introuvable : {p}")

W,H = 1920,1080
MAIN = (48,132,1440,810)               # x,y,w,h
SLOTS = [(1456,96),(1456,340),(1456,584)]
SLOTW,SLOTH = 384,216
LOGO_BOX = (1680,840,200,200)
NAME_X,NAME_Y = 48,966
INTRO_DUR = 4
AENC_REENCODE = ["-c:a","aac","-b:a","192k","-ar","48000","-ac","2"]

def audio_encoder(src):
    # L'audio de webcam.mp4 est déjà de l'AAC-LC 48 kHz stéréo (phase 2), et la
    # source BBB est à ~65 kb/s : le ré-encoder ici n'ajoute rien, ce serait une
    # 3e génération lossy pour ~2 min de CPU par vidéo. On copie donc le flux tel
    # quel. Seul effet de bord : la troncature à bdur tombe sur une frontière de
    # paquet AAC (~21 ms). BBB_AUDIO_REENCODE=1 pour forcer le ré-encodage, et on
    # y retombe aussi si le flux n'est pas de l'AAC muxable en MP4.
    if os.environ.get("BBB_AUDIO_REENCODE","0") == "1":
        return AENC_REENCODE, "ré-encodé AAC 192k"
    codec = (probe(src, "stream=codec_name", stream="a:0") or [""])[0]
    if codec == "aac":
        return ["-c:a","copy"], "audio copié"
    print(f"  (audio '{codec or 'inconnu'}' non copiable, ré-encodage AAC)", file=sys.stderr)
    return AENC_REENCODE, "ré-encodé AAC 192k"

def video_encoder(bitrate, crf):
    if VENC_NAME == "h264_videotoolbox":
        primary = [
            "-c:v", "h264_videotoolbox",
            "-b:v", bitrate,
            "-pix_fmt", "yuv420p",
            "-r", "30",
            "-profile:v", "high",
            "-prio_speed", "1",
        ]
        fallback = None if STRICT_HW else ["-c:v", "libx264", "-preset", "veryfast", "-crf", crf, "-pix_fmt", "yuv420p", "-r", "30"]
        return primary, fallback
    if VENC_NAME == "libx264":
        return ["-c:v", "libx264", "-preset", "veryfast", "-crf", crf, "-pix_fmt", "yuv420p", "-r", "30"], None
    return ["-c:v", VENC_NAME, "-pix_fmt", "yuv420p", "-r", "30"], None

VENC, VENC_FALLBACK = video_encoder("12M", "20")

def _font(sz):
    try: return ImageFont.truetype(FONT, sz)
    except Exception: return ImageFont.load_default()
def render_name(nom, path):
    f=_font(46); d=ImageDraw.Draw(Image.new("RGBA",(4,4)))
    b=d.textbbox((0,0),nom,font=f); tw,th=b[2]-b[0],b[3]-b[1]; px,py=26,16
    im=Image.new("RGBA",(tw+2*px,th+2*py),(0x2C,0x7D,0x55,255))
    ImageDraw.Draw(im).text((px-b[0],py-b[1]),nom,font=f,fill=(255,255,255,255))
    im.save(path)
def gen_intro(title, path):
    im=Image.open(BG).convert("RGB"); sc=max(W/im.width,H/im.height)
    im=im.resize((int(im.width*sc),int(im.height*sc)))
    l=(im.width-W)//2; t=(im.height-H)//2; im=im.crop((l,t,l+W,t+H))
    d=ImageDraw.Draw(im,"RGBA"); f=_font(84)
    b=d.textbbox((0,0),title,font=f); tw,th=b[2]-b[0],b[3]-b[1]
    x=(W-tw)//2-b[0]; y=(H-th)//2-b[1]
    d.rectangle([x+b[0]-34,y+b[1]-24,x+b[0]+tw+34,y+b[1]+th+24],fill=(0,0,0,120))
    d.text((x,y),title,font=f,fill=(255,255,255,255))
    im.save(path)

def sh(cmd): subprocess.run(cmd, check=True)
def sh_progress(cmd, total, label):
    # Lance ffmpeg en affichant un pourcentage d'avancement : -progress fait écrire
    # « out_time_us=<microsecondes encodées> » sur stdout, comparé à la durée totale.
    full = [cmd[0], "-progress", "pipe:1", "-nostats"] + cmd[1:]
    p = subprocess.Popen(full, stdout=subprocess.PIPE, text=True, bufsize=1)
    last = -1
    for line in p.stdout:
        line = line.strip()
        if line.startswith(("out_time_us=", "out_time_ms=")):   # les deux sont en µs
            v = line.split("=", 1)[1]
            if not v.lstrip("-").isdigit():
                continue
            pct = 0 if total <= 0 else min(100, int(int(v) / 1e6 / total * 100))
            if pct != last:
                last = pct
                print(f"\r{label} {pct:3d}%", end="", file=sys.stderr, flush=True)
    p.wait()
    if last >= 0:
        print(f"\r{label} 100%", file=sys.stderr)
    if p.returncode != 0:
        raise subprocess.CalledProcessError(p.returncode, cmd)
def sh_with_fallback(cmd, fallback_cmd, total=0, label=""):
    try:
        sh_progress(cmd, total, label) if total else sh(cmd)
    except subprocess.CalledProcessError:
        if not fallback_cmd:
            raise
        print("[encode] h264_videotoolbox indisponible, fallback libx264", file=sys.stderr)
        sh_progress(fallback_cmd, total, label) if total else sh(fallback_cmd)
def probe(path, entries, stream="v:0"):
    out = subprocess.run(["ffprobe","-v","error","-select_streams",stream,
        "-show_entries",entries,"-of","default=nk=1:nw=1",path],
        capture_output=True, text=True).stdout.split()
    return out
def dur(path):
    return float(subprocess.run(["ffprobe","-v","error","-show_entries",
        "format=duration","-of","default=nk=1:nw=1",path],
        capture_output=True,text=True).stdout.strip())
def to_s(t):
    t=t.strip()
    if ":" in t:
        p=[float(x) for x in t.split(":")]
        return p[0]*3600+p[1]*60+p[2] if len(p)==3 else p[0]*60+p[1]
    return float(t)
def even(v): v=int(round(v)); return v-(v%2)
def fit(sw,sh,bw,bh):
    s=min(bw/sw,bh/sh); return even(sw*s), even(sh*s)

def _strip_comment(v):
    # Retire un commentaire « # ... » en fin de ligne, sans toucher un « # »
    # à l'intérieur d'une valeur entre guillemets. En YAML, un « # » n'ouvre un
    # commentaire que s'il est précédé d'un espace (ou en début de valeur).
    out=[]; quote=None; prev_space=True
    for ch in v:
        if quote:
            out.append(ch)
            if ch==quote: quote=None
            prev_space=False
        elif ch in ('"',"'"):
            quote=ch; out.append(ch); prev_space=False
        elif ch=='#' and prev_space:
            break
        else:
            out.append(ch); prev_space=ch.isspace()
    return ''.join(out).rstrip()

def _u(v):
    v=_strip_comment(v.strip())
    if len(v)>=2 and ((v[0]=='"' and v[-1]=='"') or (v[0]=="'" and v[-1]=="'")):
        v=v[1:-1]
    return v

def parse_priority(v):
    if not v: return []
    v=_strip_comment(v.strip())
    if v.startswith('[') and v.endswith(']'):
        vals=[x.strip() for x in v[1:-1].split(',') if x.strip()]
    else:
        vals=[x.strip() for x in v.replace(';',',').split(',') if x.strip()]
    out=[]
    for x in vals:
        try:
            n=int(x)
            if n not in out:
                out.append(n)
        except Exception:
            pass
    return out

def token(s, fallback="NA"):
    s = (s or "").strip()
    if not s:
        s = fallback
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode("ascii")
    s = re.sub(r"\s+", "_", s)
    s = re.sub(r"[^A-Za-z0-9_-]", "_", s)
    s = re.sub(r"_+", "_", s).strip("_")
    return s or fallback

def rec_date_default(rec_dir):
    m = re.search(r"(\d{4})-(\d{2})-(\d{2})", rec_dir)
    if m:
        return f"{m.group(1)}{m.group(2)}{m.group(3)}"
    return "00000000"

def presenter_filename_token(full_name):
    s = (full_name or "").strip()
    if not s:
        return ""
    # Conserver seulement alnum/espaces pour découper proprement les mots du nom.
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode("ascii")
    s = re.sub(r"[^A-Za-z0-9\s-]", " ", s)
    parts = [p for p in re.split(r"[\s-]+", s) if p]
    if not parts:
        return ""
    first = parts[0]
    if len(parts) == 1:
        return token(first, "")
    last_initial = parts[-1][0]
    return token(f"{first}{last_initial}", "")

def output_name(meta, nn, info, presenter):
    brand    = token(meta.get("brand", "RLQ"), "RLQ")
    city     = token(meta.get("city", "CITY"), "CITY")
    date     = token(meta.get("date", rec_date_default(rec)), rec_date_default(rec))
    short_t  = token(meta.get("short_title", ""), "")
    pres     = presenter_filename_token(meta.get("presenter", presenter))
    lang     = token(meta.get("language", "FR"), "FR")
    fmt      = token(meta.get("format", "1080p"), "1080p")
    enc      = token(meta.get("encoding", "h264"), "h264")
    return f"{brand}-{city}-{date}-{short_t}.{pres}.{lang}.{fmt}.{enc}.mp4"

def require_strict_metadata(meta, nn):
    missing = []
    short_t = token(meta.get("short_title", ""), "")
    pres = token(meta.get("presenter", ""), "")
    if not short_t:
        missing.append("short_title")
    if not pres:
        missing.append("presenter")
    if missing:
        fields = ", ".join(missing)
        sys.exit(f"[{nn}] metadata manquante ou vide dans presentations_cut.yaml: {fields}")

def load_cut_map():
    cut={}
    defaults={}
    if os.path.exists("presentations_cut.yaml"):
        cur=None
        for raw in open("presentations_cut.yaml",encoding="utf-8"):
            if not raw.strip() or raw.lstrip().startswith('#'):
                continue
            m_def = re.match(r'^([a-zA-Z_][a-zA-Z0-9_]*)\s*:\s*(.*?)\s*$', raw)
            if m_def:
                k, v = m_def.group(1), _u(m_def.group(2))
                if k not in ('presentations',):
                    defaults[k] = v
                continue
            m_new=re.match(r'^\s*-\s*num\s*:\s*(.+?)\s*$', raw)
            if m_new:
                if cur and cur.get('num'):
                    cut[cur['num']] = (to_s(cur.get('start','0')), to_s(cur.get('end','0')),
                                       cur.get('presenter',''), cur.get('info',''),
                                       parse_priority(cur.get('webcams_priority','')),
                                       {
                                           'brand': cur.get('brand',''),
                                           'city': cur.get('city',''),
                                           'date': cur.get('date',''),
                                           'short_title': cur.get('short_title',''),
                                           'presenter': cur.get('presenter',''),
                                           'language': cur.get('language',''),
                                           'format': cur.get('format',''),
                                           'encoding': cur.get('encoding','')
                                       })
                cur={'num':_u(m_new.group(1)),'start':'','end':'','presenter':'','info':'','webcams_priority':'',
                     'brand':'','city':'','date':'','short_title':'','language':'','format':'','encoding':''}
                continue
            if not cur:
                continue
            m_kv=re.match(r'^\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*:\s*(.*?)\s*$', raw)
            if not m_kv:
                continue
            k,v=m_kv.group(1),m_kv.group(2)
            if k=='nom':
                k='presenter'
            if k in ('start','end','presenter','info','webcams_priority','brand','city','date','short_title','language','format','encoding'):
                cur[k]=_u(v)
        if cur and cur.get('num'):
            cut[cur['num']] = (to_s(cur.get('start','0')), to_s(cur.get('end','0')),
                               cur.get('presenter',''), cur.get('info',''),
                               parse_priority(cur.get('webcams_priority','')),
                               {
                                   'brand': cur.get('brand',''),
                                   'city': cur.get('city',''),
                                   'date': cur.get('date',''),
                                   'short_title': cur.get('short_title',''),
                                   'presenter': cur.get('presenter',''),
                                   'language': cur.get('language',''),
                                   'format': cur.get('format',''),
                                   'encoding': cur.get('encoding','')
                               })
        return cut, defaults

    if os.path.exists("presentations_cut.txt"):
        for ln in open("presentations_cut.txt",encoding="utf-8"):
            s=ln.rstrip("\n")
            if not s.strip() or s.lstrip().startswith("#"):
                continue
            parts=[x.strip() for x in s.split("|")]
            if len(parts)<5:
                continue
            cut[parts[0]]=(to_s(parts[1]),to_s(parts[2]),parts[3],parts[4],[],{})
        return cut, defaults

    sys.exit("Introuvable: presentations_cut.yaml ou presentations_cut.txt")

# --- cut file : NN -> (start,end,nom,info,webcams_priority[],meta{}) ---
cut, defaults = load_cut_map()

# --- deskshare events (temps session) ---
ds_events=[]
if os.path.exists("deskshare.xml"):
    xml=open("deskshare.xml").read()
    for m in re.finditer(r'start_timestamp="([0-9.]+)".*?stop_timestamp="([0-9.]+)"',xml):
        ds_events.append((float(m.group(1)),float(m.group(2))))

def escape_text(s):  # pour un fichier textfile de drawtext
    return s

def render(nn):
    od=f"output/{nn}"
    slides=f"{od}/slides.mp4"
    webcam=f"{od}/webcam.mp4"
    deskshare=f"{od}/deskshare.mp4"
    if nn not in cut: print(f"[{nn}] absent de presentations_cut.txt — ignoré"); return
    dstart,dend,nom,info,webcams_priority,meta = cut[nn]
    full_meta = {**defaults, **{k:v for k,v in meta.items() if v}}
    require_strict_metadata(full_meta, nn)
    # Clips périmés : la fenêtre stampée par la phase 2 doit correspondre au YAML.
    wf=f"{od}/window.txt"
    if os.path.exists(wf):
        st={}
        for ln in open(wf):
            if "=" in ln: k,v=ln.strip().split("=",1); st[k]=v
        try:
            sss=float(st["ss"]); eee=float(st["ee"])
            if abs(sss-dstart)>0.5 or abs(eee-dend)>0.5:
                print(f"[{nn}] ⚠ clips générés pour la fenêtre [{sss:.0f}..{eee:.0f}]s "
                      f"mais le YAML dit [{dstart:.0f}..{dend:.0f}]s — relancez la "
                      f"phase 2 (bbb_make_clips.sh {nn}) pour régénérer output/{nn}.")
        except (KeyError, ValueError):
            pass
    # La zone MAIN accepte les diapos, le partage d'écran, ou les deux.
    have_slides = os.path.exists(slides)
    have_ds     = os.path.exists(deskshare)
    if not have_slides and not have_ds:
        print(f"[{nn}] ni slides.mp4 ni deskshare.mp4 — ignoré"); return
    # Durée maître = fenêtre complète du clip. La webcam (source de l'audio) et le
    # deskshare couvrent toujours [start,end] ; slides.mp4 peut être plus court
    # (diapos BBB présentes sur une partie seulement de la fenêtre) — s'y fier
    # tronquerait la vidéo finale. On prend donc la plus longue piste disponible.
    def _dur0(p): return dur(p) if os.path.exists(p) else 0.0
    bdur = max(_dur0(webcam), _dur0(deskshare), _dur0(slides))
    if LIMIT: bdur=min(bdur,float(LIMIT))
    tmp=tempfile.mkdtemp()

    # ---------- COMPOSITION ----------
    ins=[]; fc=[]; ii=0
    def add_in(*args):
        nonlocal ii
        ins.extend(args); idx=ii; ii+=1; return idx
    bg_i     = add_in("-loop","1","-framerate","30","-t",f"{bdur}","-i",BG)
    if have_slides: slides_i = add_in("-i",slides)
    if have_ds: ds_i = add_in("-i",deskshare)
    logo_i   = add_in("-loop","1","-framerate","30","-t",f"{bdur}","-i",LOGO)
    wc_i     = add_in("-i",webcam)

    # Intro affichée en overlay pendant les 4 premières secondes (sans allonger la durée).
    intro_src=None
    intro_generated=False
    # Intro : d'abord propre à la présentation (output/NN/intro.*), sinon une
    # intro commune à la session à la racine du dossier (intro.*), sinon générée.
    for bdir in (od, "."):
        for e in ("intro.jpeg","intro.jpg","intro.png"):
            if os.path.exists(f"{bdir}/{e}"):
                intro_src=f"{bdir}/{e}"; break
        if intro_src: break
    if not intro_src:
        title = nom or re.sub(r"^\d+\s*diapos\s*—\s*","",info).strip() or nn
        intro_src=os.path.join(tmp,"introgen.png")
        gen_intro(title,intro_src)
        intro_generated=True
    intro_i = add_in("-loop","1","-framerate","30","-t",f"{INTRO_DUR}","-i",intro_src)

    fc.append(f"[{bg_i}:v]scale={W}:{H},setsar=1,fps=30,format=yuv420p[base]")
    cur="base"; step=0
    if have_slides:
        fc.append(f"[{slides_i}:v]scale={MAIN[2]}:{MAIN[3]},setsar=1[slid]")
        fc.append(f"[base][slid]overlay={MAIN[0]}:{MAIN[1]}:shortest=0[m0]")
        cur="m0"; step=1

    if have_ds:
        iv=[]
        for a,b in ds_events:
            lo,hi=max(a,dstart),min(b,dend)
            if hi>lo: iv.append((lo-dstart,hi-dstart))
        if iv:
            en="+".join(f"between(t,{a:.2f},{b:.2f})" for a,b in iv)
            fc.append(f"[{ds_i}:v]scale={MAIN[2]}:{MAIN[3]},setsar=1[ds]")
            fc.append(f"[{cur}][ds]overlay={MAIN[0]}:{MAIN[1]}:enable='{en}':shortest=0[m{step}]")
            cur=f"m{step}"; step+=1

    if cur=="base":
        print(f"[{nn}] avertissement : zone principale vide "
              f"(aucune diapo, aucun partage d'écran dans la fenêtre)")

    # caméras
    cams=sorted(glob.glob(f"{od}/webcams/seg*_cam*.mp4"))

    # slot caméra: par défaut cam1->slot1, cam2->slot2...;
    # si webcams_priority est fourni, il définit l'ordre des slots.
    slot_by_cam = {}
    if webcams_priority:
        for slot_i, cam_i in enumerate(webcams_priority, start=1):
            if 1 <= slot_i <= len(SLOTS):
                slot_by_cam[cam_i] = slot_i

    for cp in cams:
        m=re.search(r"seg(\d+)s_cam(\d+)-of-(\d+)",os.path.basename(cp))
        if not m: continue
        seg=int(m.group(1)); raw_k=int(m.group(2))
        k=slot_by_cam.get(raw_k, raw_k)
        if k>len(SLOTS): continue
        w,h = [int(x) for x in probe(cp,"stream=width,height")[:2]]
        cdur=dur(cp); s_end=seg+cdur
        fw,fh=fit(w,h,SLOTW,SLOTH)
        sx,sy=SLOTS[k-1]
        cx=sx+(SLOTW-fw)//2; cy=sy+(SLOTH-fh)//2
        ci=add_in("-i",cp)
        en=f"between(t,{seg},{s_end:.2f})"
        # Carte blanche à la taille EXACTE du slot : si la caméra n'a pas le
        # format 16:9 du slot (portrait, paysage étroit…), les zones non
        # couvertes sont comblées en blanc au lieu de laisser voir le fond.
        # Ombre portée douce autour de la carte (et non de la vidéo) pour un
        # rendu uniforme quel que soit le format de la caméra.
        fc.append(f"color=c=#00000000:s={SLOTW+32}x{SLOTH+32}:r=30,format=rgba,"
                  f"drawbox=x=16:y=16:w={SLOTW}:h={SLOTH}:color=black@0.5:t=fill,boxblur=10[sh{k}]")
        fc.append(f"color=c=white:s={SLOTW}x{SLOTH}:r=30,setsar=1,format=yuv420p[card{k}]")
        fc.append(f"[{ci}:v]scale={fw}:{fh},setsar=1,setpts=PTS+{seg}/TB[cam{k}]")
        fc.append(f"[{cur}][sh{k}]overlay={sx-12}:{sy-8}:enable='{en}':shortest=0[m{step}]"); cur=f"m{step}"; step+=1
        fc.append(f"[{cur}][card{k}]overlay={sx}:{sy}:enable='{en}':shortest=0[m{step}]"); cur=f"m{step}"; step+=1
        fc.append(f"[{cur}][cam{k}]overlay={cx}:{cy}:enable='{en}':eof_action=pass:shortest=0[m{step}]"); cur=f"m{step}"; step+=1

    # nom (plaque texte rendue en PNG par PIL)
    if nom:
        npng=os.path.join(tmp,"name.png"); render_name(nom,npng)
        name_i=add_in("-loop","1","-framerate","30","-t",f"{bdur}","-i",npng)
        fc.append(f"[{cur}][{name_i}:v]overlay={NAME_X}:{NAME_Y}:shortest=0[m{step}]")
        cur=f"m{step}"; step+=1

    # logo
    lw,lh=fit(*[int(x) for x in probe(LOGO,'stream=width,height')[:2]],LOGO_BOX[2],LOGO_BOX[3])
    lx=LOGO_BOX[0]+(LOGO_BOX[2]-lw); ly=LOGO_BOX[1]+(LOGO_BOX[3]-lh)
    fc.append(f"[{logo_i}:v]scale={lw}:{lh}[logo]")
    fc.append(f"[{cur}][logo]overlay={lx}:{ly}:shortest=0[vbase]")

    # Intro par-dessus la vidéo pendant les 4 premières secondes.
    fc.append(f"[{intro_i}:v]scale={W}:{H}:force_original_aspect_ratio=increase,crop={W}:{H},setsar=1,fps=30,format=yuv420p[intro]")
    fc.append(f"[vbase][intro]overlay=0:0:enable='between(t,0,{INTRO_DUR})':shortest=0[outv]")

    out_name = output_name(full_meta, nn, info, nom)
    # Rendu d'essai (COMPOSE_LIMIT) : nom distinct pour ne jamais le confondre
    # avec la vidéo finale (et le retrouver/supprimer facilement).
    if LIMIT:
        out_name = re.sub(r"\.mp4$", ".preview.mp4", out_name)
    out=f"{od}/{out_name}"
    AENC, aenc_label = audio_encoder(webcam)
    print(f"[{nn}] composition ({bdur:.0f}s, {len(cams)} caméra(s)"
          f"{' + diapos' if have_slides else ''}{' + deskshare' if have_ds else ''}"
          f"{' + nom' if nom else ''}{' + priorité cams' if webcams_priority else ''}, intro 0-{INTRO_DUR}s"
          f"{' (générée)' if intro_generated else ''}, encodeur {VENC_NAME}{' strict' if STRICT_HW else ''}"
          f", {aenc_label}) …")
    base_cmd = ["ffmpeg","-nostdin","-v","error","-y",*ins,
        "-filter_complex",";".join(fc),
        "-map","[outv]","-map",f"{wc_i}:a","-t",f"{bdur}",
        *VENC,*AENC,"-movflags","+faststart",out]
    fallback_cmd = None
    if VENC_FALLBACK:
        fallback_cmd = ["ffmpeg","-nostdin","-v","error","-y",*ins,
            "-filter_complex",";".join(fc),
            "-map","[outv]","-map",f"{wc_i}:a","-t",f"{bdur}",
            *VENC_FALLBACK,*AENC,"-movflags","+faststart",out]
    sh_with_fallback(base_cmd, fallback_cmd, bdur, f"  [{nn}] encodage")
    tag = "  (RENDU D'ESSAI — pas la vidéo finale)" if LIMIT else ""
    print(f"[{nn}] ✓ {out}  (durée ~{bdur:.0f}s, intro superposée 0-{INTRO_DUR}s){tag}")

    # Piste audio seule, extraite de la vidéo finale par simple copie de flux
    # (aucun ré-encodage, ~1 s) : elle est donc synchrone avec elle par
    # construction — même origine des temps (t=0 = début du clip), même durée.
    # BBB_AUDIO_TRACK=0 pour ne pas la produire.
    if os.environ.get("BBB_AUDIO_TRACK","1") != "0":
        aout = re.sub(r"\.mp4$", ".m4a", out)
        try:
            sh(["ffmpeg","-nostdin","-v","error","-y","-i",out,
                "-vn","-c:a","copy","-movflags","+faststart",aout])
            print(f"[{nn}] ✓ {aout}  (piste audio seule, AAC)")
        except subprocess.CalledProcessError:
            print(f"[{nn}] ⚠ extraction de la piste audio échouée (pas d'audio ?)")

    subprocess.run(["rm","-rf",tmp])

for nn in nums:
    render(nn)
PY
