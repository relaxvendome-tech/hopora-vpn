"""Configure le projet Android genere par `flutter create` pour Hopora VPN."""
import os, re, sys, glob

app_id = os.environ.get("ADMOB_APP_ID") or "ca-app-pub-3940256099942544~3347511713"

# --- AndroidManifest ---
m_path = "android/app/src/main/AndroidManifest.xml"
m = open(m_path).read()
if "xmlns:tools" not in m:
    m = m.replace("<manifest ", '<manifest xmlns:tools="http://schemas.android.com/tools" ', 1)
perms = [
    "android.permission.INTERNET",
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_SYSTEM_EXEMPTED",
    "android.permission.POST_NOTIFICATIONS",
]
for p in perms:
    if p not in m:
        m = m.replace("<application", f'<uses-permission android:name="{p}"/>\n    <application', 1)
m = m.replace('android:label="hopora_vpn"',
              'android:label="Hopora" android:usesCleartextTraffic="true" '
              'android:allowBackup="false" android:fullBackupContent="false"', 1)
service = (
    '    <service android:name=".TorVpnService"\n'
    '            android:permission="android.permission.BIND_VPN_SERVICE"\n'
    '            android:foregroundServiceType="systemExempted"\n'
    '            android:exported="false" />\n'
    '        <service android:name="de.blinkt.openvpn.core.OpenVPNService"\n'
    '            android:foregroundServiceType="systemExempted"\n'
    '            tools:replace="android:foregroundServiceType"\n'
    '            tools:node="merge" />\n'
    f'        <meta-data android:name="com.google.android.gms.ads.APPLICATION_ID" android:value="{app_id}"/>\n'
    '    </application>'
)
m = m.replace("</application>", service, 1)

# Camouflage : l'icone de lancement passe par deux alias (Hopora / Calculatrice).
m, n = re.subn(r"\s*<intent-filter>\s*<action android:name=\"android.intent.action.MAIN\"\s*/>\s*"
               r"<category android:name=\"android.intent.category.LAUNCHER\"\s*/>\s*</intent-filter>", "", m, count=1)
assert n == 1, "intent-filter LAUNCHER introuvable"
launcher = ('<intent-filter><action android:name="android.intent.action.MAIN"/>'
            '<category android:name="android.intent.category.LAUNCHER"/></intent-filter>')
aliases = (
    f'    <activity-alias android:name=".LauncherDefault" android:targetActivity=".MainActivity"\n'
    f'            android:enabled="true" android:exported="true" android:label="Hopora"\n'
    f'            android:icon="@mipmap/ic_launcher">{launcher}</activity-alias>\n'
    f'        <activity-alias android:name=".LauncherCalc" android:targetActivity=".MainActivity"\n'
    f'            android:enabled="false" android:exported="true" android:label="@string/calc_name"\n'
    f'            android:icon="@mipmap/ic_calc">{launcher}</activity-alias>\n'
    '    </application>'
)
m = m.replace("</application>", aliases, 1)
open(m_path, "w").write(m)

import shutil
res = "android/app/src/main/res"
for dens in ["mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi"]:
    os.makedirs(f"{res}/mipmap-{dens}", exist_ok=True)
    shutil.copy(f"android_templates/calc/ic_calc_{dens}.png", f"{res}/mipmap-{dens}/ic_calc.png")
for d in os.listdir("android_templates/calc/res"):
    os.makedirs(f"{res}/{d}", exist_ok=True)
    shutil.copy(f"android_templates/calc/res/{d}/hopora_strings.xml", f"{res}/{d}/hopora_strings.xml")

# --- build.gradle(.kts) de l'appli ---
for g in glob.glob("android/app/build.gradle*"):
    s = open(g).read()
    s = re.sub(r"minSdk(Version)?\s*=?\s*flutter\.minSdkVersion", "minSdk = 24", s)
    # tor-android 0.4.9.14 exige de compiler avec l'API 37 (cible inchangee).
    s = re.sub(r"compileSdk(Version)?\s*=?\s*flutter\.compileSdkVersion", "compileSdk = 37", s)
    kts = g.endswith(".kts")
    block = ("\n    packaging {\n        jniLibs {\n            useLegacyPackaging = true\n        }\n    }\n"
             if kts else
             "\n    packagingOptions {\n        jniLibs {\n            useLegacyPackaging = true\n        }\n    }\n")
    if "useLegacyPackaging" not in s:
        s = re.sub(r"(android\s*\{)", r"\1" + block, s, count=1)
    # Mode Tor : tun2socks natif (hev-socks5-tunnel) + Tor + ponts anti-censure
    if kts and "ndkBuild" not in s:
        native = ('\n    externalNativeBuild {\n        ndkBuild {\n'
                  '            path = file("src/main/jni/Android.mk")\n        }\n    }\n')
        s = re.sub(r"(android\s*\{)", r"\1" + native, s, count=1)
        s += ('\ndependencies {\n'
              '    implementation("info.guardianproject:tor-android:0.4.9.14")\n'
              '    implementation("info.guardianproject:jtorctl:0.4.5.7")\n'
              '    implementation("com.netzarchitekten:IPtProxy:5.7.0")\n'
              '}\n')
    open(g, "w").write(s)
    print("patched", g)

