# 🛠️ Scripts

Collection of VPS utility scripts.

---

## ✈️ Telegram MTProto Proxy

Deploy a high-performance Telegram proxy on your VPS in **one command**. Get faster downloads by routing Telegram traffic through your nearby VPS (Mumbai / Singapore).

### ⚡ One-Line Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/k4ran909/scripts/main/telegram_proxy.sh)
```

> Run as root on your VPS (Ubuntu/Debian). That's it!

### What it does

- 🐳 Installs Docker (if needed)
- 🚀 Deploys official Telegram MTProto proxy on port 443
- 🔐 FakeTLS obfuscation (looks like normal HTTPS — no throttling)
- ⚡ Enables BBR congestion control + TCP buffer optimization
- 🔗 Prints a `tg://` link you can tap on your phone to connect instantly
- 📦 Installs `tgproxy` command for easy management

### Management

After install, use the `tgproxy` command:

```bash
tgproxy status      # Check if running
tgproxy info        # Get connection link
tgproxy restart     # Restart proxy
tgproxy logs        # View logs
tgproxy update      # Update to latest
tgproxy speedtest   # Test VPS speed
tgproxy uninstall   # Remove everything
```

### Connect from Telegram

1. Run the installer → it prints a `tg://proxy?server=...` link
2. **Tap the link on your phone** → Telegram auto-configures
3. Or manually: **Settings → Data & Storage → Proxy → Add Proxy → MTProto**

---

## 🌐 Browser Install (`br_install.sh`)

Install a headless browser environment on VPS.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/k4ran909/scripts/main/br_install.sh)
```
