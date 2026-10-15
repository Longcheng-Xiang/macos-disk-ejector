#!/bin/zsh
set -u

readonly -a SERVICE_NAMES=(
	Spotlight
	photoanalysisd
	photolibraryd
	mediaanalysisd
	managedcorespotlightd
	cloudphotod
	PhotosReliveWidget
	"Siri AI"
)
readonly RELEASES_URL="https://github.com/Longcheng-Xiang/macos-disk-ejector/releases"
readonly LOG_FILE="$HOME/Library/Logs/Disk Ejector.log"

typeset ACTIVE_CHILD_PID=""
typeset ACTIVE_STATUS_FILE=""
typeset ACTIVE_TEMP_FILE=""
typeset PARENT_APP_PID=""
typeset DISKUTIL_PLIST=""
typeset EXTERNAL_PHYSICAL_PLIST=""
typeset RESOLVED_WHOLE_DISK=""
typeset RESOLVED_PHYSICAL_PLIST=""
typeset EJECT_OUTPUT_FILE=""

diskutil_info_plist() {
	local target="$1"
	local output_file
	local info_pid
	local info_status
	local ticks=0
	local max_ticks=12

	output_file="$(/usr/bin/mktemp /tmp/macos-disk-ejector-info.XXXXXX)" || return 1
	ACTIVE_TEMP_FILE="$output_file"
	/usr/sbin/diskutil info -plist "$target" > "$output_file" 2>/dev/null &
	info_pid=$!
	ACTIVE_CHILD_PID="$info_pid"

	while /bin/kill -0 "$info_pid" 2>/dev/null; do
		if ! parent_app_is_running; then
			/bin/kill -TERM "$info_pid" 2>/dev/null || true
			wait "$info_pid" 2>/dev/null || true
			ACTIVE_CHILD_PID=""
			handle_termination
		fi
		if (( ticks >= max_ticks )); then
			/bin/kill -TERM "$info_pid" 2>/dev/null || true
			wait "$info_pid" 2>/dev/null || true
			ACTIVE_CHILD_PID=""
			/bin/rm -f "$output_file"
			ACTIVE_TEMP_FILE=""
			return 1
		fi
		/bin/sleep 0.25
		(( ticks += 1 ))
	done

	wait "$info_pid"
	info_status=$?
	ACTIVE_CHILD_PID=""
	if (( info_status != 0 )) || [[ ! -s "$output_file" ]]; then
		/bin/rm -f "$output_file"
		ACTIVE_TEMP_FILE=""
		return 1
	fi

	DISKUTIL_PLIST="$(/bin/cat "$output_file")"
	/bin/rm -f "$output_file"
	ACTIVE_TEMP_FILE=""
}

diskutil_external_physical_list() {
	local output_file
	local list_pid
	local list_status
	local ticks=0
	local max_ticks=12

	output_file="$(/usr/bin/mktemp /tmp/macos-disk-ejector-list.XXXXXX)" || return 1
	ACTIVE_TEMP_FILE="$output_file"
	/usr/sbin/diskutil list -plist external physical > "$output_file" 2>/dev/null &
	list_pid=$!
	ACTIVE_CHILD_PID="$list_pid"

	while /bin/kill -0 "$list_pid" 2>/dev/null; do
		if ! parent_app_is_running; then
			/bin/kill -TERM "$list_pid" 2>/dev/null || true
			wait "$list_pid" 2>/dev/null || true
			ACTIVE_CHILD_PID=""
			handle_termination
		fi
		if (( ticks >= max_ticks )); then
			/bin/kill -TERM "$list_pid" 2>/dev/null || true
			wait "$list_pid" 2>/dev/null || true
			ACTIVE_CHILD_PID=""
			/bin/rm -f "$output_file"
			ACTIVE_TEMP_FILE=""
			return 1
		fi
		/bin/sleep 0.25
		(( ticks += 1 ))
	done

	wait "$list_pid"
	list_status=$?
	ACTIVE_CHILD_PID=""
	if (( list_status != 0 )); then
		/bin/rm -f "$output_file"
		ACTIVE_TEMP_FILE=""
		return 1
	fi

	EXTERNAL_PHYSICAL_PLIST="$(/bin/cat "$output_file")"
	/bin/rm -f "$output_file"
	ACTIVE_TEMP_FILE=""
}

