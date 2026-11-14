import os
import requests

def upload():
    url = "https://ango-ifood.onrender.com/apk/upload/"
    apk_file = "app-release-latest.apk"
    if not os.path.exists(apk_file):
        print("Arquivo APK não encontrado localmente.")
        return
    print(f"A carregar {apk_file} ({os.path.getsize(apk_file)} bytes) para {url}...")
    with open(apk_file, "rb") as f:
        r = requests.post(url, files={"apk": ("DeliveryPro.apk", f, "application/vnd.android.package-archive")}, timeout=180)
    print("Resposta do servidor:", r.status_code, r.text)

if __name__ == "__main__":
    upload()
