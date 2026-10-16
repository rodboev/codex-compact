#!/usr/bin/env bash
# Linux port of Build-CodexCompact.ps1: builds the installed Codex version with the compact patch,
# verifies it, packages it under the standalone custom directory and points a launcher symlink at it.
set -euo pipefail
shopt -s nullglob

usage() {
    cat <<'EOF'
Usage: build-codex-compact.sh [--stock-dir DIR] [--standalone-root DIR] [--build-root DIR]
                              [--target-dir DIR] [--launcher PATH] [--check-only] [--no-activate]
EOF
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
standalone_root="$HOME/.codex/packages/standalone"
build_root="$HOME/.cache/codex-compact-build"
target_directory=''
launcher="$HOME/.local/bin/codex"
stock_dir=''
check_only=0
no_activate=0
while (($#)); do
    case "$1" in
        --stock-dir) stock_dir=$2; shift 2 ;;
        --standalone-root) standalone_root=$2; shift 2 ;;
        --build-root) build_root=$2; shift 2 ;;
        --target-dir) target_directory=$2; shift 2 ;;
        --launcher) launcher=$2; shift 2 ;;
        --check-only) check_only=1; shift ;;
        --no-activate) no_activate=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

# 0.159 replaced command grouping, so no upstream commit is reverted anymore.
reverted_commit=''
target=x86_64-unknown-linux-gnu
migration_probe="$script_dir/Build-CodexCompact.verify.py"
local_patch="$script_dir/Build-CodexCompact.patch"
local_patch_sha256=$(sha256sum "$local_patch" | cut -d' ' -f1)
state_home=$(dirname "$(dirname "$standalone_root")")
python=$(command -v python3 || command -v python)

die() { echo "error: $*" >&2; exit 1; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
json_get() { "$python" -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2], ""); print(v)' "$1" "$2"; }

run() {
    local log=''
    if [[ $1 == --log ]]; then log=$2; shift 2; fi
    if [[ -n $log ]]; then
        echo "Running $*"
        echo "Log: $log"
        if ! "$@" >"$log" 2>&1; then tail -n 30 "$log"; die "$1 failed."; fi
    else
        "$@" || die "$1 failed."
    fi
}

test_codex_binary() {
    local reported
    reported=$("$1" --version) || die "Version check failed for $1."
    [[ $reported == "codex-cli $2" ]] || die "Version check failed for $1. Reported '$reported'."
    "$1" --help >/dev/null || die "Help check failed for $1."
}

