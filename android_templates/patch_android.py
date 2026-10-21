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
              'android:label="Hopora VPN" android:usesCleartextTraffic="true" '
              'android:allowBackup="false" android:fullBackupContent="false"', 1)
service = (
    '    <service android:name="de.blinkt.openvpn.core.OpenVPNService"\n'
    '            android:foregroundServiceType="systemExempted"\n'
    '            tools:replace="android:foregroundServiceType"\n'
    '            tools:node="merge" />\n'
    f'        <meta-data android:name="com.google.android.gms.ads.APPLICATION_ID" android:value="{app_id}"/>\n'
    '    </application>'
)
m = m.replace("</application>", service, 1)
open(m_path, "w").write(m)

# --- build.gradle(.kts) de l'appli ---
for g in glob.glob("android/app/build.gradle*"):
    s = open(g).read()
    s = re.sub(r"minSdk(Version)?\s*=?\s*flutter\.minSdkVersion", "minSdk = 24", s)
    kts = g.endswith(".kts")
    block = ("\n    packaging {\n        jniLibs {\n            useLegacyPackaging = true\n        }\n    }\n"
             if kts else
             "\n    packagingOptions {\n        jniLibs {\n            useLegacyPackaging = true\n        }\n    }\n")
    if "useLegacyPackaging" not in s:
        s = re.sub(r"(android\s*\{)", r"\1" + block, s, count=1)
    open(g, "w").write(s)
    print("patched", g)

# --- MainActivity ---
mas = glob.glob("android/app/src/main/**/MainActivity.kt", recursive=True)
if not mas:
    sys.exit("MainActivity.kt introuvable")
ma = mas[0]
pkg = re.search(r"^package\s+(\S+)", open(ma).read(), re.M).group(1)
tpl = open("android_templates/MainActivity.kt").read().replace("PACKAGE_NAME", pkg)
open(ma, "w").write(tpl)
print("MainActivity ->", ma, pkg)
print(m)
