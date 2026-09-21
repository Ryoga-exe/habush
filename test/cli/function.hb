select_status() {
    argument_count=$#
    false
    previous_status=$?
    return "$1"
}

select_status 23
