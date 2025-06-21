package main

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
)

type RFC struct {
	ID     int    `json:"id"`
	Name   string `json:"name"`
	Title  string `json:"title"`
	RFC    string `json:"rfc"`
	Status string `json:"status"`
}

type RFCResponse struct {
	Meta struct {
		TotalCount int `json:"total_count"`
	} `json:"meta"`
	Objects []RFC `json:"objects"`
}

func getRfcDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		panic(err)
	}
	return filepath.Join(home, ".rfc_dirs_nvim")
}

func initRfc() error {
	rfcDir := getRfcDir()
	listPath := filepath.Join(getRfcDir(), "rfc_list")
	err := os.MkdirAll(rfcDir, 0755)

	if err != nil {
		return err
	}

	f, err := os.OpenFile(listPath+".txt", os.O_RDWR|os.O_CREATE|os.O_EXCL, 0666)
	if err != nil {
		if !os.IsExist(err) {
			return err
		}
	}

	f.Close()

	return nil
}

func writeToRfc(name string, body []byte, writeToList bool) (int, error) {
	path := filepath.Join(getRfcDir(), name)
	f, err := os.Create(path + ".txt.gz")
	if err != nil {
		fmt.Printf("error creating %s\n", path)
		return 0, err
	}

	defer f.Close()
	gzWriter := gzip.NewWriter(f)
	defer gzWriter.Close()

	n, err := gzWriter.Write(body)
	if err != nil {
		return 0, err
	}

	if writeToList {
		listPath := filepath.Join(getRfcDir(), "rfc_list")
		f, err = os.OpenFile(listPath+".txt", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
		if err != nil {
			return 0, err
		}

		defer f.Close()

		if _, err := f.WriteString(name + "\n"); err != nil {
			return 0, err
		}
	}

	return n, nil
}

func searchRFCs(query string) (*RFCResponse, error) {
	encodedQuery := url.QueryEscape(query)
	apiURL := fmt.Sprintf(
		"https://datatracker.ietf.org/api/v1/doc/document/?format=json&type=rfc&title__icontains=%s",
		encodedQuery,
	)

	resp, err := http.Get(apiURL)
	if err != nil {
		return nil, fmt.Errorf("HTTP request failed: %v", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %v", err)
	}

	var result RFCResponse
	err = json.Unmarshal(body, &result)
	if err != nil {
		return nil, fmt.Errorf("failed to parse JSON: %v", err)
	}

	return &result, nil
}

func checkRfc(name string) (bool, error) {
	listPath := filepath.Join(getRfcDir(), "rfc_list")

	f, err := os.Open(listPath + ".txt")

	if err != nil {
		return false, err
	}

	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if line == name {
			return true, nil
		}
	}

	return false, nil
}

func getRfc(name string, save bool) (int, error) {
	if !strings.Contains(name, "::") {
		return 0, fmt.Errorf("invalid name %s must contain RFC::TITLE", name)
	}

	ok, err := checkRfc(name)
	if err != nil {
		return 0, err
	}

	if ok {
		return 0, nil
	}

	url := "https://www.rfc-editor.org/rfc/" + strings.Split(name, "::")[0] + ".txt"
	res, err := http.Get(url)
	if err != nil {
		return 0, err
	}
	defer res.Body.Close()

	var buf bytes.Buffer
	_, err = io.Copy(&buf, res.Body)
	if err != nil {
		return 0, err
	}

	body := buf.Bytes()

	if save {
		return writeToRfc(name, body, true)
	}

	return 0, nil
}

func listRfc(filter string) {
	listPath := filepath.Join(getRfcDir(), "rfc_list") + ".txt"

	file, err := os.Open(listPath)
	if err != nil {
		log.Fatalf("failed to open file: %s", err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)

	lineCount := 0
	scanner1 := bufio.NewScanner(file)

	for scanner1.Scan() {
		line := scanner1.Text()
		if filter == "" {
			lineCount++
		} else if strings.Contains(strings.ToLower(strings.Split(line, "::")[1]), strings.ToLower(filter)) {
			lineCount++
		}
	}

	if err := scanner1.Err(); err != nil {
		fmt.Println("Error reading file for count:", err)
		return
	}

	fmt.Printf("Total line count: %d\n", lineCount)

	_, err = file.Seek(0, io.SeekStart)
	if err != nil {
		fmt.Println("Error seeking file to beginning:", err)
		return
	}

	scanner = bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		if filter == "" {
			fmt.Println(line)
		} else if strings.Contains(strings.ToLower(strings.Split(line, "::")[1]), strings.ToLower(filter)) {
			fmt.Println(line)
		}
	}

	if err := scanner.Err(); err != nil {
		log.Fatalf("error reading file: %s", err)
	}
}

func viewRfc(name string) error {
	path := filepath.Join(getRfcDir(), name)
	f, err := os.Open(path + ".txt.gz")
	if err != nil {
		return err
	}

	defer f.Close()

	gzReader, err := gzip.NewReader(f)
	if err != nil {
		return err
	}
	defer gzReader.Close()

	var buf bytes.Buffer
	if _, err := io.Copy(&buf, gzReader); err != nil {
		return err
	}

	fmt.Printf("%s\n", string(buf.Bytes()))

	return nil
}

func deleteRfc(name string) error {
	path := filepath.Join(getRfcDir(), name)
	err := os.Remove(path + ".txt.gz")
	if err != nil {
		if !os.IsNotExist(err) {
			return err
		}
	}

	rfcListPath := filepath.Join(getRfcDir(), "rfc_list") + ".txt"
	tempRfcListPath := filepath.Join(getRfcDir(), "rfc_list_temp") + ".txt"

	file, err := os.Open(rfcListPath)
	if err != nil {
		return err
	}
	defer file.Close()

	var linesToKeep []string
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == name {
			continue
		}
		linesToKeep = append(linesToKeep, line)
	}

	if err := scanner.Err(); err != nil {
		return err
	}

	tempFile, err := os.Create(tempRfcListPath)
	if err != nil {
		return err
	}
	defer tempFile.Close()

	writer := bufio.NewWriter(tempFile)
	for _, line := range linesToKeep {
		_, err := writer.WriteString(line + "\n")
		if err != nil {
			return err
		}
	}
	writer.Flush()

	err = os.Remove(rfcListPath)
	if err != nil {
		return err
	}

	err = os.Rename(tempRfcListPath, rfcListPath)
	if err != nil {
		return err
	}

	return nil
}

