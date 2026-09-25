// Copyright (c) 2026 Tencent Inc.
// SPDX-License-Identifier: Apache-2.0

package warehouse

import "testing"

func TestNormalizeArch(t *testing.T) {
	t.Parallel()
	tests := []struct {
		input string
		want  string
	}{
		{input: "amd64", want: ArchAMD64},
		{input: "x86_64", want: ArchAMD64},
		{input: "arm64", want: ArchARM64},
		{input: "aarch64", want: ArchARM64},
		{input: "riscv64", want: ArchRISCV64},
		{input: " RISCV64 ", want: ArchRISCV64},
	}
	for _, test := range tests {
		t.Run(test.input, func(t *testing.T) {
			got, err := NormalizeArch(test.input)
			if err != nil {
				t.Fatalf("NormalizeArch(%q): %v", test.input, err)
			}
			if got != test.want {
				t.Errorf("NormalizeArch(%q) = %q, want %q", test.input, got, test.want)
			}
		})
	}
	if _, err := NormalizeArch("mips64"); err == nil {
		t.Error("NormalizeArch(mips64) succeeded, want error")
	}
}

func TestNormalizeVersionRejectsSeparators(t *testing.T) {
	t.Parallel()
	for _, in := range []string{"a/../b", "../../v2", `win\path`, "v1/../v2", "ok/v1"} {
		if _, err := NormalizeVersion(in); err == nil {
			t.Errorf("NormalizeVersion(%q) succeeded, want error", in)
		}
	}
}

func TestObjectMountPath(t *testing.T) {
	if ObjectMountPath != "/internal/warehouse/object" {
		t.Fatalf("ObjectMountPath=%q", ObjectMountPath)
	}
}

func TestObjectKeyUsesWarehousePrefix(t *testing.T) {
	got := ObjectKey(ArchAMD64, ComponentShim, "v0.6.0")
	want := "warehouse/blobs/amd64/cube-shim/v0.6.0/component.tar.gz"
	if got != want {
		t.Fatalf("ObjectKey=%q want %q", got, want)
	}
	if UploadObjectKey("abc") != "warehouse/uploads/abc.tar.gz" {
		t.Fatalf("UploadObjectKey=%q", UploadObjectKey("abc"))
	}
}

func TestNormalizeVersionAcceptsPlainKeys(t *testing.T) {
	t.Parallel()
	for _, in := range []string{"v0.7.0", "sha256-abcdef123456", "v0.7.0-rc2"} {
		got, err := NormalizeVersion(in)
		if err != nil {
			t.Errorf("NormalizeVersion(%q): %v", in, err)
		}
		if got != in {
			t.Errorf("NormalizeVersion(%q)=%q", in, got)
		}
	}
}
