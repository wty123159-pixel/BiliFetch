package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const adapterVersion = "2"
const capturePrefix = "https://channels.weixin.qq.com/bilifetch-capture/"

type mediaSpec struct {
	FileFormat   string  `json:"fileFormat"`
	URL          string  `json:"url"`
	Width        int     `json:"width"`
	Height       int     `json:"height"`
	FileSize     int64   `json:"fileSize"`
	CodingFormat string  `json:"codingFormat"`
	VideoBitrate float64 `json:"videoBitrate"`
	AudioBitrate float64 `json:"audioBitrate"`
}
type capturedMedia struct {
	URL             string      `json:"url"`
	URLToken        string      `json:"urlToken"`
	DecodeKey       string      `json:"decodeKey"`
	Width           int         `json:"width"`
	Height          int         `json:"height"`
	FileSize        int64       `json:"fileSize"`
	Duration        float64     `json:"duration"`
	CoverURL        string      `json:"coverUrl"`
	EncryptedLength int         `json:"encryptedLength"`
	Spec            []mediaSpec `json:"spec"`
}
type capturedFeed struct {
	ID     string          `json:"id"`
	Title  string          `json:"title"`
	Author string          `json:"author"`
	Media  []capturedMedia `json:"media"`
}
type mediaFormat struct {
	ID              string  `json:"id"`
	URL             string  `json:"url"`
	Key             string  `json:"key,omitempty"`
	EncryptedLength int     `json:"encryptedLength,omitempty"`
	Width           int     `json:"width,omitempty"`
	Height          int     `json:"height,omitempty"`
	Size            int64   `json:"size,omitempty"`
	Codec           string  `json:"codec,omitempty"`
	Bitrate         float64 `json:"bitrate,omitempty"`
	DefaultQuality  bool    `json:"defaultQuality,omitempty"`
}
type capture struct {
	ID         string        `json:"id"`
	FeedID     string        `json:"feedId"`
	Title      string        `json:"title"`
	Author     string        `json:"author"`
	Thumbnail  string        `json:"thumbnail"`
	Duration   float64       `json:"duration"`
	CapturedAt int64         `json:"capturedAt"`
	Formats    []mediaFormat `json:"formats"`
}
type capturePreview struct {
	ID          string  `json:"id"`
	Title       string  `json:"title"`
	Author      string  `json:"author"`
	Thumbnail   string  `json:"thumbnail"`
	Duration    float64 `json:"duration"`
	SourceURL   string  `json:"sourceURL"`
	CapturedAt  int64   `json:"capturedAt"`
	FormatCount int     `json:"formatCount"`
}

func (c capture) preview() capturePreview {
	return capturePreview{c.ID, c.Title, c.Author, c.Thumbnail, c.Duration, capturePrefix + c.ID, c.CapturedAt, len(c.Formats)}
}

// A capture must point to the actual Tencent media CDN, never to localhost,
// arbitrary hosts, credentials in a URL, or a non-HTTPS resource.
func mediaURL(raw string) (*url.URL, error) {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.User != nil || u.Port() != "" {
		return nil, errors.New("媒体地址格式无效，请重新播放视频")
	}
	host := strings.ToLower(u.Hostname())
	if host != "finder.video.qq.com" && host != "finder.video.weixin.qq.com" && !strings.HasSuffix(host, ".finder.video.qq.com") {
		return nil, errors.New("未识别的视频号媒体来源，请导出诊断报告")
	}
	return u, nil
}

