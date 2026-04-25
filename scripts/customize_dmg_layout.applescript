on run argv
	if (count of argv) is less than 2 then error "Usage: osascript customize_dmg_layout.applescript <volume-name> <app-name>"

	set volumeName to item 1 of argv
	set appName to item 2 of argv

	tell application "Finder"
		tell disk volumeName
			open
			delay 1
			set current view of container window to icon view
			set toolbar visible of container window to false
			set statusbar visible of container window to false
			set the bounds of container window to {120, 120, 840, 580}

			set viewOptions to the icon view options of container window
			set arrangement of viewOptions to not arranged
			set icon size of viewOptions to 128
			set text size of viewOptions to 14
			set background picture of viewOptions to file ".background:background.png"

			set position of item appName of container window to {180, 250}
			set position of item "Applications" of container window to {540, 250}

			update without registering applications
			delay 2
		end tell
	end tell
end run
