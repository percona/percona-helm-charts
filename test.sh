if git diff --quiet; then
    echo "Dependencies are up to date."
else
    echo "Dependencies are out of date. Please run 'make deps' and commit the changes."
exit 1
fi

