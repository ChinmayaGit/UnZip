# UnZip

A native macOS app for browsing and extracting ZIP, RAR, ISO, TAR, 7Z, and DMG archives, and for compressing folders and files.

Requires **macOS 14** or later. Works on **Apple Silicon** and **Intel**.

## Install

Use any one of the files in `dist/`:

- `UnZip-1.0.dmg`
- `UnZip-1.0.pkg`
- `UnZip-1.0-macos.zip`

### Disk image (`.dmg`)

1. Double-click `UnZip-1.0.dmg`.
2. Drag **UnZip** into the **Applications** folder.
3. Open UnZip from Applications or Spotlight.
4. If macOS says the app cannot be opened, Control-click UnZip, choose **Open**, then click **Open** again.

### Installer package (`.pkg`)

1. Double-click `UnZip-1.0.pkg`.
2. Follow the steps and click **Install**.
3. UnZip is copied to `/Applications`.
4. Open UnZip from Applications or Spotlight.
5. If macOS blocks the first launch, Control-click UnZip in Applications, choose **Open**, then click **Open** again.

### Zip archive (`.zip`)

1. Double-click `UnZip-1.0-macos.zip` to unpack it.
2. Move `UnZip.app` into the **Applications** folder.
3. Open UnZip from Applications or Spotlight.
4. If macOS says the app cannot be opened, Control-click UnZip, choose **Open**, then click **Open** again.

The first-launch warning is expected. The app is not signed with an Apple Developer ID.

## After install

- Drop an archive on UnZip to open it, or drop a folder or file to compress it.
- In Finder, right-click a folder or file → **Services → Zip with UnZip**.
- If that service is missing, open **System Settings → Keyboard → Keyboard Shortcuts → Services**, then turn on **Zip with UnZip** under **Files and Folders**.

## Optional tools

- Extract RAR / 7Z: `brew install unar p7zip`
- Create RAR: install the WinRAR `rar` command-line tool

## Build the installers

From this project:

```bash
./scripts/package.sh
```

That writes `UnZip-1.0.dmg`, `UnZip-1.0.pkg`, and `UnZip-1.0-macos.zip` into `dist/`. Share any one of those files.

For a local copy only:

```bash
./scripts/build-app.sh --install
```

That copies `UnZip.app` into `~/Applications`.
