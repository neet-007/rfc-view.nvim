package main

import (
	"os"
	"testing"
)

func restRfcDir(b *testing.B) {
	entries, err := os.ReadDir(RfcDir)
	if err != nil {
		b.Fatal(err)
	}

	for _, entry := range entries {
		name := entry.Name()

		if name == "rfc_list.txt" {
			continue
		}
		if name == ".rfc_dirs_nvim" {
			continue
		}

		err := os.Remove(RfcDir + "/" + name)
		if err != nil {
			b.Fatal(err)
		}
	}

	filePath := RfcDir + "/" + "rfc_list.txt"
	f, err := os.OpenFile(filePath, os.O_WRONLY, 0644)
	if err != nil {
		b.Fatalf("Error opening file %s for truncation: %v", filePath, err)
	}

	err = f.Truncate(0)
	if err != nil {
		b.Fatalf("Error truncating file %s: %v", filePath, err)
	}

	f.Close()
}

func BenchmarkDownloadAllProf(b *testing.B) {
	restRfcDir(b)
	b.ResetTimer()

	RfcDownloadAll()
}

func BenchmarkDownloadAllCompress(b *testing.B) {
	for i := 0; i < b.N; i++ {
		b.StopTimer()
		restRfcDir(b)
		b.StartTimer()
		Compress = true
		RfcDownloadAll()
	}
}

func BenchmarkDownloadAllNoCompress(b *testing.B) {
	for i := 0; i < b.N; i++ {
		b.StopTimer()
		restRfcDir(b)
		b.StartTimer()
		Compress = false
		RfcDownloadAll()
	}
}