plist_value() {
	local plist_text="$1"
	local key="$2"

	print -r -- "$plist_text" \
		| /usr/bin/plutil -extract "$key" raw -o - - 2>/dev/null
}

external_physical_list_contains() {
	local disk_id="$1"
	local disk_count
	local disk_index
	local listed_disk

	disk_count="$(plist_value "$EXTERNAL_PHYSICAL_PLIST" WholeDisks || true)"
	[[ "$disk_count" =~ '^[0-9]+$' ]] || return 1
	for (( disk_index = 0; disk_index < disk_count; disk_index += 1 )); do
		listed_disk="$(plist_value "$EXTERNAL_PHYSICAL_PLIST" "WholeDisks.$disk_index" || true)"
		[[ "$listed_disk" == "$disk_id" ]] && return 0
	done
	return 1
}

resolve_physical_whole_disk() {
	local volume_plist="$1"
	local physical_store
	local physical_store_plist
	local whole_disk

	physical_store="$(plist_value "$volume_plist" 'APFSPhysicalStores.0.APFSPhysicalStore' || true)"
	if [[ -n "$physical_store" ]]; then
		diskutil_info_plist "/dev/$physical_store" || return 1
		physical_store_plist="$DISKUTIL_PLIST"
		whole_disk="$(plist_value "$physical_store_plist" ParentWholeDisk || true)"
		RESOLVED_PHYSICAL_PLIST="$physical_store_plist"
	else
		whole_disk="$(plist_value "$volume_plist" ParentWholeDisk || true)"
		RESOLVED_PHYSICAL_PLIST="$volume_plist"
	fi

	[[ "$whole_disk" =~ '^disk[0-9]+$' ]] || return 1
	RESOLVED_WHOLE_DISK="$whole_disk"
}

is_ejectable_external_physical_disk() {
	local disk_id="$1"

	[[ "$disk_id" =~ '^disk[0-9]+$' ]] || return 1
	diskutil_external_physical_list || return 1
	external_physical_list_contains "$disk_id"
}

sanitize_field() {
	local value="$1"
	value="${value//$'\t'/ }"
	value="${value//$'\n'/ }"
	print -r -- "$value"
}

list_drives() {
	typeset -A volume_names
	typeset -A media_names
	local mount_line
	local volume_device
	local volume_name
	local volume_plist
	local whole_disk
	local media_name
	local bus_protocol

	diskutil_external_physical_list || return 1

	while IFS= read -r mount_line; do
		[[ "$mount_line" == *" on /Volumes/"* ]] || continue
		[[ "$mount_line" =~ '^/dev/(disk[^ ]+) on ' ]] || continue
		volume_device="$match[1]"
		diskutil_info_plist "/dev/$volume_device" || continue
		volume_plist="$DISKUTIL_PLIST"
		resolve_physical_whole_disk "$volume_plist" || continue
		whole_disk="$RESOLVED_WHOLE_DISK"
		external_physical_list_contains "$whole_disk" || continue
		[[ "$(plist_value "$volume_plist" RemovableMediaOrExternalDevice || true)" == "true" ]] || continue
		[[ "$(plist_value "$volume_plist" Ejectable || true)" == "true" ]] || continue

		volume_name="$(plist_value "$volume_plist" VolumeName || true)"
		[[ -n "$volume_name" ]] || volume_name="$volume_device"
		volume_name="$(sanitize_field "$volume_name")"

		if [[ -n "${volume_names[$whole_disk]-}" ]]; then
			volume_names[$whole_disk]+=", $volume_name"
		else
			volume_names[$whole_disk]="$volume_name"
		fi

		if [[ -z "${media_names[$whole_disk]-}" ]]; then
			bus_protocol="$(plist_value "$RESOLVED_PHYSICAL_PLIST" BusProtocol || true)"
			if [[ -n "$bus_protocol" ]]; then
				media_name="$bus_protocol drive"
			else
				media_name="External physical drive"
			fi
			media_names[$whole_disk]="$(sanitize_field "$media_name")"
		fi
	done < <(/sbin/mount)

	for whole_disk in ${(ok)volume_names}; do
		printf '%s\t%s\t%s\n' \
			"$whole_disk" \
			"${volume_names[$whole_disk]}" \
			"${media_names[$whole_disk]}"
	done
}

