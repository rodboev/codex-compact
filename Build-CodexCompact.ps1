#requires -Version 7.4
[CmdletBinding()]
param(
    [string]$StandaloneRoot = "$env:USERPROFILE\.codex\packages\standalone",
    [string]$BuildRoot = 'D:\ccbuild',
    [string]$TargetDirectory,
    [string]$LauncherBin = "$env:LOCALAPPDATA\Programs\OpenAI\Codex\bin",
    [switch]$CheckOnly,
    [switch]$NoActivate
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# 0.159 replaced command grouping, so no upstream commit is reverted anymore.
$RevertedCommit = ''
$Target = 'x86_64-pc-windows-msvc'
$MigrationProbe = Join-Path $PSScriptRoot 'Build-CodexCompact.verify.py'
$LocalPatch = Join-Path $PSScriptRoot 'Build-CodexCompact.patch'
$LocalPatchSha256 = (Get-FileHash -LiteralPath $LocalPatch -Algorithm SHA256).Hash
$StateHome = Split-Path (Split-Path $StandaloneRoot -Parent) -Parent

function Invoke-Native {
    param([string]$Executable, [string[]]$Arguments, [string]$Log)
    if ($Log) {
        Write-Host "Running $Executable $($Arguments -join ' ')"
        Write-Host "Log: $Log"
        & $Executable @Arguments *> $Log
    } else {
        & $Executable @Arguments | Out-Host
    }
    if ($LASTEXITCODE -ne 0) {
        if ($Log) { Get-Content -LiteralPath $Log -Tail 30 | Out-Host }
        throw "$Executable exited with code $LASTEXITCODE."
    }
}

function Test-CodexBinary {
    param([string]$Path, [string]$Version)
    $reported = (& $Path --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $reported -ne "codex-cli $Version") { throw "Version check failed for $Path. Reported '$reported'." }
    & $Path --help > $null
    if ($LASTEXITCODE -ne 0) { throw "Help check failed for $Path." }
}

function Enable-CompactBuild {
    param([string]$PackageDirectory, [string]$Version)
    $targetBin = [IO.Path]::GetFullPath((Join-Path $PackageDirectory 'bin'))
    $ownedRoot = [IO.Path]::GetFullPath($StandaloneRoot).TrimEnd('\') + '\'
    $customPrefix = [IO.Path]::GetFullPath((Join-Path $StandaloneRoot 'custom')).TrimEnd('\') + '\'
    if (!$targetBin.StartsWith($customPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Activation target escaped the custom directory.' }
    Test-CodexBinary -Path (Join-Path $targetBin 'codex.exe') -Version $Version
    if (!('CodexCompact.Junction' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace CodexCompact {
    public static class Junction {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(SafeFileHandle handle, uint control, byte[] input, int inputSize, IntPtr output, int outputSize, out int returned, IntPtr overlapped);
        public static void SetTarget(string link, string target) {
            byte[] name = Encoding.Unicode.GetBytes("\\??\\" + Path.GetFullPath(target));
            if (name.Length > 16364) { throw new ArgumentException("Junction target is too long."); }
            byte[] buffer = new byte[name.Length + 20];
            using (var writer = new BinaryWriter(new MemoryStream(buffer))) {
                writer.Write(0xA0000003u);
                writer.Write(checked((ushort)(name.Length + 12)));
                writer.Write((ushort)0);
                writer.Write((ushort)0);
                writer.Write(checked((ushort)name.Length));
                writer.Write(checked((ushort)(name.Length + 2)));
                writer.Write((ushort)0);
                writer.Write(name);
            }
            using (SafeFileHandle handle = CreateFileW(link, 0x40000000, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
                if (handle.IsInvalid) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
                int returned;
                if (!DeviceIoControl(handle, 0x000900A4, buffer, buffer.Length, IntPtr.Zero, 0, out returned, IntPtr.Zero)) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
            }
        }
    }
}
'@
    }
    # Share the stock installer's lock and retarget the junction without removing it.
    $installLock = [IO.File]::Open((Join-Path $StandaloneRoot 'install.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $link = Get-Item -LiteralPath $LauncherBin -Force
        if ($link.LinkType -ne 'Junction') { throw "The launcher bin path is not a junction: $LauncherBin" }
        $previousTarget = [string]$link.Target
        if (![IO.Path]::GetFullPath($previousTarget).StartsWith($ownedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'The launcher junction points outside the standalone installation.' }
        $changed = ![IO.Path]::GetFullPath($previousTarget).Equals($targetBin, [StringComparison]::OrdinalIgnoreCase)
        if ($changed) { [CodexCompact.Junction]::SetTarget($LauncherBin, $targetBin) }
        try {
            $actualTarget = [string](Get-Item -LiteralPath $LauncherBin -Force).Target
            if (![IO.Path]::GetFullPath($actualTarget).Equals($targetBin, [StringComparison]::OrdinalIgnoreCase)) { throw 'Launcher junction target verification failed.' }
            $launcherExe = Join-Path $LauncherBin 'codex.exe'
            if ((Get-FileHash -LiteralPath $launcherExe).Hash -ne (Get-FileHash -LiteralPath (Join-Path $targetBin 'codex.exe')).Hash) { throw 'Launcher executable checksum mismatch.' }
            Test-CodexBinary -Path $launcherExe -Version $Version
        } catch {
            if ($changed) { [CodexCompact.Junction]::SetTarget($LauncherBin, $previousTarget) }
            throw
        }
        Write-Host "Activated custom build: $LauncherBin -> $targetBin"
    } finally { $installLock.Dispose() }
}

function Install-ZipTool {
    param([string]$Name, [string]$Url, [string]$Directory)
    $binary = Join-Path $Directory $Name
    if (!(Test-Path -LiteralPath $binary)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
        $archive = Join-Path $Directory "$Name.zip"
        Invoke-WebRequest -Uri $Url -OutFile $archive
        Expand-Archive -LiteralPath $archive -DestinationPath $Directory -Force
    }
    if (!(Test-Path -LiteralPath $binary)) { throw "Tool archive did not contain $Name." }
}

$releases = Join-Path $StandaloneRoot 'releases'
$candidates = @(Get-ChildItem -LiteralPath $releases -Directory | ForEach-Object {
    if ($_.Name -match '^([0-9]+\.[0-9]+\.[0-9]+)-x86_64-pc-windows-msvc$') {
        [pscustomobject]@{ Version = $Matches[1]; SortVersion = [version]$Matches[1]; Directory = $_.FullName; Name = $_.Name }
    }
})
if ($candidates.Count -eq 0) { throw "No installed stable $Target releases found in $releases." }
$latest = $candidates | Sort-Object SortVersion -Descending | Select-Object -First 1
$version = $latest.Version
$stock = Get-Content -LiteralPath (Join-Path $latest.Directory 'codex-package.json') -Raw | ConvertFrom-Json
if ($stock.version -ne $version -or $stock.target -ne $Target -or $stock.entrypoint -ne 'bin/codex.exe') { throw 'The newest release has inconsistent package metadata.' }
Test-CodexBinary -Path (Join-Path $latest.Directory 'bin\codex.exe') -Version $version
$customRoot = Join-Path $StandaloneRoot 'custom'
$destination = Join-Path $customRoot "$($latest.Name)-compact"
Write-Host "Latest installed release: $version"
Write-Host "Custom package: $destination"
if ($CheckOnly) { return }

New-Item -ItemType Directory -Path $BuildRoot -Force | Out-Null
$buildLock = $null
$transcribing = $false
try {
    $buildLock = [IO.File]::Open((Join-Path $BuildRoot 'build.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    if (Test-Path -LiteralPath $destination) {
        $infoFile = Join-Path $destination 'build-info.json'
        if (!(Test-Path -LiteralPath $infoFile)) { throw "An unverified package already exists at $destination. Inspect it before retrying." }
        $info = Get-Content -LiteralPath $infoFile -Raw | ConvertFrom-Json
        $binary = Join-Path $destination 'bin\codex.exe'
        if ($info.version -ne $version -or $info.target -ne $Target -or $info.revertedCommit -ne $RevertedCommit) { throw 'Existing custom package has incompatible verification metadata.' }
        if ((Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash -ne $info.exeSha256) { throw 'Existing custom executable checksum mismatch.' }
        if ($info.status -eq 'verified' -and $info.testsPassed -gt 0 -and $info.PSObject.Properties['localPatchSha256'] -and $info.localPatchSha256 -eq $LocalPatchSha256 -and $info.PSObject.Properties['migrationLineEndings'] -and $info.migrationLineEndings -eq 'crlf' -and $info.PSObject.Properties['startupProbe'] -and $info.startupProbe -eq 'passed') {
            Test-CodexBinary -Path $binary -Version $version
            $probeHome = Join-Path $BuildRoot ('startup-probe-' + [guid]::NewGuid().ToString('N'))
            Invoke-Native -Executable python -Arguments @($MigrationProbe, $info.sourceDirectory, $StateHome, '--binary', $binary, '--probe', $probeHome)
            if (!$NoActivate) { Enable-CompactBuild -PackageDirectory $destination -Version $version }
            Write-Host "Already built and verified. Run: $binary"
            return
        }
        Write-Host 'The existing package needs the current patch and verification. Building its replacement.'
    }

    $work = Join-Path $BuildRoot ("c-" + $version + "-" + $LocalPatchSha256.Substring(0, 8))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    Start-Transcript -LiteralPath (Join-Path $work 'build-session.log') -Append | Out-Null
    $transcribing = $true
    $source = Join-Path $work 'source'
    $prepared = Join-Path $work 'prepared.json'
    $sourcePatch = Join-Path $work 'compact.patch'
    if (!(Test-Path -LiteralPath $source)) {
        Invoke-Native -Executable git -Arguments @('clone', '--depth', '1', '--branch', "rust-v$version", 'https://github.com/openai/codex.git', $source)
        if ($RevertedCommit) {
            Invoke-Native -Executable git -Arguments @('-C', $source, 'fetch', '--depth', '2', 'origin', $RevertedCommit)
            Invoke-Native -Executable git -Arguments @('-C', $source, 'revert', '--no-commit', '-X', 'theirs', $RevertedCommit)
        }
        Invoke-Native -Executable git -Arguments @('-C', $source, 'apply', '--check', $LocalPatch)
        Invoke-Native -Executable git -Arguments @('-C', $source, 'apply', $LocalPatch)
        # Track files the patch adds so diffs and the untracked-file check see them.
        Invoke-Native -Executable git -Arguments @('-C', $source, 'add', '--intent-to-add', '--all')
        Invoke-Native -Executable git -Arguments @('-C', $source, 'config', 'core.autocrlf', 'true')
        $manifest = Get-Content -LiteralPath (Join-Path $source 'codex-rs\Cargo.toml') -Raw
        $sourceVersion = [regex]::Match($manifest, '(?m)^version = "([^"]+)"').Groups[1].Value
        if ($sourceVersion -ne $version) { throw "Source version $sourceVersion does not match installed version $version." }
        # Release tags can leave local package versions at 0.0.0 in Cargo.lock.
        $lockPath = Join-Path $source 'codex-rs\Cargo.lock'
        $lockText = [IO.File]::ReadAllText($lockPath)
        $lockText = [regex]::Replace($lockText, '(?m)(^name = "[^"]+"\r?\nversion = ")0\.0\.0("\r?\n)(?!source =)', ('${1}' + $version + '${2}'))
        [IO.File]::WriteAllText($lockPath, $lockText)
        # Official Windows builds embed CRLF migration bytes in their SQLx checksums.
        $migrationFiles = @(Get-ChildItem -LiteralPath (Join-Path $source 'codex-rs\state') -Directory | Where-Object Name -Match 'migrations$' | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter '*.sql' })
        if ($migrationFiles.Count -eq 0) { throw 'No embedded SQL migrations found.' }
        foreach ($file in $migrationFiles) {
            $sql = [IO.File]::ReadAllText($file.FullName).Replace("`r`n", "`n").Replace("`n", "`r`n")
            [IO.File]::WriteAllText($file.FullName, $sql)
        }
        Invoke-Native -Executable git -Arguments @('-C', $source, 'diff', '--check', 'HEAD', '--', '.', ':!*.snap')
        Invoke-Native -Executable git -Arguments @('-C', $source, 'diff', '--binary', "--output=$sourcePatch", 'HEAD')
        @{ sourceCommit = (& git -C $source rev-parse HEAD).Trim(); patchSha256 = (Get-FileHash -LiteralPath $sourcePatch).Hash } | ConvertTo-Json | Set-Content -LiteralPath $prepared -Encoding utf8
    } else {
        if (!(Test-Path -LiteralPath $prepared)) { throw "Source preparation previously failed at $source. Inspect that directory; the script will not reset it." }
        $expected = Get-Content -LiteralPath $prepared -Raw | ConvertFrom-Json
        Invoke-Native -Executable git -Arguments @('-C', $source, 'diff', '--binary', "--output=$sourcePatch", 'HEAD')
        if ((& git -C $source rev-parse HEAD).Trim() -ne $expected.sourceCommit -or (Get-FileHash -LiteralPath $sourcePatch).Hash -ne $expected.patchSha256) { throw 'Prepared source has changed. Refusing to build unverified edits.' }
        if (@(& git -C $source ls-files --others --exclude-standard).Count -ne 0) { throw 'Prepared source contains untracked files. Inspect them before retrying.' }
    }

    Invoke-Native -Executable python -Arguments @($MigrationProbe, $source, $StateHome) -Log (Join-Path $work 'migration-checksums.log')

    $channel = [regex]::Match((Get-Content -LiteralPath (Join-Path $source 'codex-rs\rust-toolchain.toml') -Raw), '(?m)^channel = "([^"]+)"').Groups[1].Value
    $toolchainBin = Join-Path "$env:USERPROFILE\.rustup\toolchains" "$channel-$Target\bin"
    if (!(Test-Path -LiteralPath (Join-Path $toolchainBin 'cargo.exe'))) {
        $rustup = Get-Command rustup.exe -ErrorAction SilentlyContinue
        $rustupPath = if ($rustup) { $rustup.Source } else { "$env:USERPROFILE\.cargo\bin\rustup.exe" }
        if (!(Test-Path -LiteralPath $rustupPath)) {
            $installer = Join-Path $work 'rustup-init.exe'
            Invoke-WebRequest -Uri 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe' -OutFile $installer
            Invoke-Native -Executable $installer -Arguments @('-y', '--no-modify-path', '--default-toolchain', 'none')
        }
        Invoke-Native -Executable $rustupPath -Arguments @('toolchain', 'install', $channel, '--profile', 'minimal', '--component', 'rustfmt,clippy,rust-src')
    }
    $tools = Join-Path $BuildRoot 'tools'
    Install-ZipTool -Name 'just.exe' -Url 'https://github.com/casey/just/releases/download/1.58.0/just-1.58.0-x86_64-pc-windows-msvc.zip' -Directory $tools
    Install-ZipTool -Name 'cargo-nextest.exe' -Url 'https://github.com/nextest-rs/nextest/releases/download/cargo-nextest-0.9.143/cargo-nextest-0.9.143-x86_64-pc-windows-msvc.zip' -Directory $tools
    $env:PATH = "$tools;$toolchainBin;$env:PATH"
    if (!$TargetDirectory) {
        $initialCache = 'D:\Repos\codex-compact-command\codex-rs\target'
        $TargetDirectory = if (Test-Path -LiteralPath $initialCache) { $initialCache } else { Join-Path $BuildRoot 'target' }
    }
    $env:CARGO_TARGET_DIR = $TargetDirectory
    # Upstream tests that assert the command rows and diff previews compact mode hides.
    $hiddenByDesign = @('adjacent_exploration_groups_across_reasoning_live_and_replayed', 'apply_patch_events_emit_history_cells', 'apply_patch_manual_flow_snapshot', 'exec_end_without_begin_does_not_flush_unrelated_running_exploring_cell', 'exec_end_without_begin_flushes_completed_unrelated_exploring_cell', 'exec_end_without_begin_uses_event_command', 'exec_history_cell_shows_working_then_completed', 'exec_history_cell_shows_working_then_failed', 'exec_history_extends_previous_when_consecutive', 'exec_history_shows_unified_exec_startup_commands', 'exec_history_shows_unified_exec_tool_calls', 'exploration_nonzero_exits_remain_visible_beside_successful_reads', 'external_writer_snapshot_freezes_active_command_and_mcp_rows', 'failed_exploration_keeps_overlapping_commands_active_until_all_finish', 'final_worked_for_uses_cumulative_turn_duration_snapshot', 'overlapping_exploring_exec_end_is_not_misclassified_as_orphan', 'replayed_command_completion_preserves_tracking_without_duplicate_starts', 'replayed_completion_preserves_unrelated_running_command', 'unified_exec_unknown_end_with_active_exploring_cell_snapshot', 'snapshot_formatter_completed_patch_needs_no_started_notification', 'snapshot_formatter_live_and_buffered_patch_notifications_render_once', 'active_command_without_animations_is_stable', 'exploring_display_does_not_split_long_url_like_search_query', 'powershell_skill_read_snapshot', 'truncated_live_output_preview_and_transcript_snapshot', 'compact_patches_retain_full_changes_and_failure_details', 'coalesces_reads_across_multiple_calls', 'activity_focus_keeps_controls_without_passive_hints', 'updated_diff_copy_includes_signs_but_no_line_number_gutters', 'wrapped_added_code_keeps_indentation_and_graphemes_when_copied_and_resized', 'tool_selection_copies_its_displayed_revision_after_the_tool_commits', 'find_expands_only_the_match_and_preserves_manual_disclosures', 'terminal_output_disclosure_follows_live_history_and_keymap', 'command_and_output_copy_preserve_hard_lines_across_resize', 'terminal_output_disclosure_counts_only_revealable_lines')
    $testFilter = '(test(compact_main_view) | test(multi_agents::) | test(web_search) | test(diff_render::) | test(pager_overlay::) | test(::patch) | test(_patch) | test(exec_cell::) | test(chatwidget::tests::exec_flow) | test(coalesces_reads_across_multiple_calls) | test(chatwidget::tests::permissions) | test(transcript_view::)) - (' + (($hiddenByDesign | ForEach-Object { "test(~$_)" }) -join ' | ') + ')'
    Push-Location (Join-Path $source 'codex-rs')
    try {
        Invoke-Native -Executable cargo -Arguments @('fmt', '-p', 'codex-tui', '--', '--check') -Log (Join-Path $work 'format.log')
        Invoke-Native -Executable just -Arguments @('test', '--locked', '--cargo-profile', 'dev-small', '-p', 'codex-tui', '--lib', '-E', $testFilter) -Log (Join-Path $work 'tests.log')
        Invoke-Native -Executable cargo -Arguments @('build', '--locked', '--release', '--bin', 'codex') -Log (Join-Path $work 'build.log')
    } finally { Pop-Location }
    $testLog = Get-Content -LiteralPath (Join-Path $work 'tests.log') -Raw
    $summary = [regex]::Match($testLog, '(\d+) tests run: (\d+) passed')
    if (!$summary.Success -or [int]$summary.Groups[1].Value -lt 1 -or $summary.Groups[1].Value -ne $summary.Groups[2].Value) { throw 'Focused tests did not report a passing nonempty test run.' }
    foreach ($test in @('compact_main_view_agent_message_commits_one_summary', 'compact_main_view_approval_decision_follows_pending_summary', 'compact_main_view_collab_headers_and_waits', 'compact_main_view_concurrent_dynamic_tools_count_only_finished_calls', 'compact_main_view_counts_patch_only_after_completion', 'compact_main_view_failed_patch_matches_reflow_and_replay', 'compact_main_view_file_changes_count_patch_calls', 'compact_main_view_fullscreen_summarizes_tool_run', 'compact_main_view_fullscreen_skill_and_manual_commands_break_runs', 'compact_main_view_fullscreen_live_tail_follows_summary', 'compact_main_view_fullscreen_appending_completing_and_removing_updates_head', 'compact_main_view_fullscreen_summary_discloses_run_and_searches_members', 'compact_main_view_hides_search_progress_and_preserves_completed_searches', 'compact_main_view_hides_terminal_interactions', 'compact_main_view_labels_count_calls_in_fixed_order', 'compact_main_view_late_agent_completion_commits_summary', 'compact_main_view_live_summary_stays_above_running_call', 'compact_main_view_multi_file_patch_counts_one_edit', 'compact_main_view_preserves_skill_reads_and_manual_commands', 'compact_main_view_queued_answer_fragments_preserve_spacing', 'compact_main_view_reflow_regroups_runs_and_retains_live_tail', 'compact_main_view_replay_groups_calls_and_closes_each_turn', 'compact_main_view_shows_running_command_until_finished', 'compact_main_view_skill_reads_and_manual_commands_break_runs', 'file_edits_only_transcript_hides_other_cells')) {
        if ($testLog -notmatch ('(?m)PASS[^\r\n]*' + [regex]::Escape($test))) { throw "Required regression test did not pass: $test" }
    }
    $binary = Join-Path $TargetDirectory 'release\codex.exe'
    Test-CodexBinary -Path $binary -Version $version
    $staging = Join-Path $customRoot ('.staging-' + $latest.Name + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $staging 'bin') -Force | Out-Null
    foreach ($item in @('codex-resources', 'codex-path', 'codex-package.json')) { Copy-Item -LiteralPath (Join-Path $latest.Directory $item) -Destination $staging -Recurse }
    Copy-Item -LiteralPath (Join-Path $latest.Directory 'bin\codex-code-mode-host.exe') -Destination (Join-Path $staging 'bin')
    Copy-Item -LiteralPath $binary -Destination (Join-Path $staging 'bin\codex.exe')
    Copy-Item -LiteralPath $sourcePatch -Destination $staging
    foreach ($log in @('format.log', 'build.log', 'tests.log')) { Copy-Item -LiteralPath (Join-Path $work $log) -Destination $staging }
    $probeHome = Join-Path $work ('startup-probe-' + [guid]::NewGuid().ToString('N'))
    Invoke-Native -Executable python -Arguments @($MigrationProbe, $source, $StateHome, '--binary', (Join-Path $staging 'bin\codex.exe'), '--probe', $probeHome) -Log (Join-Path $work 'startup-probe.log')
    Copy-Item -LiteralPath (Join-Path $work 'startup-probe.log'), (Join-Path $work 'migration-checksums.log') -Destination $staging
    $info = [ordered]@{ status = 'verified'; version = $version; target = $Target; sourceCommit = (& git -C $source rev-parse HEAD).Trim(); restoredPullRequest = 38921; revertedCommit = $RevertedCommit; exeSha256 = (Get-FileHash -LiteralPath $binary).Hash; testsPassed = [int]$summary.Groups[2].Value; verifiedAtUtc = [DateTime]::UtcNow.ToString('o'); buildProfile = 'release'; sourceDirectory = $source; patchSha256 = (Get-FileHash -LiteralPath $sourcePatch).Hash; migrationLineEndings = 'crlf'; startupProbe = 'passed'; localPatchSha256 = $LocalPatchSha256 }
    $info | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $staging 'build-info.json') -Encoding utf8
    Test-CodexBinary -Path (Join-Path $staging 'bin\codex.exe') -Version $version
    $resolvedCustom = [IO.Path]::GetFullPath($customRoot).TrimEnd('\') + '\'
    foreach ($path in @($staging, $destination)) {
        if (![IO.Path]::GetFullPath($path).StartsWith($resolvedCustom, [StringComparison]::OrdinalIgnoreCase)) { throw 'Package path escaped the custom directory.' }
    }
    $backup = $null
    if (Test-Path -LiteralPath $destination) {
        $backup = Join-Path $customRoot ('.replaced-' + $latest.Name + '-' + [guid]::NewGuid().ToString('N'))
        if (![IO.Path]::GetFullPath($backup).StartsWith($resolvedCustom, [StringComparison]::OrdinalIgnoreCase)) { throw 'Backup path escaped the custom directory.' }
        Move-Item -LiteralPath $destination -Destination $backup
    }
    try {
        Move-Item -LiteralPath $staging -Destination $destination
    } catch {
        if ($backup -and !(Test-Path -LiteralPath $destination)) { Move-Item -LiteralPath $backup -Destination $destination }
        throw
    }
    if (!$NoActivate) { Enable-CompactBuild -PackageDirectory $destination -Version $version }
    Write-Host "Built and verified $version. $($info.testsPassed) focused tests passed."
    Write-Host "Run: $(Join-Path $destination 'bin\codex.exe')"
} finally {
    if ($transcribing) { Stop-Transcript | Out-Null }
    if ($buildLock) { $buildLock.Dispose() }
}