# --- Depots Maven (Guardian Project) ---
for g in glob.glob("android/build.gradle*"):
    s = open(g).read()
    if "gpmaven" not in s:
        s = re.sub(r"(allprojects\s*\{\s*repositories\s*\{)",
                   r'\1\n        maven { url = uri("https://raw.githubusercontent.com/guardianproject/gpmaven/master") }',
                   s, count=1)
    open(g, "w").write(s)
    print(s)

# --- openvpn_library embarque une libgojni.so inutilisee qui entre en conflit
#     avec celle des ponts Tor (IPtProxy). On sert une copie nettoyee de l'AAR
#     depuis un depot Maven local, consulte en premier.
import json, urllib.request, zipfile
deps = json.load(open(".flutter-plugins-dependencies"))
ovpn = [x for x in deps["plugins"]["android"] if x["name"] == "openvpn_flutter"][0]["path"]
ver = re.search(r"openvpn_library:([^'\"]+)", open(os.path.join(ovpn, "android", "build.gradle")).read()).group(1)
repo_dir = os.path.abspath("android/localmaven/com/github/nizwar/openvpn_library/" + ver)
os.makedirs(repo_dir, exist_ok=True)
base = f"https://jitpack.io/com/github/nizwar/openvpn_library/{ver}/openvpn_library-{ver}"
urllib.request.urlretrieve(base + ".pom", os.path.join(repo_dir, f"openvpn_library-{ver}.pom"))
raw = os.path.join(repo_dir, "raw.aar")
urllib.request.urlretrieve(base + ".aar", raw)
with zipfile.ZipFile(raw) as zin, zipfile.ZipFile(os.path.join(repo_dir, f"openvpn_library-{ver}.aar"), "w", zipfile.ZIP_DEFLATED) as zout:
    for item in zin.infolist():
        if item.filename.endswith("libgojni.so"):
            print("retire", item.filename)
            continue
        zout.writestr(item, zin.read(item.filename))
os.remove(raw)
for g in glob.glob("android/build.gradle*"):
    s2 = open(g).read()
    if "localmaven" not in s2:
        s2 = re.sub(r"(allprojects\s*\{\s*repositories\s*\{)",
                    r'\1\n        maven { url = uri("${rootDir}/localmaven") }', s2, count=1)
    open(g, "w").write(s2)
    print(s2)

with open("android/gradle.properties", "a") as gp:
    gp.write("\nandroid.suppressUnsupportedCompileSdk=37\n"
             "org.gradle.workers.max=3\n"
             "kotlin.daemon.jvmargs=-Xmx1536m\n")
gpp = open("android/gradle.properties").read()
gpp = re.sub(r"^org\.gradle\.jvmargs=.*$", "org.gradle.jvmargs=-Xmx4g -XX:MaxMetaspaceSize=1g -XX:+HeapDumpOnOutOfMemoryError", gpp, flags=re.M)
open("android/gradle.properties", "w").write(gpp)
print(gpp)

# --- MainActivity ---
mas = glob.glob("android/app/src/main/**/MainActivity.kt", recursive=True)
if not mas:
    sys.exit("MainActivity.kt introuvable")
ma = mas[0]
pkg = re.search(r"^package\s+(\S+)", open(ma).read(), re.M).group(1)
tpl = open("android_templates/MainActivity.kt").read().replace("PACKAGE_NAME", pkg)
open(ma, "w").write(tpl)
print("MainActivity ->", ma, pkg)

# --- Mode Tor : service Kotlin, JNI, regles R8 ---
src_dir = os.path.dirname(ma)
t = open("android_templates/tor/TorVpnService.kt").read().replace("PACKAGE_NAME", pkg)
open(os.path.join(src_dir, "TorVpnService.kt"), "w").write(t)
jni = "android/app/src/main/jni"
os.makedirs(jni, exist_ok=True)
open(os.path.join(jni, "Android.mk"), "w").write(open("android_templates/tor/Android.mk").read())
open(os.path.join(jni, "Application.mk"), "w").write(
    open("android_templates/tor/Application.mk").read().replace("PKG_PATH", pkg.replace(".", "/")))
open("android/app/proguard-rules.pro", "w").write(
    open("android_templates/tor/proguard-rules.pro").read().replace("PACKAGE_NAME", pkg))
for g in glob.glob("android/app/build.gradle*"):
    print(open(g).read())
print(m)
