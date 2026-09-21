select_status() {
    for status; do
        return "$status"
    done
    return 0
}

select_status 23
