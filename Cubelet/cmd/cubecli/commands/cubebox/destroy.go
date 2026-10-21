// Copyright (c) 2024 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0
//

package cubebox

import (
	gocontext "context"
	"errors"
	"fmt"
	"log"
	"strings"
	"sync"

	"github.com/google/uuid"
	"github.com/urfave/cli/v2"

	"github.com/tencentcloud/CubeSandbox/Cubelet/cmd/cubecli/commands"
	"github.com/tencentcloud/CubeSandbox/Cubelet/pkg/ret"
	"github.com/tencentcloud/CubeSandbox/pkgs/proto/services/cubebox/v1"
)

var Destroy = &cli.Command{
	Name:    "destroy",
	Usage:   "destroy cubebox",
	Aliases: []string{"rm"},
	Flags: []cli.Flag{
		&cli.StringFlag{
			Name:    "name",
			Aliases: []string{"n"},
			Usage:   "sandboxId",
		},
		&cli.StringFlag{
			Name:  "annotation",
			Usage: "k=v",
		},
		&cli.BoolFlag{
			Name: "all",
			Aliases: []string{
				"a",
			},
			Usage: "destroy all",
		},
		&cli.BoolFlag{
			Name:    "force",
			Aliases: []string{"f"},
			Usage:   "skip list,just do destroy",
		},
	},
	Action: func(context *cli.Context) error {
		conn, _, _, err := commands.NewGrpcConn(context)
		if err != nil {
			return err
		}
		defer conn.Close()
		client := cubebox.NewCubeboxMgrClient(conn)
		var ids []string
		args := context.Args().Slice()
		if len(args) > 0 {
			ids = args
		} else if context.Bool("all") {
			return destroyAll(context, client)
		} else if context.IsSet("name") {
			ids = append(ids, context.String("name"))
		}
		if context.Bool("force") {
			ctx, cancel := commands.AppContext(context)
			defer cancel()
			req := &cubebox.ListCubeSandboxRequest{}
			resp, err := client.List(ctx, req)
			if err != nil {
				return err
			}
			for _, id := range ids {
				resolved, err := resolveSandboxIDFromList(resp.Items, strings.TrimSpace(id))
				if err != nil {
					return err
				}
				if err = destroy(context, &cubebox.DestroyCubeSandboxRequest{
					RequestID: uuid.New().String(),
					SandboxID: resolved,
				}, client); err != nil {
					return err
				}
			}
			return nil
		}

		if len(ids) <= 0 {
			log.Printf("should provide sandboxid")
			return fmt.Errorf("should provide sandboxid")
		}
		tmpAnnation := make(map[string]string)
		if context.IsSet("annotation") {
			kv := context.String("annotation")
			m := strings.Split(kv, "=")
			tmpAnnation[m[0]] = m[1]
		}

		ctx, cancel := commands.AppContext(context)
		defer cancel()
		req := &cubebox.ListCubeSandboxRequest{}
		resp, err := client.List(ctx, req)
		if err != nil {
			log.Printf("list sandbox error:%v", err)
			return err
		}
		if len(resp.Items) == 0 {
			log.Printf("no any sandbox exits")
			return nil
		}

		for _, id := range ids {
			resolved, err := resolveSandboxIDFromList(resp.Items, strings.TrimSpace(id))
			if err != nil {
				return err
			}
			if err = destroy(context, &cubebox.DestroyCubeSandboxRequest{
				RequestID:   uuid.New().String(),
				SandboxID:   resolved,
				Annotations: tmpAnnation,
			}, client); err != nil {
				return err
			}
		}
		return nil
	},
}

var DestroyAll = &cli.Command{
	Name:  "destroyall",
	Usage: "destroy all cubeboxes",
	Flags: []cli.Flag{
		&cli.BoolFlag{
			Name:    "force",
			Aliases: []string{"f"},
			Usage:   "remove all",
		},
	},
	Action: func(context *cli.Context) error {
		log.Printf("cubecli destroyall is deprecated, please use: cubecli unsafe rm --all")
		if !commands.AskForConfirm("will destroy ALL of the container, continue only if you confirm", 3) {
			return nil
		}

		conn, ctx, cancel, err := commands.NewGrpcConn(context)
		if err != nil {
			return err
		}
		defer conn.Close()
		defer cancel()
		client := cubebox.NewCubeboxMgrClient(conn)

		req := &cubebox.ListCubeSandboxRequest{}

		resp, err := client.List(ctx, req)
		if err != nil {
			return err
		}

		sandboxes := resp.Items

		if len(sandboxes) == 0 {
			log.Printf("no any Containers")
			return nil
		}
		log.Printf("Sandboxes:%d", len(sandboxes))

		tmpAnnation := make(map[string]string)
		if context.IsSet("annotation") {
			kv := context.String("annotation")
			m := strings.Split(kv, "=")
			tmpAnnation[m[0]] = m[1]
		}

		for _, cnt := range sandboxes {
			if len(cnt.Containers) == 0 {
				continue
			}
			sb := cnt.Containers[0]
			if !context.Bool("force") {
				if sb.GetState() != cubebox.ContainerState_CONTAINER_RUNNING {
					continue
				}
			}
			destroy(context, &cubebox.DestroyCubeSandboxRequest{
				RequestID:   uuid.New().String(),
				SandboxID:   cnt.GetId(),
				Annotations: tmpAnnation,
			}, client)
		}
		return nil
	},
}