list_drives_async() {
	local status_file="$1"
	local parent_pid="$2"
	local check_updates="${3:-}"
	local result_file="${status_file}.result"

	valid_status_file "$status_file" || return 64
	[[ "$parent_pid" =~ '^[0-9]+$' ]] || return 64
	PARENT_APP_PID="$parent_pid"
	ACTIVE_STATUS_FILE="$status_file"
	print -r -- "$$" > "${status_file}.pid"
	write_status "$status_file" scanning
	if [[ "$check_updates" == check-updates ]]; then
		latest_version > "${status_file}.update" &!
	fi

	if list_drives > "$result_file"; then
		write_status "$status_file" "list:success"
	else
		write_status "$status_file" "list:failure"
		return 1
	fi
}

latest_version() {
	local location
	local tag

	location="$(/usr/bin/curl -fsI --max-time 3 "$RELEASES_URL/latest" 2>/dev/null \
		| /usr/bin/awk 'tolower($1) == "location:" { print $2 }' \
		| /usr/bin/tr -d '\r')"
	tag="${${location##*/}#v}"
	[[ "$tag" =~ '^[0-9]+(\.[0-9]+)*$' ]] && print -r -- "$tag"
	return 0
}

valid_status_file() {
	local status_file="$1"
	[[ "$status_file" =~ '^/tmp/macos-disk-ejector\.[A-Za-z0-9]+$' ]]
}

write_status() {
	local status_file="$1"
	local value="$2"
	local next_file="${status_file}.next"

	valid_status_file "$status_file" || return 1
	print -r -- "$value" > "$next_file"
	/bin/mv -f "$next_file" "$status_file"
}

try_eject() {
	local disk_id="$1"
	local keep_stopping="${2:-}"
	local eject_pid
	local eject_status
	local ticks=0
	local max_ticks=60

	/usr/sbin/diskutil eject "/dev/$disk_id" > "${EJECT_OUTPUT_FILE:-/dev/null}" 2>&1 &
	eject_pid=$!
	ACTIVE_CHILD_PID="$eject_pid"

	while /bin/kill -0 "$eject_pid" 2>/dev/null; do
		if ! parent_app_is_running; then
			/bin/kill -TERM "$eject_pid" 2>/dev/null || true
			wait "$eject_pid" 2>/dev/null || true
			ACTIVE_CHILD_PID=""
			handle_termination
		fi
		if (( ticks >= max_ticks )); then
			/bin/kill -TERM "$eject_pid" 2>/dev/null || true
			wait "$eject_pid" 2>/dev/null || true
			ACTIVE_CHILD_PID=""
			[[ -n "$EJECT_OUTPUT_FILE" ]] && print -r -- "No answer from macOS within 15 seconds." >> "$EJECT_OUTPUT_FILE"
			return 1
		fi
		[[ "$keep_stopping" == keep-stopping ]] && stop_interfering_services
		/bin/sleep 0.25
		(( ticks += 1 ))
	done

	wait "$eject_pid"
	eject_status=$?
	ACTIVE_CHILD_PID=""
	return "$eject_status"
}

stop_interfering_services() {
	local service_name
	for service_name in "${SERVICE_NAMES[@]}"; do
		/usr/bin/pkill -TERM -x "$service_name" 2>/dev/null || true
	done
}

