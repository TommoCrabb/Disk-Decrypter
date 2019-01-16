#!/usr/bin/env bash

##################
## INTRODUCTION ##
##################

# This script is intended to save time decrypting and mounting multiple devices that use identical passwords and encryption types.
# While it does do some sanity-checking on user input, you can still probably fuck things up if you try hard enough.
# It MUST be run as root.

###################
## INITIAL SETUP ##
###################

# CHECK USER-ID. EXIT IF NOT ROOT
if (( ${UID} != 0 )) ; then
    echo "Sorry, this script must be run as root."
    exit
fi

# CHECK FOR DEPENDENCIES. EXIT IF NOT MET
echo "CHECKING DEPENDENCIES"
for dep in cryptsetup lsblk perl column ; do
	hash "${dep}" && echo "OK: FOUND ${dep}" || { echo "ERROR: COULDN'T FIND ${dep}" ; fatal=1 ; }
done
[[ "${fatal}" == 1 ]] && exit

# THE FIRST THING WE WANT TO DO IS GET A LIST OF SUITABLE BLOCK DEVICES.
# WE WANT TO LIMIT OUR OPTIONS TO EMPTY DISK PARTITIONS THAT AREN'T ALREADY IN USE BY DM-CRYPT.
# UNFORTUNATELY, LSBLK CAN'T TELL US WHICH PARTITIONS DM-CRYPT IS USING, SO WE NEED TO ADD AN EXTRA STEP.

# FIRST, WE WANT TO GET A LIST OF ALL DISK PARTITIONS WITH NO FILE SYSTEM.
empty_part_list=(
    $( lsblk --paths --pairs --output NAME,TYPE,FSTYPE |
	   perl -ne 's|^\h*NAME="(/dev/[a-z0-9]+)" TYPE="part" FSTYPE=""\h*$|\1 | and print' )
)

# THEN, WE WANT TO GET A LIST OF ALL BLOCK DEVICES BEING USED BY DM-CRYPT
crypt_list=(
    $( for dev in /dev/dm-* ; do cryptsetup status "${dev}" ; done |
	   perl -ne 's|^\h*device:\h*(/dev/[a-z0-9]+)\h*$|\1 | and print' ) 
)

# THEN WE USE OUR SECOND LIST AS A FILTER TO ELIMINATE DEVICES FROM OUR FIRST LIST
for dev in "${empty_part_list[@]}" ; do
    for crypt in "${crypt_list[@]}" ; do
		[[ "${dev}" == "${crypt}" ]] && continue 2
    done
    filtered_dev_list+=( "${dev}" )
done

# NOW WE RUN OUR RESULTS BACK THROUGH LSBLK, SO THAT WE CAN GET A NICELY FORMATTED TABLE
mapfile -t menu < <( lsblk --paths --noheadings --output NAME,PARTLABEL,SIZE "${filtered_dev_list[@]}" )

################################
## REPEATABLE SETUP FUNCTIONS ##
################################

function print_selection
{
	local item
	
    echo
    echo "SKIPPED:"
    for item in "${skipped[@]}" ; do echo "${item}" ; done
    echo
    echo "SELECTED:"
    for item in "${selection[@]}" ; do echo "${item}" ; done
}

function get_dev_label_pairs
{
	declare -g -A dev_label_pairs=()
	local item rgx='^(/dev/([^ ]+)) '

	for item in "${selection[@]}" ; do
		[[ "${item}" =~ $rgx ]] || { echo "ERROR: get_dev_label_pairs, regex match failure" ; exit ; }
		dev_label_pairs["${BASH_REMATCH[2]}"]=$( lsblk --noheadings --output PARTLABEL "${BASH_REMATCH[1]}"  )
	done
}

