#!/bin/bash

# Package an Xcode-exported, Developer ID-signed and notarized app in a
# signed, notarized, and stapled drag-to-Applications disk image.

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
readonly PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

notary_profile="${NOTARYTOOL_PROFILE:-}"
signing_identity="${DMG_SIGNING_IDENTITY:-}"
output_path=""
volume_name=""
force=0
app_path=""
work_dir=""

usage() {
    cat <<EOF
Create a signed, notarized, and stapled DMG containing an exported macOS app
and an Applications-folder shortcut.

Usage:
  $SCRIPT_NAME [options] /path/to/Xray.app

Options:
  --notary-profile NAME  notarytool Keychain profile created with
                         'xcrun notarytool store-credentials' (required unless
                         NOTARYTOOL_PROFILE is set)
  --identity IDENTITY    Developer ID Application identity used to sign the
                         DMG (defaults to the identity that signed the app;
                         DMG_SIGNING_IDENTITY may also be set)
  --output PATH          Destination .dmg path (default:
                         Build/Distribution/<App>-<Version>.dmg)
  --volume-name NAME     Finder volume name (default: <App> <Version>)
  --force                Replace an existing output file after the new DMG has
                         passed all checks
  -h, --help             Show this help

Example:
  $SCRIPT_NAME --notary-profile xray-notary "/path/from/Xcode/export/Xray.app"

The input app is never modified or re-signed. It must already be exported with
a Developer ID Application signature and have its app notarization ticket
stapled (Xcode does this when you export the notarized archive again).
EOF
}

log() {
    printf '\n==> %s\n' "$*"
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$work_dir" && -d "$work_dir" ]]; then
        rm -rf -- "$work_dir"
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_value() {
    local option="$1"
    local value="${2:-}"
    [[ -n "$value" ]] || die "$option requires a value"
}

create_disk_image() {
    local diskutil_help=""

    if command -v diskutil >/dev/null 2>&1; then
        diskutil_help="$(diskutil help image create from 2>&1 || true)"
    fi

    if [[ "$diskutil_help" == *"USAGE: diskutil image create from"* ]]; then
        printf 'Using diskutil image create from.\n'
        diskutil image create from \
            --format UDZO \
            --volumeName "$volume_name" \
            "$staging_dir" \
            "$working_dmg"
    else
        printf 'Using hdiutil create (compatibility fallback).\n'
        hdiutil create \
            -volname "$volume_name" \
            -srcfolder "$staging_dir" \
            -fs HFS+ \
            -format UDZO \
            -ov \
            "$working_dmg"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --notary-profile)
            require_value "$1" "${2:-}"
            notary_profile="$2"
            shift 2
            ;;
        --identity)
            require_value "$1" "${2:-}"
            signing_identity="$2"
            shift 2
            ;;
        --output)
            require_value "$1" "${2:-}"
            output_path="$2"
            shift 2
            ;;
        --volume-name)
            require_value "$1" "${2:-}"
            volume_name="$2"
            shift 2
            ;;
        --force)
            force=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            [[ $# -eq 1 ]] || die "expected exactly one .app path"
            app_path="$1"
            shift
            ;;
        -*)
            die "unknown option: $1 (run '$SCRIPT_NAME --help' for usage)"
            ;;
        *)
            [[ -z "$app_path" ]] || die "expected exactly one .app path"
            app_path="$1"
            shift
            ;;
    esac
done

[[ -n "$app_path" ]] || die "missing .app path (run '$SCRIPT_NAME --help' for usage)"
[[ -n "$notary_profile" ]] || die \
    "provide --notary-profile NAME or set NOTARYTOOL_PROFILE"
[[ -d "$app_path" ]] || die "app does not exist: $app_path"
[[ "$app_path" == *.app ]] || die "input must be an .app bundle: $app_path"

for command_name in codesign ditto hdiutil plutil spctl xcrun; do
    command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done

app_path="$(cd "$(dirname "$app_path")" && pwd -P)/$(basename "$app_path")"
readonly app_path
readonly app_name="$(basename "$app_path")"
readonly display_name="${app_name%.app}"
readonly info_plist="$app_path/Contents/Info.plist"

[[ -f "$info_plist" ]] || die "missing app Info.plist: $info_plist"

bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$info_plist" 2>/dev/null || true)"
version="$(plutil -extract CFBundleShortVersionString raw -o - "$info_plist" 2>/dev/null || true)"
[[ -n "$bundle_id" ]] || die "CFBundleIdentifier is missing from $info_plist"