eject_drive() {
	local disk_id="$1"
	local status_file="$2"
	local parent_pid="$3"
	local attempt

	valid_status_file "$status_file" || return 64
	[[ "$parent_pid" =~ '^[0-9]+$' ]] || return 64
	PARENT_APP_PID="$parent_pid"
	ACTIVE_STATUS_FILE="$status_file"
	EJECT_OUTPUT_FILE="${status_file}.output"
	print -r -- "$$" > "${status_file}.pid"
	log_line "Ejecting $disk_id"
	if ! is_ejectable_external_physical_disk "$disk_id"; then
		log_line "  the drive is no longer available"
		write_status "$status_file" unavailable
		return 1
	fi

	write_status "$status_file" normal
	if try_eject "$disk_id"; then
		log_line "  ejected on the first attempt"
		write_status "$status_file" success
		return 0
	fi
	log_line "  first attempt failed: $(eject_message full)"

	for attempt in {1..5}; do
		if ! is_ejectable_external_physical_disk "$disk_id"; then
			log_line "  the drive is no longer available"
			write_status "$status_file" unavailable
			return 1
		fi

		write_status "$status_file" "retry:$attempt"
		suppress_services 1

		if try_eject "$disk_id" keep-stopping; then
			log_line "  ejected on retry $attempt"
			write_status "$status_file" success
			return 0
		fi
		log_line "  retry $attempt failed: $(eject_message full)"
	done

	write_reason "$disk_id" "$status_file"
	write_status "$status_file" failure
	return 1
}

# Explains a failed eject for the app: what still has files open on the drive,
# and macOS's own reason.
write_reason() {
	local disk_id="$1"
	local status_file="$2"
	local holders
	local message

	holders="$(drive_holders "$disk_id")"
	message="$(eject_message)"
	log_line "  gave up${holders:+; still using the drive: $holders}"
	{
		[[ -n "$holders" ]] && print -r -- "Still using the drive: $holders"
		[[ -n "$message" ]] && print -r -- "macOS said: $message"
	} > "${status_file}.reason"
}

# macOS's answer to the last eject attempt, on one line: just who refused,
# or everything macOS said when called with "full".
eject_message() {
	local text

	[[ -s "$EJECT_OUTPUT_FILE" ]] || return 0
	if [[ "${1:-}" == full ]]; then
		text="$(/usr/bin/grep -v '^[[:space:]]*$' "$EJECT_OUTPUT_FILE")"
	else
		text="$(/usr/bin/grep -i 'dissented by' "$EJECT_OUTPUT_FILE" | /usr/bin/head -1)"
		[[ -n "$text" ]] || text="$(/usr/bin/grep -v '^[[:space:]]*$' "$EJECT_OUTPUT_FILE" | /usr/bin/tail -1)"
	fi
	text="$(print -r -- "$text" | /usr/bin/sed -E 's#\(/[^)]*/([^/)]+)\)#(\1)#g' | /usr/bin/paste -sd ';' - | /usr/bin/sed -E 's/;/; /g; s/[[:space:]]+$//')"
	print -r -- "${text[1,300]}"
}

# This user's processes that still have files open on the drive's volumes.
drive_holders() {
	local disk_id="$1"
	local mount_points

	mount_points="$(mount_points_for_disk "$disk_id")"
	[[ -n "$mount_points" ]] || return 0
	/usr/sbin/lsof -n -P -w +c 0 -F cn 2>/dev/null | MOUNT_POINTS="$mount_points" /usr/bin/awk '
		BEGIN { count = split(ENVIRON["MOUNT_POINTS"], points, "\n") }
		/^c/ { command = substr($0, 2) }
		/^n/ {
			name = substr($0, 2)
			for (i = 1; i <= count; i += 1) {
				if (name == points[i] || index(name, points[i] "/") == 1) found[command] = 1
			}
		}
		END {
			for (command in found) list = list (list == "" ? "" : ", ") command
			print list
		}'
}

mount_points_for_disk() {
	local disk_id="$1"
	local mount_line
	local volume_device
	local mount_point

	while IFS= read -r mount_line; do
		[[ "$mount_line" =~ '^/dev/(disk[^ ]+) on (/Volumes/.+) \(' ]] || continue
		volume_device="$match[1]"
		mount_point="$match[2]"
		diskutil_info_plist "/dev/$volume_device" || continue
		resolve_physical_whole_disk "$DISKUTIL_PLIST" || continue
		[[ "$RESOLVED_WHOLE_DISK" == "$disk_id" ]] && print -r -- "$mount_point"
	done < <(/sbin/mount)
}