# The launcher is a symlink owned by this script; it is created or retargeted, never replaced if it is a real file.
enable_compact_build() {
    local package_dir=$1 version=$2 target_exe previous='' resolved
    target_exe=$(realpath "$package_dir/bin/codex")
    [[ $target_exe == "$(realpath "$standalone_root/custom")"/* ]] || die 'Activation target escaped the custom directory.'
    test_codex_binary "$target_exe" "$version"
    if [[ -e $launcher || -L $launcher ]]; then
        [[ -L $launcher ]] || die "The launcher path is not a symlink: $launcher"
        previous=$(readlink "$launcher")
        [[ $(realpath -m "$previous") == "$(realpath "$standalone_root")"/* ]] || die 'The launcher symlink points outside the standalone installation.'
    fi
    mkdir -p "$(dirname "$launcher")"
    ln -sfn "$target_exe" "$launcher.tmp.$$" && mv -Tf "$launcher.tmp.$$" "$launcher"
    if [[ $(realpath "$launcher") != "$target_exe" ]] || [[ $(sha "$launcher") != "$(sha "$target_exe")" ]] || ! (test_codex_binary "$launcher" "$version"); then
        if [[ -n $previous ]]; then ln -sfn "$previous" "$launcher"; else rm -f "$launcher"; fi
        die 'Launcher verification failed.'
    fi
    echo "Activated custom build: $launcher -> $target_exe"
    resolved=$(command -v codex || true)
    if [[ $(realpath "$resolved" 2>/dev/null) != "$target_exe" ]]; then
        echo "warning: 'codex' on PATH resolves to $resolved. Put $(dirname "$launcher") ahead of it to use the compact build."
    fi
}

install_tar_tool() {
    local name=$1 url=$2 directory=$3
    if [[ ! -x $directory/$name ]]; then
        mkdir -p "$directory"
        curl -fsSL "$url" | tar -xz -C "$directory" "$name"
    fi
    [[ -x $directory/$name ]] || die "Tool archive did not contain $name."
}

if [[ -z $stock_dir ]]; then
    # Newest npm-installed Linux package, such as mise's npm:@openai/codex.
    best=''
    for manifest in "$HOME"/.local/share/mise/installs/npm-openai-codex/*/node_modules/.mise/*/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/codex-package.json \
        "$(npm root -g 2>/dev/null || echo /nonexistent)"/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/codex-package.json; do
        [[ -f $manifest ]] || continue
        v=$(json_get "$manifest" version)
        [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        if [[ -z $best ]] || [[ $(printf '%s\n%s\n' "$best" "$v" | sort -V | tail -n1) == "$v" && $v != "$best" ]]; then
            best=$v
            stock_dir=$(dirname "$manifest")
        fi
    done
    [[ -n $stock_dir ]] || die 'No installed stable Linux Codex package found. Pass --stock-dir.'
fi
stock_manifest="$stock_dir/codex-package.json"
version=$(json_get "$stock_manifest" version)
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $(json_get "$stock_manifest" entrypoint) == bin/codex ]] || die 'The stock package has inconsistent metadata.'
test_codex_binary "$stock_dir/bin/codex" "$version"
custom_root="$standalone_root/custom"
package_name="$version-$target"
destination="$custom_root/$package_name-compact"
echo "Latest installed release: $version ($stock_dir)"
echo "Custom package: $destination"
((check_only)) && exit 0

mkdir -p "$build_root" "$custom_root"
exec 9>"$build_root/build.lock"
flock -n 9 || die "Another build holds $build_root/build.lock."

if [[ -e $destination ]]; then
    info_file="$destination/build-info.json"
    [[ -f $info_file ]] || die "An unverified package already exists at $destination. Inspect it before retrying."
    binary="$destination/bin/codex"
    [[ $(json_get "$info_file" version) == "$version" && $(json_get "$info_file" target) == "$target" && $(json_get "$info_file" revertedCommit) == "$reverted_commit" ]] || die 'Existing custom package has incompatible verification metadata.'
    [[ $(sha "$binary") == "$(json_get "$info_file" exeSha256)" ]] || die 'Existing custom executable checksum mismatch.'
    if [[ $(json_get "$info_file" status) == verified && $(json_get "$info_file" testsPassed) -gt 0 && $(json_get "$info_file" localPatchSha256) == "$local_patch_sha256" && $(json_get "$info_file" migrationLineEndings) == lf && $(json_get "$info_file" startupProbe) == passed ]]; then
        test_codex_binary "$binary" "$version"
        run "$python" "$migration_probe" "$(json_get "$info_file" sourceDirectory)" "$state_home" --binary "$binary" --probe "$build_root/startup-probe-$(uuidgen | tr -d -)"
        ((no_activate)) || enable_compact_build "$destination" "$version"
        echo "Already built and verified. Run: $binary"
        exit 0
    fi
    echo 'The existing package needs the current patch and verification. Building its replacement.'
fi

work="$build_root/c-$version-${local_patch_sha256:0:8}"
mkdir -p "$work"
exec > >(tee -a "$work/build-session.log") 2>&1
source="$work/source"
prepared="$work/prepared.json"
source_patch="$work/compact.patch"
if [[ ! -e $source ]]; then
    run git clone --depth 1 --branch "rust-v$version" https://github.com/openai/codex.git "$source"
    if [[ -n $reverted_commit ]]; then
        run git -C "$source" fetch --depth 2 origin "$reverted_commit"
        run git -C "$source" revert --no-commit -X theirs "$reverted_commit"
    fi
    run git -C "$source" apply --check "$local_patch"
    run git -C "$source" apply "$local_patch"
    # Track files the patch adds so diffs and the untracked-file check see them.
    run git -C "$source" add --intent-to-add --all
    source_version=$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$source/codex-rs/Cargo.toml" | head -n1)
    [[ $source_version == "$version" ]] || die "Source version $source_version does not match installed version $version."
    # Release tags can leave local package versions at 0.0.0 in Cargo.lock.
    "$python" - "$source/codex-rs/Cargo.lock" "$version" <<'EOF'
import re, sys
path, version = sys.argv[1], sys.argv[2]
text = open(path).read()
text = re.sub(r'(?m)(^name = "[^"]+"\nversion = ")0\.0\.0("\n)(?!source =)', lambda m: m.group(1) + version + m.group(2), text)
open(path, "w").write(text)
EOF
    # Official Linux builds embed LF migration bytes in their SQLx checksums, which matches the checkout.
    # Snapshots record rendered padding, so trailing spaces there are expected.
    run git -C "$source" diff --check HEAD -- . ':!*.snap'
    run git -C "$source" diff --binary "--output=$source_patch" HEAD
    printf '{"sourceCommit": "%s", "patchSha256": "%s"}\n' "$(git -C "$source" rev-parse HEAD)" "$(sha "$source_patch")" >"$prepared"
else
    [[ -f $prepared ]] || die "Source preparation previously failed at $source. Inspect that directory; the script will not reset it."
    run git -C "$source" diff --binary "--output=$source_patch" HEAD
    [[ $(git -C "$source" rev-parse HEAD) == "$(json_get "$prepared" sourceCommit)" && $(sha "$source_patch") == "$(json_get "$prepared" patchSha256)" ]] || die 'Prepared source has changed. Refusing to build unverified edits.'
    [[ -z $(git -C "$source" ls-files --others --exclude-standard) ]] || die 'Prepared source contains untracked files. Inspect them before retrying.'
fi

run --log "$work/migration-checksums.log" "$python" "$migration_probe" "$source" "$state_home"

channel=$(sed -n 's/^channel = "\([^"]*\)"/\1/p' "$source/codex-rs/rust-toolchain.toml")
rustup=$(command -v rustup || echo "$HOME/.cargo/bin/rustup")
if [[ ! -x $rustup ]]; then
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --default-toolchain none
fi
toolchain_bin="${RUSTUP_HOME:-$HOME/.rustup}/toolchains/$channel-$target/bin"
if [[ ! -x $toolchain_bin/cargo ]]; then
    run "$rustup" toolchain install "$channel" --profile minimal --component rustfmt,clippy,rust-src
fi
tools="$build_root/tools"
install_tar_tool just https://github.com/casey/just/releases/download/1.58.0/just-1.58.0-x86_64-unknown-linux-musl.tar.gz "$tools"
install_tar_tool cargo-nextest https://github.com/nextest-rs/nextest/releases/download/cargo-nextest-0.9.143/cargo-nextest-0.9.143-x86_64-unknown-linux-gnu.tar.gz "$tools"
export PATH="$tools:$toolchain_bin:$PATH"
export CARGO_TARGET_DIR="${target_directory:-$build_root/target}"

# Upstream tests that assert the command rows and diff previews compact mode hides.
hidden_by_design=(adjacent_exploration_groups_across_reasoning_live_and_replayed apply_patch_events_emit_history_cells apply_patch_manual_flow_snapshot exec_end_without_begin_does_not_flush_unrelated_running_exploring_cell exec_end_without_begin_flushes_completed_unrelated_exploring_cell exec_end_without_begin_uses_event_command exec_history_cell_shows_working_then_completed exec_history_cell_shows_working_then_failed exec_history_extends_previous_when_consecutive exec_history_shows_unified_exec_startup_commands exec_history_shows_unified_exec_tool_calls exploration_nonzero_exits_remain_visible_beside_successful_reads external_writer_snapshot_freezes_active_command_and_mcp_rows failed_exploration_keeps_overlapping_commands_active_until_all_finish final_worked_for_uses_cumulative_turn_duration_snapshot overlapping_exploring_exec_end_is_not_misclassified_as_orphan replayed_command_completion_preserves_tracking_without_duplicate_starts replayed_completion_preserves_unrelated_running_command unified_exec_unknown_end_with_active_exploring_cell_snapshot snapshot_formatter_completed_patch_needs_no_started_notification snapshot_formatter_live_and_buffered_patch_notifications_render_once active_command_without_animations_is_stable exploring_display_does_not_split_long_url_like_search_query powershell_skill_read_snapshot truncated_live_output_preview_and_transcript_snapshot compact_patches_retain_full_changes_and_failure_details coalesces_reads_across_multiple_calls activity_focus_keeps_controls_without_passive_hints updated_diff_copy_includes_signs_but_no_line_number_gutters wrapped_added_code_keeps_indentation_and_graphemes_when_copied_and_resized tool_selection_copies_its_displayed_revision_after_the_tool_commits find_expands_only_the_match_and_preserves_manual_disclosures terminal_output_disclosure_follows_live_history_and_keymap command_and_output_copy_preserve_hard_lines_across_resize terminal_output_disclosure_counts_only_revealable_lines)
excluded=$(printf 'test(~%s) | ' "${hidden_by_design[@]}")
test_filter="(test(compact_main_view) | test(multi_agents::) | test(web_search) | test(diff_render::) | test(pager_overlay::) | test(::patch) | test(_patch) | test(exec_cell::) | test(chatwidget::tests::exec_flow) | test(coalesces_reads_across_multiple_calls) | test(chatwidget::tests::permissions) | test(transcript_view::)) - (${excluded% | })"
(
    cd "$source/codex-rs"
    run --log "$work/format.log" cargo fmt -p codex-tui -- --check
    run --log "$work/tests.log" just test --locked --cargo-profile dev-small -p codex-tui --lib -E "$test_filter"
    run --log "$work/build.log" cargo build --locked --release --bin codex
)
summary=$(grep -oE '[0-9]+ tests run: [0-9]+ passed' "$work/tests.log" | tail -n1 || true)
read -r tests_run _ _ tests_passed _ <<<"$summary"
[[ -n $summary && $tests_run -ge 1 && $tests_run == "$tests_passed" ]] || die 'Focused tests did not report a passing nonempty test run.'
for test in compact_main_view_agent_message_commits_one_summary compact_main_view_approval_decision_follows_pending_summary compact_main_view_collab_headers_and_waits compact_main_view_concurrent_dynamic_tools_count_only_finished_calls compact_main_view_counts_patch_only_after_completion compact_main_view_failed_patch_matches_reflow_and_replay compact_main_view_file_changes_count_patch_calls compact_main_view_fullscreen_summarizes_tool_run compact_main_view_fullscreen_skill_and_manual_commands_break_runs compact_main_view_fullscreen_live_tail_follows_summary compact_main_view_fullscreen_appending_completing_and_removing_updates_head compact_main_view_fullscreen_summary_discloses_run_and_searches_members compact_main_view_fullscreen_user_prompt_has_plain_margins compact_main_view_inline_user_prompt_has_plain_margins compact_main_view_hides_search_progress_and_preserves_completed_searches compact_main_view_hides_terminal_interactions compact_main_view_labels_count_calls_in_fixed_order compact_main_view_late_agent_completion_commits_summary compact_main_view_live_summary_stays_above_running_call compact_main_view_multi_file_patch_counts_one_edit compact_main_view_preserves_skill_reads_and_manual_commands compact_main_view_queued_answer_fragments_preserve_spacing compact_main_view_reflow_regroups_runs_and_retains_live_tail compact_main_view_replay_groups_calls_and_closes_each_turn compact_main_view_shows_running_command_until_finished compact_main_view_skill_reads_and_manual_commands_break_runs file_edits_only_transcript_hides_other_cells; do
    grep -qE "PASS.*$test" "$work/tests.log" || die "Required regression test did not pass: $test"
done
binary="$CARGO_TARGET_DIR/release/codex"
test_codex_binary "$binary" "$version"

staging="$custom_root/.staging-$package_name-$(uuidgen | tr -d -)"
mkdir -p "$staging/bin"
cp -a "$stock_dir/codex-resources" "$stock_dir/codex-path" "$stock_dir/codex-package.json" "$staging/"
cp -a "$stock_dir/bin/codex-code-mode-host" "$staging/bin/"
cp "$binary" "$staging/bin/codex"
cp "$source_patch" "$work/format.log" "$work/build.log" "$work/tests.log" "$staging/"
run --log "$work/startup-probe.log" "$python" "$migration_probe" "$source" "$state_home" --binary "$staging/bin/codex" --probe "$work/startup-probe-$(uuidgen | tr -d -)"
cp "$work/startup-probe.log" "$work/migration-checksums.log" "$staging/"
"$python" - "$staging/build-info.json" <<EOF
import json, sys
from datetime import datetime, timezone
info = {"status": "verified", "version": "$version", "target": "$target", "sourceCommit": "$(git -C "$source" rev-parse HEAD)", "restoredPullRequest": 38921, "revertedCommit": "$reverted_commit", "exeSha256": "$(sha "$binary")", "testsPassed": $tests_passed, "verifiedAtUtc": datetime.now(timezone.utc).isoformat(), "buildProfile": "release", "sourceDirectory": "$source", "patchSha256": "$(sha "$source_patch")", "migrationLineEndings": "lf", "startupProbe": "passed", "localPatchSha256": "$local_patch_sha256"}
json.dump(info, open(sys.argv[1], "w"), indent=2)
EOF
test_codex_binary "$staging/bin/codex" "$version"
backup=''
if [[ -e $destination ]]; then
    backup="$custom_root/.replaced-$package_name-$(uuidgen | tr -d -)"
    mv -T "$destination" "$backup"
fi
if ! mv -T "$staging" "$destination"; then
    [[ -n $backup && ! -e $destination ]] && mv -T "$backup" "$destination"
    die "Could not move $staging into place."
fi
[[ -z $backup ]] || rm -rf "$backup"
((no_activate)) || enable_compact_build "$destination" "$version"
echo "Built and verified $version. $tests_passed focused tests passed."
echo "Run: $destination/bin/codex"