func normalizeCapture(f capturedFeed) (capture, error) {
	if f.ID == "" || len(f.ID) > 512 || len(f.Media) != 1 {
		return capture{}, errors.New("未取得有效作品标识或视频信息")
	}
	identity := sha256.Sum256([]byte(f.ID))
	c := capture{ID: hex.EncodeToString(identity[:16]), FeedID: f.ID, Title: strings.TrimSpace(f.Title), Author: f.Author, CapturedAt: time.Now().Unix()}
	if c.Title == "" {
		c.Title = "视频号作品"
	}
	if len(c.Title) > 4096 {
		c.Title = string([]rune(c.Title)[:1024])
	}
	seen := make(map[string]bool)
	for index, m := range f.Media {
		u, err := mediaURL(m.URL + m.URLToken)
		if err != nil {
			continue
		}
		if strings.HasSuffix(strings.ToLower(u.Path), ".m3u8") {
			continue
		}
		limit := 0
		if m.DecodeKey != "" && m.DecodeKey != "0" {
			if _, err := strconv.ParseUint(m.DecodeKey, 10, 64); err != nil {
				return capture{}, errors.New("视频还原参数无效，请更新微信后重新播放")
			}
			limit = m.EncryptedLength
			if limit == 0 {
				limit = 131072
			} // Current ISAAC64 media prefix; verified again by final FFprobe.
			if limit < 0 || limit > 4*1024*1024 {
				return capture{}, errors.New("暂不支持这种媒体还原长度")
			}
		}
		if c.Duration == 0 {
			c.Duration = m.Duration
		}
		if c.Thumbnail == "" {
			if cover, e := url.Parse(m.CoverURL); e == nil && cover.Scheme == "https" && cover.User == nil && cover.Port() == "" {
				h := strings.ToLower(cover.Hostname())
				if h == "qpic.cn" || strings.HasSuffix(h, ".qpic.cn") || h == "finder.video.qq.com" {
					c.Thumbnail = cover.String()
				}
			}
		}
		add := func(format mediaFormat) {
			if !seen[format.URL] {
				seen[format.URL] = true
				c.Formats = append(c.Formats, format)
			}
		}
		// The descriptor's dimensions and size describe the uploaded original.
		// The unqualified CDN URL can return a smaller adaptive/default encode
		// (confirmed with the live desktop client), so do not label it as the
		// original quality. Prefer the variants actually advertised by spec.
		add(mediaFormat{ID: fmt.Sprintf("media-%d", index), URL: u.String(), Key: m.DecodeKey, EncryptedLength: limit, DefaultQuality: true})
		for j, s := range m.Spec {
			if j >= 20 {
				break
			}
			source := s.URL
			if source == "" && s.FileFormat != "" {
				// Only request quality variants explicitly advertised by the player.
				// Preserve every other signed parameter and never strip watermark flags.
				variant := *u
				q := variant.Query()
				q.Set("X-snsvideoflag", s.FileFormat)
				variant.RawQuery = q.Encode()
				source = variant.String()
			}
			if _, e := mediaURL(source); e != nil {
				continue
			}
			codec := "unknown"
			switch strings.ToLower(s.CodingFormat) {
			case "h264", "avc", "avc1":
				codec = "avc1"
			case "h265", "hevc", "hev1":
				codec = "hevc"
			}
			add(mediaFormat{ID: fmt.Sprintf("media-%d-%d", index, j), URL: source, Key: m.DecodeKey, EncryptedLength: limit, Width: s.Width, Height: s.Height, Size: s.FileSize, Codec: codec, Bitrate: s.VideoBitrate + s.AudioBitrate})
		}
	}
	if len(c.Formats) == 0 {
		return capture{}, errors.New("捕获结果没有可下载的普通视频；暂不支持图集或直播")
	}
	return c, nil
}

type captureStore struct {
	mu        sync.RWMutex
	directory string
	items     map[string]capture
}

