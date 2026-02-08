# Daylight Computer as Mac External Display — Research

## Daylight DC-1 Specifications

| Spec | Detail |
|---|---|
| **Display** | 10.5" LivePaper (transflective IGZO LCD), 1600x1200, 190 PPI |
| **Refresh Rate** | 60 Hz (hardware supports 6-120 Hz variable) |
| **Color** | Black & white (grayscale), amber backlight |
| **OS** | Sol:OS (Android 13 custom ROM) |
| **Chip** | MediaTek Helio G99 |
| **RAM / Storage** | 8 GB / 128 GB + microSD |
| **Ports** | USB-C (with PD), pogo pins, microSD |
| **Connectivity** | WiFi 6, Bluetooth 5.0 |
| **Google Play** | Yes (full access) |
| **Sideloading** | Supported (APKs from APKMirror, F-Droid, etc.) |
| **Developer** | ADB/USB debugging, bootloader unlock planned |

**Key insight**: The LivePaper display is NOT e-ink — it's a fast-refresh transflective LCD that *looks* like e-ink. This means standard Android display apps work at normal frame rates, unlike true e-ink devices. The 60 Hz refresh rate means screen mirroring apps will feel fluid, not laggy like on a Kindle or reMarkable.

## Official Daylight Guide

Daylight officially documents using the DC-1 as a monitor at:
https://support.daylightcomputer.com/getting-started/use-the-dc-1-as-a-monitor

**However, this guide is Windows-only.** It recommends:
- **SuperDisplay** ($14.99) — higher quality, USB + WiFi
- **Spacedesk** (free) — lower quality but functional

Both are Windows-only solutions. Mac users need alternative approaches.

---

## Approaches Evaluated

### 1. Duet Display (RECOMMENDED — Best Overall)

**What**: Commercial app that turns Android tablets into USB second monitors for Mac.
**How**: Install app on both Mac and Daylight. Connect via USB-C. Display extends/mirrors.
**Cost**: $4/month or $9.99 one-time on Google Play.

**Pros**:
- Native Mac + Android support
- USB connection (low latency, no WiFi needed)
- Mature product, actively maintained
- Works as both mirror and extended display
- Pen input support possible

**Cons**:
- Subscription model for full features
- No touchscreen control on extended display (can use as touchpad)
- Needs testing on Daylight's specific display resolution

**Feasibility**: HIGH — This is the most polished, well-supported option. A Hacker News user confirmed SuperDisplay works "like a charm" on the Daylight; Duet Display is the Mac equivalent.

