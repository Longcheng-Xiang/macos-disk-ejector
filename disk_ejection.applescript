use framework "Foundation"
use scripting additions

on run
	set appTitle to "Disk Ejector"
	set helperPath to POSIX path of (path to resource "disk_ejection.sh")
	set appProcessIdentifier to (current application's NSProcessInfo's processInfo()'s processIdentifier()) as integer

	set listStatusFile to do shell script "/usr/bin/mktemp /tmp/macos-disk-ejector.XXXXXX"
	set listCommand to quoted form of helperPath & " list-async " & quoted form of listStatusFile & " " & appProcessIdentifier & " >/dev/null 2>&1 &"

	try
		do shell script listCommand
		set listStatus to my waitForDriveList(listStatusFile)
		if listStatus is "list:success" then
			set driveData to do shell script "/bin/cat " & quoted form of (listStatusFile & ".result")
		else
			my cancelEjection(helperPath, listStatusFile)
			my cleanUpStatusFile(helperPath, listStatusFile)
			activate
			display dialog "Disk Ejector could not inspect the connected drives." & return & return & "Try again. If the problem continues, run diskutil list in Terminal to check whether macOS can see the drive." with title appTitle buttons {"OK"} default button "OK" with icon stop
			return
		end if
	on error errorMessage number errorNumber
		my cancelEjection(helperPath, listStatusFile)
		my cleanUpStatusFile(helperPath, listStatusFile)
		if errorNumber is -128 then return
		activate
		display dialog "Disk Ejector could not inspect the connected drives." & return & return & errorMessage with title appTitle buttons {"OK"} default button "OK" with icon stop
		return
	end try

	my cleanUpStatusFile(helperPath, listStatusFile)

	if driveData is "" then
		activate
		display dialog "No mounted external physical drives were found." & return & return & "Connect and mount an external drive, then open Disk Ejector again." with title appTitle buttons {"OK"} default button "OK" with icon caution
		return
	end if

	set {choiceLabels, diskIdentifiers, volumeLabels} to my parseDriveData(driveData)
	if (count choiceLabels) is 0 then
		activate
		display dialog "No mounted external physical drives were found." & return & return & "Connect and mount an external drive, then open Disk Ejector again." with title appTitle buttons {"OK"} default button "OK" with icon caution
		return
	end if

	activate
	set selectedItems to choose from list choiceLabels with title appTitle with prompt "Choose the external drive to eject:" default items {item 1 of choiceLabels} OK button name "Continue" cancel button name "Cancel" multiple selections allowed false empty selection allowed false
	if selectedItems is false then return

	set selectedLabel to item 1 of selectedItems
	set selectedIndex to my indexOfItem(selectedLabel, choiceLabels)
	if selectedIndex is 0 then return

	set diskIdentifier to item selectedIndex of diskIdentifiers
	set volumeLabel to item selectedIndex of volumeLabels

	try
		display dialog "Eject \"" & volumeLabel & "\"?" & return & return & "Make sure you close all active windows and processes related to the external drive." with title appTitle buttons {"Cancel", "Eject"} default button "Eject" cancel button "Cancel" with icon caution
	on error number -128
		return
	end try

	set statusFile to do shell script "/usr/bin/mktemp /tmp/macos-disk-ejector.XXXXXX"
	set launchCommand to quoted form of helperPath & " eject " & quoted form of diskIdentifier & " " & quoted form of statusFile & " " & appProcessIdentifier & " >/dev/null 2>&1 &"

	set progress total steps to 6
	set progress completed steps to 0
	set progress description to "Ejecting " & volumeLabel
	set progress additional description to "Trying a normal eject..."

	try
		do shell script launchCommand
		set finalStatus to my waitForEjection(statusFile)
	on error errorMessage number errorNumber
		if errorNumber is -128 then
			my cancelEjection(helperPath, statusFile)
			my cleanUpStatusFile(helperPath, statusFile)
			my resetProgress()
			return
		end if

		my cleanUpStatusFile(helperPath, statusFile)
		my resetProgress()
		activate
		display dialog "Disk Ejector could not start the ejection process." & return & return & errorMessage with title appTitle buttons {"OK"} default button "OK" with icon stop
		return
	end try

	my cleanUpStatusFile(helperPath, statusFile)
	my resetProgress()
	activate

	if finalStatus is "success" then
		display dialog volumeLabel & " was safely ejected. You can disconnect it now." with title appTitle buttons {"OK"} default button "OK"
	else if finalStatus is "unavailable" then
		display dialog "The selected drive is no longer available." & return & return & "It may already have been ejected or disconnected." with title appTitle buttons {"OK"} default button "OK" with icon caution
	else if finalStatus is "timeout" then
		display dialog "Ejecting " & volumeLabel & " is taking longer than expected." & return & return & "The operation was left running safely in the background. Wait a little longer and check Finder before disconnecting the drive." with title appTitle buttons {"OK"} default button "OK" with icon caution
	else if finalStatus is "cancelled" then
		display dialog "The eject attempt was stopped." & return & return & "The drive has not been reported as safely ejected. Do not disconnect it yet." with title appTitle buttons {"OK"} default button "OK" with icon caution
	else
		display dialog volumeLabel & " could not be safely ejected." & return & return & "A file or application may still be using the drive. Close related applications and Finder windows, then try again." with title appTitle buttons {"OK"} default button "OK" with icon caution
	end if
end run

on parseDriveData(driveData)
	set oldDelimiters to AppleScript's text item delimiters
	set choiceLabels to {}
	set diskIdentifiers to {}
	set volumeLabels to {}

	try
		repeat with driveRow in paragraphs of driveData
			if (driveRow as text) is not "" then
				set AppleScript's text item delimiters to tab
				set rowItems to text items of (driveRow as text)
				if (count rowItems) is greater than or equal to 3 then
					set diskIdentifier to item 1 of rowItems
					set volumeLabel to item 2 of rowItems
					set mediaName to item 3 of rowItems
					set end of choiceLabels to volumeLabel & " — " & mediaName & " (" & diskIdentifier & ")"
					set end of diskIdentifiers to diskIdentifier
					set end of volumeLabels to volumeLabel
				end if
			end if
		end repeat
	on error errorMessage number errorNumber
		set AppleScript's text item delimiters to oldDelimiters
		error errorMessage number errorNumber
	end try

	set AppleScript's text item delimiters to oldDelimiters
	return {choiceLabels, diskIdentifiers, volumeLabels}
end parseDriveData

on indexOfItem(theItem, itemList)
	repeat with itemIndex from 1 to count itemList
		if (item itemIndex of itemList as text) is (theItem as text) then return itemIndex
	end repeat
	return 0
end indexOfItem

on waitForEjection(statusFile)
	repeat with pollNumber from 1 to 720
		try
			set currentStatus to do shell script "/bin/cat " & quoted form of statusFile
		on error
			set currentStatus to ""
		end try

		if currentStatus is "success" then
			set progress completed steps to 6
			set progress additional description to "The drive was safely ejected."
			return "success"
		else if currentStatus is "failure" then
			return "failure"
		else if currentStatus is "unavailable" then
			return "unavailable"
		else if currentStatus is "cancelled" then
			return "cancelled"
		else if currentStatus starts with "retry:" then
			set attemptNumber to text 7 thru -1 of currentStatus
			try
				set progress completed steps to attemptNumber as integer
			end try
			set progress additional description to "The drive is busy. Retrying safely (" & attemptNumber & " of 5)..."
		else if currentStatus is "normal" then
			set progress additional description to "Trying a normal eject..."
		end if

		delay 0.25
	end repeat

	return "timeout"
end waitForEjection

on waitForDriveList(statusFile)
	repeat with pollNumber from 1 to 240
		try
			set currentStatus to do shell script "/bin/cat " & quoted form of statusFile
		on error
			set currentStatus to ""
		end try

		if currentStatus is "list:success" then
			return "list:success"
		else if currentStatus is "list:failure" then
			return "list:failure"
		else if currentStatus is "cancelled" then
			return "cancelled"
		end if

		delay 0.25
	end repeat

	return "timeout"
end waitForDriveList

on cancelEjection(helperPath, statusFile)
	try
		do shell script quoted form of helperPath & " cancel " & quoted form of statusFile
	end try
end cancelEjection

on cleanUpStatusFile(helperPath, statusFile)
	try
		do shell script quoted form of helperPath & " cleanup " & quoted form of statusFile
	end try
end cleanUpStatusFile

on resetProgress()
	set progress total steps to 0
	set progress completed steps to 0
	set progress description to ""
	set progress additional description to ""
end resetProgress