func destroy(context *cli.Context, req *cubebox.DestroyCubeSandboxRequest, client cubebox.CubeboxMgrClient) error {
	log.Printf("destroy sandbox: %s", req.GetSandboxID())
	ctx, cancel := commands.AppContext(context)
	defer cancel()
	rsp, err := client.Destroy(ctx, req)
	if err != nil {
		log.Printf("destroy failure:%v", err)
		return err
	}
	if !ret.IsSuccessCode(rsp.GetRet().GetRetCode()) {
		return fmt.Errorf("destroy sandbox %s failed: code=%s message=%s", req.GetSandboxID(), rsp.GetRet().GetRetCode(), rsp.GetRet().GetRetMsg())
	}
	log.Printf("destroy rsp:%+v", rsp)
	return nil
}

const destroyAllConcurrency = 16

func destroyAll(cliContext *cli.Context, client cubebox.CubeboxMgrClient) error {
	ctx, cancel := commands.AppContext(cliContext)
	defer cancel()
	return destroyAllWithContext(ctx, destroyAllConcurrency,
		func(ctx gocontext.Context) ([]*cubebox.CubeSandbox, error) {
			resp, err := client.List(ctx, &cubebox.ListCubeSandboxRequest{})
			if err != nil {
				return nil, err
			}
			return resp.Items, nil
		},
		func(ctx gocontext.Context, id string) error {
			rsp, err := client.Destroy(ctx, &cubebox.DestroyCubeSandboxRequest{
				RequestID: uuid.New().String(),
				SandboxID: id,
			})
			if err == nil && !ret.IsSuccessCode(rsp.GetRet().GetRetCode()) {
				err = fmt.Errorf("code=%s message=%s", rsp.GetRet().GetRetCode(), rsp.GetRet().GetRetMsg())
			}
			return err
		},
	)
}

func destroyAllWithContext(
	ctx gocontext.Context,
	concurrency int,
	list func(gocontext.Context) ([]*cubebox.CubeSandbox, error),
	destroyOne func(gocontext.Context, string) error,
) error {
	if concurrency < 1 {
		concurrency = 1
	}

	seen := make(map[string]struct{})
	var errs []error
	for {
		items, err := list(ctx)
		if err != nil {
			return errors.Join(append(errs, err)...)
		}

		var ids []string
		for _, item := range items {
			id := item.GetId()
			if id == "" {
				continue
			}
			if _, ok := seen[id]; ok {
				continue
			}
			seen[id] = struct{}{}
			ids = append(ids, id)
		}
		if len(ids) == 0 {
			if len(seen) == 0 {
				log.Printf("no any sandbox exits")
			}
			return errors.Join(errs...)
		}

		errs = append(errs, destroySandboxBatch(ctx, concurrency, ids, destroyOne)...)
		if ctx.Err() != nil {
			return errors.Join(append(errs, ctx.Err())...)
		}
	}
}

func destroySandboxBatch(
	ctx gocontext.Context,
	concurrency int,
	items []string,
	destroyOne func(gocontext.Context, string) error,
) []error {
	workers := min(concurrency, len(items))
	ids := make(chan string)
	var wg sync.WaitGroup
	var mu sync.Mutex
	var errs []error

	for range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for id := range ids {
				if err := destroyOne(ctx, id); err != nil {
					mu.Lock()
					errs = append(errs, fmt.Errorf("destroy sandbox %s: %w", id, err))
					mu.Unlock()
				}
			}
		}()
	}

	for _, id := range items {
		select {
		case ids <- id:
		case <-ctx.Done():
			close(ids)
			wg.Wait()
			return errs
		}
	}
	close(ids)
	wg.Wait()
	return errs
}
