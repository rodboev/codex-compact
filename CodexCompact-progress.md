- [x] Inspect the restored upstream command folding code.
- [x] Hide agent command rows and terminal polling in the normal view. Keep skill reads terse and preserve Ctrl+T details.
- [x] Pass 120 focused tests covering command execution, rendering, and approvals.
- [x] Update Build-CodexCompact.ps1 to use the compact slug, apply the additional patch, and verify its hash before reusing a package.
- [x] Build the release executable.
- [x] Package the executable separately and verify startup and 65 migration checksums.
- [x] Verify that the builder reuses the new package without changing the default launcher.
- [x] Prepare the executable at file:///C:/Users/Rod/.codex/packages/standalone/custom/0.153.4-x86_64-pc-windows-msvc-compact/bin/codex.exe 
- [x] Rod approves the trial output.

- [x] Activate compact through the launcher junction and verify PATH resolution and executable checksum.

- [x] Show only the header for file additions, edits, deletions, and multi-file patches.
- [x] Verify that Ctrl+T retains file contents and diffs.
- [x] Rebuild compact and update its installed package. New sessions show only file-change headers.

- [x] Hide search progress rows and preserve completed search rows.
- [x] Verify search rendering and transcript details.
- [x] Rebuild and activate the updated compact package.

- [x] Hide agent wait rows and show agent event headers only.
- [x] Remove blank separators before bullet rows.
- [x] Verify compact agent rendering and spacing.
- [x] Build and activate the updated compact package.

- [x] Preserve a blank line before the first bullet after input.
- [x] Verify spacing during insertion and replay.
- [x] Rebuild and activate input spacing update.

- [x] Port the compact patch to 0.155.1, including renamed tool flushing and removed message separators.
- [x] Build and activate 0.155.1 compact through the normal codex command.
