// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0
//

package cubebox

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	cubeboxv1 "github.com/tencentcloud/CubeSandbox/pkgs/proto/services/cubebox/v1"
)

func TestDestroyAllIncludesNonRunningSandboxesAndRunsConcurrently(t *testing.T) {
	items := []*cubeboxv1.CubeSandbox{
		{Id: "running", Containers: []*cubeboxv1.Container{{State: cubeboxv1.ContainerState_CONTAINER_RUNNING}}},
		{Id: "creating", Containers: []*cubeboxv1.Container{{State: cubeboxv1.ContainerState_CONTAINER_CREATED}}},
		{Id: "unknown", Containers: []*cubeboxv1.Container{{State: cubeboxv1.ContainerState_CONTAINER_UNKNOWN}}},
	}
	var active atomic.Int32
	var peak atomic.Int32
	var mu sync.Mutex
	var destroyed []string
	started := make(chan struct{}, len(items))
	release := make(chan struct{})

	errCh := make(chan error, 1)
	go func() {
		errCh <- destroyAllWithContext(context.Background(), 3,
			func(context.Context) ([]*cubeboxv1.CubeSandbox, error) {
				return items, nil
			},
			func(_ context.Context, id string) error {
				current := active.Add(1)
				defer active.Add(-1)
				for {
					old := peak.Load()
					if current <= old || peak.CompareAndSwap(old, current) {
						break
					}
				}
				started <- struct{}{}
				<-release
				mu.Lock()
				destroyed = append(destroyed, id)
				mu.Unlock()
				return nil
			},
		)
	}()

	for range items {
		select {
		case <-started:
		case <-time.After(time.Second):
			close(release)
			t.Fatal("bulk destroy did not start all workers concurrently")
		}
	}
	close(release)
	select {
	case err := <-errCh:
		require.NoError(t, err)
	case <-time.After(time.Second):
		t.Fatal("bulk destroy did not finish")
	}
	require.ElementsMatch(t, []string{"running", "creating", "unknown"}, destroyed)
	require.Greater(t, peak.Load(), int32(1))
}

func TestDestroyAllReportsPartialFailureAfterDrainingBatch(t *testing.T) {
	first := []*cubeboxv1.CubeSandbox{{Id: "ok-1"}, {Id: "bad"}}
	second := []*cubeboxv1.CubeSandbox{{Id: "bad"}, {Id: "ok-2"}}
	var listCalls atomic.Int32
	var mu sync.Mutex
	var destroyed []string

	err := destroyAllWithContext(context.Background(), 2,
		func(context.Context) ([]*cubeboxv1.CubeSandbox, error) {
			switch listCalls.Add(1) {
			case 1:
				return first, nil
			case 2:
				return second, nil
			default:
				return nil, nil
			}
		},
		func(_ context.Context, id string) error {
			mu.Lock()
			destroyed = append(destroyed, id)
			mu.Unlock()
			if id == "bad" {
				return errors.New("injected failure")
			}
			return nil
		},
	)

	require.ErrorContains(t, err, "destroy sandbox bad")
	require.ElementsMatch(t, []string{"ok-1", "bad", "ok-2"}, destroyed)
	require.Equal(t, int32(3), listCalls.Load())
}
