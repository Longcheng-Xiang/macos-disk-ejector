#!/bin/zsh
set -u

readonly -a SERVICE_NAMES=(
	Spotlight
	photoanalysisd
	photolibraryd
	mediaanalysisd
	managedcorespotlightd
	cloudphotod
)

typeset ACTIVE_CHILD_PID=""
typeset ACTIVE_STATUS_FILE=""
typeset ACTIVE_TEMP_FILE=""
typeset PARENT_APP_PID=""
typeset DISKUTIL_PLIST=""
typeset EXTERNAL_PHYSICAL_PLIST=""
typeset RESOLVED_WHOLE_DISK=""
typeset RESOLVED_PHYSICAL_PLIST=""

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
	local result_file="${status_file}.result"

	valid_status_file "$status_file" || return 64
	[[ "$parent_pid" =~ '^[0-9]+$' ]] || return 64
	PARENT_APP_PID="$parent_pid"
	ACTIVE_STATUS_FILE="$status_file"
	print -r -- "$$" > "${status_file}.pid"
	write_status "$status_file" scanning

	if list_drives > "$result_file"; then
		write_status "$status_file" "list:success"
	else
		write_status "$status_file" "list:failure"
		return 1
	fi
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
	local eject_pid
	local eject_status
	local ticks=0
	local max_ticks=60

	/usr/sbin/diskutil eject "/dev/$disk_id" >/dev/null 2>&1 &
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
			return 1
		fi
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
	print -r -- "$$" > "${status_file}.pid"
	if ! is_ejectable_external_physical_disk "$disk_id"; then
		write_status "$status_file" unavailable
		return 1
	fi

	write_status "$status_file" normal
	if try_eject "$disk_id"; then
		write_status "$status_file" success
		return 0
	fi

	for attempt in {1..5}; do
		if ! is_ejectable_external_physical_disk "$disk_id"; then
			write_status "$status_file" unavailable
			return 1
		fi

		write_status "$status_file" "retry:$attempt"
		stop_interfering_services
		responsive_sleep 1

		if try_eject "$disk_id"; then
			write_status "$status_file" success
			return 0
		fi
	done

	write_status "$status_file" failure
	return 1
}

parent_app_is_running() {
	[[ -z "$PARENT_APP_PID" ]] && return 0
	/bin/kill -0 "$PARENT_APP_PID" 2>/dev/null
}

responsive_sleep() {
	local seconds="$1"
	local ticks=$(( seconds * 10 ))
	local tick

	for (( tick = 1; tick <= ticks; tick += 1 )); do
		parent_app_is_running || handle_termination
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
			/bin/rm -f "$ACTIVE_STATUS_FILE" "${ACTIVE_STATUS_FILE}.next" "${ACTIVE_STATUS_FILE}.pid" "${ACTIVE_STATUS_FILE}.result"
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
	/bin/rm -f "$status_file" "${status_file}.next" "${status_file}.pid" "${status_file}.result"
}

trap handle_termination HUP INT TERM

case "${1:-}" in
	list)
		[[ $# -eq 1 ]] || exit 64
		list_drives
		;;
	list-async)
		[[ $# -eq 3 ]] || exit 64
		list_drives_async "$2" "$3"
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
		print -u2 "Usage: ${0:t} {list|list-async STATUS_FILE APP_PID|eject DISK_ID STATUS_FILE APP_PID|cancel STATUS_FILE|cleanup STATUS_FILE}"
		exit 64
		;;
esac
