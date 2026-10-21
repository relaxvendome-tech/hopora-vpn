#!/bin/bash
# Test de bout en bout sur un Android virtuel : connexion Tor (directe puis
# Snowflake) verifiee par check.torproject.org, et camouflage calculatrice.
set -u
APK="$1"; OUT="$2"; mkdir -p "$OUT"
PKG=com.hopora.hopora_vpn
UI="python3 ci/ui.py"
RES="$OUT/resultats.txt"; : > "$RES"
shot() { adb exec-out screencap -p > "$OUT/$1.png"; }
step() { echo "== $1"; }

adb wait-for-device
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0
adb install -r -g "$APK" || { echo "ECHEC installation" >> "$RES"; exit 1; }
# Autorisation VPN accordee d'avance (equivalent du clic "OK" de l'utilisateur).
adb shell appops set $PKG ACTIVATE_VPN allow
adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null
sleep 12
shot 01-demarrage

tor_test() {   # $1 = methode affichee, $2 = nom du fichier
  $UI tap "$1" || return 1
  sleep 1
  $UI tap "Connect via Tor" || return 1
  $UI tap "I agree, connect" >/dev/null 2>&1 || true
  if $UI wait "Confirmed by torproject.org" 420; then
    shot "$2-ok"; return 0
  fi
  shot "$2-echec"; $UI dump > "$OUT/$2-ecran.txt"; return 1
}

step "Onglet Tor"
$UI tap "Tor" ; sleep 3; shot 02-onglet-tor

step "Tor direct"
if tor_test "Fastest, where Tor is not blocked" 03-tor-direct; then echo "TOR_DIRECT=OK" >> "$RES"; else echo "TOR_DIRECT=ECHEC" >> "$RES"; fi
$UI tap "Disconnect"; sleep 6

step "Tor Snowflake"
if tor_test "Looks like a video call" 04-tor-snowflake; then echo "TOR_SNOWFLAKE=OK" >> "$RES"; else echo "TOR_SNOWFLAKE=ECHEC" >> "$RES"; fi
$UI tap "Disconnect"; sleep 6

adb logcat -d | grep -iE "hopora|TorService|FATAL|AndroidRuntime" | tail -300 > "$OUT/logcat.txt"
echo "--- termine" >> "$RES"
cat "$RES"
