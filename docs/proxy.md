# Proxy

Runway can route all provider requests through a proxy.

- Supported: `socks5://`, `http://`, `https://`
- Config file: `~/.runway/config.json`
- Default: off
- No UI. File only.

## Config file

```json
{
  "proxy": {
    "enabled": true,
    "url": "socks5://127.0.0.1:10808"
  }
}
```

For an authenticated proxy, put the credentials in the URL:

```json
{
  "proxy": {
    "enabled": true,
    "url": "http://user:pass@proxy.example.com:8080"
  }
}
```

When the URL has no port, the scheme's default applies (socks5 → 1080, http → 80, https → 443).

## Behavior

- Runway reads the config once at launch. Restart Runway after changing the file.
- `localhost`, `127.0.0.1`, and `::1` always bypass the proxy, so the [local HTTP API](local-http-api.md) is unaffected.
- A missing, disabled, invalid, or unreadable config leaves proxying off.

## Scope

Applies to provider HTTP requests made by the app, including the hourly [model pricing](pricing.md) refresh. It is not a system-wide proxy.
