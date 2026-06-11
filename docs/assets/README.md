# App icon asset

Drop a square PNG named **`shepherd.png`** in this folder to set the Shepherd **Dock /
app icon** — a black German-shepherd face is the intent. `app/make-icon.sh` (run by
`make app`) prefers this file and resizes it into the app's `.icns` automatically.

- **Name:** `shepherd.png` (exact)
- **Shape:** square (1024×1024 ideal; a non-square image gets squished by the resizer)
- **Background:** transparent
- **Color:** a solid black silhouette/face reads best at Dock size

If this file is absent, `make-icon.sh` draws a black GSD-head silhouette as the fallback
(or, without Swift / Xcode CLT, keeps the default applet icon). The **menubar** icon stays
🐑 (the flock the shepherd watches) — this asset is only the Dock/app icon.

After adding or changing it: **`make app dock`** (rebuilds the app + refreshes the Dock).