log_line() {
	print -r -- "$(/bin/date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE" 2>/dev/null || true
}

parent_app_is_running() {
	[[ -z "$PARENT_APP_PID" ]] && return 0
	/bin/kill -0 "$PARENT_APP_PID" 2>/dev/null
}

# Repeat the stop request: a service macOS restarts at once (such as Siri AI)
# then cannot be restarted again for 10 seconds, which leaves time to eject.
suppress_services() {
	local seconds="$1"
	local ticks=$(( seconds * 10 ))
	local tick

	for (( tick = 1; tick <= ticks; tick += 1 )); do
		parent_app_is_running || handle_termination
		stop_interfering_services
		/bin/sleep 0.1
	done
}

handle_termination() {
	if [[ -n "$ACTIVE_CHILD_PID" ]]; then
		/bin/kill -TERM "$ACTIVE_CHILD_PID" 2>/dev/null || true
		wait "$ACTIVE_CHILD_PID" 2>/dev/null || true
		ACTIVE_CHILD_PID=""
	fi

	if [[ -n "$ACTIVE_TEMP_FILE" ]]; then
		/bin/rm -f "$ACTIVE_TEMP_FILE"
		ACTIVE_TEMP_FILE=""
	fi

	if [[ -n "$ACTIVE_STATUS_FILE" ]]; then
		write_status "$ACTIVE_STATUS_FILE" cancelled || true
		(
			/bin/sleep 2
			/bin/rm -f "$ACTIVE_STATUS_FILE" "${ACTIVE_STATUS_FILE}.next" "${ACTIVE_STATUS_FILE}.pid" "${ACTIVE_STATUS_FILE}.result" "${ACTIVE_STATUS_FILE}.update" "${ACTIVE_STATUS_FILE}.output" "${ACTIVE_STATUS_FILE}.reason"
		) </dev/null >/dev/null 2>&1 &!
	fi

	exit 130
}

cancel_ejection() {
	local status_file="$1"
	local pid_file="${status_file}.pid"
	local worker_pid
	local wait_count=0

	valid_status_file "$status_file" || return 64
	[[ -f "$pid_file" ]] || return 0
	worker_pid="$(/bin/cat "$pid_file" 2>/dev/null || true)"
	[[ "$worker_pid" =~ '^[0-9]+$' ]] || return 1

	/bin/kill -TERM "$worker_pid" 2>/dev/null || return 0
	while /bin/kill -0 "$worker_pid" 2>/dev/null && (( wait_count < 100 )); do
		/bin/sleep 0.05
		(( wait_count += 1 ))
	done
}

cleanup_status_file() {
	local status_file="$1"
	valid_status_file "$status_file" || return 64
	/bin/rm -f "$status_file" "${status_file}.next" "${status_file}.pid" "${status_file}.result" "${status_file}.update" "${status_file}.output" "${status_file}.reason"
}

trap handle_termination HUP INT TERM

case "${1:-}" in
	list)
		[[ $# -eq 1 ]] || exit 64
		list_drives
		;;
	list-async)
		[[ $# -eq 3 || $# -eq 4 ]] || exit 64
		list_drives_async "$2" "$3" "${4:-}"
		;;
	latest-version)
		[[ $# -eq 1 ]] || exit 64
		latest_version
		;;
	eject)
		[[ $# -eq 4 ]] || exit 64
		eject_drive "$2" "$3" "$4"
		;;
	cancel)
		[[ $# -eq 2 ]] || exit 64
		cancel_ejection "$2"
		;;
	cleanup)
		[[ $# -eq 2 ]] || exit 64
		cleanup_status_file "$2"
		;;
	*)
		print -u2 "Usage: ${0:t} {list|list-async STATUS_FILE APP_PID [check-updates]|latest-version|eject DISK_ID STATUS_FILE APP_PID|cancel STATUS_FILE|cleanup STATUS_FILE}"
		exit 64
		;;
esac
