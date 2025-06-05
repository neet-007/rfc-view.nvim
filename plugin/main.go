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

func writeToRfc(name string, body []byte) (int, error) {
	path := filepath.Join(getRfcDir(), name)
	listPath := filepath.Join(getRfcDir(), "rfc_list")
	f, err := os.Create(path + ".txt.gz")
	if err != nil {
		return 0, err
	}

	defer f.Close()
	gzWriter := gzip.NewWriter(f)
	defer gzWriter.Close()

	n, err := gzWriter.Write(body)
	if err != nil {
		return 0, err
	}

	f, err = os.OpenFile(listPath+".txt", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return 0, err
	}

	defer f.Close()

	f.WriteString(name + "\n")
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

func getRfc(rfc RFC, save bool) (int, error) {
	url := "https://www.rfc-editor.org/rfc/" + rfc.Name + ".txt"
	res, err := http.Get(url)
	if err != nil {
		return 0, err
	}
	defer res.Body.Close()

	//fmt.Printf("length %d\n", res.ContentLength)
	var buf bytes.Buffer
	_, err = io.Copy(&buf, res.Body)
	if err != nil {
		return 0, err
	}

	body := buf.Bytes()
	//fmt.Printf("Body (%d bytes): %s\n", len(body), body[:100])

	if save {
		return writeToRfc("rfc"+rfc.Name, body)
	}

	return 0, nil
}

func listRfc() {
	listPath := filepath.Join(getRfcDir(), "rfc_list") + ".txt"

	file, err := os.Open(listPath)
	if err != nil {
		log.Fatalf("failed to open file: %s", err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)

	for scanner.Scan() {
		line := scanner.Text()
		fmt.Println(line)
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

func main() {
	err := initRfc()
	if err != nil {
		log.Fatal(err)
	}

	rfcSearch := flag.String("rfc", "", "rfc name")
	rfcSave := flag.Bool("save", false, "save rfc")
	rfcList := flag.Bool("list", false, "view rfc list")
	rfcView := flag.String("view", "", "view rfc")

	flag.Parse()

	if *rfcList {
		listRfc()
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
		fmt.Printf("name %s\n", rfc.Name)
		fmt.Printf("title %s\n", rfc.Title)
		if *rfcSave {
			getRfc(rfc, *rfcSave)
		}
	}
}
