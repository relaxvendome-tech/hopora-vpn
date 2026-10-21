"""Pilote l'interface Android (uiautomator) pour le test de bout en bout.

  python3 ci/ui.py tap "Texte"          -> touche l'element le plus court contenant ce texte
  python3 ci/ui.py wait "Texte" 300     -> attend que le texte apparaisse (secondes)
  python3 ci/ui.py dump                 -> affiche les textes visibles
"""
import re, subprocess, sys, time
import xml.etree.ElementTree as ET


def nodes():
    subprocess.run(["adb", "shell", "uiautomator", "dump", "/sdcard/ui.xml"],
                   capture_output=True, timeout=60)
    raw = subprocess.run(["adb", "exec-out", "cat", "/sdcard/ui.xml"],
                         capture_output=True, timeout=60).stdout.decode("utf-8", "ignore")
    try:
        root = ET.fromstring(raw[raw.index("<?xml"):] if "<?xml" in raw else raw)
    except Exception:
        return []
    out = []
    for n in root.iter("node"):
        label = (n.get("text") or "") + " " + (n.get("content-desc") or "")
        label = label.strip()
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", n.get("bounds") or "")
        if label and m:
            x1, y1, x2, y2 = map(int, m.groups())
            out.append((label, (x1 + x2) // 2, (y1 + y2) // 2))
    return out


def find(text):
    hits = [n for n in nodes() if text.lower() in n[0].lower()]
    return min(hits, key=lambda n: len(n[0])) if hits else None


cmd = sys.argv[1]
if cmd == "dump":
    for n in nodes():
        print(repr(n[0])[:120])
elif cmd == "tap":
    # Cherche l'element ; s'il n'est pas a l'ecran, fait defiler (bas puis haut).
    swipes = [None, None, "up", "up", "up", "down", "down", "down", "down", "up", None, None]
    for sw in swipes:
        n = find(sys.argv[2])
        if n:
            subprocess.run(["adb", "shell", "input", "tap", str(n[1]), str(n[2])])
            print("TAP", repr(n[0])[:80])
            sys.exit(0)
        if sw == "up":
            subprocess.run(["adb", "shell", "input", "swipe", "540", "1500", "540", "700", "300"])
        elif sw == "down":
            subprocess.run(["adb", "shell", "input", "swipe", "540", "700", "540", "1500", "300"])
        time.sleep(2)
    print("INTROUVABLE", sys.argv[2])
    sys.exit(1)
elif cmd == "wait":
    end = time.time() + int(sys.argv[3])
    while time.time() < end:
        n = find(sys.argv[2])
        if n:
            print("OK", repr(n[0])[:120])
            sys.exit(0)
        time.sleep(5)
    print("DELAI DEPASSE", sys.argv[2])
    sys.exit(1)
