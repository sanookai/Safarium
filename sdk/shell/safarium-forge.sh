#!/bin/sh
# POSIX / zsh helper SDK wrapping `safarium-render forge` (SF-VIDEO-1 compliant).
# Source this file (`source sdk/shell/safarium-forge.sh`) or execute subcommands directly.

forge_render_bin() {
    if [ -n "${SAFARIUM_RENDER_BIN:-}" ]; then
        printf '%s\n' "$SAFARIUM_RENDER_BIN"
    else
        printf '%s\n' "$HOME/.local/bin/safarium-render"
    fi
}

forge_exec() {
    _bin="$(forge_render_bin)"
    "$_bin" forge "$@"
}

forge_capabilities() { forge_exec capabilities "$@"; }
forge_version()      { forge_exec version "$@"; }
forge_run()          { forge_exec run --recipe "$@"; }
forge_validate()     { forge_exec validate --recipe "$@"; }
forge_remux()        { forge_exec remux "$@"; }
forge_inspect()      { forge_exec inspect "$@"; }
forge_image()        { forge_exec image "$@"; }
forge_audio()        { forge_exec audio "$@"; }
forge_sheet()        { forge_exec sheet "$@"; }
forge_compare()      { forge_exec compare "$@"; }
forge_pq()           { forge_exec pq "$@"; }
forge_qa()           { forge_exec qa "$@"; }
forge_reframe()      { forge_exec reframe "$@"; }
forge_matte()        { forge_exec matte "$@"; }
forge_pipe_encode()  { forge_exec pipe-encode "$@"; }
forge_daemon()       { forge_exec daemon "$@"; }
forge_ring_encode()  { forge_exec ring-encode "$@"; }
forge_cache()        { forge_exec cache "$@"; }
forge_ab_gallery()   { forge_exec ab-gallery "$@"; }
forge_prism()                { forge_exec prism "$@"; }
forge_prism_capabilities()   { forge_exec prism capabilities "$@"; }
forge_prism_sync_ir()        { forge_exec prism sync-ir "$@"; }
forge_prism_preview_stills() { forge_exec prism preview-stills "$@"; }
forge_prism_render_web()     { forge_exec prism render-web "$@"; }
forge_prism_render_blender() { forge_exec prism render-blender "$@"; }
forge_prism_composite()      { forge_exec prism composite "$@"; }

if [ "${0##*/}" = "safarium-forge.sh" ] && [ "${ZSH_EVAL_CONTEXT:-}" != "toplevel:file" ]; then
    if [ "$#" -eq 0 ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
        forge_exec --help
    else
        forge_exec "$@"
    fi
fi
