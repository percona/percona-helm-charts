package everest

import "embed"

// Chart contains the Everest Helm chart files.
//
//go:embed all:*
var Chart embed.FS