function select_devices
{
	local entry rgx opt
	
    while true ; do
		echo
		for entry in "${menu[@]}" ; do
			echo "${entry}"
		done

		echo
		echo "Please enter a bash-compatible regexp:"
		read -er rgx
		history -s -- "${rgx}"

		selection=()
		skipped=()

		for entry in "${menu[@]}" ; do
			if [[ "${entry}" =~ ${rgx} ]] ; then
				selection+=( "${entry}" )
			else
				skipped+=( "${entry}" )
			fi
		done

		if [[ "${#selection[@]}" == 0 ]] ; then
			echo
			echo REGEXP DID NOT MATCH ANY DEVICES
			continue
		fi

		while true ; do

			print_selection
			echo
			echo "Are you happy with this selection?"
			read -p "y/n: " opt

			case "${opt}" in
				y) get_dev_label_pairs ; return ;;
				n) break ;;
				*) continue ;;
			esac

		done

    done
}

function set_naming_options
{
	local opt i
	
    while true ; do
		print_selection
		echo
		echo "What naming convention do you want to use?"
		naming_options=( "Device names (eg: sda1)"
						 "Partition Labels (reverts to device names if necessary)"
						 "User input + names (eg: Foo_sda1)"
						 "User input + labels (eg: Foo_mandy)"
						 "User input + labels + names (eg: Foo_mandy_sda1)"
					   )
		echo
		select opt in "${naming_options[@]}" ; do
			for ((i=0; i<${#naming_options[@]} ; i++)) ; do
				if [[ "${naming_options[$i]}" == "${opt}" ]] ; then
					name_type="${i}"
					if (( ${name_type} > 1 )) ; then
						echo
						read -re -p "Enter prefix: " name_prefix
					fi
					return
				fi
			done
			break
		done
    done
}

function set_cryptsetup_type
{
	local opt types=( plain luks loopaes tcrypt )
	
	while true ; do
		echo
		echo "What encryption type are you using?"
		echo
		select cryptsetup_type in "${types[@]}" ; do
			for opt in "${types[@]}" ; do
				if [[ "${cryptsetup_type}" == "${opt}" ]] ; then
					return
				fi
			done
			break
		done
	done
}

function set_cryptsetup_options {
    echo
    echo "What options would you like to pass to cryptsetup?"
    echo "eg: --type luks --test-passphrase"
	echo "eg: --type plain -c serpent -h sha256 -s 256"
	history -s -- "${cryptsetup_options}"
    read -er cryptsetup_options
}

function set_password_visibility
{
	local opt
	
    while true ; do
		echo
		echo "Would you like your password printed as you type?"
		read -p "y/n: " opt
		case "${opt}" in
			y) print_password=1 ; return ;;
			n) print_password=0 ; return ;;
			*) continue ;;
		esac
    done
}

function enter_password
{
    echo
    echo "Please enter your password."
    case "${print_password}" in
		1) read -er password ;;
		0) read -ser password ;;
		*) echo "ERROR: print_password needs to be either 1 or 0." ; exit ;;
    esac
}

function print_preview ## 
{
	declare -g -A dev_name_pairs=()
	local previews=()
	local dev name item
	
	echo
	echo "CRYPTSETUP COMMANDS:"
	for dev in "${!dev_label_pairs[@]}" ; do
		case "${name_type}" in
			0) name="${dev}" ;;
			1) name="${dev_label_pairs[$dev]}" ;;
			2) name="${name_prefix}_${dev}" ;;
			3) name="${name_prefix}_${dev_label_pairs[$dev]}" ;;
			4) name="${name_prefix}_${dev_label_pairs[$dev]}_${dev}" ;;
		esac
		dev_name_pairs["${dev}"]="${name}"
		previews+=( "cryptsetup open /dev/${dev} ${name} ${cryptsetup_options}" )
	done
	for item in "${previews[@]}" ; do echo "${item}" ; done | column -t
}

