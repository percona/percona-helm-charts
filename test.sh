if git diff --exit-code > /dev/null && [ -z "$(git ls-files --others --exclude-standard)" ]; then
    echo "Dependencies are up to date."
else
    echo "Dependencies are out of date. Please run 'make deps' and commit the changes."
exit 1
fi

