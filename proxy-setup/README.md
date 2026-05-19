# 🛡️ One-Command Proxy Server

Full VPN + Proxy + Anti-Traceroute setup for your VPS in **one command**.

## What It Does

| Layer | Tool | Purpose |
|-------|------|---------|
| 🔒 VPN | WireGuard (wg-easy) | Full-tunnel VPN with Web UI |
| 🌐 SOCKS5 | 3proxy | App-specific proxy (port 1080) |
| 🌐 HTTP | 3proxy | Browser proxy (port 3128) |
| 📡 DNS | Cloudflared | DNS-over-HTTPS leak protection |
| 🛡️ Firewall | iptables | Anti-traceroute + anti-fingerprint |
| 🚫 Fail2Ban | fail2ban | SSH brute-force auto-ban |

## One-Liner Install

```bash
curl -fsSL https://raw.githubusercontent.com/k4ran909/scripts/main/proxy-setup/setup.sh | sudo bash
```

## After Setup

1. Open `http://YOUR_VPS_IP:51821` → WireGuard Web UI
2. Create a client → scan QR / download `.conf`
3. Import into WireGuard app → connect
4. Verify at https://ipleak.net

## Credentials (defaults)

| Service | User | Password |
|---------|------|----------|
| VPN Web UI | — | `Admin@VPN#2026` |
| SOCKS5/HTTP Proxy | `karan` | `SecureProxy#2026` |

⚠️ **Change these in `setup.sh` before deploying!**

## Management

```bash
cd /opt/proxy-stack
docker compose ps          # Status
docker compose logs -f     # Logs
docker compose restart     # Restart
docker compose down        # Stop
docker compose up -d       # Start
```
