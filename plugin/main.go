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
	"math"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"unicode"
)

const (
	SCORE_GAP_LEADING       = -0.005
	SCORE_GAP_TRAILING      = -0.005
	SCORE_GAP_INNER         = -0.01
	SCORE_MATCH_CONSECUTIVE = 1.0
	SCORE_MATCH_SLASH       = 0.9
	SCORE_MATCH_WORD        = 0.8
	SCORE_MATCH_CAPITAL     = 0.7
	SCORE_MATCH_DOT         = 0.6
	MATCH_MAX_LENGTH        = 1024
)

var SCORE_MAX = math.Inf(1)
var SCORE_MIN = math.Inf(-1)

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

type RfcExists struct {
	name string
}

func newNotFound(name string) error {
	return &NotFound{name}
}

func (e *NotFound) Error() string {
	return fmt.Sprintf("not found %s", e.name)
}

func newRfcExists(name string) error {
	return &RfcExists{name}
}

func (e *RfcExists) Error() string {
	return fmt.Sprintf("rfc %s already exists", e.name)
}

var RfcDir string

func init() {
	RfcDir = getRfcDir()
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
	listPath := filepath.Join(RfcDir, "rfc_list")
	err := os.MkdirAll(RfcDir, 0755)

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
	path := filepath.Join(RfcDir, name)
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
		listPath := filepath.Join(RfcDir, "rfc_list")
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

func SearchRFCs(query string, offset int) (*RFCResponse, error) {
	encodedQuery := url.QueryEscape(query)
	apiURL := fmt.Sprintf(
		"https://datatracker.ietf.org/api/v1/doc/document/?format=json&type=rfc&title__icontains=%s&offset=%d",
		encodedQuery,
		offset,
	)

	resp, err := http.Get(apiURL)
	defer resp.Body.Close()
	if err != nil {
		return nil, fmt.Errorf("HTTP request failed: %v", err)
	}

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
	listPath := filepath.Join(RfcDir, "rfc_list")

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

func GetRfc(rfc RFC, save bool) (int, error) {
	if !strings.Contains(rfc.PathName, "::") {
		return 0, fmt.Errorf("invalid path name %v must contain RFC::TITLE", rfc)
	}

	ok, err := checkRfc(rfc.PathName)
	if err != nil {
		return 0, err
	}

	if ok {
		fmt.Printf("rfc %s already exists\n", rfc.PathName)
		return 0, nil
	}

	url := "https://www.rfc-editor.org/rfc/" + rfc.RFC + ".txt"
	res, err := http.Get(url)
	defer res.Body.Close()
	if err != nil {
		return 0, err
	}

	if save {
		n, err := writeToRfc(rfc.PathName, res.Body, true)
		if err != nil {
			return 0, err
		}
		return n, nil
	}

	return 0, nil
}

func buildRfcListFromDir() error {
	rfcListPath := filepath.Join(RfcDir, "rfc_list")

	f, err := os.Open(RfcDir)
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
	i = slices.Index(entries, RfcDir)
	if i != -1 {
		slices.Delete(entries, i, i+1)
	}

	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		if entry == "." || entry == ".." || entry == "" {
			continue
		}

		names = append(names, strings.TrimSuffix(entry, ".txt.gz"))
	}

	f, err = os.OpenFile(rfcListPath+"_temp.txt", os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}

	defer f.Close()

	w := bufio.NewWriter(f)
	defer w.Flush()

	for _, name := range names {
		if _, err := w.WriteString(name); err != nil {
			return err
		}
		if err := w.WriteByte('\n'); err != nil {
			return err
		}
	}

	err = os.Rename(rfcListPath+"_temp.txt", rfcListPath+".txt")
	if err != nil {
		return err
	}

	return nil
}

func preComputeBonus(s string) []float64 {
	bonus := make([]float64, len(s))
	lastChar := filepath.Separator

	for i := 0; i < len(s); i++ {
		thisChar := s[i]

		switch {
		case lastChar == filepath.Separator:
			bonus[i] = SCORE_MATCH_SLASH
		case lastChar == '_' || lastChar == '-' || lastChar == ' ':
			bonus[i] = SCORE_MATCH_WORD
		case lastChar == '.':
			bonus[i] = SCORE_MATCH_DOT
		case unicode.IsLower(lastChar) && unicode.IsUpper(rune(thisChar)):
			bonus[i] = SCORE_MATCH_CAPITAL
		}

		lastChar = rune(thisChar)
	}

	return bonus
}

func compute(s1 string, s2 string, D [][]float64, M [][]float64) {
	bonus := preComputeBonus(s2)

	n := len(s1)
	m := len(s2)
	s1Lower := strings.ToLower(s1)
	s2Lower := strings.ToLower(s2)

	for i := 0; i < n; i++ {
		prevScore := SCORE_MIN
		gap := SCORE_GAP_INNER
		if i == n-1 {
			gap = SCORE_GAP_TRAILING
		}
		s1Char := s1Lower[i]

		for j := 0; j < m; j++ {
			if s1Char == s2Lower[j] {
				score := SCORE_MIN
				if i == 0 {
					score = ((float64(j)) * SCORE_GAP_LEADING) + bonus[j]
				} else if j > 0 {
					a := M[i-1][j-1] + bonus[j]
					b := D[i-1][j-1] + SCORE_MATCH_CONSECUTIVE
					score = max(a, b)
				}
				D[i][j] = score
				prevScore = max(score, prevScore+gap)
				M[i][j] = prevScore
			} else {
				D[i][j] = SCORE_MIN
				prevScore += gap
				M[i][j] = prevScore
			}
		}
	}
}

func Fzy(filter string, list []string) []string {
	n := len(filter)

	ch := make(chan struct {
		score float64
		s     string
	}, len(list))
	tokens := make(chan struct{}, 20)

	wg := sync.WaitGroup{}
	for _, s2 := range list {
		wg.Add(1)
		go func(s2 string) {
			tokens <- struct{}{}
			defer func() {
				<-tokens
				wg.Done()
			}()
			m := len(s2)

			if n == 0 || m == 0 || n > MATCH_MAX_LENGTH || m > MATCH_MAX_LENGTH {
				ch <- struct {
					score float64
					s     string
				}{SCORE_MIN, s2}
				return
			}

			if n == m {
				ch <- struct {
					score float64
					s     string
				}{SCORE_MAX, s2}
				return
			}

			D := make([][]float64, n)
			M := make([][]float64, n)

			for i := 0; i < n; i++ {
				D[i] = make([]float64, m)
				M[i] = make([]float64, m)
			}

			compute(filter, s2, D, M)

			ch <- struct {
				score float64
				s     string
			}{M[n-1][m-1], s2}
		}(s2)
	}

	wg.Wait()
	close(ch)

	scoreList := make([]struct {
		score float64
		s     string
	}, 0, len(list))

	for tempStruct := range ch {
		scoreList = append(scoreList, struct {
			score float64
			s     string
		}{tempStruct.score, tempStruct.s})
	}

	slices.SortFunc(scoreList, func(a, b struct {
		score float64
		s     string
	}) int {
		if a.score == b.score {
			return 0
		}
		if a.score > b.score {
			return -1
		}
		return 1
	})

	for i := len(scoreList) - 1; i >= 0; i-- {
		if scoreList[i].score == SCORE_MIN {
			scoreList = slices.Delete(scoreList, i, i+1)
		}
	}

	retList := make([]string, 0, len(scoreList))
	for _, score := range scoreList {
		retList = append(retList, score.s)
	}

	return retList
}

func ListRfc(filter string) {
	listPath := filepath.Join(RfcDir, "rfc_list") + ".txt"

	file, err := os.Open(listPath)
	if err != nil {
		log.Fatalf("failed to open file: %s", err)
	}
	defer file.Close()

	list := make([]string, 0)
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		list = append(list, line)
	}

	if err := scanner.Err(); err != nil {
		log.Fatalf("error reading file: %s", err)
	}

	var res []string
	if filter == "" {
		res = list
	} else {
		res = Fzy(filter, list)
	}

	fmt.Printf("Total line count: %d\n", len(res))
	for _, line := range res {
		fmt.Println(line)
	}
}

