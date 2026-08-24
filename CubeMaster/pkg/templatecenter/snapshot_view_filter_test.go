// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0
//

package templatecenter

import (
	"testing"

	"github.com/stretchr/testify/require"
	"github.com/tencentcloud/CubeSandbox/CubeMaster/pkg/base/constants"
	"github.com/tencentcloud/CubeSandbox/CubeMaster/pkg/base/db/models"
)

func TestSnapshotBackendFilterMatchesNormalizedRecords(t *testing.T) {
	opts, err := normalizeListSnapshotsOptions(&ListSnapshotsOptions{Backend: constants.SnapshotBackendXFS})
	require.NoError(t, err)

	for _, backend := range []string{"", "cow", "cubecow", "reflink", "xfscow", "xfs"} {
		record := &models.SnapshotRecord{Backend: backend}
		require.True(t, matchesSnapshotRecordListOptions(record, opts), "backend %q should match xfs", backend)
	}

	require.False(t, matchesSnapshotRecordListOptions(
		&models.SnapshotRecord{Backend: constants.SnapshotBackendS3}, opts,
	))
}

func TestSnapshotBackendFilterRejectsUnsupportedValue(t *testing.T) {
	_, err := normalizeListSnapshotsOptions(&ListSnapshotsOptions{Backend: "unsupported"})
	require.ErrorContains(t, err, "unsupported backend")
}

func TestSnapshotBackendFilterPreservesUnfilteredLists(t *testing.T) {
	opts, err := normalizeListSnapshotsOptions(&ListSnapshotsOptions{})
	require.NoError(t, err)

	require.True(t, matchesSnapshotRecordListOptions(
		&models.SnapshotRecord{Backend: constants.SnapshotBackendS3}, opts,
	))
	require.True(t, matchesSnapshotRecordListOptions(
		&models.SnapshotRecord{}, opts,
	))
}
