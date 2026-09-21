value='two words'
/bin/cat <<EOF
expanded $value
EOF
/bin/cat <<'EOF'
literal $value
EOF
/bin/cat <<<"$value"
{ /bin/cat; } <<EOF
compound input
EOF
/bin/cat <<FIRST <<SECOND
unused first input
FIRST
second input wins
SECOND
/bin/cat <<-EOF
	tabs stripped
	EOF