func ViewRfc(name string) error {
	path := filepath.Join(RfcDir, name)
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

func DeleteRfc(name string) error {
	path := filepath.Join(RfcDir, name)
	err := os.Remove(path + ".txt.gz")
	if err != nil {
		if !os.IsNotExist(err) {
			return err
		}
	}

	rfcListPath := filepath.Join(RfcDir, "rfc_list") + ".txt"
	tempRfcListPath := filepath.Join(RfcDir, "rfc_list_temp") + ".txt"

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

func DeleteAllRfcs() error {
	rfcListPath := filepath.Join(RfcDir, "rfc_list") + ".txt"

	f, err := os.Open(RfcDir)
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
	i = slices.Index(entries, RfcDir)
	if i != -1 {
		slices.Delete(entries, i, i+1)
	}

	n := sync.WaitGroup{}
	ch := make(chan struct{}, 20)
	for _, entry := range entries {
		if entry == "." || entry == ".." || entry == "" {
			continue
		}

		fullPath := filepath.Join(RfcDir, entry)

		n.Add(1)
		go func(fullPath string) {
			ch <- struct{}{}
			defer func() {
				<-ch
				n.Done()
			}()

			if err := os.Remove(fullPath); err != nil {
				log.Printf("error deleting %s: %v", fullPath, err)
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
	defer resp.Body.Close()
	if err != nil {
		return nil, err
	}

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
	url := fmt.Sprintf("%s/%s", "https://www.rfc-editor.org/rfc", rfc.Name+".txt")

	ok, err := checkRfc(rfc.PathName)
	if err != nil {
		return err
	}

	if ok {
		return newRfcExists(rfc.PathName)
	}

	resp, err := http.Get(url)
	defer resp.Body.Close()
	if resp.StatusCode == 404 {
		return newNotFound(rfc.RFC)
	} else if err != nil || resp.StatusCode != 200 {
		return fmt.Errorf("Failed to fetch RFC %s: %v (%d)\n", rfc, err, resp.StatusCode)
	}

	_, err = writeToRfc(rfc.PathName, resp.Body, false)
	if err != nil {
		return err
	}

	return nil
}

// TODO: consider what happens when it crashes
func RfcDownloadAll() error {
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
					} else if _, ok := err.(*RfcExists); ok {
						fmt.Printf("rfc already exists %s %v\n", rfc, err)
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

	listPath := filepath.Join(RfcDir, "rfc_list")
	f, err := os.OpenFile(listPath+".txt", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}

	defer f.Close()

	w := bufio.NewWriter(f)
	defer w.Flush()

	for _, rfc := range rfcs {
		if blackList[rfc.PathName] {
			continue
		}

		if _, err := w.WriteString(rfc.PathName); err != nil {
			return err
		}
		if err := w.WriteByte('\n'); err != nil {
			return err
		}
	}

	return nil
}

func main() {
	rfcSearch := flag.String("rfc", "", "rfc name")
	rfcSearchOffset := flag.Int("offset", 0, "rfc search offset")
	rfcSave := flag.Bool("save", false, "save rfc")
	rfcList := flag.Bool("list", false, "view rfc list")
	rfcDeleteAll := flag.Bool("delete-all", false, "delete all rfcs")
	rfcListFilter := flag.String("filter", "", "filter rfc list")
	rfcView := flag.String("view", "", "view rfc")
	rfcGet := flag.String("get", "", "get rfc")
	rfcDelete := flag.String("delete", "", "delete rfc")
	rfcDownloadAllRfc := flag.Bool("download-all", false, "download all rfcs")

	flag.Parse()

	if *rfcSearchOffset < 0 {
		log.Fatal("offset must be >= 0")
	}

	if *rfcSearchOffset > 0 && *rfcSearch == "" {
		log.Fatal("must provide rfc")
	}

	if *rfcDownloadAllRfc {
		if err := RfcDownloadAll(); err != nil {
			log.Fatal(err)
		}

		return
	}

	if *rfcList {
		ListRfc(*rfcListFilter)
		return
	}

	if *rfcDeleteAll {
		if err := DeleteAllRfcs(); err != nil {
			log.Fatal(err)
		}

		return
	}

	if *rfcDelete != "" {
		if err := DeleteRfc(*rfcDelete); err != nil {
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

		if _, err := GetRfc(rfc, true); err != nil {
			log.Fatal(err)
		}

		if err := ViewRfc(*rfcGet); err != nil {
			log.Fatal(err)
		}

		return
	}

	if *rfcView != "" {
		if err := ViewRfc(*rfcView); err != nil {
			log.Fatal(err)
		}

		return
	}

	if *rfcSearch == "" {
		log.Fatal("must provide rfc")
	}

	rfcs, err := SearchRFCs(*rfcSearch, *rfcSearchOffset)
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
			GetRfc(rfc, *rfcSave)
		}
	}
}
