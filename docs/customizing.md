# Make it yours

[← README](../README.md) · [Configuration](configuration.md) · [Controls](controls.md)

Themes, layouts, sizing and the panel's controls. Keyboard shortcuts and the Stream Deck are in
[Controls](controls.md#global-hotkeys).

## Layouts

The switcher at the top-right of the panel changes how tiles are arranged, instantly; your choice
is saved (in Hammerspoon's settings, not `cc-config.json`).

- **Cards** (default): project cards with name, status, branch, context bar and details.
- **Bar**: compact rounded pills in a flowing row.
- **Contrast**: large, bold tiles with a thick coloured border.
- **Dots**: a minimal vertical list, just a coloured dot and the project name.

## Appearance

**⚙ Settings → Appearance** changes the panel's look with a live preview. **Save** writes it to the
`appearance` block of `~/.claude/cc-config.json`; **Cancel** reverts the preview; **Reset
appearance to defaults** starts over.

- **Theme**: 50 colour themes in six groups (Essentials, Light, Editor Classics, Dark & Moody,
  Neon, Video Games). A fresh install starts on **Cyberpunk** (the installer's default settings);
  **Reset appearance to defaults** returns to **Refined Midnight**. The **slate** and **flat** themes
  also change the tiles' shape.
- **Layout**: the same four layouts as the switcher, applied at once.
- **Accent**: the theme's own accent, one of ten preset swatches, or any colour.
- **Font**: System (default), Rounded, Monospace or Serif.
- **Colours**: optional overrides for the palette (background, surface, border, text, muted), the
  status colours (working, ready, needs you, error), or, under **Advanced**, every colour token the
  panel uses.
- **Sizing**: UI scale (80–140%), tile width (120–320 px, default 170), **Compact** density, and
  **Reduce motion** (no pulsing or spinning).
- **Export / Import**: Export puts the current look (colours, font, sizing, density, motion) as JSON
  in a box to copy; Import takes pasted JSON. An import with an unknown colour token or a bad hex
  value is rejected whole.

Two switches in the same tab change what the detail panel shows. They are panel preferences, so a
theme export never carries them:

- **Model controls** (off by default) adds the Effort, Mode, Model, Gate, Policy and Auto-model row
  ([Controls](controls.md#the-detail-panel)).
- **Hide the detail panel's controls** (off by default) hides the button rows and the nudge box,
  bringing back only what a waiting or errored session needs
  ([Controls](controls.md#the-detail-panel)).

## Faster rendering

The panel refreshes every second. The grid keeps a signature of what every visible card shows; when
nothing changed, it skips the rebuild and only updates the ages in place. When anything changed, it
rebuilds the grid. A quiet fleet costs almost nothing to draw.

## The panel window

Drag the panel by its title bar and resize it; it floats above other windows and shows on every
Space. Its size and position are remembered across reloads. The 🐑 menu-bar icon shows and hides it,
as do **⌘⌥B** and the optional [Dock launcher](install.md#shepherdapp-a-dock-launcher). The panel
stays out of your way: messages are toasts inside it
([Fleet → Messages](fleet.md#messages)), and relabel, close and new-session use in-panel bars and
dialogs, not native ones, so they don't pull Hammerspoon's console forward.