function set_mount_options
{
	local opt

	while true ; do
		echo
		echo "Do you want to mount devices?"
		read -p "y/n: " opt
		case "${opt}" in
			y) mount=1 ; break ;;
			n) mount=0 ; return ;;
			*) continue ;;
		esac
	done
	if [[ "${mount}" == 1 ]] ; then
		while true ; do
			echo
			echo "Where do you want to create mount points?"
			echo "(eg: /mnt/)"
			history -s -- "${mount_point}"
			read -re mount_point
			if [[ -d "${mount_point}" ]] ; then
				return
			else
				echo
				echo "Not a valid directory"
			fi
		done
	fi
}

###############
## FIRST RUN ##
###############

select_devices
set_naming_options
# set_cryptsetup_type
set_cryptsetup_options
set_password_visibility
enter_password
set_mount_options

######################
## INTERACTIVE MENU ##
######################

while true ; do
    print_selection
	print_preview
	if [[ "${mount}" == 1 ]] ; then
		echo
		echo "MOUNT POINT: ${mount_point}"
	fi
#	echo
#	echo "NAMING OPTIONS: ${naming_options[$name_type]}"
#	echo
#	echo "CRYPTSETUP TYPE: ${cryptsetup_type}"
#	echo
#	echo "CRYPTSETUP OPTIONS: ${cryptsetup_options}"
    echo
    case "${print_password}" in
		1) echo "PASSWORD: ${password}" ;;
		0) echo "PASSWORD HIDDEN" ;;
		*) echo "ERROR: print_password needs to be set to either 1 or 0" ; exit ;;
    esac
    echo
    select opt in "Change devices" "Change names" "Change cryptsetup options" "Change password" "Show/hide password" "Change mount options" "Continue" ; do
		case "${opt}" in
			"Change devices") select_devices ; break ;;
			"Change names") set_naming_options ; break ;;
#			"Change cryptsetup type") set_cryptsetup_type ; break ;;
			"Change cryptsetup options") set_cryptsetup_options ; break ;;
			"Change password") enter_password ; break ;;
			"Show/hide password") set_password_visibility ; break ;;
			"Change mount options") set_mount_options ; break ;;
			"Continue") break 2 ;;
			*) break ;;
		esac
    done
done

####################
## END USER INPUT ##
####################

# GLOBAL VARIABLES IN PLAY
# selection:ARRAY: Devices selected for decryption
# password:STRING: Password
# cryptsetup_options:STRING: (eg: -c serpent -h sha1 -s 128)
# cryptsetup_type:STRING: (eg: luks)
# naming_options:ARRAY:
#  0: Device names (eg: sda1)
#  1: Partition Labels reverts to device names if necessary)
#  2: User input + device names (eg: Foo_sda1)
# name_type:STRING: 0,1,2 (eg: ${naming_options[$name_type]})
# name_prefix:STRING:
# dev_label_pairs:HASH:
# dev_name_pairs:HASH:
# mount:INT: (0=false, 1=true)
# mount_point:STRING:

# DECRYPT DEVICES
echo
echo "DECRYPTING DEVICES ..."
echo
for dev in "${!dev_name_pairs[@]}" ; do
	echo -n "${password}" | cryptsetup open "/dev/${dev}" "${dev_name_pairs[${dev}]}" $cryptsetup_options --verbose --key-file -
done

# MOUNT DEVICES IF APPLICABLE
if [[ "${mount}" == 1 ]] ; then
	echo
	echo "MOUNTING DEVICES ..."
	echo
	for dev in "${dev_name_pairs[@]}" ; do
		if ! [[ -e "/dev/mapper/${dev}" ]] ; then
			echo "SKIPPING: COULDN'T FIND /dev/mapper/${dev}"
			continue
		elif [[ -e "${mount_point}/${dev}" ]] ; then
			if [[ $( ls -A "${mount_point}/${dev}" ) ]] ; then
				echo "SKIPPING: DIRECTORY ALREADY EXISTS AND IS NOT EMPTY ${mount_point}/${dev}"
				continue
			fi
		else
			mkdir --verbose "${mount_point}/${dev}"
		fi
		mount --verbose "/dev/mapper/${dev}" "${mount_point}/${dev}"
	done
fi