**Setup**:
1. Install Duet Display from Google Play on Daylight
2. Install Duet Display Mac app from duetdisplay.com
3. Connect USB-C cable
4. Configure resolution to 1584x1184 (Daylight's optimal)

### 2. Deskreen (RECOMMENDED — Best Free Option)

**What**: Open-source Electron app that streams your screen to any device with a web browser via WebRTC.
**How**: Run Deskreen on Mac. Open browser on Daylight. Scan QR code. Screen appears.
**Cost**: Free, open source (GPL).

**Pros**:
- Free and open source
- Works on Mac natively
- No app install needed on Daylight (just a browser)
- Can share entire screen or specific windows
- End-to-end encrypted
- Works offline on local WiFi

**Cons**:
- WiFi only (no USB) — latency depends on network
- ~250 MB RAM on Mac per session
- No touch/pen input back to Mac
- WebRTC streaming quality varies
- Not optimized for e-ink/grayscale displays

**Feasibility**: HIGH — Zero-friction setup. Great for static content (documents, code). Less ideal for frequent interaction.

**Setup**:
1. Download from deskreen.com, install on Mac
2. Start Deskreen, choose screen/window to share
3. On Daylight, open Chrome/browser
4. Scan QR code or enter IP address
5. Approve connection on Mac

### 3. Weylus (RECOMMENDED — Best for Pen Input)

**What**: Open-source server that streams your screen to any device's browser, with touch/pen input back to the computer.
**How**: Run Weylus on Mac. Open browser on Daylight. Use pen to interact.
**Cost**: Free, open source.

**Pros**:
- Free and open source
- Mac support (runs as native app)
- Browser-based on tablet (no app install on Daylight)
- **Pen/stylus input** forwarded back to Mac
- Can capture specific windows
- Low latency streaming

**Cons**:
- WiFi only
- Pen pressure/tilt not supported on macOS (Linux only)
- Android 14+ needs Firefox Nightly for pointer events
- Less polished UI than commercial options
- May need firewall configuration

**Feasibility**: HIGH — Best option if you want to use the Daylight's Wacom EMR pen to interact with Mac apps. The bidirectional input is unique.

**Setup**:
1. Download from github.com/H-M-H/Weylus
2. Run on Mac (double-click)
3. On Daylight, open Firefox and navigate to Mac's IP:port
4. Select window/screen to capture

### 4. VNC (Remote Desktop)

**What**: Run a VNC server on Mac, VNC viewer app on Daylight.
**How**: Enable Screen Sharing on Mac. Install RealVNC Viewer or similar on Daylight.
**Cost**: Free (macOS has built-in VNC server).

**Pros**:
- Free (built into macOS)
- Full remote control (keyboard, mouse, touch)
- Many VNC viewer apps on Google Play
- Works over WiFi and can work over USB (with port forwarding)

**Cons**:
- Mirrors entire screen (not extend)
- Higher latency than purpose-built solutions
- macOS VNC server can be finicky
- No display extension (mirror only)
- VNC encoding not optimized for grayscale

**Feasibility**: MEDIUM — Works but feels like remote desktop, not a second monitor. Better for "controlling Mac from the couch" than "extending your workspace."

### 5. SuperDisplay (Windows Only)

**What**: The app Daylight officially recommends. Turns Android into USB display.
**How**: Install on both Windows PC and Daylight. Connect via USB.
**Cost**: $14.99 one-time.

**Pros**:
- Officially recommended by Daylight
- Confirmed working by multiple users
- USB connection (lowest latency)
- Pen/stylus support

**Cons**:
- **Windows only — does not work on Mac**
- Cannot be used for this use case

**Feasibility**: N/A for Mac users.

### 6. Spacedesk (Windows Only)

**What**: Free display extension app. Daylight's alternative recommendation.
**How**: Install driver on Windows. App on Daylight.
**Cost**: Free.

**Pros**:
- Free
- USB and WiFi support

**Cons**:
- **Windows only — no Mac support**
- Lower quality than SuperDisplay
- Mac was "not supported" as of Catalina+

**Feasibility**: N/A for Mac users.

### 7. Splashtop Wired XDisplay

**What**: USB display extension tool.
**How**: Install on both Mac and Android.
**Cost**: Free (limited) / Paid.

**Pros**:
- Supports USB connection
- Android support

**Cons**:
- **Mac support dropped after macOS 10.13** (High Sierra)
- Not compatible with modern macOS versions
- Effectively dead for Mac

**Feasibility**: NONE — Incompatible with modern macOS.

### 8. Custom Solution (vnsee-inspired)

**What**: Build a custom lightweight VNC client app for the Daylight, optimized for its grayscale display, similar to how vnsee works for the reMarkable tablet.
**How**: Write an Android app that connects to macOS built-in VNC, renders in grayscale, optimizes for text.
**Cost**: Development time.

**Pros**:
- Optimized for Daylight's display characteristics
- Could support USB connection via ADB port forwarding
- Could use pen input
- Full control over rendering pipeline
- Could be tuned for text-heavy workflows

**Cons**:
- Significant development effort
- Need to maintain across OS updates
- VNC protocol overhead
- Reinventing the wheel vs. using Duet Display

**Feasibility**: LOW priority — Only worth pursuing if commercial solutions fail on the Daylight's display.

### 9. scrcpy (Reverse Direction Not Supported)

**What**: scrcpy mirrors Android to computer, not the other way around.
**How**: N/A — wrong direction.

**Feasibility**: NONE — scrcpy only does Android → Computer, not Computer → Android.

### 10. ADB + Framebuffer Streaming

**What**: Low-level approach using ADB to push framebuffer data over USB.
**How**: Capture Mac screen, encode, push to Android framebuffer via USB.
**Cost**: Development time.

**Pros**:
- USB connection (low latency)
- No WiFi needed
- Could be highly optimized

**Cons**:
- Extremely complex to implement
- May need root on Daylight
- Framebuffer access is restricted on modern Android
- Not a realistic approach

**Feasibility**: VERY LOW — Too complex, too many restrictions.

---

## Feasibility Ranking

| Rank | Solution | Connection | Cost | Mac Support | Effort |
|------|----------|-----------|------|-------------|--------|
| 1 | **Duet Display** | USB + WiFi | $4/mo | Yes | Install apps |
| 2 | **Deskreen** | WiFi | Free | Yes | Install Mac app |
| 3 | **Weylus** | WiFi | Free | Yes | Install Mac app |
| 4 | **VNC** | WiFi (USB possible) | Free | Yes | Configure |
| 5 | **Custom app** | USB + WiFi | Free | Yes | Build |
| - | SuperDisplay | USB | $14.99 | No | N/A |
| - | Spacedesk | USB + WiFi | Free | No | N/A |
| - | Splashtop | USB | Paid | Dropped | N/A |
| - | scrcpy | USB | Free | Wrong direction | N/A |

---

## Recommended Action Plan

### Phase 1: Try Duet Display (30 minutes)
1. Install Duet Display on Daylight from Google Play ($9.99)
2. Install Duet Display on Mac from duetdisplay.com
3. Connect via USB-C
4. Test with text editor, code editor, browser
5. Evaluate: latency, text clarity, pen support

### Phase 2: Try Deskreen as free alternative (15 minutes)
1. Install Deskreen on Mac
2. Open browser on Daylight
3. Connect and test
4. Compare quality/latency with Duet Display

### Phase 3: Try Weylus if pen input matters (15 minutes)
1. Download Weylus for Mac
2. Open in Daylight's browser
3. Test pen input forwarding
4. Evaluate for drawing/annotation workflows

### Phase 4: Optimize whichever works best
- Set display resolution to 1584x1184 (Daylight's sweet spot per official guide)
- For WiFi solutions: use 5 GHz band, same-room proximity
- For grayscale optimization: use high-contrast themes, disable animations on Mac
- Consider building a macOS "Daylight mode" script that:
  - Switches to grayscale color profile
  - Disables transparency/animations
  - Uses high-contrast fonts
  - Optimizes for the Daylight's display

---

## Display Optimization Tips for Daylight

Since the Daylight is grayscale, optimize the Mac output:

1. **macOS Grayscale**: System Settings → Accessibility → Display → Color Filters → Grayscale (preview how things look)
2. **High Contrast**: Use dark-on-light or light-on-dark themes with maximum contrast
3. **Reduce Motion**: System Settings → Accessibility → Display → Reduce Motion
4. **Reduce Transparency**: System Settings → Accessibility → Display → Reduce Transparency
5. **Font Rendering**: Use well-hinted fonts (Menlo, SF Mono, Georgia) that render clearly at the Daylight's 190 PPI
6. **Resolution**: Target 1584x1184 or 1600x1200 (native) for pixel-perfect rendering

---

## About amber-writer

The `amber-writer` repo (github.com/welfvh/amber-writer) is a **standalone Flutter writing app**, not a screen mirroring tool. It's a minimalist markdown editor designed for the Daylight Computer with:
- Times New Roman typography, iOS-style UI
- Runs natively on Android (Daylight), iOS, and macOS
- Local storage via shared_preferences
- PDF export, Claude AI integration
- Dark/light/system theme with amber text mode
- Brightness control with logarithmic slider (optimized for Daylight's backlight)

It was built as a "write on Daylight, export to Mac" workflow — not a screen mirroring solution. The amber-writer concept represents a **different strategy**: rather than mirroring the Mac screen to Daylight, build native apps that work well on the Daylight directly.

Both strategies have value:
- **Screen mirroring**: Use Mac apps on the Daylight's eye-friendly screen
- **Native apps (amber-writer)**: Purpose-built for the Daylight's unique display

---

## Links & Resources

- [Daylight FAQ](https://daylightcomputer.com/faq)
- [Daylight Official Monitor Setup Guide (Windows)](https://support.daylightcomputer.com/getting-started/use-the-dc-1-as-a-monitor)
- [Duet Display](https://www.duetdisplay.com/)
- [Deskreen (GitHub)](https://github.com/pavlobu/deskreen)
- [Weylus (GitHub)](https://github.com/H-M-H/Weylus)
- [SuperDisplay](https://superdisplay.app/) (Windows only)
- [Spacedesk](https://www.spacedesk.net/) (Windows only)
- [vnsee — VNC for reMarkable](https://github.com/matteodelabre/vnsee) (inspiration for custom solution)
- [scrcpy](https://github.com/Genymobile/scrcpy) (Android → PC only)
- [Daylight DC-1 Review (Liliputing)](https://liliputing.com/daylight-computer-dc-1-is-a-799-tablet-with-a-live-paper-display-designed-to-be-easy-on-the-eyes-but-not-the-wallet/)
- [Daylight DC-1 Review (TechRadar)](https://www.techradar.com/tablets/the-daylight-dc-1-is-an-exciting-cross-between-a-kindle-and-an-ipad-with-an-lcd-screen-that-looks-like-e-ink)
- [Hacker News Discussion](https://news.ycombinator.com/item?id=43098318)
