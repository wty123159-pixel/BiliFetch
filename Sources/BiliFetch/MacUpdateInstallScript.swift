import Foundation

enum MacUpdateInstallScript {
    static let text = """
    #!/bin/zsh
    set -u
    script_path="$0"
    source_app="$1"
    target_app="$2"
    running_pid="$3"
    log_file="$4"
    lock_dir="$5"
    backup_app="${target_app}.update-backup"
    if ! /bin/mkdir "$lock_dir" 2>/dev/null; then
        print "Another update installer is already running." >>"$log_file"
        /bin/rm -f -- "$script_path"
        exit 0
    fi
    cleanup() {
        /bin/rmdir "$lock_dir" 2>/dev/null || true
        /bin/rm -f -- "$script_path"
    }
    trap cleanup EXIT
    while /bin/kill -0 "$running_pid" 2>/dev/null; do /bin/sleep 0.2; done
    /bin/rm -rf -- "$backup_app"
    had_backup=0
    if [[ -d "$target_app" ]]; then
        if /bin/mv -- "$target_app" "$backup_app" >>"$log_file" 2>&1; then
            had_backup=1
        else
            print "Unable to create update backup." >>"$log_file"
            exit 1
        fi
    fi
    if /usr/bin/ditto "$source_app" "$target_app" >>"$log_file" 2>&1 && \
       /usr/bin/open "$target_app" >>"$log_file" 2>&1; then
        /bin/rm -rf -- "$backup_app"
        print "Update installed successfully." >>"$log_file"
    else
        print "Update installation failed." >>"$log_file"
        /bin/rm -rf -- "$target_app"
        if (( had_backup )) && [[ -d "$backup_app" ]]; then
            /bin/mv -- "$backup_app" "$target_app"
            /usr/bin/open "$target_app"
        fi
    fi
    """
}