func openStore(directory string) (*captureStore, error) {
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	s := &captureStore{directory: directory, items: make(map[string]capture)}
	files, _ := filepath.Glob(filepath.Join(directory, "*.capture.json"))
	for _, file := range files {
		data, e := os.ReadFile(file)
		if e != nil || len(data) > 2*1024*1024 {
			continue
		}
		var c capture
		if json.Unmarshal(data, &c) == nil && validID(c.ID) && len(c.Formats) > 0 {
			// Upgrade captures made by adapter 1, which mistook the original
			// upload descriptor for the unqualified CDN response's quality.
			for i := range c.Formats {
				if c.Formats[i].ID == "media-0" {
					c.Formats[i].DefaultQuality = true
					c.Formats[i].Width, c.Formats[i].Height, c.Formats[i].Size = 0, 0, 0
				}
			}
			valid := true
			for _, f := range c.Formats {
				if _, e := mediaURL(f.URL); e != nil {
					valid = false
				}
				if f.EncryptedLength < 0 || f.EncryptedLength > 4*1024*1024 {
					valid = false
				}
				if f.EncryptedLength > 0 {
					if _, e := strconv.ParseUint(f.Key, 10, 64); e != nil {
						valid = false
					}
				}
			}
			if valid {
				s.items[c.ID] = c
			}
		}
	}
	return s, nil
}
func validID(id string) bool { d, e := hex.DecodeString(id); return e == nil && len(d) == 16 }
func (s *captureStore) add(c capture) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := writePrivateJSON(filepath.Join(s.directory, c.ID+".capture.json"), c); err != nil {
		return err
	}
	s.items[c.ID] = c
	return nil
}
func (s *captureStore) get(id string) (capture, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	c, ok := s.items[id]
	return c, ok
}
func (s *captureStore) previews() []capturePreview {
	s.mu.RLock()
	defer s.mu.RUnlock()
	list := make([]capturePreview, 0, len(s.items))
	for _, c := range s.items {
		list = append(list, c.preview())
	}
	sort.Slice(list, func(i, j int) bool { return list[i].CapturedAt > list[j].CapturedAt })
	return list
}
func (s *captureStore) clear() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for id := range s.items {
		if err := os.Remove(filepath.Join(s.directory, id+".capture.json")); err != nil && !os.IsNotExist(err) {
			return err
		}
		_ = os.Remove(filepath.Join(s.directory, id+".info.json"))
	}
	s.items = make(map[string]capture)
	return nil
}
func writePrivateJSON(path string, value any) error {
	data, e := json.MarshalIndent(value, "", "  ")
	if e != nil {
		return e
	}
	file, e := os.CreateTemp(filepath.Dir(path), ".bilifetch-*")
	if e != nil {
		return e
	}
	name := file.Name()
	defer os.Remove(name)
	if e = file.Chmod(0600); e == nil {
		_, e = file.Write(data)
	}
	if closeErr := file.Close(); e == nil {
		e = closeErr
	}
	if e != nil {
		return e
	}
	return os.Rename(name, path)
}

func (s *captureStore) manifest(id, base, token string) (string, error) {
	c, ok := s.get(id)
	if !ok {
		return "", errors.New("这条捕获记录已不存在，请在微信重新播放")
	}
	formats := make([]map[string]any, 0, len(c.Formats))
	for i, f := range c.Formats {
		format := map[string]any{"format_id": f.ID, "url": fmt.Sprintf("%s/media/%s/%d", base, id, i), "ext": "mp4", "protocol": "http", "vcodec": "unknown", "acodec": "unknown", "http_headers": map[string]string{"Authorization": "Bearer " + token}}
		if f.DefaultQuality {
			format["preference"] = -10
			format["format_note"] = "播放器默认画质"
		}
		if f.Width > 0 {
			format["width"] = f.Width
		}
		if f.Height > 0 {
			format["height"] = f.Height
		}
		if f.Size > 0 {
			format["filesize"] = f.Size
		}
		if f.Bitrate > 0 {
			format["tbr"] = f.Bitrate
		}
		if f.Codec != "" {
			format["vcodec"] = f.Codec
		}
		formats = append(formats, format)
	}
	info := map[string]any{"id": c.ID, "title": c.Title, "uploader": c.Author, "duration": c.Duration, "webpage_url": capturePrefix + c.ID, "extractor": "bilifetch:wechat", "extractor_key": "BiliFetchWeChat", "formats": formats}
	path := filepath.Join(s.directory, id+".info.json")
	return path, writePrivateJSON(path, info)
}
