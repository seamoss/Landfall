# Landfall for Raycast and Shortcuts

**Raycast:** Raycast › Settings › Extensions › Script Commands › Add Directories → pick this folder
(also inside the app at `Landfall.app/Contents/Resources/extras/raycast`).

**Shortcuts / Spotlight / any launcher:** open a `landfall://` URL ("Open URLs" action):

| URL | Does |
|---|---|
| `landfall://settings` | Open Settings |
| `landfall://scan` | Classify everything now |
| `landfall://review` | Open the menu (proposals waiting) |
| `landfall://space` | Run the space report |
| `landfall://file?path=/full/path` | File that item now |
| `landfall://ask?path=/full/path` | Ask Claude where it belongs |
| `landfall://toast?path=/full/path` | Show its toast |

Or use "Run Shell Script" with the CLI: `landfall recent --since 1d --json`, `landfall search … --json`.
