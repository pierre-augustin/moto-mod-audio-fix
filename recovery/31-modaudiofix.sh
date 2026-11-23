#!/sbin/sh
#
# ADDOND_VERSION=3
#
# /system/addon.d/31-modaudiofix.sh
# Keeps ModAudioFix (Moto Mods audio routing helper) across LineageOS updates.
#
. /tmp/backuptool.functions

list_files() {
cat <<LIST
priv-app/ModAudioFix/ModAudioFix.apk
etc/permissions/privapp-permissions-modaudiofix.xml
addon.d/31-modaudiofix.sh
LIST
}

case "$1" in
  backup)
    list_files | while read FILE DUMMY; do
      backup_file $S/$FILE
    done
  ;;
  restore)
    list_files | while read FILE REPLACEMENT; do
      R=""
      [ -n "$REPLACEMENT" ] && R="$S/$REPLACEMENT"
      [ -f "$C/$S/$FILE" ] && restore_file $S/$FILE $R
    done
  ;;
  pre-backup|post-backup|pre-restore)
  ;;
  post-restore)
    for i in $(list_files); do
      f=$(get_output_path "$S/$i")
      chown root:root $f
      chmod 644 $f
      chmod 755 $(dirname $f)
    done
    chmod 755 $(get_output_path "$S/addon.d/31-modaudiofix.sh")
  ;;
esac