func deleteAllRfcs() error {
	rfcListPath := filepath.Join(getRfcDir(), "rfc_list") + ".txt"

	entries, err := os.ReadDir(getRfcDir())
	if err != nil {
		return err
	}

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}

		fullPath := filepath.Join(getRfcDir(), entry.Name())
		if fullPath == rfcListPath {
			continue
		}

		err = os.Remove(filepath.Join(getRfcDir(), entry.Name()))
		if err != nil {
			log.Printf("error deleting %s: %v", entry.Name(), err)
		}
	}

	f, err := os.Open(rfcListPath)
	if err != nil {
		return err
	}
	defer f.Close()

	err = os.Truncate(rfcListPath, 0)
	if err != nil {
		return err
	}

	return nil
}

func fetchRFCList() ([]string, error) {
	indexURL := "https://www.rfc-editor.org/rfc/rfc-index.txt"
	resp, err := http.Get(indexURL)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	scanner := bufio.NewScanner(resp.Body)
	re := regexp.MustCompile(`^(\d{4})\s+(.*?)\.\s`)

	var rfcs []string
	for scanner.Scan() {
		line := scanner.Text()

		if strings.Contains(line, "Not Issued.") {
			continue
		}

		if matches := re.FindStringSubmatch(line); matches != nil {
			for matches[1][0] == '0' {
				matches[1] = matches[1][1:]
			}
			rfcs = append(rfcs, matches[1]+"::"+matches[2])
		}
	}
	return rfcs, scanner.Err()
}

