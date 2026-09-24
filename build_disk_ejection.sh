#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
source_file="$script_dir/disk_ejection.applescript"
helper_file="$script_dir/disk_ejection.sh"
dist_dir="$script_dir/dist"
app_path="$dist_dir/Disk Ejector.app"
installed_app_path="/Applications/disk ejection.app"
install_app=false

case "${1:-}" in
	"")
		;;
	--install)
		install_app=true
		;;
	*)
		print -u2 "Usage: ${0:t} [--install]"
		exit 64
		;;
esac

/bin/mkdir -p "$dist_dir"
/usr/bin/osacompile -o "$app_path" "$source_file"
/usr/bin/install -m 755 "$helper_file" "$app_path/Contents/Resources/disk_ejection.sh"

if ! /usr/libexec/PlistBuddy -c \
	'Add :CFBundleIdentifier string io.github.macos-disk-ejector' \
	"$app_path/Contents/Info.plist" 2>/dev/null; then
	/usr/libexec/PlistBuddy -c \
		'Set :CFBundleIdentifier io.github.macos-disk-ejector' \
		"$app_path/Contents/Info.plist"
fi

set_plist_string() {
	local key="$1"
	local value="$2"

	if /usr/libexec/PlistBuddy -c "Print :$key" "$app_path/Contents/Info.plist" >/dev/null 2>&1; then
		/usr/libexec/PlistBuddy -c "Set :$key $value" "$app_path/Contents/Info.plist"
	else
		/usr/libexec/PlistBuddy -c "Add :$key string $value" "$app_path/Contents/Info.plist"
	fi
}

set_plist_string CFBundleName "Disk Ejector"
set_plist_string CFBundleDisplayName "Disk Ejector"
set_plist_string CFBundleShortVersionString "1.0.0"
set_plist_string CFBundleVersion "1"

/usr/bin/xattr -cr "$app_path"
/usr/bin/codesign --force --deep --sign - "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"

print "Built: $app_path"

if [[ "$install_app" == true ]]; then
	/usr/bin/ditto "$app_path" "$installed_app_path"
	/usr/bin/xattr -cr "$installed_app_path"
	/usr/bin/codesign --force --deep --sign - "$installed_app_path"
	/usr/bin/codesign --verify --deep --strict "$installed_app_path"
	print "Installed: $installed_app_path"
fi
