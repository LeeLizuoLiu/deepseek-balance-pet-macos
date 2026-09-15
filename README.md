# DeepSeek Balance Pet · Native macOS

**English** | [中文](README.zh.md)

A DeepSeek-chan that sits on your macOS desktop: **frameless, fully transparent, always on top**, showing your live DeepSeek account balance in her speech bubble. Refreshes every 20 seconds by default.

This is a native macOS rewrite of [Ho11ow8/deepseek-harness-balance-pet](https://github.com/Ho11ow8/deepseek-harness-balance-pet) (Windows-only, WPF + `DesktopPet.exe`). It keeps the same character artwork and the same speech-bubble geometry, but needs no Windows, no .NET, and no browser.

> **Note:** the pet's own UI strings — the bubble text and the right-click menu — are in Chinese, matching the original. The code and this README are in English.

## Highlights

- **Floats above everything** — `NSWindow.level = .floating` with `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, so she stays visible when you switch apps, change Spaces, or go full-screen
- **Never steals focus** — the window's `canBecomeKey` is always `false`; keyboard focus stays exactly where it was
- **No Dock icon, no menu bar** — `LSUIElement = 1`
- **Zero dependencies** — built with `swiftc` from Xcode Command Line Tools; no Xcode project, no third-party libraries
- **No browser involved** — she reads `~/.dsh/.credentials.yaml` herself and talks to `https://api.deepseek.com/user/balance` directly, so she keeps working with the browser and the Harness shut down
- Drag to move, click to refresh, hover to hide, right-click menu, remembered position, multi-display clamping

## Requirements

- macOS 13 or later
- Xcode Command Line Tools: `xcode-select --install` (the CLT alone is enough — full Xcode is not required)

## Build

```sh
./build.sh                  # compile + assemble the .app + run a headless self-test
./build.sh --run            # ...and launch it
./build.sh --install        # ...and install it to ~/Applications
```

Output: `build/DeepSeekBalancePet.app`

Launch at login: drag `~/Applications/DeepSeekBalancePet.app` into System Settings → General → Login Items.

## Usage

| Action | Result |
| --- | --- |
| Left-drag | Move her anywhere; the position is stored in `UserDefaults` and survives restarts, and is clamped back into view when the screen shrinks |
| Click / double-click | Refresh the balance immediately |
| Hover | A `×` appears in the top-right corner; click it to hide |
| Right-click | Menu: Refresh now / Hide pet / Open config file / Quit |
| While hidden | A small round `¥` badge is left in place — click it to bring her back, right-click to quit |

Quit: right-click → Quit, or `pkill -f DeepSeekBalancePet`.

## Configuration

On first run a default config is written to `~/Library/Application Support/DeepSeekBalancePet/config.json`. Set only the keys you want to change:

```json
{
  "pollSeconds": 20,
  "width": 220,
  "currency": "CNY",
  "shadow": true,
  "animation": true,
  "margin": 16,
  "apiBase": "https://api.deepseek.com"
}
```

| Key | Default | Meaning |
| --- | --- | --- |
| `pollSeconds` | `20` | Refresh interval in seconds; minimum 5 |
| `width` | `220` | Width of **the character itself** in points; height follows the 960×912 aspect ratio, and the drop-shadow padding is added on top of this |
| `currency` | `CNY` | Preferred currency; use `auto` to pick the first non-zero entry |
| `shadow` | `true` | Drop shadow, matching the original WPF `DropShadowEffect(Blur 14 / Depth 3 / Opacity 0.38)` |
| `animation` | `true` | Gentle vertical bob (Core Animation, GPU-driven, no CPU cost) |
| `margin` | `16` | Default gap from the screen edge (bottom-right) |
| `apiBase` | `https://api.deepseek.com` | Balance endpoint; point it at a mirror or gateway if you like |

"Open config file" in the right-click menu opens it directly. `pollSeconds` takes effect on the next poll; anything geometry-related needs a restart.

### About currency selection

For multi-currency accounts, `balance_infos` is an array and the original code took index 0. This account actually returns `[USD: 0.00, CNY: 48.94]`, so copying that behaviour would display `$0.00`. The lookup order here is **requested currency → first non-zero entry → first entry**, which correctly shows `¥48.94`.

## API key

Looked up in this order:

1. The `DEEPSEEK_API_KEY` environment variable
2. The `DEEPSEEK_API_KEY` line in `~/.dsh/.credentials.yaml`

In other words, **put the key in your environment and this app has nothing to do with DeepSeek Harness at all.** The key is used only inside this process, and is sent only to whatever `apiBase` points at.

## Self-test and logs

```sh
# Checks config, credentials, artwork and the balance endpoint, then exits without opening a window
build/DeepSeekBalancePet.app/Contents/MacOS/DeepSeekBalancePet --selftest

# Prints where the config, log and credentials files live
build/DeepSeekBalancePet.app/Contents/MacOS/DeepSeekBalancePet --print-paths
```

`./build.sh` runs `--selftest` automatically after every build.

Log: `~/Library/Application Support/DeepSeekBalancePet/pet.log`

## Troubleshooting

- **The bubble says `余额：获取失败` (failed to fetch)** — hover over the character to read the actual error in the tooltip. Usually an expired key or an empty account.
- **She disappeared** — you probably hit the `×`. A small `¥` badge is left where she was; click it to restore. If you can't find it, `pkill -f DeepSeekBalancePet` and start her again.
- **She quits immediately on launch** — check `pet.log`. If it reports a missing `pet.png`, make sure `assets/pet.png` exists (`build.sh` copies it into `.app/Contents/Resources/`).
- **Build fails with `this SDK is not supported by the compiler`** — that is a misleading error caused by an unwritable clang module cache directory, not an actual SDK mismatch. `build.sh` already points `CLANG_MODULE_CACHE_PATH` at `build/.modulecache`; if you invoke `swiftc` by hand, pass `-module-cache-path`.
- **Gatekeeper blocks the first launch** — `build.sh` ad-hoc signs the app; if it still gets blocked, right-click the `.app` → Open.

## Layout

```
deepseek-balance-pet-macos/
├── BalancePet.swift      # everything: window / artwork / bubble / fetching / config
├── Info.plist            # LSUIElement=1, no Dock icon
├── build.sh              # swiftc compile + .app assembly + self-test
├── assets/
│   └── pet.png           # character artwork (from the original, 960×912, alpha-cut)
└── LICENSE
```

## Credits and license

The character artwork, the speech-bubble geometry (`(70,130)-(545,300)`), the alpha cut-out and the balance-normalization logic come from [Ho11ow8/deepseek-harness-balance-pet](https://github.com/Ho11ow8/deepseek-harness-balance-pet) (MIT — see `LICENSE`).

The AppKit implementation, multi-currency selection, baked drop shadow, single-line font auto-fit and position persistence in this repository are new work, released under the same MIT license.
