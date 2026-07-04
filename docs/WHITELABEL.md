# Whitelabel branding

Ticketarget ships as a brandable platform: one static file controls the name,
logo mark, tagline, color scheme and visual style of the whole frontend. No
rebuild is required — deployers override the file and refresh.

## How it works

The frontend fetches `/branding.json` (cache: no-store) before the app mounts,
validates it **per field**, and merges it onto the stock defaults. A missing,
malformed or partially invalid file can never break the app: bad fields keep
their defaults, and startup never blocks for more than 1.5s on the fetch.

Colors flow into a CSS token bridge: the two brand colors per theme drive every
derived tint (hover states, soft washes, glows, gradients, chart series 1 and
venue-zone category 1) via `color-mix()`. Browsers without `color-mix` keep the
stock tints while still applying the primary brand colors.

## Deploying your brand

Mount your file over the baked-in one (nginx serves it as-is):

```yaml
# docker-compose.override.yml
services:
  frontend:
    volumes:
      - ./my-branding.json:/usr/share/nginx/html/branding.json:ro
```

## The file

```json
{
  "name": "Aurora Tickets",
  "initial": "A",
  "tagline": "tickets for the northern lights.",
  "colors": {
    "dark":  { "accent": "#10b981", "accentSecondary": "#f59e0b" },
    "light": { "accent": "#0e9f6e", "accentSecondary": "#b45309" }
  },
  "style": {
    "radius": "square",
    "glass": true
  }
}
```

| Field | Rules |
|---|---|
| `name` | 1–60 chars; becomes the page title, topbar and footer |
| `initial` | 1–2 chars; the logo mark |
| `tagline` | up to 200 chars; footer |
| `colors.dark/light.accent` | `#rrggbb`; primary brand color per theme |
| `colors.dark/light.accentSecondary` | `#rrggbb`; secondary (teal-role) color |
| `style.radius` | `square` (default) or `rounded` |
| `style.glass` | `true` (default) for translucent blurred surfaces, `false` for solid |

## Color guidance

Pick accents with at least **3:1 contrast** against your surfaces (dark theme
surface ≈ `#151823`, light ≈ `#ffffff`). The app checks this at startup and
logs a console warning when a brand color falls below 3:1 — it will not block,
but low-contrast brands hurt readability and accessibility.

Chart series 2+ and venue-zone categories 2–6 deliberately stay on the
platform's colorblind-validated palette; only the first slot follows your
brand. Data surfaces (charts, venue maps, QR codes) keep near-opaque
backgrounds even in glass mode — readability wins over style there.

## Deployment notes

- **Subpath deployments are supported at build time**: build the frontend
  image with `--build-arg VITE_BASE=/tickets/` (trailing slash required) and
  serve the SPA under that prefix. Asset URLs, the router base and the
  branding fetch all follow it. Brand swaps stay runtime-only within a
  chosen base; changing the base itself is a one-arg rebuild. Your reverse
  proxy must preserve the prefix and serve `branding.json` + assets under
  it, with the SPA index fallback applied to app routes only.
- The client fetches with `cache: no-store`, but an upstream CDN must not
  cache `branding.json` aggressively or live brand swaps will lag.
- Browsers without `color-mix()`/`backdrop-filter` get the stock derived
  tints and solid surfaces, with your primary brand colors still applied —
  a degraded but consistent appearance.
- The page `<title>` is restored from a local cache before first paint on
  every visit after the first, so returning visitors never see the stock
  name. Only the **first-ever** visit shows it for one request round-trip —
  the structural floor without server-side rendering.