if [[ -z "$volume_name" ]]; then
    volume_name="$display_name"
    if [[ -n "$version" ]]; then
        volume_name="$volume_name $version"
    fi
fi

if [[ -z "$output_path" ]]; then
    output_filename="$display_name"
    if [[ -n "$version" ]]; then
        output_filename="$output_filename-$version"
    fi
    output_filename="$(printf '%s' "$output_filename" | tr ' /:' '---' | tr -cd '[:alnum:]._-')"
    output_path="$PROJECT_DIR/Build/Distribution/$output_filename.dmg"
fi

[[ "$output_path" == *.dmg ]] || die "output path must end in .dmg: $output_path"

output_dir="$(dirname "$output_path")"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd -P)"
output_path="$output_dir/$(basename "$output_path")"

if [[ ( -e "$output_path" || -L "$output_path" ) && $force -ne 1 ]]; then
    die "output already exists: $output_path (pass --force to replace it)"
fi
if [[ -d "$output_path" ]]; then
    die "output path is a directory: $output_path"
fi

log "Verifying the exported app"
codesign --verify --deep --strict --verbose=2 "$app_path"

codesign_details="$(codesign --display --verbose=4 "$app_path" 2>&1)"
app_signing_identity="$(printf '%s\n' "$codesign_details" | awk -F= \
    '/^Authority=Developer ID Application:/ { print substr($0, index($0, "=") + 1); exit }')"
[[ -n "$app_signing_identity" ]] || die \
    "the app is not signed with a Developer ID Application certificate"

if [[ -z "$signing_identity" ]]; then
    signing_identity="$app_signing_identity"
fi

printf 'App:              %s\n' "$app_path"
printf 'Bundle ID:        %s\n' "$bundle_id"
printf 'App signer:       %s\n' "$app_signing_identity"
printf 'DMG signer:       %s\n' "$signing_identity"
printf 'Notary profile:   %s\n' "$notary_profile"
printf 'Destination:      %s\n' "$output_path"

log "Validating the app's notarization ticket and Gatekeeper acceptance"
xcrun stapler validate -v "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"

work_dir="$(mktemp -d "$output_dir/.dmg-build.XXXXXX")"
readonly staging_dir="$work_dir/staging"
readonly working_dmg="$work_dir/$(basename "$output_path")"
readonly notary_result="$work_dir/notary-result.plist"
mkdir -p "$staging_dir"

log "Staging $app_name and the Applications shortcut"
ditto "$app_path" "$staging_dir/$app_name"
ln -s /Applications "$staging_dir/Applications"

log "Creating the compressed disk image"
create_disk_image

log "Signing the disk image"
codesign --force \
    --sign "$signing_identity" \
    --timestamp \
    --identifier "$bundle_id.dmg" \
    "$working_dmg"
codesign --verify --verbose=2 "$working_dmg"

log "Submitting the disk image to Apple's notary service"
notarytool_exit=0
xcrun notarytool submit "$working_dmg" \
    --keychain-profile "$notary_profile" \
    --wait \
    --timeout 2h \
    --output-format plist >"$notary_result" || notarytool_exit=$?

notary_status=""
submission_id=""
if [[ -s "$notary_result" ]]; then
    plutil -p "$notary_result" || true
    notary_status="$(plutil -extract status raw -o - "$notary_result" 2>/dev/null || true)"
    submission_id="$(plutil -extract id raw -o - "$notary_result" 2>/dev/null || true)"
fi

if [[ "$notary_status" != "Accepted" ]]; then
    if [[ -n "$submission_id" ]]; then
        printf '\nNotarization log for submission %s:\n' "$submission_id" >&2
        xcrun notarytool log "$submission_id" \
            --keychain-profile "$notary_profile" || true
    fi
    die "notarization was not accepted (status: ${notary_status:-unknown})"
fi
[[ $notarytool_exit -eq 0 ]] || die "notarytool exited with status $notarytool_exit"

log "Stapling and validating the disk image ticket"
xcrun stapler staple -v "$working_dmg"
xcrun stapler validate -v "$working_dmg"

log "Running final disk image and Gatekeeper checks"
hdiutil verify "$working_dmg"
codesign --verify --verbose=2 "$working_dmg"
spctl --assess \
    --type open \
    --context context:primary-signature \
    --verbose=2 \
    "$working_dmg"

if [[ -e "$output_path" || -L "$output_path" ]]; then
    rm -f -- "$output_path"
fi
mv "$working_dmg" "$output_path"

printf '\nDone: %s\n' "$output_path"
printf 'Notary submission: %s\n' "$submission_id"
