package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"strings"
)

var APIToken string
var Port string

func loadConfig() error {
	file, err := os.Open("/usr/local/etc/sing-box/api.conf")
	if err != nil {
		return err
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "TOKEN=") {
			APIToken = strings.TrimPrefix(line, "TOKEN=")
		}
		if strings.HasPrefix(line, "PORT=") {
			Port = ":" + strings.TrimPrefix(line, "PORT=")
		}
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	if APIToken == "" || Port == ":" {
		return fmt.Errorf("missing config")
	}
	return nil
}

type RequestPayload struct {
	Action   string `json:"action"`
	Username string `json:"username"`
}

func nodeActionHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if r.Header.Get("X-Node-Token") != APIToken {
		w.WriteHeader(http.StatusUnauthorized)
		json.NewEncoder(w).Encode(map[string]string{"status": "error", "message": "Unauthorized"})
		return
	}
	var payload RequestPayload
	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}

	// Gọi script bash
	cmd := exec.Command("bash", "/root/singbox-manager/modules/users.sh", "api", payload.Action, payload.Username)
	output, err := cmd.CombinedOutput()
	w.Header().Set("Content-Type", "application/json")
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(map[string]string{"status": "error", "message": strings.TrimSpace(string(output))})
		return
	}

	// Trả về thành công kèm proxy_link
	json.NewEncoder(w).Encode(map[string]string{"status": "success", "proxy_link": strings.TrimSpace(string(output))})
}

func main() {
	if err := loadConfig(); err != nil {
		fmt.Println("API Config not found or invalid. Exiting...")
		os.Exit(1)
	}
	http.HandleFunc("/api/node_action", nodeActionHandler)
	http.ListenAndServe(Port, nil)
}
