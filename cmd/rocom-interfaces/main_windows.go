// rocom-interfaces lists Npcap device names without requiring game assets.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"

	"github.com/google/gopacket/pcap"
)

func main() {
	jsonOutput := flag.Bool("json", false, "Print adapters as JSON")
	flag.Parse()
	if err := pcap.LoadWinPCAP(); err != nil {
		log.Fatalf("Install Npcap from https://npcap.com/: %v", err)
	}
	devices, err := pcap.FindAllDevs()
	if err != nil {
		log.Fatal(err)
	}
	if *jsonOutput {
		type adapter struct {
			Name        string   `json:"name"`
			Description string   `json:"description"`
			Addresses   []string `json:"addresses"`
		}
		items := make([]adapter, 0, len(devices))
		for _, d := range devices {
			item := adapter{Name: d.Name, Description: d.Description, Addresses: []string{}}
			for _, a := range d.Addresses {
				item.Addresses = append(item.Addresses, a.IP.String())
			}
			items = append(items, item)
		}
		if err := json.NewEncoder(os.Stdout).Encode(items); err != nil {
			log.Fatal(err)
		}
		return
	}
	for _, d := range devices {
		fmt.Printf("%s\n  %s\n", d.Name, d.Description)
		for _, a := range d.Addresses {
			fmt.Printf("  IP: %s\n", a.IP)
		}
		fmt.Printf("  .\\rocom-capture.exe -iface '%s' -addr 127.0.0.1:4939\n\n", d.Name)
	}
	if len(devices) == 0 {
		log.Fatal("No capture adapters found; check Npcap installation and adapter permissions")
	}
}
