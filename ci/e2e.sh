#!/bin/bash
# Test de bout en bout sur un Android virtuel, sans piloter l'ecran :
# la version de test (debuggable) recoit l'ordre de se connecter a Tor par
# une intention, puis ecrit son verdict (verifie par check.torproject.org)
# dans le journal Android.
set -u
APK="$1"; OUT="$2"; mkdir -p "$OUT"
PKG=com.hopora.hopora_vpn
RES="$OUT/resultats.txt"; : > "$RES"

adb wait-for-device
adb install -r -g "$APK" > "$OUT/installation.txt" 2>&1 || { echo "INSTALLATION=ECHEC" >> "$RES"; cat "$OUT/installation.txt" >> "$RES"; exit 0; }
# Autorisation VPN accordee d'avance (equivalent du clic "OK" de l'utilisateur).
adb shell appops set $PKG ACTIVATE_VPN allow

run() {   # $1 = methode (direct, snowflake, obfs4...)
  adb logcat -c
  adb shell am force-stop $PKG
  adb shell am start -n $PKG/.LauncherDefault -e hopora_ci "$1" > /dev/null
  local verdict=""
  for _ in $(seq 1 90); do      # 90 x 5 s = 7 min 30 maximum
    verdict=$(adb logcat -d -s HOPORA_CI:I | grep -o "HOPORA_CI_RESULT:.*" | tail -1)
    [ -n "$verdict" ] && break
    sleep 5
  done
  adb logcat -d -s HOPORA_CI:I TorService:* AndroidRuntime:E > "$OUT/journal-$1.txt"
  echo "${verdict:-HOPORA_CI_RESULT:$1=ECHEC (aucun verdict)}" | sed 's/^HOPORA_CI_RESULT://' >> "$RES"
  adb shell am startservice -n $PKG/.TorVpnService -a hopora.tor.STOP > /dev/null 2>&1 || true
  adb shell am force-stop $PKG
  sleep 5
}

run direct
run snowflake
echo "--- termine" >> "$RES"
cat "$RES"
