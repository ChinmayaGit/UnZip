# UnZip

A native macOS file explorer that also opens archives, plays music and video, and compresses folders.

**Free for anyone.** No account, no license key, no paid permission. The app is [public domain](LICENSE).

Requires **macOS 14** or later. Works on **Apple Silicon** and **Intel**.

Full walkthrough: **[How to use](HowToUse.md)** — every feature, what it is for, and how to use it.

## Download

Get the latest build from **[Releases](https://github.com/ChinmayaGit/UnZip/releases/latest)**. Use any one file:

- `UnZip-1.1.0.dmg` — drag the app into Applications
- `UnZip-1.1.0.pkg` — double-click to install
- `UnZip-1.1.0-macos.zip` — unpack and move `UnZip.app` into Applications

No sign-in. No license agreement.

The first time macOS may say the app cannot be opened (it is not signed with an Apple Developer ID). That is not a license. Control-click **UnZip**, choose **Open**, then click **Open** again.

## Screenshots

File explorer with sidebar, path bar (copy path, Details, Terminal), Grid / Details / Large views, and a video preview.

![File explorer — Movies](Pics/explorer-movies.png)

Music folder with the bottom music bar, full player in the preview pane, shuffle / auto-next / queue.

![File explorer — Music](Pics/explorer-music.png)

Connect to FTP, FTPS, or SFTP and browse remote files without leaving the app.

![Connect to server](Pics/connect-server.png)

Share files on the local network with a QR code or HTTP link. Other UnZip apps nearby can receive them; a phone or browser can play and download them.

![Share QR](Pics/share-qr.png)

![Share in a browser](Pics/share-web.png)

![Share on a phone](Pics/share-phone.jpg)

Right-click a folder for Folder Image, Details, copy / cut / paste, compress, and trash.

![Folder context menu](Pics/folder-menu.png)

Set a folder cover: first image, custom picture, `.ico`, or a symbol. Crop or fit.

![Folder image](Pics/folder-image.png)

Settings: grouped into Appearance, Folder Images, Explorer, Sidebar, and Playback.

![Settings](Pics/settings.png)

Create a ZIP or RAR with High, Medium, or Low compression, and optional split volumes.

![Create archive](Pics/2.png)

In Finder, right-click a folder or file → **Services → Zip with UnZip**.

![Finder Zip with UnZip](Pics/4.png)

## What UnZip does

- **File explorer** — default home screen. Sidebar, path bar, multiple views, sort, filter, search, preview
- **Devices** — USB sticks, external disks, and network volumes in the sidebar, with Eject
- **Path bar** — click folders, edit the path, **copy** it, or open **Terminal** in that folder
- **Folder covers** — first picture in a folder becomes the icon; per-folder or global
- **File actions** — copy, cut, paste, duplicate, move, rename, trash, drag-drop (Option = copy)
- **Open With** — pick VLC, QuickTime, Preview, or any other app; **Set as Default** for that file type
- **Images** — fullscreen viewer; left / right through the folder
- **Music** — play/pause, next, seek, volume, shuffle, auto-next, loop, album art
- **Video** — play/pause, volume, fullscreen; VP9 picture is prepared through VLC if installed
- **Archives** — ZIP, RAR, 7Z, TAR, ISO, DMG, and more; extract and create
- **FTP / FTPS / SFTP** — connect, browse, download
- **Share (HTTP)** — QR + local web page so phones and browsers can play or download
- **Finder service** — Zip with UnZip from the right-click menu

## Install

### Disk image (`.dmg`)

1. Double-click `UnZip-1.1.0.dmg`.
2. Drag **UnZip** into the **Applications** folder.
3. Open UnZip from Applications or Spotlight.
4. If macOS says the app cannot be opened, Control-click UnZip, choose **Open**, then click **Open** again.

### Installer package (`.pkg`)

1. Double-click `UnZip-1.1.0.pkg`.
2. Follow the steps and click **Install**. There is no license to accept.
3. UnZip is copied to `/Applications`.
4. Open UnZip from Applications or Spotlight.
5. If macOS blocks the first launch, Control-click UnZip in Applications, choose **Open**, then click **Open** again.

### Zip archive (`.zip`)

1. Double-click `UnZip-1.1.0-macos.zip` to unpack it.
2. Move `UnZip.app` into the **Applications** folder.
3. Open UnZip from Applications or Spotlight.
4. If macOS says the app cannot be opened, Control-click UnZip, choose **Open**, then click **Open** again.

## After install

- Drop an archive on UnZip to open it, or drop a folder or file to compress it.
- In Finder, right-click a folder or file → **Services → Zip with UnZip**.
- If that service is missing, open **System Settings → Keyboard → Keyboard Shortcuts → Services**, then turn on **Zip with UnZip** under **Files and Folders**.

## Optional tools

- Extract RAR / 7Z: `brew install unar p7zip`
- Create RAR: install the WinRAR `rar` command-line tool
- Play VP9 / some WebM video in the preview player: install [VLC](https://www.videolan.org/vlc/)

## Build from source

From this project:

```bash
./scripts/package.sh
```

That writes `UnZip-1.1.0.dmg`, `UnZip-1.1.0.pkg`, and `UnZip-1.1.0-macos.zip` into `dist/`.

For a local copy only:

```bash
./scripts/build-app.sh --install
```

That copies `UnZip.app` into `~/Applications`. Apple Silicon only:

```bash
./scripts/build-app.sh --install --arm64-only
```

UnZip is a Swift Package (`Package.swift`) targeting macOS 14. Sources live in `Sources/UnZip`.
