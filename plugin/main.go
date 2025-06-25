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
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
)

type RFC struct {
	ID       int    `json:"id"`
	Name     string `json:"name"`
	Title    string `json:"title"`
	RFC      string `json:"rfc"`
	Status   string `json:"status"`
	PathName string
}

type RFCResponse struct {
	Meta struct {
		TotalCount int `json:"total_count"`
	} `json:"meta"`
	Objects []RFC `json:"objects"`
}

type NotFound struct {
	name string
}

func newNotFound(name string) error {
	return &NotFound{name}
}

func (e *NotFound) Error() string {
	return fmt.Sprintf("not found %s", e.name)
}

var rfcDir string

func init() {
	rfcDir = getRfcDir()
	if err := initRfc(); err != nil {
		log.Fatal(err)
	}
}

func getRfcDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		panic(err)
	}
	return filepath.Join(home, ".rfc_dirs_nvim")
}

func initRfc() error {
	listPath := filepath.Join(rfcDir, "rfc_list")
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

func writeToRfc(name string, data io.ReadCloser, writeToList bool) (int, error) {
	//name = strings.ReplaceAll(name, "/", "-")
	path := filepath.Join(rfcDir, name)
	f, err := os.Create(path + ".txt.gz")
	if err != nil {
		log.Printf("error creating %s %v\n", path, err)
		return 0, err
	}

	defer f.Close()
	gzWriter := gzip.NewWriter(f)
	defer gzWriter.Close()

	n, err := io.Copy(gzWriter, data)
	if err != nil {
		log.Printf("error writing to %s %v\n", path, err)
		return 0, err
	}

	if writeToList {
		listPath := filepath.Join(rfcDir, "rfc_list")
		f, err = os.OpenFile(listPath+".txt", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
		if err != nil {
			return 0, err
		}

		defer f.Close()

		if _, err := f.WriteString(name + "\n"); err != nil {
			return 0, err
		}
	}

	return int(n), nil
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
	listPath := filepath.Join(rfcDir, "rfc_list")

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

func getRfc(rfc RFC, save bool) (int, error) {
	if !strings.Contains(rfc.PathName, "::") {
		return 0, fmt.Errorf("invalid path name %v must contain RFC::TITLE", rfc)
	}

	ok, err := checkRfc(rfc.PathName)
	if err != nil {
		return 0, err
	}

	if ok {
		return 0, nil
	}

	//url := "https://www.rfc-editor.org/rfc/" + strings.Split(rfc, "::")[0] + ".txt"
	url := "https://www.rfc-editor.org/rfc/" + rfc.RFC + ".txt"
	res, err := http.Get(url)
	if err != nil {
		return 0, err
	}

	if save {
		n, err := writeToRfc(rfc.PathName, res.Body, true)
		res.Body.Close()
		if err != nil {
			return 0, err
		}
		return n, nil
	}
	res.Body.Close()

	return 0, nil
}

func listRfc(filter string) {
	listPath := filepath.Join(rfcDir, "rfc_list") + ".txt"

	file, err := os.Open(listPath)
	if err != nil {
		log.Fatalf("failed to open file: %s", err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	lineCount := 0

	for scanner.Scan() {
		line := scanner.Text()
		if filter == "" {
			lineCount++
		} else {
			split := strings.Split(line, "::")
			if len(split) != 2 {
				log.Printf("filter invalid %s", line)
				continue
			}
			lowerLine := strings.ToLower(split[1])
			lowerFilter := strings.ToLower(filter)
			if !strings.Contains(lowerLine, lowerFilter) {
				continue
			}
			lineCount++
		}
	}

	if err := scanner.Err(); err != nil {
		log.Printf("Error reading file for count:", err)
		return
	}

	fmt.Printf("Total line count: %d\n", lineCount)

	_, err = file.Seek(0, io.SeekStart)
	if err != nil {
		log.Printf("Error seeking file to beginning:", err)
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
		} else {
			split := strings.Split(line, "::")
			if len(split) != 2 {
				log.Printf("filter invalid %s", line)
				continue
			}
			lowerLine := strings.ToLower(split[1])
			lowerFilter := strings.ToLower(filter)
			if !strings.Contains(lowerLine, lowerFilter) {
				continue
			}
			fmt.Println(line)
		}
	}

	if err := scanner.Err(); err != nil {
		log.Fatalf("error reading file: %s", err)
	}
}

func viewRfc(name string) error {
	path := filepath.Join(rfcDir, name)
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
	path := filepath.Join(rfcDir, name)
	err := os.Remove(path + ".txt.gz")
	if err != nil {
		if !os.IsNotExist(err) {
			return err
		}
	}

	rfcListPath := filepath.Join(rfcDir, "rfc_list") + ".txt"
	tempRfcListPath := filepath.Join(rfcDir, "rfc_list_temp") + ".txt"

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
	rfcListPath := filepath.Join(rfcDir, "rfc_list") + ".txt"

	f, err := os.Open(rfcDir)
	if err != nil {
		return err
	}
	defer f.Close()

	entries, err := f.Readdirnames(0)
	if err != nil {
		return err
	}

	i := slices.Index(entries, "rfc_list.txt")
	if i != -1 {
		slices.Delete(entries, i, i+1)
	}
	i = slices.Index(entries, rfcDir)
	if i != -1 {
		slices.Delete(entries, i, i+1)
	}

	n := sync.WaitGroup{}
	ch := make(chan struct{}, 20)
	for _, entry := range entries {
		fullPath := filepath.Join(rfcDir, entry)

		n.Add(1)
		go func(fullPath string) {
			ch <- struct{}{}
			defer func() {
				<-ch
				n.Done()
			}()

			if err := os.Remove(fullPath); err != nil {
				log.Printf("error deleting %s: %v", entry, err)
			}
		}(fullPath)
	}

	n.Wait()
	close(ch)

	f, err = os.Open(rfcListPath)
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

func fetchRFCList() ([]RFC, error) {
	indexURL := "https://www.rfc-editor.org/rfc/rfc-index.txt"
	resp, err := http.Get(indexURL)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	scanner := bufio.NewScanner(resp.Body)
	re := regexp.MustCompile(`^(\d{4})\s+(.*?)\.\s`)

	var rfcs []RFC
	for scanner.Scan() {
		line := scanner.Text()

		if strings.Contains(line, "Not Issued.") {
			continue
		}

		if matches := re.FindStringSubmatch(line); matches != nil {
			for matches[1][0] == '0' {
				matches[1] = matches[1][1:]
			}
			name := "rfc" + matches[1]
			rfc := RFC{
				Name:     name,
				Title:    matches[2],
				RFC:      name,
				Status:   "Active",
				PathName: strings.ReplaceAll(name+"::"+matches[2], "/", "-"),
			}
			rfcs = append(rfcs, rfc)
		}
	}
	return rfcs, scanner.Err()
}

func downloadRFC(rfc RFC) error {
	//rfcNumber := fmt.Sprintf("rfc%s.txt", strings.Split(rfc, "::")[0])
	url := fmt.Sprintf("%s/%s", "https://www.rfc-editor.org/rfc", rfc.Name+".txt")

	resp, err := http.Get(url)
	if resp.StatusCode == 404 {
		return newNotFound(rfc.RFC)
	} else if err != nil || resp.StatusCode != 200 {
		return fmt.Errorf("Failed to fetch RFC %s: %v (%d)\n", rfc, err, resp.StatusCode)
	}

	//_, err = writeToRfc("rfc"+rfc, resp.Body, false)
	_, err = writeToRfc(rfc.PathName, resp.Body, false)
	resp.Body.Close()
	if err != nil {
		return err
	}

	return nil
}

func rfcDownloadAll() error {
	fmt.Println("Downloading RFC index...")
	rfcs, err := fetchRFCList()
	if err != nil {
		return err
	}
	fmt.Printf("Found %d RFCs\n", len(rfcs))

	jobs := make(chan RFC, len(rfcs))
	var wg sync.WaitGroup

	var mu sync.Mutex
	blackList := make(map[string]bool)

	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for rfc := range jobs {
				if err := downloadRFC(rfc); err != nil {
					mu.Lock()
					blackList[rfc.PathName] = true
					mu.Unlock()

					if _, ok := err.(*NotFound); ok {
						fmt.Printf("rfc does not exist %s %v\n", rfc, err)
					} else {
						fmt.Printf("failed to download %s %v\n", rfc, err)
					}
				}
			}
		}()
	}

	for _, rfc := range rfcs {
		jobs <- rfc
	}

	close(jobs)
	wg.Wait()

	if len(blackList) > 0 {
		fmt.Println("Failed to download RFCs:")
		for rfc := range blackList {
			fmt.Println(rfc)
		}
	} else {
		fmt.Println("All RFCs downloaded.")
	}

	listPath := filepath.Join(rfcDir, "rfc_list")
	f, err := os.OpenFile(listPath+".txt", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}

	defer f.Close()

	for _, rfc := range rfcs {
		if blackList[rfc.PathName] {
			continue
		}
		//rfc = strings.ReplaceAll(rfc, "/", "-")
		//if _, err := f.WriteString("rfc" + rfc + "\n"); err != nil {
		if _, err := f.WriteString(rfc.PathName + "\n"); err != nil {
			return err
		}
	}

	return nil
}

func main() {
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
		if !strings.Contains(*rfcGet, "::") {
			log.Fatal("invalid name %s must contain RFC::TITLE", *rfcGet)
		}
		split := strings.Split(*rfcGet, "::")
		rfcNumber := split[0]
		rfcTitle := split[1]
		rfc := RFC{
			Name:     rfcNumber,
			Title:    rfcTitle,
			RFC:      rfcNumber,
			Status:   "Active",
			PathName: rfcNumber + "::" + rfcTitle,
		}

		if _, err := getRfc(rfc, true); err != nil {
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
			rfc.Name = fmt.Sprintf("rfc%s", rfc.Name)
			rfc.RFC = rfc.Name
			rfc.PathName = strings.ReplaceAll(rfc.Name+"::"+title, "/", "-")
			getRfc(rfc, *rfcSave)
		}
	}
}