func downloadRFC(rfc string) error {
	rfcNumber := fmt.Sprintf("rfc%s.txt", strings.Split(rfc, "::")[0])
	url := fmt.Sprintf("%s/%s", "https://www.rfc-editor.org/rfc", rfcNumber)
	target := path.Join(getRfcDir(), "rfc"+rfc+".txt.gz")

	if _, err := os.Stat(target); err == nil {
		return fmt.Errorf("Already exists: RFC %s\n", rfc)
	}

	resp, err := http.Get(url)
	if err != nil || resp.StatusCode != 200 {
		return fmt.Errorf("Failed to fetch RFC %s: %v (%d)\n", rfc, err, resp.StatusCode)
	}
	defer resp.Body.Close()

	var buf bytes.Buffer
	_, err = io.Copy(&buf, resp.Body)
	if err != nil {
		return err
	}

	body := buf.Bytes()
	writeToRfc("rfc"+rfc, body, false)

	return nil
}

func rfcDownloadAll() error {
	fmt.Println("Downloading RFC index...")
	rfcs, err := fetchRFCList()
	if err != nil {
		return err
	}
	fmt.Printf("Found %d RFCs\n", len(rfcs))

	jobs := make(chan string, len(rfcs))
	var wg sync.WaitGroup

	var mu sync.Mutex
	failed_rfcs := []string{}

	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for rfc := range jobs {
				if err := downloadRFC(rfc); err != nil {
					mu.Lock()
					failed_rfcs = append(failed_rfcs, rfc)
					mu.Unlock()
				}
			}
		}()
	}

	for _, rfc := range rfcs {
		jobs <- rfc
	}

	close(jobs)
	wg.Wait()

	fmt.Println("All RFCs downloaded.")

	listPath := filepath.Join(getRfcDir(), "rfc_list")
	f, err := os.OpenFile(listPath+".txt", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}

	defer f.Close()

	for _, rfc := range rfcs {
		if slices.Contains(failed_rfcs, rfc) {
			continue
		}

		if _, err := f.WriteString("rfc" + rfc + "\n"); err != nil {
			return err
		}
	}

	return nil
}

func main() {
	err := initRfc()
	if err != nil {
		log.Fatal(err)
	}

	rfcSearch := flag.String("rfc", "", "rfc name")
	rfcSave := flag.Bool("save", false, "save rfc")
	rfcList := flag.Bool("list", false, "view rfc list")
	rfcDeleteAll := flag.Bool("delete-all", false, "delete all rfcs")
	rfcListFilter := flag.String("filter", "", "filter rfc list")
	rfcView := flag.String("view", "", "view rfc")
	rfcGet := flag.String("get", "", "get rfc")
	rfcDelete := flag.String("delete", "", "delete rfc")
	rfcDownloadAllRfc := flag.Bool("download-all", false, "download all rfcs")

	flag.Parse()

	if *rfcDownloadAllRfc {
		if err := rfcDownloadAll(); err != nil {
			log.Fatal(err)
		}

		return
	}

	if *rfcList {
		listRfc(*rfcListFilter)
		return
	}

	if *rfcDeleteAll {
		if err := deleteAllRfcs(); err != nil {
			log.Fatal(err)
		}

		return
	}

	if *rfcDelete != "" {
		if err := deleteRfc(*rfcDelete); err != nil {
			log.Fatal(err)
		}

		return
	}

	if *rfcGet != "" {
		if _, err := getRfc(*rfcGet, true); err != nil {
			log.Fatal(err)
		}

		if err := viewRfc(*rfcGet); err != nil {
			log.Fatal(err)
		}

		return
	}

	if *rfcView != "" {
		if err := viewRfc(*rfcView); err != nil {
			log.Fatal(err)
		}

		return
	}

	if *rfcSearch == "" {
		log.Fatal("must provide rfc")
	}

	rfcs, err := searchRFCs(*rfcSearch)
	if err != nil {
		log.Fatal(err)
	}

	fmt.Printf("total count: %d\n", rfcs.Meta.TotalCount)
	for _, rfc := range rfcs.Objects {
		title := strings.ReplaceAll(rfc.Title, "/", "-")
		fmt.Printf("%s::%s\n", rfc.Name, title)
		if *rfcSave {
			getRfc(fmt.Sprintf("%s::%s", rfc.Name, title), *rfcSave)
		}
	}
}
