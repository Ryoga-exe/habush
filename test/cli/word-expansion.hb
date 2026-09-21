word_expansion_status() {
    empty=
    assigned="${missing:=23}"
    alternative="${assigned:+$assigned}"
    selected="${empty:-$alternative}"
    return "$selected"
}

word_expansion_status
